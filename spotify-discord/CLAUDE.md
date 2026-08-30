# Spotify → Discord bridge — orientation for Claude

Makes a Discord bot act as a **Spotify Connect speaker**. Pick **Discord** from the Connect/devices
menu in any Spotify app and the audio plays into a Discord voice channel. Playback is driven from
Spotify itself (or from Discord slash commands); the bot is just the output device. Requires
**Spotify Premium**.

`README.md` (user-facing) and `cloud/README.md` (VPS install) describe how to *set it up*. This file
describes **where it actually runs, why each piece exists, and what has broken before** — read it
before changing anything here.

---

## READ THIS FIRST: it does not run on this PC

**The live bridge runs on a RackNerd cloud VPS. Nothing spotify-related runs locally.**

The root `CLAUDE.md` still describes the original local WSL deployment (systemd units in
`Ubuntu-24.04`, `WSLKeepAlive`, the `SpotifyDiscordBridge` scheduled task, mirrored networking).
That deployment is **gone**. Verified on 2026-08-30:

| Claim in the old docs | Reality on this machine |
|---|---|
| `go-librespot` / `spotify-discord-bot` systemd units in WSL | `Unit go-librespot.service could not be found` — neither unit exists |
| `/etc/spotify-discord.env` in WSL | does not exist |
| bot installed in WSL | no binaries, no app dir, nothing listening on 3678 |
| `SpotifyDiscordBridge` scheduled task | not registered |
| WSL in **mirrored** networking mode (a stated hard requirement) | `wslinfo --networking-mode` → **`nat`**, and there is no `%USERPROFILE%\.wslconfig` at all |

So when the bridge misbehaves, **do not debug locally** — you will find an empty machine and
conclude the wrong thing. Go to the VPS (see *Operating it*).

The local-WSL scripts are still in this folder and still work, but they are a **dormant alternative
path**, not what is deployed. The VPS was chosen because a real KVM box has clean outbound UDP (so
Discord voice and the OAuth callback just work, with none of the mirrored-networking gymnastics) and
because it is always on, with no WSL CPU jitter in the audio.

---

## Architecture

```
Spotify app (phone / desktop / web)   ← you control playback here
   │  pick the "Discord" device in the Connect menu
   ▼
go-librespot          Spotify Connect device, logged in via OAuth
   │                  HTTP control API on 127.0.0.1:3678 (+ /events WebSocket)
   │  raw PCM  s16le 44.1 kHz stereo
   ▼
/tmp/spotify-discord.fifo            named pipe
   ▼
bot.js  →  ffmpeg (44.1 → 48 kHz, soxr)  →  @discordjs/voice (gateway v8, Opus)
   ▼
Discord voice channel
```

`dj.js` and `accounts.js` ride alongside `bot.js` in the same process:

- **`bot.js`** owns the audio path — FIFO, ffmpeg, the voice connection, auto-join/auto-leave.
- **`dj.js`** owns Discord-side *control*: it drives go-librespot's HTTP API at `127.0.0.1:3678`
  and follows its `/events` WebSocket to auto-advance a bot-managed queue. Spotify Web API
  (client-credentials) provides search; without `SPOTIFY_CLIENT_ID`/`SECRET` it is links-only.
- **`accounts.js`** swaps which Spotify account go-librespot is logged into (`/login`,
  `/logincode`, `/resetaccount`, `/account`), driving the service via `systemctl` and keeping the
  original login in `state.owner.json`. One account plays at a time.

### Why it is built this way

| Choice | Reason |
|---|---|
| **go-librespot** | Spotify has no official "be a speaker" API. It is a reverse-engineered Connect client, so the device appears natively in the Connect menu. |
| **OAuth login, not LAN zeroconf** | zeroconf only advertises on the same LAN. OAuth makes the "Discord" device visible from **anywhere over the internet** — the whole point of a VPS-hosted speaker. |
| **A named pipe (FIFO)** | Decouples the two processes: go-librespot writes a plain PCM stream and neither side needs to know about the other. Also means restarting one does not require restarting the other. |
| **ffmpeg 44.1 → 48 kHz** | go-librespot's pipe output is 44.1 kHz; Discord voice is 48 kHz. `soxr` at precision 28 keeps the resample transparent. |
| **`@discordjs/voice` ≥ 0.19** | Load-bearing — see gotchas. |

---

## Runtime layout (on the VPS)

