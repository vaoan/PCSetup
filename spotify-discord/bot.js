// Spotify → Discord voice bridge.
//
// go-librespot exposes a Spotify Connect device named "Discord" and writes raw
// PCM into a named pipe (FIFO). This bot reads that FIFO, transcodes 44.1 kHz →
// 48 kHz with ffmpeg, and streams it into a Discord voice channel.
//
// Control playback entirely from your normal Spotify app — pick the "Discord"
// device from the Connect menu. This bot is just the speaker.
//
// YouTube tracks queued with /play take a second path (youtube.js): yt-dlp →
// ffmpeg → the same audio player, with the FIFO transcoder stopped for the
// length of the track and restarted when it ends.
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
const youtube = require('./youtube');

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

/**
 * Log a line to the journal, prefixed so `journalctl` output is greppable per module.
 *
 * @param args - Values forwarded to `console.log`.
 */
function log(...args) {
  console.log('[bot]', ...args);
}

// ── Keep the FIFO alive ───────────────────────────────────────────────────────
// go-librespot opens/closes its writer end between tracks and when paused. If we
// let ffmpeg be the only handle, it hits EOF and exits every time playback stops.
// Holding an idle O_RDWR fd open guarantees the pipe always has a writer, so the
// reader never EOFs. We never read or write through this fd.
let keepAliveFd = null;

/**
 * Hold an idle `O_RDWR` descriptor open on the FIFO so it always has a writer.
 *
 * go-librespot opens and closes its writer end between tracks and on pause. If
 * ffmpeg were the only handle, the pipe would hit EOF and ffmpeg would exit
 * every time playback stopped. This descriptor is never read from or written
 * to — it exists purely to keep the pipe from EOF-ing. **Do not "clean up" this
 * seemingly unused descriptor.**
 *
 * Exits the process if the FIFO is missing, since nothing downstream can work
 * without it and a clear startup error beats a silent no-audio bridge.
 *
 * @failureMode SD-007 This is the entire mitigation for the FIFO EOF failure.
 */
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

/**
 * (Re)start the ffmpeg transcode from the FIFO into the Discord audio player.
 *
 * Reads raw `s16le` at the pipe's native rate and emits `s16le` at 48 kHz,
 * which `@discordjs/voice` consumes directly as {@link StreamType.Raw}. Any
 * existing ffmpeg is killed first, with its `exit` listener removed so the
 * teardown does not trigger the respawn handler and race a second instance.
 *
 * ffmpeg exiting is normal and self-healing: the `exit` handler respawns it
 * after 1s.
 *
 * @failureMode SD-007 Calls {@link ensureFifoKeepAlive} first; without that the
 * respawn loop would fire on every pause.
 */
