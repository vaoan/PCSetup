// Spotify → Discord voice bridge.
//
// go-librespot exposes a Spotify Connect device named "Discord" and writes raw
// PCM into a named pipe (FIFO). This bot reads that FIFO, transcodes 44.1 kHz →
// 48 kHz with ffmpeg, and streams it into a Discord voice channel.
//
// Control playback entirely from your normal Spotify app — pick the "Discord"
// device from the Connect menu. This bot is just the speaker.
//
// Env (see .env.example):
//   DISCORD_BOT_TOKEN          - bot token
//   DISCORD_GUILD_ID           - server (guild) id
//   DISCORD_VOICE_CHANNEL_ID   - voice channel to auto-join on startup
//   SPOTIFY_FIFO               - path to the go-librespot pipe (default /tmp/spotify-discord.fifo)
//   SPOTIFY_PIPE_RATE          - sample rate go-librespot writes (default 44100)

const fs = require('node:fs');
const { spawn } = require('node:child_process');
const {
  Client,
  GatewayIntentBits,
  Events,
  REST,
  Routes,
  SlashCommandBuilder,
} = require('discord.js');
const {
  joinVoiceChannel,
  createAudioPlayer,
  createAudioResource,
  StreamType,
  AudioPlayerStatus,
  NoSubscriberBehavior,
  VoiceConnectionStatus,
  entersState,
} = require('@discordjs/voice');
const dj = require('./dj');
const accounts = require('./accounts');

const TOKEN = process.env.DISCORD_BOT_TOKEN;
const GUILD_ID = process.env.DISCORD_GUILD_ID;
const DEFAULT_CHANNEL_ID = process.env.DISCORD_VOICE_CHANNEL_ID;
const FIFO = process.env.SPOTIFY_FIFO || '/tmp/spotify-discord.fifo';
const PIPE_RATE = process.env.SPOTIFY_PIPE_RATE || '44100';

// ── Audio quality / resilience tuning ─────────────────────────────────────────
// Opus bitrate in bits/s. Discord voice defaults low (~64k); 96k is safe on any
// server, higher if the server is boosted (128/256/384k at tiers 1/2/3).
const OPUS_BITRATE = parseInt(process.env.SPOTIFY_OPUS_BITRATE || '128000', 10);
// Inband Forward Error Correction: Opus embeds recovery data so brief packet loss
// doesn't cause audible dropouts. The main reliability win.
const OPUS_FEC = (process.env.SPOTIFY_OPUS_FEC || '1') !== '0';
// Expected packet-loss percentage (0..1) FEC optimises for.
const OPUS_PLP = parseFloat(process.env.SPOTIFY_OPUS_PLP || '0.05');
// ffmpeg resampler for 44.1→48 kHz. 'soxr' = high quality; set empty to use the
// default resampler if a build lacks libsoxr.
const RESAMPLER = process.env.hasOwnProperty('SPOTIFY_RESAMPLER') ? process.env.SPOTIFY_RESAMPLER : 'soxr';

if (!TOKEN) {
  console.error('[bot] DISCORD_BOT_TOKEN is not set. Edit /etc/spotify-discord.env');
  process.exit(1);
}

function log(...args) {
  console.log('[bot]', ...args);
}

// ── Keep the FIFO alive ───────────────────────────────────────────────────────
// go-librespot opens/closes its writer end between tracks and when paused. If we
// let ffmpeg be the only handle, it hits EOF and exits every time playback stops.
// Holding an idle O_RDWR fd open guarantees the pipe always has a writer, so the
// reader never EOFs. We never read or write through this fd.
let keepAliveFd = null;
function ensureFifoKeepAlive() {
  if (!fs.existsSync(FIFO)) {
    console.error(`[bot] FIFO ${FIFO} does not exist. Did setup run mkfifo + start go-librespot?`);
    process.exit(1);
  }
  if (keepAliveFd === null) {
    keepAliveFd = fs.openSync(FIFO, fs.constants.O_RDWR);
    log(`FIFO keep-alive handle open on ${FIFO}`);
  }
}