| Thing | Path / value |
|---|---|
| App dir | `/opt/spotify-discord` (`bot.js`, `dj.js`, `accounts.js`, `node_modules`) |
| go-librespot binary | `/usr/local/bin/go-librespot` |
| go-librespot config + credentials | `/root/.config/go-librespot/` — `config.yml`, `state.json` (login), `state.owner.json` (owner backup) |
| Bot environment | `/etc/spotify-discord.env` |
| FIFO | `/tmp/spotify-discord.fifo` (created by `ExecStartPre` on both units) |
| Control API | `127.0.0.1:3678` — HTTP + `/events` WebSocket, loopback only |
| OAuth callback | `127.0.0.1:8898`, only during interactive login |
| systemd units | `go-librespot.service`, `spotify-discord-bot.service`, `golibrespot-watchdog.{service,timer}` |

Both services are `Restart=on-failure`, enabled at boot. The bot unit is `After=go-librespot.service`
but does not require it — `dj.js` reconnects its `/events` WebSocket every 2 s on close, so
restarting go-librespot alone is safe and the bot re-attaches on its own (verified).

Environment keys actually set on the box: `DISCORD_BOT_TOKEN`, `DISCORD_GUILD_ID`,
`DISCORD_VOICE_CHANNEL_ID`, `SPOTIFY_FIFO`, `SPOTIFY_PIPE_RATE`, `SPOTIFY_CLIENT_ID`,
`SPOTIFY_CLIENT_SECRET`. `.env.example` documents the optional audio-tuning knobs
(`SPOTIFY_OPUS_BITRATE`, `SPOTIFY_OPUS_FEC`, `SPOTIFY_OPUS_PLP`, `SPOTIFY_RESAMPLER`,
`EMPTY_DISCONNECT_SECONDS`) that are left at their `bot.js` defaults here.

Known-good versions as deployed: go-librespot **0.9.0**, Node **v22**, ffmpeg **6.1.1**,
`@discordjs/voice` **0.19.2**.

---

## Files

### Shared runtime (deployed to the VPS *and* usable in WSL)

| File | Purpose |
|---|---|
| `bot.js` | Audio path: FIFO reader, ffmpeg, voice connection, auto-join/auto-leave, `/join` `/leave` `/reconnect` `/status` |
| `dj.js` | DJ engine: queue, search, transport, live player card; drives the go-librespot API + `/events` |
| `accounts.js` | Swappable Spotify account (`/login`, `/logincode`, `/resetaccount`, `/account`) |
| `config.yml` | go-librespot config — pipe output, OAuth, fixed callback port, API on 3678 |
| `package.json` | Node deps. **`@discordjs/voice` ≥ 0.19 is load-bearing** |
| `.env.example` | Reference for `/etc/spotify-discord.env` |
| `README.md` | User-facing setup guide |

### Cloud deployment — **this is the live one**

| File | Purpose |
|---|---|
| `cloud/setup-cloud.sh` | One-shot installer, run as root on a fresh Debian/Ubuntu KVM box. Installs deps, Node 22, go-librespot, fetches the app from GitHub raw, writes both units + the watchdog, enables everything |
| `cloud/login-spotify-cloud.sh` | One-time Spotify OAuth on the VPS (needs an SSH `-L 8898` tunnel so your local browser can reach the callback) |
| `cloud/golibrespot-heal.sh` | **Self-healing watchdog.** Runs every 2 min from `golibrespot-watchdog.timer`; detects the known failure modes and escalates restart -> binary upgrade -> rollback. See *Self-healing* below |
| `cloud/vps-ssh.ps1` | **How you reach the box.** Runs remote commands / scripts / tunnels via plink, reading credentials from the repo `.secrets` |
| `cloud/README.md` | VPS install walkthrough |

### Documentation and tracking (mandatory, and enforced)

| File | Purpose |
|---|---|
| `FAILURES.md` | **The failure registry.** Every way this bridge has broken, with a stable `SD-0NN` id, its detection signature, and whether it is `auto-healed` / `prevented` / `manual` |
| `tests/spotify-discord.tests.ps1` | Enforces both rules below. Run: `tests\run-tests.ps1 -Path tests\spotify-discord.tests.ps1` |

Two rules apply to any change in this folder:

1. **Every fix and every self-healing behaviour gets a `FAILURES.md` entry, in the same change.**
   Ids are stable and permanent — never renumber, never reuse a retired one.
2. **Every top-level function in `bot.js` / `dj.js` / `accounts.js` carries a TSDoc block**, ending
   on the line directly above the declaration. Where a function exists because of a known failure,
   tag it `@failureMode SD-0NN` — that tag is the link between the code and the registry.

