// DJ engine for the Spotify → Discord bridge.
//
// Adds Discord-side control on top of the audio bridge: search/add songs, a
// reorderable bot-managed queue, transport controls, and /summon. It drives
// go-librespot's HTTP API (127.0.0.1:3678) and auto-advances the queue using
// go-librespot's /events WebSocket. Spotify search uses the Web API with an
// app token (client-credentials) when SPOTIFY_CLIENT_ID/SECRET are set;
// otherwise it's links-only.

const WebSocket = require('ws');
const { SlashCommandBuilder, EmbedBuilder } = require('discord.js');

const LIBRESPOT = process.env.GO_LIBRESPOT_API || 'http://127.0.0.1:3678';
const SPOTIFY_CLIENT_ID = process.env.SPOTIFY_CLIENT_ID || '';
const SPOTIFY_CLIENT_SECRET = process.env.SPOTIFY_CLIENT_SECRET || '';
const SEARCH_ENABLED = Boolean(SPOTIFY_CLIENT_ID && SPOTIFY_CLIENT_SECRET);

function log(...a) { console.log('[dj]', ...a); }
const fmtDur = (ms) => {
  if (!ms || ms < 0) return '0:00';
  const s = Math.round(ms / 1000);
  const m = Math.floor(s / 60);
  return `${m}:${String(s % 60).padStart(2, '0')}`;
};

// ── go-librespot HTTP API ─────────────────────────────────────────────────────
async function lrs(path, body) {
  const res = await fetch(LIBRESPOT + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`go-librespot ${path} → HTTP ${res.status}`);
  const t = await res.text();
  return t ? JSON.parse(t) : {};
}
const api = {
  status: () => lrs('/status'),
  play: (uri, opts = {}) => lrs('/player/play', { uri, paused: false, skip_to_uri: opts.skipToUri }),
  resume: () => lrs('/player/resume'),
  pause: () => lrs('/player/pause'),
  stop: () => lrs('/player/stop'),
  next: () => lrs('/player/next', {}),
  prev: () => lrs('/player/prev', {}),
  seek: (position) => lrs('/player/seek', { position }),
  addToQueue: (uri) => lrs('/player/add_to_queue', { uri }),
  getVolume: () => lrs('/player/volume'),
  setVolume: (volume) => lrs('/player/volume', { volume }),
};

// ── Spotify Web API (search + link resolution) ───────────────────────────────
let spTokenCache = { token: null, exp: 0 };
async function spToken() {
  if (!SEARCH_ENABLED) throw new Error('Spotify search is not configured');
  if (spTokenCache.token && Date.now() < spTokenCache.exp) return spTokenCache.token;
  const auth = Buffer.from(`${SPOTIFY_CLIENT_ID}:${SPOTIFY_CLIENT_SECRET}`).toString('base64');
  const res = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials',
  });
  if (!res.ok) throw new Error(`Spotify token → HTTP ${res.status}`);
  const j = await res.json();
  spTokenCache = { token: j.access_token, exp: Date.now() + (j.expires_in - 60) * 1000 };
  return spTokenCache.token;
}
async function sp(path) {
  const res = await fetch('https://api.spotify.com/v1' + path, {
    headers: { Authorization: `Bearer ${await spToken()}` },
  });
  if (!res.ok) throw new Error(`Spotify ${path} → HTTP ${res.status}`);
  return res.json();
}
const trackFrom = (t, addedBy) => ({
  uri: t.uri,
  id: t.id,
  name: t.name,
  artists: (t.artists || []).map((a) => a.name).join(', '),
  durationMs: t.duration_ms,
  url: t.external_urls?.spotify,
  addedBy,
});
async function searchTrack(query, addedBy) {
  const j = await sp(`/search?type=track&limit=1&q=${encodeURIComponent(query)}`);
  const t = j.tracks?.items?.[0];
  return t ? trackFrom(t, addedBy) : null;
}
// Resolve a Spotify link/URI into one or more tracks.
async function resolveInput(input, addedBy) {
  const m = input.match(/(?:open\.spotify\.com\/(?:intl-[a-z]+\/)?|spotify:)(track|album|playlist)[/:]([A-Za-z0-9]+)/i);
  if (!m) {
    if (!SEARCH_ENABLED) return { error: 'Search is off — paste a Spotify track/album/playlist link.' };
    const t = await searchTrack(input, addedBy);
    return t ? { tracks: [t] } : { error: `No results for “${input}”.` };
  }
  const [, type, id] = m;
  if (!SEARCH_ENABLED) {
    // Links-only: we can still queue a single track by URI (metadata fills in on play).
    if (type === 'track') return { tracks: [{ uri: `spotify:track:${id}`, name: '(loading…)', artists: '', durationMs: 0, addedBy }] };
    return { error: 'Album/playlist links need Spotify search enabled.' };
  }
  if (type === 'track') return { tracks: [trackFrom(await sp(`/tracks/${id}`), addedBy)] };
  if (type === 'album') {
    const al = await sp(`/albums/${id}`);
    return { tracks: (al.tracks?.items || []).map((t) => trackFrom({ ...t, external_urls: t.external_urls }, addedBy)), label: `album “${al.name}”` };
  }
  if (type === 'playlist') {
    const pl = await sp(`/playlists/${id}?fields=name,tracks.items(track(uri,id,name,artists,duration_ms,external_urls))`);
    const tracks = (pl.tracks?.items || []).map((it) => it.track).filter(Boolean).map((t) => trackFrom(t, addedBy));
    return { tracks, label: `playlist “${pl.name}”` };
  }
  return { error: 'Unsupported link.' };
}