// ── Audio pipeline ────────────────────────────────────────────────────────────
const player = createAudioPlayer({
  behaviors: { noSubscriber: NoSubscriberBehavior.Play },
});

let ffmpeg = null;

function startStream() {
  ensureFifoKeepAlive();

  if (ffmpeg) {
    ffmpeg.removeAllListeners('exit');
    try { ffmpeg.kill('SIGKILL'); } catch { /* ignore */ }
    ffmpeg = null;
  }

  // Read the raw pipe (s16le @ PIPE_RATE stereo) → emit s16le @ 48k stereo,
  // which @discordjs/voice's opus encoder consumes directly (StreamType.Raw).
  const ffArgs = ['-hide_banner', '-loglevel', 'error', '-f', 's16le', '-ar', PIPE_RATE, '-ac', '2', '-i', FIFO];
  if (RESAMPLER) ffArgs.push('-af', `aresample=resampler=${RESAMPLER}:precision=28`);
  ffArgs.push('-f', 's16le', '-ar', '48000', '-ac', '2', 'pipe:1');
  ffmpeg = spawn('ffmpeg', ffArgs, { stdio: ['ignore', 'pipe', 'inherit'] });

  ffmpeg.on('exit', (code, signal) => {
    log(`ffmpeg exited (code=${code}, signal=${signal}); restarting in 1s`);
    setTimeout(startStream, 1000);
  });

  const resource = createAudioResource(ffmpeg.stdout, { inputType: StreamType.Raw });
  tuneEncoder(resource);
  player.play(resource);
  log(`streaming pipe → voice (bitrate=${OPUS_BITRATE}, fec=${OPUS_FEC}, resampler=${RESAMPLER || 'default'})`);
}

// Tune the Opus encoder for music quality + packet-loss resilience. Guarded so
// it degrades gracefully if the encoder API differs.
function tuneEncoder(resource) {
  try {
    const enc = resource.encoder;
    if (!enc) return;
    const bitrate = channelBitrate ? Math.min(OPUS_BITRATE, channelBitrate) : OPUS_BITRATE;
    if (typeof enc.setBitrate === 'function') enc.setBitrate(bitrate);
    if (OPUS_FEC && typeof enc.setFEC === 'function') enc.setFEC(true);
    if (typeof enc.setPLP === 'function') enc.setPLP(OPUS_PLP);
  } catch (err) {
    log('encoder tuning skipped: ' + err.message);
  }
}

player.on('error', (err) => console.error('[bot] player error:', err.message));
player.on(AudioPlayerStatus.Idle, () => {
  // Resource ended (ffmpeg died); startStream's exit handler will respawn it.
  log('player idle');
});

// ── Voice connection ──────────────────────────────────────────────────────────
let connection = null;
let channelBitrate = null; // the target channel's max bitrate (caps OPUS_BITRATE)
const VOICE_DEBUG = process.env.DEBUG_VOICE === '1'; // verbose voice/UDP logging (off by default)
// Auto-leave when no humans are in the channel (0 disables). Grace period avoids
// leaving on brief disconnects.
const EMPTY_DISCONNECT_MS = Math.max(0, parseInt(process.env.EMPTY_DISCONNECT_SECONDS || '90', 10)) * 1000;
let emptyTimer = null;

