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

function log(...a) { console.log('[accounts]', ...a); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function sh(cmd, args) {
  return new Promise((res, rej) => execFile(cmd, args, { timeout: 25000 }, (e, so, se) => (e ? rej(new Error((se || e.message || '').trim())) : res(so))));
}
const systemctl = (...args) => sh('systemctl', args);

function hasCreds(file = STATE) { try { return /"data":"[^"]+"/.test(fs.readFileSync(file, 'utf8')); } catch { return false; } }
async function currentUser() { try { const r = await fetch(API + '/status'); const j = await r.json(); return j.username || null; } catch { return null; } }
async function authUrl() {
  const out = await sh('journalctl', ['-u', 'go-librespot', '-n', '25', '--no-pager']).catch(() => '');
  const m = out.replace(/\x1b\[[0-9;]*m/g, '').match(/https:\/\/accounts\.spotify\.com\/authorize\S+/g);
  return m ? m[m.length - 1] : null;
}

// Capture the current login as the "owner" default on first run.
function init() {
  try { if (!fs.existsSync(OWNER) && hasCreds()) { fs.copyFileSync(STATE, OWNER); log('saved owner account backup'); } } catch (e) { log('init:', e.message); }
}

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
async function cmdLoginCode(ix) {
  await ix.deferReply({ ephemeral: true });
  const url = ix.options.getString('url', true);
  const user = await deliverCode(url.trim());
  return ix.editReply(`✅ Switched — the Discord device now plays from **${user || 'your account'}**. Use \`/play\` to start. (\`/resetaccount\` restores the owner.)`);
}
async function cmdResetAccount(ix) {
  await ix.deferReply({ ephemeral: true });
  const user = await resetToOwner();
  return ix.editReply(`↩️ Restored the owner account (**${user || 'owner'}**).`);
}
async function cmdAccount(ix) {
  const user = await currentUser();
  return ix.reply({ content: `🎧 Playing from Spotify account **${user || '(none / logging in)'}**.`, ephemeral: true });
}

const handlers = { login: cmdLogin, logincode: cmdLoginCode, resetaccount: cmdResetAccount, account: cmdAccount };
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
const SLASH_COMMANDS = [
  new SlashCommandBuilder().setName('login').setDescription('Switch the Spotify account to yours (needs Premium)').setDefaultMemberPermissions(admin),
  new SlashCommandBuilder().setName('logincode').setDescription('Finish the account switch by pasting the redirect URL').setDefaultMemberPermissions(admin)
    .addStringOption((o) => o.setName('url').setDescription('The 127.0.0.1:8898/login?code=… URL from your browser').setRequired(true)),
  new SlashCommandBuilder().setName('resetaccount').setDescription('Restore the owner Spotify account').setDefaultMemberPermissions(admin),
  new SlashCommandBuilder().setName('account').setDescription('Show which Spotify account is playing'),
].map((c) => c.toJSON());

module.exports = { init, handleInteraction, SLASH_COMMANDS };
