# Spotify → Discord voice bridge

Turns a Discord bot into a **Spotify Connect speaker**. Pick **Discord** from the
Connect (devices) menu in your normal Spotify app — on your phone, PC, or web —
and the audio plays into a Discord voice channel instead of your local speakers.
You control everything (play, pause, skip, queue) from Spotify as usual; the bot
is only the output device.

Requires **Spotify Premium**.

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
- Both pieces run as **systemd services in WSL** (`go-librespot`,
  `spotify-discord-bot`), enabled at boot, held alive by the `WSLKeepAlive` task,
  and (re)started at logon by the `SpotifyDiscordBridge` scheduled task.

## Networking: WSL mirrored mode (required)

This bridge requires **WSL2 mirrored networking** (`networkingMode=mirrored` in
`%USERPROFILE%\.wslconfig`). Two reasons:

1. **Discord voice needs a clean network path.** Under WSL2's default NAT the
   voice UDP handshake and the OAuth callback are flaky. Mirrored mode gives WSL
   the Windows network stack directly.
2. **`hostAddressLoopback=true`** lets Windows (cloudflared) reach WSL services on
   `127.0.0.1` directly.

`setup-wsl-mirrored.ps1` writes this config and restarts WSL (idempotent).

> **Console impact (already handled):** mirrored mode makes WSL and Windows share
> ports, so the web console no longer uses the Windows `tcp-relay.js`/`ssh-proxy.js`
> relays, and WSL sshd moves to **2222** (Windows OpenSSH keeps 22). `start-console.ps1`
> auto-detects mirrored mode and does the right thing — no manual action needed.

## Files

| File | Purpose |
|---|---|
| `bot.js` | discord.js bot: reads the pipe, joins voice, streams audio |
| `config.yml` | go-librespot config (pipe output, OAuth login, fixed callback port) |
| `package.json` | Node deps (**`@discordjs/voice` ≥ 0.19** = voice gateway v8) |
| `setup-spotify-discord.bat` | One-click installer: mirrored net → WSL install → scheduled task |
| `setup-wsl-mirrored.ps1` | Sets WSL to mirrored networking (prereq) |
| `setup-spotify-discord-wsl.sh` | WSL installer — go-librespot, deps, systemd services |
| `install-scheduled-task.ps1` | Registers the `SpotifyDiscordBridge` logon task |
| `login-spotify.ps1` | One-time Spotify OAuth login (Windows, mirrored-aware) |
| `login-spotify.sh` | Older WSL-only OAuth helper (PS1 is preferred) |
| `.env.example` | Reference for the runtime env (`/etc/spotify-discord.env`) |

## First-time setup

1. **Create the Discord bot** at <https://discord.com/developers/applications>:
   - New Application → **Bot** → Reset Token → copy it.
   - **OAuth2 → URL Generator**: scopes `bot` + `applications.commands`; bot
     permissions **View Channels + Connect + Speak** (`permissions=3146752`).
     Open the generated URL to invite it to your server.
   - Copy your **Server ID** and target **Voice Channel ID** (Developer Mode →
     right-click → Copy ID). *(Or let the bot print them: it logs `VOICECHAN`
     lines for every voice channel on startup.)*

2. **Add the secrets** to GitHub, then sync:
   - GitHub → repo Settings → Secrets → Actions, add `DISCORD_BOT_TOKEN`,
     `DISCORD_GUILD_ID`, `DISCORD_VOICE_CHANNEL_ID`.
   - Run `cloudflared\sync-secrets.bat` to pull them into `.secrets`.

3. **Install** (double-click or run):
   ```
   spotify-discord\setup-spotify-discord.bat
   ```
   This runs all three steps: mirrored networking → WSL install → scheduled task.

4. **One-time Spotify login**:
   ```
   powershell -ExecutionPolicy Bypass -File spotify-discord\login-spotify.ps1
   ```
   Log in with Premium and click **Agree**. A "connection reset/refused" page
   after Agree is normal — the login still completes. Credentials are
   account-scoped and reused across reboots (genuinely one-time).

5. **Use it** — open Spotify, hit the Connect/devices icon, pick **Discord**, and
   play. The bot auto-joins `DISCORD_VOICE_CHANNEL_ID` (or use `/join`).

## Run it on a cloud VPS (always-on, better sound)

For 24/7 availability and cleaner audio (no WSL CPU jitter), run the bridge on a
cheap always-on Linux VPS instead of your PC. A real VPS has proper outbound UDP,
so none of the mirrored-networking setup is needed. See **`cloud/README.md`** —
it's a one-command installer plus an SSH-tunnel login. Recommended: any KVM VPS
with ≥ 1 GB RAM (a private music bot uses ~5–10% CPU / ~150 MB RAM / ~50 MB per
hour of listening).

## Slash commands

| Command | Action |
|---|---|
| `/join` | Pull the speaker into the voice channel you're currently in |
| `/leave` | Disconnect |
| `/reconnect` | Restart the audio stream (if it ever stalls) |
| `/status` | Show voice / ffmpeg / pipe status |

## Restore after a format

Fully reproducible from this repo:

1. Restore WSL, run `cloudflared\sync-secrets.bat` (brings back the 3 Discord secrets).
2. Run `spotify-discord\setup-spotify-discord.bat` (mirrored net + install + task).
3. Run `login-spotify.ps1` once (Spotify OAuth can't live in a secret).

systemd services are enabled and the `SpotifyDiscordBridge` task starts them at
logon — nothing to do day to day.

## Troubleshooting

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
- **Device not showing in Spotify:** go-librespot needs login → run `login-spotify.ps1`.
- **WSL VM asleep (services dead):** `wsl --list --running`; the `WSLKeepAlive`
  task should prevent it.

## Hard-won gotchas (why the scripts look the way they do)

- **go-librespot needs `HOME`** — it calls `os.UserConfigDir()` before parsing
  `--config_dir`, so the systemd unit sets `Environment=HOME=/root`.
- **OAuth callback / restart churn** — go-librespot's login callback is on a fixed
  port (`credentials.interactive.callback_port: 8898`); `login-spotify.ps1`
  temporarily disables service auto-restart so the PKCE challenge can't rotate
  mid-login.
- **Voice gateway v8** — the single biggest fix. Everything else (NAT vs mirrored)
  was a red herring for *voice*; the real blocker was the outdated library.
- **Encryption** — `@noble/ciphers` + `libsodium-wrappers` are installed for the
  v8 AEAD encryption modes.

## Caveats

- **Spotify ToS:** go-librespot is a reverse-engineered Connect client, so this is
  technically against Spotify's terms. Keep the bot **private** to your own server.
- **One stream per account:** while the bridge plays, "Discord" is your active
  Spotify device.
- Expect ~1–2s latency.
