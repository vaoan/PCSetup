# Spotify → Discord bridge on a cloud VPS

Runs the bridge on an always-on Linux VPS (RackNerd, Hetzner, or any KVM box)
instead of your PC — so it's available 24/7 with clean, low-latency audio. A real
VPS has proper outbound UDP, so Discord voice and the OAuth callback just work
(none of the WSL mirrored-networking gymnastics needed locally).

Same stack as local: `go-librespot` (Spotify Connect device) → FIFO → `bot.js`
(ffmpeg + @discordjs/voice v8) → Discord voice channel.

## 1. Get a VPS

- Any **KVM** VPS with **≥ 1 GB RAM**, **x86_64** (RackNerd's ~$12/yr specials are plenty).
- OS: **Ubuntu 22.04 / 24.04** or **Debian 12**, 64-bit.
- You'll receive an **IP** and **root password**.

A private music bot needs almost nothing: ~5–10% CPU, ~150 MB RAM, ~50 MB/hour
bandwidth (one Opus stream regardless of listener count).

## 2. Install

SSH in as root and run the installer, passing your Discord secrets inline:

```bash
ssh root@<vps-ip>

curl -fsSL https://raw.githubusercontent.com/vaoan/PCSetup/main/spotify-discord/cloud/setup-cloud.sh -o setup-cloud.sh
DISCORD_BOT_TOKEN='...' DISCORD_GUILD_ID='...' DISCORD_VOICE_CHANNEL_ID='...' bash setup-cloud.sh
```

Get the three values from your GitHub Secrets (or `.secrets` after
`sync-secrets.bat`). This installs go-librespot, Node, ffmpeg, the bot, and
enables both as systemd services.

## 3. One-time Spotify login (SSH tunnel)

go-librespot's login callback listens on `127.0.0.1:8898` **on the VPS**, but your
browser is local. Bridge it with an SSH tunnel, then run the login helper:

```bash
# From YOUR computer — note the -L tunnel:
ssh -L 8898:localhost:8898 root@<vps-ip>

# On the VPS:
bash <(curl -fsSL https://raw.githubusercontent.com/vaoan/PCSetup/main/spotify-discord/cloud/login-spotify-cloud.sh)
```

Open the printed URL in your **local** browser, log in with Premium, click
**Agree**. A "connection reset" page after Agree is normal — the login still
completes. Credentials persist across reboots (genuinely one-time).

## 4. Use it

Open Spotify → Connect/devices icon → pick **Discord** → play. The bot auto-joins
`DISCORD_VOICE_CHANNEL_ID` (or use `/join` from a voice channel).

## 5. Retire the local WSL bot

Only **one** instance can run per bot token, so turn off the local one to avoid a
conflict (go-librespot as a second Spotify device is harmless, but two bot
processes on the same token will clash):

```powershell
# On Windows / WSL:
wsl -d Ubuntu-24.04 --user root -- systemctl disable --now spotify-discord-bot go-librespot
Disable-ScheduledTask -TaskName SpotifyDiscordBridge
```

(Leave the repo scripts in place — they're your fallback if the VPS ever dies.)

## Files

| File | Purpose |
|---|---|
| `setup-cloud.sh` | One-command VPS installer (deps, go-librespot, bot, systemd) |
| `login-spotify-cloud.sh` | One-time Spotify OAuth over an SSH tunnel |

## Updating the bot later

`bot.js` / `config.yml` are pulled from GitHub `main` at install time. To update
after pushing changes:

```bash
curl -fsSL https://raw.githubusercontent.com/vaoan/PCSetup/main/spotify-discord/bot.js -o /opt/spotify-discord/bot.js
systemctl restart spotify-discord-bot
```

## Troubleshooting

```bash
journalctl -u go-librespot -u spotify-discord-bot -f
systemctl status spotify-discord-bot
```

- **Voice won't connect / "operation was aborted":** confirm `@discordjs/voice`
  is v8 — `grep -o 'v=[0-9]' /opt/spotify-discord/node_modules/@discordjs/voice/dist/index.js`.
- **No audio but device connects:** `pgrep -a ffmpeg` should show the transcoder;
  check the FIFO exists (`ls -l /tmp/spotify-discord.fifo`).
- **Device missing in Spotify:** re-run the login helper (SSH `-L 8898` tunnel).

## Security notes

- No inbound ports are needed except SSH — the go-librespot API (3678) and OAuth
  callback (8898) bind to loopback only; the bot only makes outbound connections.
- Harden SSH (key auth, disable root password) and enable a firewall (`ufw allow
  OpenSSH && ufw enable`) once you're set up.