async function connectTo(guild, channelId) {
  // Cap the encoder to the channel's own bitrate limit (96k unboosted, more when
  // the server is boosted) so we never exceed it.
  try {
    const ch = await guild.channels.fetch(channelId);
    channelBitrate = ch && ch.bitrate ? ch.bitrate : null;
  } catch { channelBitrate = null; }

  connection = joinVoiceChannel({
    channelId,
    guildId: guild.id,
    adapterCreator: guild.voiceAdapterCreator,
    selfDeaf: true,
    selfMute: false,
    debug: VOICE_DEBUG,
  });

  connection.on('stateChange', (oldS, newS) => {
    const extra = newS.status === 'disconnected'
      ? ` (reason=${newS.reason}${newS.closeCode !== undefined ? ` closeCode=${newS.closeCode}` : ''})`
      : '';
    log(`voice: ${oldS.status} -> ${newS.status}${extra}`);
    if (!VOICE_DEBUG) return;
    // Verbose UDP/websocket detail (enable with DEBUG_VOICE=1).
    const net = newS.networking;
    if (net && !net.__dbgHooked) {
      net.__dbgHooked = true;
      net.on('debug', (m) => log('net: ' + String(m).slice(0, 400)));
      net.on('error', (e) => log('neterr: ' + (e && e.message ? e.message : e)));
      net.on('stateChange', (o, n) => log(`net-state: ${o.code} -> ${n.code}`));
    }
  });
  connection.on('error', (err) => console.error('[bot] voice connection error:', err.message));
  if (VOICE_DEBUG) connection.on('debug', (m) => log('voicedbg: ' + String(m).slice(0, 300)));

  connection.on(VoiceConnectionStatus.Disconnected, async () => {
    try {
      await Promise.race([
        entersState(connection, VoiceConnectionStatus.Signalling, 5000),
        entersState(connection, VoiceConnectionStatus.Connecting, 5000),
      ]);
      // Transient move/reconnect — let it recover.
    } catch {
      log('voice disconnected; tearing down');
      try { connection.destroy(); } catch { /* ignore */ }
      connection = null;
    }
  });

  await entersState(connection, VoiceConnectionStatus.Ready, 20000);
  connection.subscribe(player);
  startStream();
  log(`connected to voice channel ${channelId}`);
  checkListeners(); // handle joining an already-empty channel
}

function leaveVoice() {
  if (emptyTimer) { clearTimeout(emptyTimer); emptyTimer = null; }
  if (connection) {
    try { connection.destroy(); } catch { /* ignore */ }
    connection = null;
  }
  if (ffmpeg) {
    ffmpeg.removeAllListeners('exit');
    try { ffmpeg.kill('SIGKILL'); } catch { /* ignore */ }
    ffmpeg = null;
  }
}

// ── Auto-leave when only bots remain ──────────────────────────────────────────
// Counts real humans in the bot's channel — every bot (this one, the TTS bot,
// other music bots) has user.bot === true and is excluded. If zero humans remain
// past the grace period, disconnect and pause playback.
function humanListeners() {
  if (!connection || !connection.joinConfig) return -1;
  const guild = client.guilds.cache.get(connection.joinConfig.guildId);
  const channel = guild && guild.channels.cache.get(connection.joinConfig.channelId);
  if (!channel || !channel.members) return -1;
  return channel.members.filter((m) => !m.user?.bot).size;
}

function checkListeners() {
  const humans = humanListeners();
  if (humans === -1) return; // not connected
  if (humans === 0) {
    if (!emptyTimer && EMPTY_DISCONNECT_MS > 0) {
      log(`no human listeners — leaving in ${EMPTY_DISCONNECT_MS / 1000}s unless someone joins`);
      emptyTimer = setTimeout(async () => {
        emptyTimer = null;
        if (humanListeners() === 0) {
          log('still only bots — disconnecting and pausing playback');
          try { await fetch('http://127.0.0.1:3678/player/pause', { method: 'POST' }); } catch { /* ignore */ }
          leaveVoice();
        }
      }, EMPTY_DISCONNECT_MS);
    }
  } else if (emptyTimer) {
    clearTimeout(emptyTimer);
    emptyTimer = null;
  }
}

// ── Discord client + slash commands ───────────────────────────────────────────
const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildVoiceStates],
});

// Voice helper the DJ engine uses to pull the bot into the caller's channel.
async function ensureVoiceForInteraction(ix) {
  const channel = ix.member?.voice?.channel;
  if (!channel) return { error: 'Join a voice channel first, then try again.' };
  const currentId = connection?.joinConfig?.channelId || null;
  if (!connection || currentId !== channel.id) {
    leaveVoice();
    await connectTo(ix.guild, channel.id);
  }
  return { channelName: channel.name };
}
const djEngine = dj.createDJ({ ensureVoiceForInteraction, leaveVoice });

