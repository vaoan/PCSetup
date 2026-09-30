// Spotify account switching for the bridge.
//
// One go-librespot, swappable credentials. A trusted user runs /login, opens the
// returned Spotify auth link, logs in with THEIR account, and pastes the
// redirect URL back via /logincode — the bot delivers the code to go-librespot
// (on loopback) so it re-logs in as that account. /resetaccount restores the
// owner account (saved on first run). One account plays at a time.
//
// The bot runs as root on the host, so it drives go-librespot via systemd. These
// commands are gated to Manage-Server by default (grant others in Discord →
// Server Settings → Integrations).

const { execFile } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { SlashCommandBuilder, PermissionFlagsBits } = require('discord.js');

const CONFIG_DIR = process.env.GO_LIBRESPOT_CONFIG_DIR || '/root/.config/go-librespot';
const STATE = path.join(CONFIG_DIR, 'state.json');
const OWNER = path.join(CONFIG_DIR, 'state.owner.json');
const DROPIN_DIR = '/etc/systemd/system/go-librespot.service.d';
const DROPIN = path.join(DROPIN_DIR, 'nologin-restart.conf');
const CALLBACK = 'http://127.0.0.1:8898';
const API = process.env.GO_LIBRESPOT_API || 'http://127.0.0.1:3678';

/**
 * Log a line to the journal, prefixed so `journalctl` output is greppable per module.
 *
 * @param a - Values forwarded to `console.log`.
 */
function log(...a) { console.log('[accounts]', ...a); }

/**
 * Resolve after a delay.
 *
 * Used throughout this module to wait out go-librespot restarts, which are
 * asynchronous: `systemctl restart` returns long before the Spotify session is
 * re-established.
 *
 * @param ms - Milliseconds to wait.
 * @returns A promise that resolves once the delay has elapsed.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Run an external command and capture stdout.
 *
 * Rejects with the command's stderr rather than a generic failure, so the text
 * surfaced to Discord names the actual problem.
 *
 * @param cmd - Executable to run.
 * @param args - Arguments passed to it.
 * @returns Resolves with stdout; rejects with an `Error` carrying stderr.
 * @throws If the command exits non-zero or exceeds the 25s timeout.
 */
function sh(cmd, args) {
  return new Promise((res, rej) => execFile(cmd, args, { timeout: 25000 }, (e, so, se) => (e ? rej(new Error((se || e.message || '').trim())) : res(so))));
}

/**
 * Run `systemctl` with the given arguments.
 *
 * The bot runs as root on the host, so it drives the go-librespot unit directly
 * rather than through any supervisor of its own.
 *
 * @param args - Arguments for `systemctl`.
 * @returns Resolves with stdout.
 */
const systemctl = (...args) => sh('systemctl', args);

/**
 * Report whether a go-librespot state file holds usable Spotify credentials.
 *
 * Tests for a populated `"data"` field rather than mere file existence:
 * go-librespot writes a state file with an empty credential blob before login
 * completes, so `fs.existsSync` alone would report success mid-login.
 *
 * @param file - State file to inspect. Defaults to the live `state.json`.
 * @returns `true` when the file exists and contains a credential blob.
 */