The test suite fails the build if a top-level function is undocumented, if code references an
`SD-` id the registry does not define, or if the registry claims a failure is `auto-healed` while
the healer script contains no detector for it. That last one matters most: it stops "we self-heal
that" from becoming a claim nothing backs up.

> **Verified by breaking it, not by watching it pass.** Each rule was proven by introducing the
> violation and confirming the matching test failed: stripping the TSDoc above `connectEvents`,
> pointing a tag at a nonexistent `SD-999`, and adding an `auto-healed` registry row the healer
> knows nothing about. All three failed as intended and were reverted.

### Legacy local-WSL path (dormant — not deployed)

| File | Purpose |
|---|---|
| `setup-spotify-discord.bat` | One-click: mirrored networking → WSL install → scheduled task |
| `setup-spotify-discord-wsl.sh` | WSL installer (systemd units inside the distro) |
| `setup-wsl-mirrored.ps1` | Writes `networkingMode=mirrored` + `hostAddressLoopback=true` to `.wslconfig` |
| `install-scheduled-task.ps1` | Registers the `SpotifyDiscordBridge` logon task |
| `login-spotify.ps1` / `login-spotify.sh` | One-time OAuth for the WSL deployment |

> Reviving the local path is a real decision, not a fallback: mirrored networking changes how the
> **web console** is wired (WSL sshd moves to 2222, the Windows TCP relays stop being used). See the
> mirrored-networking note in the root `CLAUDE.md`.

---

## Operating it

Everything goes through `cloud/vps-ssh.ps1`, which reads `RACKNERD_VPS_IP` / `_USER` / `_PASSWORD` /
`_HOSTKEY` from the repo `.secrets` (populate with `cloudflared\sync-secrets.bat`; needs plink from
PuTTY). **Never hardcode or echo those values.**

```powershell
cd spotify-discord\cloud
.\vps-ssh.ps1 "systemctl is-active go-librespot spotify-discord-bot"
.\vps-ssh.ps1 "journalctl -u go-librespot -u spotify-discord-bot -n 80 --no-pager"
.\vps-ssh.ps1 -Script path\to\local.sh      # run a multi-line script remotely
.\vps-ssh.ps1 -Tunnel 8898                  # OAuth login tunnel
```

**Health check that actually distinguishes the layers:**

```bash
systemctl is-active go-librespot spotify-discord-bot golibrespot-watchdog.timer
curl -s -w '\n%{http_code}\n' http://127.0.0.1:3678/status      # is the Connect device alive + logged in?
ps -o pid,pcpu,etime -C go-librespot                            # sustained high CPU is a bug, not load
journalctl -u go-librespot -n 50 --no-pager                     # the real error always lands here
```

**Deploying a code change:** the VPS runs *copies* fetched from GitHub raw at install time
(`/opt/spotify-discord`), not a checkout. Push first, then re-fetch on the box — editing the repo
alone changes nothing. Current copies were verified byte-identical to this repo, so keep it that
way; drift here is invisible and behaves like a phantom bug.

---

## Slash commands

`/play` `/radio` `/summon` `/skip` `/pause` `/resume` `/nowplaying` `/player` `/queue` `/move`
`/remove` `/shuffle` `/clear` `/volume` `/help` (dj.js) · `/join` `/leave` `/reconnect` `/status`
(bot.js) · `/login` `/logincode` `/resetaccount` `/account` (accounts.js, gated to Manage-Server).

`/play` and `/radio` accept song *names* only when `SPOTIFY_CLIENT_ID`/`SECRET` are set; otherwise
Spotify links only.

---

## Self-healing (`cloud/golibrespot-heal.sh`)

`golibrespot-watchdog.timer` fires every 2 minutes and runs the healer. It repairs only what is
actually broken, and escalates when a restart provably cannot help.

```bash
golibrespot-heal.sh --dry-run             # report what it WOULD do, change nothing
golibrespot-heal.sh                       # heal (what the timer runs)
golibrespot-heal.sh --force-check-version # ignore the weekly interval
journalctl -t golibrespot-heal -n 50      # what it has been doing
```

**Escalation.** Dealer stalls (SD-003) and a dead API (SD-004) get a plain restart. A login5 auth
failure (SD-001) or a CPU spin (SD-002) gets **one** restart; if the symptom returns within the
hour, that proves the fault is in the binary rather than the process, so the healer upgrades
go-librespot, verifies, and **rolls back to the previous binary if verification fails**. Separately
it checks weekly for a newer release (SD-005), so the box cannot rot silently between failures.

