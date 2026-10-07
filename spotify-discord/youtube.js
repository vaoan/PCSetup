// YouTube source for the Spotify → Discord bridge.
//
// go-librespot only plays Spotify, so YouTube audio takes a different path:
// yt-dlp downloads the best audio stream to stdout, ffmpeg decodes it to the
// same s16le 48 kHz stereo the FIFO path produces, and bot.js plays that into
// the voice connection instead of the pipe for the length of the track.
//
// YouTube refuses almost every request from a datacenter IP ("Sign in to
// confirm you're not a bot"), so a cookies.txt from a signed-in account is
// effectively required on the VPS — see SD-015 in FAILURES.md.
//
// Env (see .env.example):
//   YOUTUBE_COOKIES          - Netscape cookies.txt (default /etc/spotify-discord/youtube-cookies.txt)
//   YTDLP_BIN                - yt-dlp (default yt-dlp; setup-cloud.sh installs the zipapp to /usr/local/bin)
//   YTDLP_JS_RUNTIME         - JS runtime yt-dlp uses for YouTube's player code (default node)
//   YOUTUBE_PLAYLIST_LIMIT   - most entries taken from one playlist link (default 100)

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const YTDLP = process.env.YTDLP_BIN || 'yt-dlp';
const COOKIES = process.env.YOUTUBE_COOKIES || '/etc/spotify-discord/youtube-cookies.txt';
const JS_RUNTIME = process.env.YTDLP_JS_RUNTIME || 'node';
const PLAYLIST_LIMIT = Math.max(1, parseInt(process.env.YOUTUBE_PLAYLIST_LIMIT || '100', 10));
const URL_RE = /^(?:https?:\/\/)?(?:www\.|m\.|music\.)?(?:youtube\.com|youtu\.be)\/\S+/i;
const SEARCH_RE = /^(?:yt|youtube)\s*:\s*(.+)$/i;

/**
 * Log a line to the journal, prefixed so `journalctl` output is greppable per module.
 *
 * @param a - Values forwarded to `console.log`.
 */
function log(...a) { console.log('[yt]', ...a); }

/**
 * Whether a cookies file is installed for yt-dlp.
 *
 * Without one the bridge still tries, but from a VPS most videos fail the bot
 * check, so `/status` reports this.
 *
 * @returns True when the cookies file exists.
 * @failureMode SD-015
 */
function hasCookies() {
  try { return fs.statSync(COOKIES).size > 0; } catch { return false; }
}

/**
 * Whether user input should be resolved through YouTube rather than Spotify.
 *
 * Matches youtube.com / youtu.be / music.youtube.com links (watch, shorts,
 * live, playlist) and an explicit `yt:` prefix for a YouTube search.
 *
 * @param input - Whatever the user typed into `/play`.
 * @returns True for a YouTube link or a `yt:` search.
 */
function isYouTubeInput(input) {
  return URL_RE.test(input) || SEARCH_RE.test(input);
}

/**
 * Give one yt-dlp run its own copy of the cookies, and write the refreshed jar back on success.
 *
 * yt-dlp rewrites its cookie file on exit with whatever YouTube sent back,
 * which is what keeps a session alive for months. Several runs overlap (a
 * playlist lookup while a track streams), so each works on a private copy and
 * a successful run replaces the master atomically (write + rename); the last
 * writer wins and the file is never half-written. A failed run is not written
 * back, so a signed-out jar from a bad run cannot replace a good one.
 *
 * @returns `{ args, finish(ok) }` — the yt-dlp arguments, and the cleanup to
 * call when the run exits.
 * @failureMode SD-015 The cookies are what get the VPS past the bot check.
 */