// ── Queue + player engine ─────────────────────────────────────────────────────
function createDJ({ ensureVoiceForInteraction }) {
  const queue = [];        // upcoming tracks (reorderable)
  let current = null;      // now playing
  let advancing = false;   // guard against double-advance
  let radioMode = false;   // radio: let go-librespot autoplay drive, don't use our queue

  async function playNext() {
    const t = queue.shift();
    if (!t) { current = null; try { await api.stop(); } catch {} return; }
    current = t;
    await api.play(t.uri);
    log(`▶ ${t.name} — ${t.artists}`);
  }

  function onEvent(evt) {
    const type = evt.type;
    const data = evt.data || {};
    // In radio mode go-librespot's autoplay picks the next songs; track them so
    // /nowplaying stays accurate, and DON'T advance our (unused) queue.
    if (radioMode) {
      if ((type === 'metadata' || type === 'playing') && data.uri) {
        current = { uri: data.uri, name: data.name || current?.name || '(loading…)', artists: (data.artist_names || []).join(', '), durationMs: data.duration || 0, addedBy: current?.addedBy };
      }
      return;
    }
    // Queue mode: a finished track (not_playing for the current uri) → play next.
    if (type === 'not_playing' && current && data.uri === current.uri && !advancing) {
      advancing = true;
      playNext().catch((e) => log('advance error:', e.message)).finally(() => { advancing = false; });
    }
    // Backfill metadata for links-only-added tracks once go-librespot loads them.
    if (type === 'metadata' && current && data.uri === current.uri) {
      if (!current.name || current.name === '(loading…)') {
        current.name = data.name || current.name;
        current.artists = (data.artist_names || []).join(', ') || current.artists;
        current.durationMs = data.duration || current.durationMs;
      }
    }
  }
  connectEvents(onEvent);

  // ── command implementations ────────────────────────────────────────────────
  async function cmdPlay(ix) {
    const inputRaw = ix.options.getString('query', true);
    await ix.deferReply();
    // Make sure the bot is in the caller's voice channel.
    const joined = await ensureVoiceForInteraction(ix).catch((e) => ({ error: e.message }));
    if (joined && joined.error) return ix.editReply(`⚠️ ${joined.error}`);

    const r = await resolveInput(inputRaw.trim(), ix.user.username).catch((e) => ({ error: e.message }));
    if (r.error) return ix.editReply(`⚠️ ${r.error}`);
    if (!r.tracks?.length) return ix.editReply('⚠️ Nothing to add.');

    radioMode = false; // switch back to queue control
    const startedIdle = !current && queue.length === 0;
    queue.push(...r.tracks);
    if (!current) await playNext();

    if (r.tracks.length === 1) {
      const t = r.tracks[0];
      return ix.editReply(startedIdle ? `▶️ Now playing **${t.name}** — ${t.artists}` : `➕ Queued **${t.name}** — ${t.artists} (position ${queue.length})`);
    }
    return ix.editReply(`➕ Added **${r.tracks.length}** tracks from ${r.label || 'link'}.${startedIdle ? ' Starting now.' : ''}`);
  }

  async function cmdSkip(ix) {
    if (!current) return ix.reply({ content: 'Nothing is playing.', ephemeral: true });
    const was = current;
    if (radioMode) { await api.next().catch(() => {}); return ix.reply(`⏭️ Skipped **${was.name}** — next radio pick incoming.`); }
    await playNext();
    return ix.reply(`⏭️ Skipped **${was.name}**.${current ? ` Now: **${current.name}**` : ' Queue empty.'}`);
  }

  async function cmdRadio(ix) {
    const inputRaw = ix.options.getString('query', true);
    await ix.deferReply();
    const joined = await ensureVoiceForInteraction(ix).catch((e) => ({ error: e.message }));
    if (joined && joined.error) return ix.editReply(`⚠️ ${joined.error}`);
    const r = await resolveInput(inputRaw.trim(), ix.user.username).catch((e) => ({ error: e.message }));
    if (r.error) return ix.editReply(`⚠️ ${r.error}`);
    const seed = r.tracks?.[0];
    if (!seed) return ix.editReply('⚠️ Could not find a seed track.');
    // Radio: play the seed, then let go-librespot autoplay continue with similar
    // songs. Our queue is set aside while radio is on.
    radioMode = true;
    queue.length = 0;
    current = seed;
    await api.play(seed.uri);
    return ix.editReply(`📻 Started radio from **${seed.name}** — ${seed.artists}. Similar songs will keep playing. Use \`/skip\` to move on, or \`/play\` to go back to the queue.`);
  }
  async function cmdPause(ix) { await api.pause().catch(() => {}); return ix.reply('⏸️ Paused.'); }
  async function cmdResume(ix) { await api.resume().catch(() => {}); return ix.reply('▶️ Resumed.'); }
  async function cmdClear(ix) { const n = queue.length; queue.length = 0; return ix.reply(`🗑️ Cleared ${n} queued track(s).`); }
  async function cmdShuffle(ix) {
    for (let i = queue.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [queue[i], queue[j]] = [queue[j], queue[i]]; }
    return ix.reply(`🔀 Shuffled ${queue.length} track(s).`);
  }
  async function cmdRemove(ix) {
    const pos = ix.options.getInteger('position', true);
    if (pos < 1 || pos > queue.length) return ix.reply({ content: `Position must be 1–${queue.length}.`, ephemeral: true });
    const [t] = queue.splice(pos - 1, 1);
    return ix.reply(`➖ Removed **${t.name}**.`);
  }
  async function cmdMove(ix) {
    const from = ix.options.getInteger('from', true);
    const to = ix.options.getInteger('to', true);
    if (from < 1 || from > queue.length || to < 1 || to > queue.length) return ix.reply({ content: `Positions must be 1–${queue.length}.`, ephemeral: true });
    const [t] = queue.splice(from - 1, 1);
    queue.splice(to - 1, 0, t);
    return ix.reply(`↕️ Moved **${t.name}** to position ${to}.`);
  }
  async function cmdVolume(ix) {
    const pct = ix.options.getInteger('percent', true);
    const clamped = Math.max(0, Math.min(100, pct));
    try {
      const v = await api.getVolume();
      const max = v.max || 65535;
      await api.setVolume(Math.round((clamped / 100) * max));
      return ix.reply(`🔊 Volume set to ${clamped}%.`);
    } catch (e) { return ix.reply({ content: `Couldn't set volume: ${e.message}`, ephemeral: true }); }
  }
  async function cmdNowPlaying(ix) {
    if (!current) return ix.reply({ content: 'Nothing is playing.', ephemeral: true });
    let pos = 0;
    try { const st = await api.status(); pos = st.track?.position || 0; } catch {}
    const dur = current.durationMs || 0;
    const filled = dur ? Math.round((pos / dur) * 20) : 0;
    const bar = '▬'.repeat(filled) + '🔘' + '▬'.repeat(Math.max(0, 20 - filled - 1));
    const e = new EmbedBuilder().setColor(0x1db954).setTitle('▶️ Now Playing')
      .setDescription(`**${current.name}**\n${current.artists}`)
      .addFields({ name: '​', value: `${fmtDur(pos)} ${bar} ${fmtDur(dur)}` });
    if (current.url) e.setURL?.(current.url);
    if (current.addedBy) e.setFooter({ text: `Added by ${current.addedBy}` });
    return ix.reply({ embeds: [e] });
  }
  async function cmdQueue(ix) {
    const e = new EmbedBuilder().setColor(0x1db954).setTitle('🎶 Queue');
    const nowLine = current ? `**Now:** ${current.name} — ${current.artists}` : '**Now:** (nothing)';
    const list = queue.slice(0, 15).map((t, i) => `\`${i + 1}.\` ${t.name} — ${t.artists} \`${fmtDur(t.durationMs)}\``).join('\n');
    const more = queue.length > 15 ? `\n…and ${queue.length - 15} more` : '';
    e.setDescription(`${nowLine}\n\n${list || '_Queue is empty — add with_ `/play`'}${more}`);
    e.setFooter({ text: `${queue.length} track(s) queued` });
    return ix.reply({ embeds: [e] });
  }
  async function cmdSummon(ix) {
    await ix.deferReply();
    const joined = await ensureVoiceForInteraction(ix).catch((e) => ({ error: e.message }));
    if (joined && joined.error) return ix.editReply(`⚠️ ${joined.error}`);
    // Make go-librespot the active device: resume/play so audio moves here.
    if (current) { await api.resume().catch(() => {}); }
    else if (queue.length) { await playNext(); }
    else { try { await api.resume(); } catch {} }
    return ix.editReply(`🔊 I'm in **${joined?.channelName || 'your channel'}** — playback is here now. ${current ? '' : 'Add songs with `/play`, or pick **Discord** in your Spotify app.'}`);
  }
  async function cmdHelp(ix) {
    const e = new EmbedBuilder().setColor(0x1db954).setTitle('🎧 Spotify Bridge — how to use it')
      .setDescription('I play Spotify into this server. Add songs, reorder the queue, and summon me to your voice channel.')
      .addFields(
        { name: '▶️ Play / add', value: '`/play <song name or Spotify link>` — search or add a track/album/playlist' + (SEARCH_ENABLED ? '' : ' *(links only — search not configured)*') },
        { name: '📻 Radio', value: '`/radio <song>` — endless station of similar songs from a seed track' },
        { name: '🔊 Summon', value: '`/summon` — pull me into your voice channel and move playback here\n`/leave` — disconnect me' },
        { name: '⏯️ Controls', value: '`/skip` · `/pause` · `/resume` · `/nowplaying` · `/volume <0-100>`' },
        { name: '🎶 Queue', value: '`/queue` — show it\n`/move <from> <to>` · `/remove <position>` · `/shuffle` · `/clear`' },
        { name: '💡 Tip', value: 'You can also control everything from the Spotify app — pick **Discord** in the devices menu. Requires Spotify Premium.' },
      );
    return ix.reply({ embeds: [e] });
  }

  const handlers = {
    play: cmdPlay, radio: cmdRadio, skip: cmdSkip, pause: cmdPause, resume: cmdResume,
    queue: cmdQueue, move: cmdMove, remove: cmdRemove, shuffle: cmdShuffle,
    clear: cmdClear, volume: cmdVolume, nowplaying: cmdNowPlaying,
    summon: cmdSummon, help: cmdHelp,
  };
  async function handleInteraction(ix) {
    const fn = handlers[ix.commandName];
    if (!fn) return false;
    try { await fn(ix); } catch (e) {
      log(`command ${ix.commandName} error:`, e.message);
      const msg = `⚠️ ${e.message}`;
      if (ix.deferred || ix.replied) ix.editReply(msg).catch(() => {}); else ix.reply({ content: msg, ephemeral: true }).catch(() => {});
    }
    return true;
  }
  return { handleInteraction, get current() { return current; }, get queue() { return queue; } };
}