**Verification is capability-based, not liveness-based:** unit active **and** `/status` 200 **and**
`authenticated Login5` in the log since the restart. A process that is up but cannot authenticate is
not a fixed one. The check polls for up to 45s rather than sampling once after a fixed sleep — the
marker normally lands 0.5s after start, but calling a *slow* login a *failed* one would roll back a
perfectly good upgrade, unattended, where nobody would notice for weeks.

> **Safety contract — why this is safe to run every 2 minutes.** It never acts while audio is
> playing (checked first, before anything else). It only ever restarts go-librespot — never the bot.
> It never writes `state.json`, only backs it up. Restarts and upgrades are rate-limited (5 min /
> 24 h) so it cannot flap. Errors logged *before* the last restart are ignored, or it would re-read
> the same historical failure every 2 minutes and escalate forever.

> **What the old watchdog got wrong, and must not be reverted to.** It greped for exactly one
> string — `did not receive last pong from dealer` — and therefore sat idle through the entire
> SD-001 outage, in which every play returned HTTP 500 for two weeks while it reported nothing. A
> watchdog that matches one failure mode is not a watchdog; it is a single retry with a timer.

> **Playback is a hard gate, so a box that streams 24/7 defers upgrades.** That is intended — an
> upgrade waits for an idle moment rather than cutting off a song. It does not defer *detection* of
> a broken state, because SD-001 makes playback impossible, so an affected box is idle by
> definition.

## Gotchas — every one of these actually happened

> **A stale go-librespot binary breaks playback with `/player/play → HTTP 500`, and nothing else
> looks wrong.** This was the 2026-08-30 outage, and it is the failure mode most likely to recur.
>
> The Discord-visible symptom is `[dj] command play error: go-librespot /player/play → HTTP 500`
> (thrown by `lrs()` in `dj.js`). Everything else looked healthy: both services `active`, the bot in
> the voice channel, `/status` returning 200, and go-librespot logging `authenticated AP` on
> schedule. The real error was only ever in go-librespot's own journal:
>
> ```
> failed handling request play → failed resolving context: spclient request failed:
>   failed obtaining spclient access token: failed renewing login5 access token:
>   failed authenticating with login5: UNKNOWN_ERROR
> ```
>
> **Cause:** the box was running go-librespot **v0.7.4** (installed June), which has a bug in the
> login5 hashcash solver — `hasher := sha1.New()` is created *outside* the retry loop and never
> reset, so every iteration after the first hashes the accumulated concatenation of all previous
> candidates instead of the current one. It submits a solution Spotify cannot verify, login5 answers
> `UNKNOWN_ERROR`, and every `spclient` call (context resolution, i.e. *playing anything*) fails.
> Upstream fixed it in **v0.9.0** (`fix: reset hasher when retrying hashcash`, plus
> `fix: do not send requests with empty Client-Token`).
>
> **Why it is easy to misread:** AP authentication uses a different path and kept succeeding, so the
> logs are full of reassuring `authenticated AP` lines. The tell is the *absence* of
> `authenticated Login5` at startup — v0.9.0 logs it, the broken version never did. The other tell
> is **CPU**: the spinning solver ran at 63.7% for 39 days (systemd reported `Consumed 3w 4d 9h`
> CPU time on stop, load average pinned at exactly 1.00). A Connect device that is idle should sit
> near 0%.
>
> **Fix:** upgrade the binary and restart.
>
> ```bash
> cp -a /root/.config/go-librespot/state.json /root/.config/go-librespot/state.json.bak.$(date +%F)
> cp -a /usr/local/bin/go-librespot /usr/local/bin/go-librespot.prev.bak
> curl -fsSL https://github.com/devgianlu/go-librespot/releases/latest/download/go-librespot_linux_x86_64.tar.gz -o /root/glr.tar.gz
> tar -xzf /root/glr.tar.gz -C /root go-librespot && install -m 755 /root/go-librespot /usr/local/bin/go-librespot
> systemctl restart go-librespot
> journalctl -u go-librespot -n 20 --no-pager   # expect: "running go-librespot 0.9.0" AND "authenticated Login5"
> ```
>
> Back up `state.json` first — it holds the Spotify login, and losing it means redoing the OAuth
> tunnel dance. Verify with a real request, not just a healthy-looking status:
> `curl -X POST -H 'Content-Type: application/json' -d '{"uri":"spotify:track:...","paused":false}' http://127.0.0.1:3678/player/play`
> must return **200**, then `POST /player/stop`.
>
> **This is now auto-healed** — `cloud/golibrespot-heal.sh` detects exactly these log lines and
> escalates to an upgrade (see *Self-healing* above). The manual procedure remains here because it
> is what the healer automates, and because you will want it if the healer itself is what broke.
>
> **Nothing upgraded this binary before that.** `setup-cloud.sh` installs `releases/latest` —
> correct at install time and never revisited, so a long-lived box silently rots as Spotify tightens
> its auth; the healer's weekly version check now closes that gap. When
> playback breaks with no obvious cause, **check the go-librespot version first**. The installed
> version is not printable (`--version` is not a flag; it errors with `unknown flag`) — read it from
> the startup log line `running go-librespot X.Y.Z`, or match the binary's mtime against the release
> dates, since the tarball preserves the build time.