function cookieSession() {
  if (!hasCookies()) return { args: [], finish() {} };
  const tmp = path.join(os.tmpdir(), `yt-cookies-${process.pid}-${crypto.randomBytes(4).toString('hex')}.txt`);
  try {
    fs.copyFileSync(COOKIES, tmp);
    fs.chmodSync(tmp, 0o600);
  } catch (e) {
    log('could not copy cookies: ' + e.message);
    return { args: [], finish() {} };
  }
  let done = false;
  return {
    args: ['--cookies', tmp],
    finish(ok) {
      if (done) return;
      done = true;
      try {
        if (ok && fs.statSync(tmp).size > 0) {
          const next = `${COOKIES}.${crypto.randomBytes(4).toString('hex')}.new`;
          fs.copyFileSync(tmp, next);
          fs.chmodSync(next, 0o600);
          fs.renameSync(next, COOKIES);
        }
      } catch (e) { log('could not save refreshed cookies: ' + e.message); }
      try { fs.unlinkSync(tmp); } catch { /* ignore */ }
    },
  };
}

/**
 * Start yt-dlp as the leader of its own process group.
 *
 * yt-dlp forks helpers (the JS runtime that solves YouTube's player challenge;
 * with the PyInstaller build, the real Python process under a bootloader).
 * Killing only the pid we spawned orphans them, and an orphan keeps
 * downloading a track nobody is listening to. Seen on the VPS: after a stop,
 * the onefile build's child was still running. {@link killTree} kills the
 * whole group instead.
 *
 * @param args - Full yt-dlp argument list.
 * @returns The child process.
 * @failureMode SD-018
 */
function spawnYtDlp(args) {
  return spawn(YTDLP, args, { stdio: ['ignore', 'pipe', 'pipe'], detached: true });
}

/**
 * SIGKILL a process started by {@link spawnYtDlp} together with everything it forked.
 *
 * @param child - The child process (its pid is the process-group id).
 */
function killTree(child) {
  if (!child || !child.pid) return;
  try { process.kill(-child.pid, 'SIGKILL'); } catch { try { child.kill('SIGKILL'); } catch { /* ignore */ } }
}

/**
 * Arguments every yt-dlp run gets.
 *
 * @returns The shared argument list.
 */
function baseArgs() {
  return ['--no-warnings', '--no-progress', '--js-runtimes', JS_RUNTIME];
}

/**
 * Turn yt-dlp's stderr into one line a Discord user can act on.
 *
 * @param stderr - Captured stderr of a failed run.
 * @returns A short message for the user.
 * @failureMode SD-015 "Sign in to confirm you're not a bot" means the cookies
 * are missing or no longer signed in.
 */
function friendlyError(stderr) {
  const text = String(stderr || '');
  if (/confirm you.?re not a bot|Sign in to confirm/i.test(text)) {
    return hasCookies()
      ? 'YouTube wants the bot to sign in again. The YouTube cookies on the server have expired and need re-exporting.'
      : 'YouTube is blocking the server. YouTube cookies are not installed on it.';
  }
  if (/Private video/i.test(text)) return 'That video is private.';
  if (/Video unavailable|This video is not available|has been removed/i.test(text)) return 'That video is unavailable.';
  if (/age|inappropriate/i.test(text) && /confirm your age|age-restricted/i.test(text)) return 'That video is age-restricted.';
  const err = text.split('\n').reverse().find((l) => l.startsWith('ERROR')) || text.trim().split('\n').pop() || 'unknown error';
  return err.replace(/^ERROR:\s*(\[[^\]]+\]\s*)?/, '').slice(0, 180);
}

/**
 * Run yt-dlp to completion and collect its output.
 *
 * @param args - Arguments after the shared ones.
 * @param timeoutMs - Kill the run after this long.
 * @returns `{ code, stdout, stderr }`; a timeout reports code `-1`.
 */