function hasCreds(file = STATE) { try { return /"data":"[^"]+"/.test(fs.readFileSync(file, 'utf8')); } catch { return false; } }

/**
 * Read which Spotify account go-librespot is currently logged in as.
 *
 * @returns The Spotify username, or `null` if the API is unreachable or no
 * account is logged in.
 * @failureMode SD-004 Returns `null` rather than throwing when the control API
 * is down, so an unhealthy go-librespot degrades the reply text instead of
 * breaking the command.
 */
async function currentUser() { try { const r = await fetch(API + '/status'); const j = await r.json(); return j.username || null; } catch { return null; } }

/**
 * Recover the Spotify authorization URL that go-librespot printed to its log.
 *
 * go-librespot emits the OAuth URL to stdout only; there is no API for it, so
 * it is scraped back out of the journal. ANSI colour codes are stripped first
 * because the log is coloured when a TTY is attached.
 *
 * @returns The most recent authorize URL, or `null` if none was logged.
 */
async function authUrl() {
  const out = await sh('journalctl', ['-u', 'go-librespot', '-n', '25', '--no-pager']).catch(() => '');
  const m = out.replace(/\x1b\[[0-9;]*m/g, '').match(/https:\/\/accounts\.spotify\.com\/authorize\S+/g);
  return m ? m[m.length - 1] : null;
}

/**
 * Capture the current login as the "owner" default on first run.
 *
 * Called once at bot startup. Snapshots `state.json` to `state.owner.json` so
 * `/resetaccount` always has something to restore to.
 *
 * @failureMode SD-014 This snapshot is the only thing standing between a failed
 * account switch and a permanently logged-out bridge, since {@link startLogin}
 * deliberately deletes the live credentials.
 */
function init() {
  try { if (!fs.existsSync(OWNER) && hasCreds()) { fs.copyFileSync(STATE, OWNER); log('saved owner account backup'); } } catch (e) { log('init:', e.message); }
}

/**
 * Begin an account switch: clear the current credentials and restart
 * go-librespot so it prints a fresh Spotify authorization URL.
 *
 * Writes a `Restart=no` systemd drop-in for the duration of the login. Without
 * it, go-librespot's own `Restart=on-failure` can bounce the process
 * mid-login, which rotates the PKCE challenge and invalidates the URL the user
 * is part-way through authorizing.
 *
 * @returns The authorization URL to hand the user, or `null` if none appeared.
 * @failureMode SD-013 The drop-in is what prevents the PKCE challenge rotating
 * mid-login. Removing it makes `/login` fail intermittently and unreproducibly.
 * @failureMode SD-014 Deletes the live credentials by design; the owner backup
 * taken here and in {@link init} is the recovery path.
 */
async function startLogin() {
  fs.mkdirSync(DROPIN_DIR, { recursive: true });
  fs.writeFileSync(DROPIN, '[Service]\nRestart=no\n'); // freeze the PKCE challenge during login
  try { if (!fs.existsSync(OWNER) && hasCreds()) fs.copyFileSync(STATE, OWNER); } catch {}
  try { fs.rmSync(STATE, { force: true }); } catch {}                  // clear creds → forces interactive login
  await systemctl('daemon-reload');
  await systemctl('reset-failed', 'go-librespot').catch(() => {});
  await systemctl('restart', 'go-librespot');
  await sleep(5000);
  return authUrl();
}

/**
 * Complete an account switch by replaying the OAuth redirect URL to
 * go-librespot's loopback callback, then restore normal service behaviour.
 *
 * The user's browser cannot reach the callback (it listens on the host's
 * `127.0.0.1:8898`), so they paste the URL and the bot performs the request
 * locally on their behalf. Accepts either the full redirect URL or anything
 * containing the `code=` query string.
 *
 * @param pasted - The redirect URL copied out of the user's browser.
 * @returns The Spotify username now logged in, or `null` if unknown.
 * @throws If the paste is not a recognizable callback URL, or if credentials
 * do not appear within 20 seconds (usually an expired link).
 * @failureMode SD-013 Removes the `Restart=no` drop-in and re-enables the unit;
 * skipping this would leave go-librespot unable to restart on failure forever.
 */
async function deliverCode(pasted) {
  let target = (pasted.match(/https?:\/\/127\.0\.0\.1:8898\/login\?\S+/) || [])[0];
  if (!target && pasted.includes('code=')) target = `${CALLBACK}/login?${pasted.split('?').slice(1).join('?')}`;
  if (!target) throw new Error('That doesn’t look like the `127.0.0.1:8898/login?code=…` URL — paste the whole thing.');
  await fetch(target).catch(() => {}); // go-librespot captures the code on loopback
  for (let i = 0; i < 20 && !hasCreds(); i++) await sleep(1000);
  if (!hasCreds()) throw new Error('Login didn’t complete — the link may have expired. Try `/login` again.');
  try { fs.rmSync(DROPIN, { force: true }); } catch {}
  await systemctl('daemon-reload');
  await systemctl('enable', 'go-librespot').catch(() => {});
  await systemctl('restart', 'go-librespot');
  await sleep(3500);
  const user = await currentUser();
  try { if (user) fs.copyFileSync(STATE, path.join(CONFIG_DIR, `state.${user}.json`)); } catch {} // remember for later
  return user;
}

/**
 * Restore the owner's Spotify account from the snapshot taken by {@link init}.
 *
 * Also clears any leftover `Restart=no` drop-in, so this doubles as the escape
 * hatch when an account switch was abandoned half-way.
 *
 * @returns The Spotify username after the restore, or `null` if unknown.
 * @throws If no owner snapshot exists.
 * @failureMode SD-014 This is the recovery path for a failed account switch.
 */
async function resetToOwner() {
  if (!fs.existsSync(OWNER)) throw new Error('No saved owner account to restore to.');
  try { fs.rmSync(DROPIN, { force: true }); } catch {}
  fs.copyFileSync(OWNER, STATE);
  await systemctl('daemon-reload').catch(() => {});
  await systemctl('enable', 'go-librespot').catch(() => {});
  await systemctl('restart', 'go-librespot');
  await sleep(3500);
  return currentUser();
}

// ── command handlers ─────────────────────────────────────────────────────────

/**
 * `/login` — start an account switch and reply with the authorization URL.
 *
 * Replies ephemerally: the URL is a live credential-granting link and must not
 * be visible to the rest of the channel.
 *
 * @param ix - The Discord chat-input interaction.
 */
async function cmdLogin(ix) {
  await ix.deferReply({ ephemeral: true });
  const url = await startLogin();
  if (!url) return ix.editReply('⚠️ Couldn’t start the login (no auth URL). Try again in a moment.');
  return ix.editReply(
    '**Switch the Spotify account to yours** (needs Premium):\n' +
    `1. Open this and log in + **Agree**:\n${url}\n` +
    '2. You’ll hit a “can’t reach **127.0.0.1:8898**” page — that’s expected.\n' +
    '3. **Copy that page’s URL** and run `/logincode url:<paste it>`.\n\n' +
    '_Playback is paused during the switch._',
  );
}
/**
 * `/logincode` — finish an account switch from the pasted redirect URL.
 *
 * @param ix - The Discord chat-input interaction; requires a `url` option.
 */
async function cmdLoginCode(ix) {
  await ix.deferReply({ ephemeral: true });
  const url = ix.options.getString('url', true);
  const user = await deliverCode(url.trim());
  return ix.editReply(`✅ Switched — the Discord device now plays from **${user || 'your account'}**. Use \`/play\` to start. (\`/resetaccount\` restores the owner.)`);
}
/**
 * `/resetaccount` — restore the owner's Spotify account.
 *
 * @param ix - The Discord chat-input interaction.
 */
async function cmdResetAccount(ix) {
  await ix.deferReply({ ephemeral: true });
  const user = await resetToOwner();
  return ix.editReply(`↩️ Restored the owner account (**${user || 'owner'}**).`);
}
/**
 * `/account` — report which Spotify account is currently playing.
 *
 * @param ix - The Discord chat-input interaction.
 */
async function cmdAccount(ix) {
  const user = await currentUser();
  return ix.reply({ content: `🎧 Playing from Spotify account **${user || '(none / logging in)'}**.`, ephemeral: true });
}

const handlers = { login: cmdLogin, logincode: cmdLoginCode, resetaccount: cmdResetAccount, account: cmdAccount };

/**
 * Dispatch a Discord interaction to this module's command handlers.
 *
 * Returns a boolean rather than throwing on an unknown command so `bot.js` can
 * offer the interaction to each module in turn. Handler errors are reported to
 * the user and swallowed: one failed command must never take the bot down.
 *
 * @param ix - The Discord chat-input interaction.
 * @returns `true` if this module owned and handled the command, `false` if it
 * belongs to another module.
 */
async function handleInteraction(ix) {
  const fn = handlers[ix.commandName];
  if (!fn) return false;
  try { await fn(ix); } catch (e) {
    log(`${ix.commandName} error:`, e.message);
    const msg = `⚠️ ${e.message}`;
    if (ix.deferred || ix.replied) ix.editReply(msg).catch(() => {}); else ix.reply({ content: msg, ephemeral: true }).catch(() => {});
  }
  return true;
}

const admin = PermissionFlagsBits.ManageGuild;

/**
 * Slash commands owned by this module, serialized for Discord's registration API.
 *
 * All account-switching commands are gated to Manage-Server by default. They
 * change whose Spotify Premium account is being streamed, so they are not
 * something any channel member should be able to trigger. Access can be widened
 * per-server in Discord → Server Settings → Integrations.
 */
const SLASH_COMMANDS = [
  new SlashCommandBuilder().setName('login').setDescription('Switch the Spotify account to yours (needs Premium)').setDefaultMemberPermissions(admin),
  new SlashCommandBuilder().setName('logincode').setDescription('Finish the account switch by pasting the redirect URL').setDefaultMemberPermissions(admin)
    .addStringOption((o) => o.setName('url').setDescription('The 127.0.0.1:8898/login?code=… URL from your browser').setRequired(true)),
  new SlashCommandBuilder().setName('resetaccount').setDescription('Restore the owner Spotify account').setDefaultMemberPermissions(admin),
  new SlashCommandBuilder().setName('account').setDescription('Show which Spotify account is playing'),
].map((c) => c.toJSON());

module.exports = { init, handleInteraction, SLASH_COMMANDS };