> **The dealer watchdog does not cover this.** `golibrespot-watchdog.timer` fires every 2 minutes
> but only greps for `did not receive last pong from dealer` (≥ 3 in 3 min) — a *stale dealer
> connection*. The login5 failure produces entirely different log lines, so the watchdog sat there
> doing nothing for two weeks while every play failed. Do not assume "the watchdog would have caught
> it"; it catches exactly one failure mode.

> **`@discordjs/voice` must be ≥ 0.19 (voice gateway v8).** Discord rejects gateway v4, which 0.18
> uses: the voice websocket opens, receives Hello, then closes — surfacing as *"the operation was
> aborted"* and `net-state 1 → 6`, never reaching UDP. This was the single biggest fix in the
> project's history, and NAT-vs-mirrored networking was a **red herring** for voice the whole time.
> Verify with `grep -o 'v=[0-9]' node_modules/@discordjs/voice/dist/index.js`. `@noble/ciphers` and
> `libsodium-wrappers` are dependencies because v8 needs the AEAD encryption modes.

> **go-librespot needs `HOME` set.** It calls `os.UserConfigDir()` *before* parsing `--config_dir`,
> so the unit carries `Environment=HOME=/root`. Drop it and it looks for credentials in the wrong
> place and asks for a fresh login.

> **`bot.js` holds the FIFO open `O_RDWR` on purpose.** go-librespot opens and closes its writer end
> between tracks and on pause. If ffmpeg were the only handle, it would hit EOF and exit every time
> playback stopped. The idle keep-alive fd guarantees the pipe always has a writer; it is never read
> from or written to. Do not "clean up" that unused descriptor.

> **`needrestart` is deliberately muzzled.** `setup-cloud.sh` writes
> `$nrconf{restart} = 'l'` so unattended security upgrades only *list* services instead of bouncing
> them — a restart mid-stream drops the playback session and reads as "the sound randomly died".

> **The OAuth callback is on a fixed port for a reason.** `credentials.interactive.callback_port:
> 8898` exists so a stable SSH `-L 8898:localhost:8898` tunnel can carry the redirect from your
> local browser to the VPS. A *"connection reset"* page after clicking **Agree** is normal — the
> login still completes. Login is genuinely one-time; credentials persist in `state.json` across
> reboots. Back that file up (and `SPOTIFY_GO_LIBRESPOT_STATE_B64` in secrets lets `setup-cloud.sh`
> rebuild a box without any login step).

> **`vps-ssh.ps1` takes one string, and PowerShell will fight you.** Backslash-escaped quotes,
> `|` inside the command, and `,`/`(` in an inline `node -e` all get eaten by the PowerShell parser
> before plink sees them. For anything beyond a simple command, write a `.sh` file and use
> `-Script` — it is passed to plink with `-m` and reaches the shell verbatim.

> **Spotify ToS / privacy:** go-librespot is a reverse-engineered client, so keep the bot private to
> your own server. While the bridge plays, "Discord" is the account's active device — one stream at
> a time. Expect ~1–2 s latency.

---

## Debugging order (learned the hard way)

The 500 above cost real time because the investigation started at the wrong layer. Work in this
order:

1. **Which box?** The VPS. Not WSL, not Windows.
2. **go-librespot's own journal.** The Discord-side error (`HTTP 500`) is only a relay of it; the
   actionable message is always upstream in `journalctl -u go-librespot`.
3. **Version and CPU of go-librespot** before suspecting the network, Discord, or the bot.
4. **Only then** the bot, ffmpeg, and the voice connection.

A green `systemctl is-active` and a 200 from `/status` prove the process is *up*, not that it can
*play*. Prove playback with an actual `POST /player/play`.
