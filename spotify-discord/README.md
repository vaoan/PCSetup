# Spotify → Discord voice bridge

Turns a Discord bot into a **Spotify Connect speaker**. Pick **Discord** from the
Connect (devices) menu in your normal Spotify app — on your phone, PC, or web —
and the audio plays into a Discord voice channel instead of your local speakers.
You control everything (play, pause, skip, queue) from Spotify as usual; the bot
is only the output device.

Requires **Spotify Premium**.

**It runs on an always-on Linux VPS, not on this PC.** Install, login and updates
are all in **`cloud/README.md`**. The local WSL variant (systemd units inside
Ubuntu-24.04, a `SpotifyDiscordBridge` scheduled task, and a WSL mirrored-networking
prerequisite) was removed on 2026-09-15: it was never in use after the VPS went
live, and its docs kept getting cited as a reason not to touch local WSL. If you
ever need it back, it is in git history before that date.

## How it works

```
Spotify app (phone / PC / web)
   │  pick "Discord" in the Connect menu
   ▼
go-librespot  (Spotify Connect device, logged into your account via OAuth)
   │  raw PCM → named pipe  /tmp/spotify-discord.fifo  (s16le 44.1 kHz stereo)
   ▼
bot.js  →  ffmpeg (44.1 kHz → 48 kHz)  →  @discordjs/voice (v8)  →  voice channel
```

- go-librespot logs into your account with **OAuth** (not LAN zeroconf), so the
  device shows up in your Connect list **everywhere over the internet**.
- Both pieces run as **systemd services on the VPS** (`go-librespot`,
  `spotify-discord-bot`), enabled at boot. A real VPS has clean outbound UDP, so
  Discord voice and the OAuth callback just work — no networking workarounds.

## Files

| File | Purpose |
|---|---|
| `bot.js` | discord.js bot: reads the pipe, joins voice, streams audio |
| `dj.js`, `accounts.js` | Bot modules (DJ commands, account handling) |
| `config.yml` | go-librespot config (pipe output, OAuth login, fixed callback port 8898) |
| `package.json` | Node deps (**`@discordjs/voice` ≥ 0.19** = voice gateway v8) |
| `.env.example` | Reference for the runtime env the VPS installer writes to `/etc/spotify-discord.env` |
| `cloud/setup-cloud.sh` | One-command VPS installer (deps, go-librespot, bot, systemd). Pulls the files above from GitHub `main` |
| `cloud/login-spotify-cloud.sh` | One-time Spotify OAuth over an SSH tunnel |
| `cloud/vps-ssh.ps1` | Connect to / deploy on the VPS using the `.secrets` entries |

## Setup, restore and updates

See **`cloud/README.md`**. In short: add `DISCORD_BOT_TOKEN`, `DISCORD_GUILD_ID`
and `DISCORD_VOICE_CHANNEL_ID` to GitHub Secrets and run `cloudflared\sync-secrets.bat`,
run `setup-cloud.sh` on the VPS, then do the one-time Spotify login through an SSH
tunnel. Nothing on this PC needs to be installed or restored after a format.

## Slash commands

| Command | Action |
|---|---|
| `/join` | Pull the speaker into the voice channel you're currently in |
| `/leave` | Disconnect |
| `/reconnect` | Restart the audio stream (if it ever stalls) |
| `/status` | Show voice / ffmpeg / pipe status |

## Troubleshooting (on the VPS)

```bash
# Live logs
journalctl -u go-librespot -u spotify-discord-bot -f

# Confirm voice reached "ready" and is streaming
journalctl -u spotify-discord-bot | grep -E 'voice:|streaming|net-state'
```

- **Bot joins but no audio / Spotify bounces back to your phone:** the pipe isn't
  being drained. Confirm voice reached `ready` (see above) and `pgrep ffmpeg`
  shows the transcoder running.
- **"Failed to join: The operation was aborted" + `net-state 1 → 6`:** the voice
  websocket is being closed right after Hello. This is the **voice gateway v4**
  problem — Discord rejects v4. Fix: `@discordjs/voice` must be **≥ 0.19** (uses
  v8). Verify: `grep -o 'v=[0-9]' node_modules/@discordjs/voice/dist/index.js`.
- **Device not showing in Spotify:** go-librespot needs login → `cloud/login-spotify-cloud.sh`.
- **Someone is listening right now?** `curl -s 127.0.0.1:3678/status` shows
  `"stopped":false` while playback is active. Restarting go-librespot cuts the
  audio, so check before any restart.

## Hard-won gotchas (why the scripts look the way they do)

- **go-librespot needs `HOME`** — it calls `os.UserConfigDir()` before parsing
  `--config_dir`, so the systemd unit sets `Environment=HOME=/root`.
- **OAuth callback / restart churn** — go-librespot's login callback is on a fixed
  port (`credentials.interactive.callback_port: 8898`); the login helper stops
  the service first so the PKCE challenge can't rotate mid-login.
- **Voice gateway v8** — the single biggest fix. Everything else (NAT vs mirrored
  networking, back when this ran in WSL) was a red herring for *voice*; the real
  blocker was the outdated library.
- **Encryption** — `@noble/ciphers` + `libsodium-wrappers` are installed for the
  v8 AEAD encryption modes.

## Caveats

- **Spotify ToS:** go-librespot is a reverse-engineered Connect client, so this is
  technically against Spotify's terms. Keep the bot **private** to your own server.
- **One stream per account:** while the bridge plays, "Discord" is your active
  Spotify device.
- Expect ~1–2s latency.