function runYtDlp(args, timeoutMs) {
  return new Promise((resolve) => {
    const ck = cookieSession();
    let stdout = '';
    let stderr = '';
    let child;
    try {
      child = spawnYtDlp([...baseArgs(), ...ck.args, ...args]);
    } catch (e) {
      ck.finish(false);
      resolve({ code: -1, stdout: '', stderr: `ERROR: cannot start ${YTDLP}: ${e.message}` });
      return;
    }
    const timer = setTimeout(() => { stderr += '\nERROR: yt-dlp timed out'; killTree(child); }, timeoutMs);
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr = (stderr + d).slice(-8000); });
    child.on('error', (e) => { stderr += `\nERROR: ${e.message}`; });
    child.on('close', (code) => {
      clearTimeout(timer);
      ck.finish(code === 0);
      resolve({ code: code === null ? -1 : code, stdout, stderr });
    });
  });
}

/**
 * Normalize a yt-dlp info object (full or flat-playlist entry) into a queue track.
 *
 * Shares the field names the Spotify tracks use, so the queue, the player card
 * and `/queue` treat both alike; `source: 'youtube'` is what routes playback.
 *
 * @param e - A yt-dlp info dict or playlist entry.
 * @param addedBy - Display name of whoever queued it.
 * @returns The track record, or `null` for a private/deleted placeholder entry.
 */
function trackFromInfo(e, addedBy) {
  if (!e || !e.id) return null;
  if (/^\[(Private|Deleted) video\]$/i.test(e.title || '')) return null;
  const thumbs = Array.isArray(e.thumbnails) ? e.thumbnails.filter((t) => t && t.url) : [];
  return {
    source: 'youtube',
    uri: `youtube:${e.id}`,
    id: e.id,
    name: (e.title || e.id) + (e.is_live || e.live_status === 'is_live' ? ' 🔴 LIVE' : ''),
    artists: e.channel || e.uploader || '',
    durationMs: e.duration ? Math.round(e.duration * 1000) : 0,
    url: `https://www.youtube.com/watch?v=${e.id}`,
    albumArt: e.thumbnail || (thumbs.length ? thumbs[thumbs.length - 1].url : `https://i.ytimg.com/vi/${e.id}/hqdefault.jpg`),
    addedBy,
  };
}

/**
 * Resolve a YouTube link or `yt:` search into queueable tracks.
 *
 * A playlist link (`/playlist?list=`) expands to its entries, capped at
 * `YOUTUBE_PLAYLIST_LIMIT`; a watch link that also carries `&list=` plays just
 * that video, which is what people mean when they share one. Only metadata is
 * fetched here (`--flat-playlist`), so a 100-song playlist resolves in seconds;
 * the audio is looked up again when each track starts.
 *
 * Returns an `error` string instead of throwing, like `resolveInput` in dj.js.
 *
 * @param input - A YouTube URL, or `yt: <search>`.
 * @param addedBy - Display name of whoever queued it.
 * @returns `{ tracks, label? }` on success, or `{ error }` to show the user.
 */
async function resolveYouTube(input, addedBy) {
  const search = input.match(SEARCH_RE);
  return resolveTarget(search ? { query: search[1].trim() } : { url: input }, addedBy);
}

/**
 * Search YouTube for the single best match.
 *
 * Used for plain-text `/play` when Spotify search is not configured, so a song
 * name still plays something.
 *
 * @param query - Free-text search.
 * @param addedBy - Display name of whoever queued it.
 * @returns `{ tracks }` on success, or `{ error }` to show the user.
 */
async function searchYouTube(query, addedBy) {
  return resolveTarget({ query }, addedBy);
}

/**
 * Shared body of {@link resolveYouTube} and {@link searchYouTube}.
 *
 * @param target - `{ url }` or `{ query }`.
 * @param addedBy - Display name of whoever queued it.
 * @returns `{ tracks, label? }` on success, or `{ error }`.
 */