// WebSocket to go-librespot /events with auto-reconnect.
function connectEvents(onEvent) {
  let ws;
  const connect = () => {
    ws = new WebSocket(LIBRESPOT.replace(/^http/, 'ws') + '/events');
    ws.on('message', (buf) => { try { onEvent(JSON.parse(buf.toString())); } catch {} });
    ws.on('close', () => setTimeout(connect, 2000));
    ws.on('error', () => { try { ws.close(); } catch {} });
  };
  connect();
}

// Slash command definitions (merged into the bot's registration).
const SLASH_COMMANDS = [
  new SlashCommandBuilder().setName('play').setDescription('Play or queue a song (name or Spotify link)')
    .addStringOption((o) => o.setName('query').setDescription('Song name or Spotify track/album/playlist link').setRequired(true)),
  new SlashCommandBuilder().setName('radio').setDescription('Start a radio of similar songs from a seed track')
    .addStringOption((o) => o.setName('query').setDescription('Seed song name or Spotify track link').setRequired(true)),
  new SlashCommandBuilder().setName('summon').setDescription('Bring me into your voice channel and play here'),
  new SlashCommandBuilder().setName('skip').setDescription('Skip to the next track'),
  new SlashCommandBuilder().setName('pause').setDescription('Pause playback'),
  new SlashCommandBuilder().setName('resume').setDescription('Resume playback'),
  new SlashCommandBuilder().setName('nowplaying').setDescription('Show the current track'),
  new SlashCommandBuilder().setName('queue').setDescription('Show the queue'),
  new SlashCommandBuilder().setName('move').setDescription('Move a queued track to a new position')
    .addIntegerOption((o) => o.setName('from').setDescription('Current position').setRequired(true))
    .addIntegerOption((o) => o.setName('to').setDescription('New position').setRequired(true)),
  new SlashCommandBuilder().setName('remove').setDescription('Remove a track from the queue')
    .addIntegerOption((o) => o.setName('position').setDescription('Queue position to remove').setRequired(true)),
  new SlashCommandBuilder().setName('shuffle').setDescription('Shuffle the queue'),
  new SlashCommandBuilder().setName('clear').setDescription('Clear the queue'),
  new SlashCommandBuilder().setName('volume').setDescription('Set playback volume (0-100)')
    .addIntegerOption((o) => o.setName('percent').setDescription('0 to 100').setRequired(true)),
  new SlashCommandBuilder().setName('help').setDescription('How to use the music bot'),
].map((c) => c.toJSON());

module.exports = { createDJ, SLASH_COMMANDS, SEARCH_ENABLED };