const commands = [
  ...dj.SLASH_COMMANDS,
  ...accounts.SLASH_COMMANDS,
  ...[
    new SlashCommandBuilder().setName('leave').setDescription('Disconnect the bot from voice'),
    new SlashCommandBuilder().setName('reconnect').setDescription('Restart the audio stream'),
    new SlashCommandBuilder().setName('status').setDescription('Show bridge status'),
  ].map((c) => c.toJSON()),
];

async function registerCommands(appId) {
  const rest = new REST({ version: '10' }).setToken(TOKEN);
  if (GUILD_ID) {
    await rest.put(Routes.applicationGuildCommands(appId, GUILD_ID), { body: commands });
    log(`registered ${commands.length} guild slash commands`);
  } else {
    await rest.put(Routes.applicationCommands(appId), { body: commands });
    log(`registered ${commands.length} global slash commands`);
  }
}

client.once(Events.ClientReady, async (c) => {
  log(`logged in as ${c.user.tag}`);
  // Hold the FIFO open from startup so go-librespot always has a reader and
  // never fails playback with ENXIO ("no such device or address"), even before
  // the bot has joined a voice channel.
  try { ensureFifoKeepAlive(); } catch (err) { console.error('[bot] fifo keep-alive:', err.message); }
  try { accounts.init(); } catch (err) { console.error('[bot] accounts init:', err.message); }
  try {
    await registerCommands(c.user.id);
  } catch (err) {
    console.error('[bot] failed to register commands:', err.message);
  }

  // Dump voice channels from the gateway cache (REST /channels can 40333).
  if (GUILD_ID) {
    try {
      const guild = await client.guilds.fetch(GUILD_ID);
      const chans = await guild.channels.fetch();
      chans.filter((c) => c && c.type === 2).forEach((c) => log(`VOICECHAN ${c.name} id=${c.id}`));
    } catch (err) {
      log('voice channel dump failed: ' + err.message);
    }
  }

  if (GUILD_ID && DEFAULT_CHANNEL_ID) {
    try {
      const guild = await client.guilds.fetch(GUILD_ID);
      await connectTo(guild, DEFAULT_CHANNEL_ID);
    } catch (err) {
      console.error('[bot] auto-join failed:', err.message);
    }
  } else {
    log('no DISCORD_VOICE_CHANNEL_ID set; use /join in a voice channel');
  }
});

client.on(Events.InteractionCreate, async (interaction) => {
  // Player card buttons (▶️/⏸️ ⏭️ ⏹️ 👋).
  if (interaction.isButton()) { try { await djEngine.handleButton(interaction); } catch (e) { log('button error: ' + e.message); } return; }
  if (!interaction.isChatInputCommand()) return;

  // DJ engine handles all music commands (play, radio, summon, queue, …).
  if (await djEngine.handleInteraction(interaction)) return;
  // Account switching (login/logincode/resetaccount/account).
  if (await accounts.handleInteraction(interaction)) return;

  if (interaction.commandName === 'leave') {
    leaveVoice();
    return interaction.reply({ content: '👋 Disconnected.', ephemeral: true });
  }

  if (interaction.commandName === 'reconnect') {
    if (!connection) {
      return interaction.reply({ content: 'Not connected. Use /summon in a voice channel first.', ephemeral: true });
    }
    startStream();
    return interaction.reply({ content: '🔄 Restarted the audio stream.', ephemeral: true });
  }

  if (interaction.commandName === 'status') {
    const state = connection ? connection.state.status : 'not connected';
    const ff = ffmpeg ? 'running' : 'stopped';
    return interaction.reply({
      content: `Voice: **${state}**\nffmpeg: **${ff}**\nsearch: **${dj.SEARCH_ENABLED ? 'on' : 'off (links only)'}**`,
      ephemeral: true,
    });
  }
});

// Re-evaluate whenever anyone joins/leaves/moves voice channels.
client.on(Events.VoiceStateUpdate, () => { try { checkListeners(); } catch (e) { log('listener check:', e.message); } });

function shutdown() {
  log('shutting down');
  leaveVoice();
  if (keepAliveFd !== null) { try { fs.closeSync(keepAliveFd); } catch { /* ignore */ } }
  client.destroy();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

client.login(TOKEN);