async function resolveTarget(target, addedBy) {
  let arg;
  const args = ['-J', '--flat-playlist'];
  let isList = false;
  if (target.query) {
    arg = `ytsearch1:${target.query}`;
  } else {
    arg = /^https?:\/\//i.test(target.url) ? target.url : `https://${target.url}`;
    isList = /\/playlist\b/i.test(arg) && /[?&]list=/i.test(arg);
    if (isList) args.push('--playlist-end', String(PLAYLIST_LIMIT));
    else args.push('--no-playlist');
  }
  const r = await runYtDlp([...args, '--', arg], 90000);
  if (r.code !== 0) return { error: friendlyError(r.stderr) };
  let info;
  try { info = JSON.parse(r.stdout); } catch { return { error: 'YouTube returned something unreadable.' }; }
  const entries = Array.isArray(info.entries) ? info.entries : [info];
  const tracks = entries.map((e) => trackFromInfo(e, addedBy)).filter(Boolean);
  if (!tracks.length) return { error: target.query ? `No YouTube results for “${target.query}”.` : 'Nothing playable at that link.' };
  return { tracks, label: isList ? `YouTube playlist “${info.title || 'playlist'}”` : undefined };
}

/**
 * Start streaming one YouTube track as raw PCM.
 *
 * yt-dlp downloads and pipes the audio itself (`-o -`) and ffmpeg decodes it to
 * s16le 48 kHz stereo — the exact format the FIFO path feeds the voice player.
 * Handing ffmpeg the googlevideo URL directly is *not* equivalent: it was
 * refused with HTTP 403 for one video in the VPS tests while yt-dlp, which
 * sends the right headers and requests ranges, played all eight.
 *
 * Backpressure from the audio player paces the download, so a paused track
 * holds the connection rather than buffering the whole file.
 *
 * @param track - A track from {@link resolveYouTube}.
 * @returns `{ stdout, stop(), result() }` — the PCM stream, a kill switch that
 * ends both processes, and the outcome once the stream has ended
 * (`{ ok, error? }`).
 * @failureMode SD-017 Why this pipes through yt-dlp instead of giving ffmpeg the URL.
 * @failureMode SD-018 `stop()` kills yt-dlp's whole process group, not just its pid.
 */
function startYouTubeStream(track) {
  const ck = cookieSession();
  const yt = spawnYtDlp([...baseArgs(), ...ck.args, '-q', '-f', 'bestaudio/best', '-o', '-', '--', track.url]);
  const ff = spawn('ffmpeg', ['-nostdin', '-hide_banner', '-loglevel', 'error', '-i', 'pipe:0',
    '-f', 's16le', '-ar', '48000', '-ac', '2', 'pipe:1'], { stdio: ['pipe', 'pipe', 'inherit'] });
  let stderr = '';
  let ytCode = null;
  let stopped = false;
  yt.stderr.on('data', (d) => { stderr = (stderr + d).slice(-8000); });
  yt.stdout.pipe(ff.stdin);
  // EPIPE when ffmpeg is killed while yt-dlp is still writing; harmless.
  ff.stdin.on('error', () => {});
  yt.stdout.on('error', () => {});
  yt.on('error', (e) => { stderr += `\nERROR: cannot start ${YTDLP}: ${e.message}`; ytCode = -1; try { ff.stdin.end(); } catch { /* ignore */ } });
  ff.on('error', (e) => log('ffmpeg error: ' + e.message));
  yt.on('close', (code) => {
    ytCode = code === null ? -1 : code;
    ck.finish(code === 0);
    if (code !== 0 && !stopped) log(`yt-dlp exited ${code} for ${track.id}: ${friendlyError(stderr)}`);
  });
  log(`streaming ${track.id} (${track.name})`);
  return {
    stdout: ff.stdout,
    stop() {
      stopped = true;
      killTree(yt);
      try { yt.stdout.unpipe(ff.stdin); yt.stdout.destroy(); } catch { /* ignore */ }
      try { ff.kill('SIGKILL'); } catch { /* ignore */ }
    },
    result() {
      if (ytCode === null || ytCode === 0) return { ok: true };
      return { ok: false, error: friendlyError(stderr) };
    },
  };
}

module.exports = { isYouTubeInput, resolveYouTube, searchYouTube, startYouTubeStream, hasCookies };
