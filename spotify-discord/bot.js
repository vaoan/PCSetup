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

const TOKEN = process.env.DISCORD_BOT_TOKEN;
const GUILD_ID = process.env.DISCORD_GUILD_ID;
const DEFAULT_CHANNEL_ID = process.env.DISCORD_VOICE_CHANNEL_ID;
const FIFO = process.env.SPOTIFY_FIFO || '/tmp/spotify-discord.fifo';
const PIPE_RATE = process.env.SPOTIFY_PIPE_RATE || '44100';

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
  ffmpeg = spawn('ffmpeg', [
    '-hide_banner', '-loglevel', 'error',
    '-f', 's16le', '-ar', PIPE_RATE, '-ac', '2',
    '-i', FIFO,
    '-f', 's16le', '-ar', '48000', '-ac', '2',
    'pipe:1',
  ], { stdio: ['ignore', 'pipe', 'inherit'] });

  ffmpeg.on('exit', (code, signal) => {
    log(`ffmpeg exited (code=${code}, signal=${signal}); restarting in 1s`);
    setTimeout(startStream, 1000);
  });

  const resource = createAudioResource(ffmpeg.stdout, { inputType: StreamType.Raw });
  player.play(resource);
  log('streaming pipe → voice');
}

player.on('error', (err) => console.error('[bot] player error:', err.message));
player.on(AudioPlayerStatus.Idle, () => {
  // Resource ended (ffmpeg died); startStream's exit handler will respawn it.
  log('player idle');
});

// ── Voice connection ──────────────────────────────────────────────────────────
let connection = null;

async function connectTo(guild, channelId) {
  connection = joinVoiceChannel({
    channelId,
    guildId: guild.id,
    adapterCreator: guild.voiceAdapterCreator,
    selfDeaf: true,
    selfMute: false,
    debug: true,
  });

  connection.on('stateChange', (oldS, newS) => {
    const extra = newS.status === 'disconnected'
      ? ` (reason=${newS.reason}${newS.closeCode !== undefined ? ` closeCode=${newS.closeCode}` : ''})`
      : '';
    log(`voice: ${oldS.status} -> ${newS.status}${extra}`);
    // Attach to the underlying networking layer to see UDP/websocket detail.
    const net = newS.networking;
    if (net && !net.__dbgHooked) {
      net.__dbgHooked = true;
      net.on('debug', (m) => log('net: ' + String(m).slice(0, 400)));
      net.on('error', (e) => log('neterr: ' + (e && e.message ? e.message : e)));
      net.on('stateChange', (o, n) => log(`net-state: ${o.code} -> ${n.code}`));
    }
  });
  connection.on('error', (err) => console.error('[bot] voice connection error:', err.message));
  connection.on('debug', (m) => log('voicedbg: ' + String(m).slice(0, 300)));

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
}

function leaveVoice() {
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

// ── Discord client + slash commands ───────────────────────────────────────────
const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildVoiceStates],
});

const commands = [
  new SlashCommandBuilder().setName('join').setDescription('Bring the Spotify speaker into your current voice channel'),
  new SlashCommandBuilder().setName('leave').setDescription('Disconnect the Spotify speaker'),
  new SlashCommandBuilder().setName('reconnect').setDescription('Restart the audio stream'),
  new SlashCommandBuilder().setName('status').setDescription('Show bridge status'),
].map((c) => c.toJSON());

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
  if (!interaction.isChatInputCommand()) return;

  if (interaction.commandName === 'join') {
    const channel = interaction.member?.voice?.channel;
    if (!channel) {
      return interaction.reply({ content: 'Join a voice channel first.', ephemeral: true });
    }
    await interaction.deferReply({ ephemeral: true });
    try {
      leaveVoice();
      await connectTo(interaction.guild, channel.id);
      await interaction.editReply(`🎵 Joined **${channel.name}**. Pick **Discord** in your Spotify Connect menu.`);
    } catch (err) {
      await interaction.editReply(`Failed to join: ${err.message}`);
    }
    return;
  }

  if (interaction.commandName === 'leave') {
    leaveVoice();
    return interaction.reply({ content: '👋 Disconnected.', ephemeral: true });
  }

  if (interaction.commandName === 'reconnect') {
    if (!connection) {
      return interaction.reply({ content: 'Not connected. Use /join first.', ephemeral: true });
    }
    startStream();
    return interaction.reply({ content: '🔄 Restarted the audio stream.', ephemeral: true });
  }

  if (interaction.commandName === 'status') {
    const state = connection ? connection.state.status : 'not connected';
    const ff = ffmpeg ? 'running' : 'stopped';
    return interaction.reply({
      content: `Voice: **${state}**\nffmpeg: **${ff}**\nFIFO: \`${FIFO}\` @ ${PIPE_RATE} Hz`,
      ephemeral: true,
    });
  }
});

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