function startStream() {
  ensureFifoKeepAlive();
  // A YouTube track owns the player; the respawn timer below must not steal it back.
  if (external) return;

  stopFifoStream();

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

/**
 * Kill the FIFO transcoder without triggering its respawn.
 *
 * The `exit` listener is removed first, so a deliberate stop does not schedule
 * the 1s restart in {@link startStream}.
 */
function stopFifoStream() {
  if (!ffmpeg) return;
  ffmpeg.removeAllListeners('exit');
  try { ffmpeg.kill('SIGKILL'); } catch { /* ignore */ }
  ffmpeg = null;
}

// ── Second audio source: YouTube ──────────────────────────────────────────────
// While a YouTube track plays, `external` holds its stream and the FIFO
// transcoder is stopped. go-librespot is paused by dj.js before this starts,
// so nothing is written into the pipe meanwhile (the keep-alive fd still holds
// it open, so go-librespot never sees ENXIO).
let external = null;     // { handle, resource, onEnd }
let externalVolume = 1;  // 0..1, follows /volume

/**
 * Play a YouTube track through the voice player in place of the FIFO.
 *
 * Replacing a previous YouTube track stops it without calling its `onEnd`, so
 * a skip never double-advances the queue.
 *
 * @param track - A YouTube track from `youtube.resolveYouTube`.
 * @param onEnd - Called once with `{ ok, error? }` when the track finishes on
 * its own (not when it is stopped or replaced).
 * @param volume - Starting volume 0..1, matched to go-librespot's.
 */
function playExternal(track, onEnd, volume) {
  if (typeof volume === 'number' && volume >= 0) externalVolume = Math.min(1, volume);
  stopFifoStream();
  if (external) { const old = external; external = null; old.handle.stop(); }
  const handle = youtube.startYouTubeStream(track);
  const resource = createAudioResource(handle.stdout, { inputType: StreamType.Raw, inlineVolume: true });
  try { resource.volume?.setVolume(externalVolume); } catch { /* ignore */ }
  tuneEncoder(resource);
  external = { handle, resource, onEnd };
  player.play(resource);
}

/**
 * Stop the YouTube track, if any, and hand the player back to the FIFO.
 *
 * Does not call the track's `onEnd`: stopping is a decision, not an ending.
 *
 * @param opts - `{ resumePipe }` — restart the FIFO transcoder (default true,
 * when connected).
 */
function stopExternal({ resumePipe = true } = {}) {
  if (!external) return;
  const old = external;
  external = null;
  old.handle.stop();
  if (resumePipe && connection) startStream();
}

/**
 * The YouTube controls `dj.js` drives, injected so the audio path stays here.
 */
const externalAudio = {
  play: playExternal,
  stop: () => stopExternal(),
  active: () => external !== null,
  paused: () => external !== null && player.state.status === AudioPlayerStatus.Paused,
  pause: () => { if (external) player.pause(); },
  resume: () => { if (external) player.unpause(); },
  position: () => (external ? external.resource.playbackDuration : 0),
  setVolume: (v) => {
    externalVolume = Math.max(0, Math.min(1, v));
    try { external?.resource.volume?.setVolume(externalVolume); } catch { /* ignore */ }
  },
};

/**
 * Tune the Opus encoder for music quality and packet-loss resilience.
 *
 * Bitrate is capped to the target voice channel's own limit (96k unboosted;
 * 128/256/384k at boost tiers 1/2/3) so the encoder never exceeds what the
 * channel accepts. Inband FEC is the main reliability win — Opus embeds
 * recovery data so brief packet loss does not become an audible dropout.
 *
 * Every call is feature-detected and the whole body is guarded: a
 * `@discordjs/voice` upgrade that renames these methods must degrade to default
 * encoder settings, never take the audio path down.
 *
 * @param resource - The audio resource whose encoder should be tuned.
 */
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
player.on(AudioPlayerStatus.Idle, (oldState) => {
  // A YouTube track ran out: give the player back to the FIFO and let dj.js
  // advance. Anything else ending is the FIFO transcoder dying, and its exit
  // handler respawns it.
  if (external && oldState && oldState.resource === external.resource) {
    const ended = external;
    external = null;
    // A beat later, so yt-dlp's exit status has landed before it is read.
    setTimeout(() => {
      const result = ended.handle.result();
      ended.handle.stop();
      if (connection) startStream();
      try { ended.onEnd(result); } catch (e) { log('youtube onEnd error: ' + e.message); }
    }, 250);
    return;
  }
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

/**
 * Join a voice channel, subscribe it to the player, and start streaming.
 *
 * Waits for the connection to actually reach `Ready` (20s budget) before
 * subscribing, so a failed handshake surfaces as a thrown error rather than a
 * bot that appears connected but is silent.
 *
 * A `Disconnected` event is treated as recoverable if the connection returns to
 * `Signalling`/`Connecting` within 5s — that is what a channel move or a brief
 * blip looks like. Only a genuine drop tears the connection down.
 *
 * @param guild - The Discord guild containing the channel.
 * @param channelId - Voice channel to join.
 * @throws If the connection does not reach `Ready` within 20 seconds.
 * @failureMode SD-006 A voice websocket that opens, receives Hello and closes —
 * surfacing here as an aborted `entersState` with `net-state 1 -> 6` — means
 * `@discordjs/voice` is speaking gateway v4. Check the dependency version
 * before debugging the network.
 */
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
  // A YouTube track survives a channel move: the player keeps its resource and
  // the new connection just subscribes to it.
  if (!external) startStream();
  log(`connected to voice channel ${channelId}`);
  checkListeners(); // handle joining an already-empty channel
}

/**
 * Disconnect from voice and tear down the transcoder.
 *
 * Removes ffmpeg's `exit` listener before killing it, so the deliberate
 * teardown does not trip the 1s respawn in {@link startStream} and leave an
 * orphaned transcoder writing into a destroyed connection.
 *
 * Safe to call when not connected.
 *
 * @param opts - `{ keepExternal }` — leave a playing YouTube track alone. Used
 * when moving to another channel, where the track should carry on; a real
 * leave stops it and tells the DJ engine, so its card does not show a track
 * that is no longer playing.
 */
function leaveVoice({ keepExternal = false } = {}) {
  if (emptyTimer) { clearTimeout(emptyTimer); emptyTimer = null; }
  if (connection) {
    try { connection.destroy(); } catch { /* ignore */ }
    connection = null;
  }
  stopFifoStream();
  if (!keepExternal && external) {
    stopExternal({ resumePipe: false });
    try { djEngine?.externalStopped(); } catch { /* ignore */ }
  }
}

// ── Auto-leave when only bots remain ──────────────────────────────────────────

/**
 * Count real people in the bot's current voice channel.
 *
 * Every bot (this one, the TTS bot, other music bots) has `user.bot === true`
 * and is excluded, so a channel containing only bots counts as empty.
 *
 * @returns The number of human members, or `-1` when not connected or the
 * channel cannot be resolved. `-1` is distinct from `0` on purpose: "unknown"
 * must not trigger the auto-leave that "genuinely empty" does.
 */
function humanListeners() {
  if (!connection || !connection.joinConfig) return -1;
  const guild = client.guilds.cache.get(connection.joinConfig.guildId);
  const channel = guild && guild.channels.cache.get(connection.joinConfig.channelId);
  if (!channel || !channel.members) return -1;
  return channel.members.filter((m) => !m.user?.bot).size;
}

/**
 * Start or cancel the auto-leave countdown based on who is still listening.
 *
 * Called on voice-state changes and after connecting. When the last human
 * leaves, playback is paused and the bot disconnects after a grace period
 * (`EMPTY_DISCONNECT_SECONDS`, 0 disables) — the grace period is what stops a
 * brief reconnect from ending the session. Anyone rejoining cancels it.
 *
 * Pausing go-librespot as well as leaving matters: otherwise the Spotify
 * account keeps "playing" into a channel nobody is in.
 */
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

/**
 * Ensure the bot is in the voice channel of whoever ran the command.
 *
 * Injected into the DJ engine so `dj.js` can pull the speaker to the caller
 * without importing the voice internals — the audio path stays owned by this
 * module.
 *
 * Returns an error object rather than throwing, because "you're not in a voice
 * channel" is a normal user mistake that deserves a friendly reply.
 *
 * @param ix - The Discord chat-input interaction.
 * @returns `{ channelName }` on success, or `{ error }` with a message to show
 * the user.
 */
async function ensureVoiceForInteraction(ix) {
  const channel = ix.member?.voice?.channel;
  if (!channel) return { error: 'Join a voice channel first, then try again.' };
  const currentId = connection?.joinConfig?.channelId || null;
  if (!connection || currentId !== channel.id) {
    leaveVoice({ keepExternal: true });
    await connectTo(ix.guild, channel.id);
  }
  return { channelName: channel.name };
}
const djEngine =dj.createDJ({ ensureVoiceForInteraction, leaveVoice: () => leaveVoice(), audio: externalAudio });

const commands = [
  ...dj.SLASH_COMMANDS,
  ...accounts.SLASH_COMMANDS,
  ...[
    new SlashCommandBuilder().setName('leave').setDescription('Disconnect the bot from voice'),
    new SlashCommandBuilder().setName('reconnect').setDescription('Restart the audio stream'),
    new SlashCommandBuilder().setName('status').setDescription('Show bridge status'),
  ].map((c) => c.toJSON()),
];

/**
 * Register every module's slash commands with Discord.
 *
 * Registers against `DISCORD_GUILD_ID` when set, because guild commands appear
 * instantly whereas global commands can take up to an hour to propagate.
 *
 * @param appId - The Discord application id to register under.
 */
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
    if (external) {
      return interaction.reply({ content: 'A YouTube track is playing, and it has its own stream. If it is stuck, use `/skip`.', ephemeral: true });
    }
    startStream();
    return interaction.reply({ content: '🔄 Restarted the audio stream.', ephemeral: true });
  }

  if (interaction.commandName === 'status') {
    const state = connection ? connection.state.status : 'not connected';
    const ff = ffmpeg ? 'running' : 'stopped';
    const source = external ? 'YouTube' : 'Spotify';
    const yt = youtube.hasCookies() ? 'on' : 'on, but no cookies (most videos will be blocked)';
    return interaction.reply({
      content: `Voice: **${state}**\nsource: **${source}**\nffmpeg (Spotify pipe): **${ff}**\nsearch: **${dj.SEARCH_ENABLED ? 'on' : 'off (links only)'}**\nYouTube: **${yt}**`,
      ephemeral: true,
    });
  }
});

// Re-evaluate whenever anyone joins/leaves/moves voice channels.
client.on(Events.VoiceStateUpdate, () => { try { checkListeners(); } catch (e) { log('listener check:', e.message); } });

/**
 * Shut down cleanly on SIGINT/SIGTERM.
 *
 * Closes the FIFO keep-alive descriptor explicitly so the pipe is released
 * rather than left held by a lingering process, then destroys the Discord
 * client so systemd sees a clean exit instead of having to time out and
 * SIGKILL.
 */
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
