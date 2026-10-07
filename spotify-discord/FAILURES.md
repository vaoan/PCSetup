# Failure registry — Spotify → Discord bridge

Every way this bridge has actually broken, what it looked like, and what now handles it.

**This file is mandatory to update.** Whenever a fix or a self-healing behaviour is added, add or
amend an entry here *in the same change*. The point is to know the shape of this bot's failure
surface without re-deriving it from journals at 2am. IDs are stable and permanent — never renumber
them, never reuse a retired one.

Library functions reference these IDs in their TSDoc with `@failureMode SD-00N`, so the code and
this registry stay tied together. `tests/spotify-discord.tests.ps1` fails the build if an ID is
referenced but missing here, or if a documented auto-heal has no detector in the healer script.

**Status** values:
- `auto-healed` — `cloud/golibrespot-heal.sh` detects and repairs it unattended.
- `prevented` — a design/config choice makes it structurally impossible; no runtime detection.
- `manual` — still needs a human. These are the gaps.

| ID | Failure | Status |
|---|---|---|
| [SD-001](#sd-001) | login5 auth failure → every play returns HTTP 500 | `auto-healed` |
| [SD-002](#sd-002) | hashcash solver CPU spin (idle box burns a core) | `auto-healed` |
| [SD-003](#sd-003) | Spotify dealer connection goes stale | `auto-healed` |
| [SD-004](#sd-004) | control API stops answering on 3678 | `auto-healed` |
| [SD-005](#sd-005) | go-librespot binary version rot | `auto-healed` |
| [SD-006](#sd-006) | Discord voice gateway v4 rejected → cannot join voice | `prevented` |
| [SD-007](#sd-007) | ffmpeg exits at every pause (FIFO EOF) | `prevented` |
| [SD-008](#sd-008) | unattended-upgrades bounces services mid-stream | `prevented` |
| [SD-009](#sd-009) | `HOME` unset → go-librespot reads the wrong config dir | `prevented` |
| [SD-010](#sd-010) | transport controls sent as GET → HTTP 405 | `prevented` |
| [SD-011](#sd-011) | VPS runs a stale copy of the app files | `manual` |
| [SD-012](#sd-012) | debugging the wrong machine (docs say WSL; it runs on a VPS) | `manual` |
| [SD-013](#sd-013) | service auto-restart rotates the PKCE challenge mid-login | `prevented` |
| [SD-014](#sd-014) | a failed account switch leaves the bridge logged out | `prevented` |
| [SD-015](#sd-015) | YouTube bot check blocks the VPS IP ("Sign in to confirm you're not a bot") | `manual` |
| [SD-016](#sd-016) | yt-dlp version rot → YouTube stops resolving | `prevented` |
| [SD-017](#sd-017) | ffmpeg fetching the googlevideo URL directly → HTTP 403 | `prevented` |
| [SD-018](#sd-018) | a skipped YouTube track's yt-dlp keeps running (orphaned child) | `prevented` |

---

## SD-001
**login5 authentication failure — every play returns HTTP 500**

- **First seen:** 2026-08-16 · **Diagnosed & fixed:** 2026-08-30 (broken ~2 weeks)
- **Symptom (Discord):** `[dj] command play error: go-librespot /player/play → HTTP 500`
- **Symptom (go-librespot journal):**
  `failed handling request play → failed resolving context: spclient request failed: failed
  obtaining spclient access token: failed renewing login5 access token: failed authenticating with
  login5: UNKNOWN_ERROR`
- **Root cause:** a bug in go-librespot **v0.7.4**. Its login5 hashcash solver creates
  `hasher := sha1.New()` *outside* the retry loop and never resets it, so every iteration after the
  first digests the accumulated concatenation of all previous candidates rather than the current
  one. It submits a solution Spotify cannot verify → `UNKNOWN_ERROR` → no spclient token → context
  resolution fails → playing anything is impossible. Fixed upstream in **v0.9.0**
  (`fix: reset hasher when retrying hashcash`).
- **Why it was hard to see:** AP authentication uses a different code path and kept succeeding, so
  the journal is full of reassuring `authenticated AP` lines. Both services were `active`, `/status`
  returned 200, and the bot sat happily in the voice channel. The tell is the **absence** of
  `authenticated Login5`.
- **A restart does not fix it.** The fault is compiled into the binary. This is the entire reason
  the healer escalates to an upgrade instead of just restarting.
- **Detection:** journal match on
  `failed authenticating with login5|failed renewing login5 access token|failed obtaining spclient access token`
  within the live window (strictly after the last restart, so old lines cannot re-trigger it).
- **Healing:** restart once → if the symptom returns inside 1 h, upgrade the binary, verify, roll
  back on failure.
- **Evidence:** upstream commit `09e1186`; reproduced with `POST /player/play` → 500 before the
  upgrade and 200 after.

## SD-002
**hashcash solver CPU spin**

- **First seen:** 2026-08-30 (as the corroborating signal for SD-001)
- **Symptom:** go-librespot burns a full core while completely idle. Measured **63.7% average over
  39 days**; systemd reported `Consumed 3w 4d 9h 49min` CPU time on stop, load average pinned at
  exactly 1.00.
- **Root cause:** same broken hashcash loop as SD-001, spinning without ever finding an acceptable
  solution.
- **Why it matters separately:** it is observable **while nobody is playing anything**, which makes
  it the early-warning signal for SD-001. SD-001 only announces itself when a human presses play and
  gets an error; this shows up beforehand.
- **Detection:** instantaneous CPU ≥ 30% sampled from `/proc/<pid>/stat` while playback is stopped.
  Deliberately *not* `ps -o pcpu`, which reports the average over process lifetime and would both
  miss a new spin and slander a freshly restarted process.
- **Healing:** same escalation as SD-001.

## SD-003
**Spotify dealer connection goes stale**

- **Symptom:** new tracks fail (HTTP 500 / `context deadline exceeded`); journal repeats
  `did not receive last pong from dealer`. go-librespot does not reconnect on its own.
- **Detection:** ≥ 3 pong-loss lines in the live window.
- **Healing:** plain restart — this one genuinely is fixed by a restart, so it deliberately never
  escalates to a binary upgrade.
- **Note:** this was the *only* thing the original watchdog looked for, which is why it sat idle
  through the entire SD-001 outage.

## SD-004
**control API stops answering on 127.0.0.1:3678**

- **Symptom:** `/status` returns nothing or a non-200; the bot's `/events` WebSocket cannot attach,
  so the DJ queue stops advancing.
- **Detection:** `curl /status` returns anything other than 200 (including `000`).
- **Healing:** restart, escalating to an upgrade if it recurs.

## SD-005
**binary version rot**

- **Root cause:** `setup-cloud.sh` installs `releases/latest` — correct on install day and never
  revisited. Nothing ever upgraded go-librespot again, so the box silently decayed as Spotify
  tightened its auth. This is the *systemic* cause behind SD-001: the box ran a June binary in
  late August.
- **Detection:** weekly comparison of the running version (`running go-librespot X.Y.Z` in the
  startup log) against the latest GitHub release.
- **Healing:** upgrade during an idle moment, verified, with rollback.
- **Note:** the binary has **no `--version` flag** (`--version` errors with `unknown flag`), which
  is why the version is read from the startup log line.

## SD-006
**Discord voice gateway v4 rejected — bot cannot join voice**

- **Symptom:** `Failed to join: The operation was aborted`, `net-state 1 → 6`. The voice websocket
  opens, receives Hello, then closes; UDP is never reached.
- **Root cause:** `@discordjs/voice` 0.18 speaks voice gateway **v4**, which Discord now rejects.
- **Prevented by:** pinning `@discordjs/voice` **≥ 0.19** (v8) in `package.json`, with
  `@noble/ciphers` + `libsodium-wrappers` for the v8 AEAD modes.
- **Historical note:** NAT-vs-mirrored networking was chased for a long time and was a **red
  herring** for voice. The library version was the whole problem.
- **Verify:** `grep -o 'v=[0-9]' node_modules/@discordjs/voice/dist/index.js`

## SD-007
**ffmpeg exits at every pause (FIFO EOF)**

- **Symptom:** the transcoder dies and restarts whenever playback stops or between tracks; audible
  as dropouts, visible as `ffmpeg exited (code=224)` churn.
- **Root cause:** go-librespot opens and closes its writer end of the FIFO between tracks. If ffmpeg
  is the only handle, the pipe hits EOF and ffmpeg exits.
- **Prevented by:** `bot.js` holding an idle `O_RDWR` descriptor on the FIFO so it always has a
  writer. It is never read from or written to — **do not "clean up" that unused descriptor.**

## SD-008
**unattended-upgrades bounces services mid-stream**

- **Symptom:** audio dies at seemingly random times, correlating with security update cycles.
- **Root cause:** `needrestart` auto-restarts services whose libraries were updated; restarting
  go-librespot drops the playback session.
- **Prevented by:** `setup-cloud.sh` writing `$nrconf{restart} = 'l'` (list only).

## SD-009
**`HOME` unset → go-librespot reads the wrong config dir**

- **Symptom:** go-librespot ignores existing credentials and asks for a fresh interactive login.
- **Root cause:** it calls `os.UserConfigDir()` *before* parsing `--config_dir`.
- **Prevented by:** `Environment=HOME=/root` in `go-librespot.service`.

## SD-010
**transport controls sent as GET → HTTP 405**

- **Symptom:** `/pause`, `/resume`, `/stop` fail with HTTP 405.
- **Root cause:** go-librespot's player endpoints are POST-only; they were being called with GET.
- **Prevented by:** `lrs()` in `dj.js` choosing POST whenever a body is supplied — which is why
  the no-argument calls pass `{}` rather than nothing. Removing those braces silently reintroduces
  this. Fixed in commit `e8914ee`.

## SD-011
**VPS runs a stale copy of the app files**

- **Symptom:** a fix is made in the repo, the service is restarted, and nothing changes.
- **Root cause:** the VPS runs *copies* in `/opt/spotify-discord` fetched from GitHub raw at install
  time — it is not a checkout. Editing the repo alone changes nothing on the box, and pushing alone
  does not either.
- **Status:** `manual`. Deploying means re-fetching on the box after pushing.
- **Check:** compare `md5sum` of `/opt/spotify-discord/{bot,dj,accounts}.js` against the repo
  (normalise line endings first). Verified identical on 2026-08-30.
- **Same class of bug** as the WSL console proxies documented in the root `CLAUDE.md`, which served
  dead hostnames for days for exactly this reason.

## SD-012
**debugging the wrong machine**

- **Symptom:** investigation of a live bridge failure finds no services, no config and no binaries,
  suggesting a catastrophic uninstall.
- **Root cause:** the root `CLAUDE.md` documents the original **local WSL** deployment, which no
  longer exists on this PC. The live bridge runs on the RackNerd VPS. Verified 2026-08-30: no
  systemd units, no `/etc/spotify-discord.env`, no `SpotifyDiscordBridge` task, and WSL is in `nat`
  mode with no `.wslconfig` — despite mirrored mode being documented as a hard requirement.
- **Status:** `manual`. `spotify-discord/CLAUDE.md` now leads with this so the next investigation
  starts on the right box. On 2026-09-15 the local-WSL scripts were deleted and the root
  `CLAUDE.md` was rewritten to say the bridge runs on the VPS, so the misleading docs themselves
  are gone; the entry stays because the id is permanent.

## SD-013
**service auto-restart rotates the PKCE challenge mid-login**

- **Symptom:** `/login` produces an authorization URL that is already invalid by the time the user
  finishes authorizing it. Intermittent and hard to reproduce, because it depends on whether the
  unit happened to restart during the login.
- **Root cause:** `go-librespot.service` is `Restart=on-failure`. A restart regenerates the PKCE
  challenge, invalidating the URL the user is part-way through.
- **Prevented by:** `startLogin()` in `accounts.js` writing a `Restart=no` systemd drop-in for the
  duration of the login, removed again by `deliverCode()` / `resetToOwner()`.
- **Watch for:** an abandoned `/login` leaves the drop-in in place, so go-librespot stops restarting
  on failure until `/resetaccount` or `/logincode` clears it.

## SD-014
**a failed account switch leaves the bridge logged out**

- **Symptom:** after an interrupted `/login`, no Spotify account is logged in and the "Discord"
  device disappears from Connect.
- **Root cause:** `startLogin()` deliberately deletes `state.json` to force an interactive login. If
  the user never completes it, there are no credentials left.
- **Prevented by:** the owner snapshot `state.owner.json`, taken by `init()` at startup and again by
  `startLogin()` before the delete. `/resetaccount` restores it.
- **Also:** `cloud/golibrespot-heal.sh` backs up `state.json` before every binary upgrade, and
  `SPOTIFY_GO_LIBRESPOT_STATE_B64` in GitHub Secrets allows a full rebuild with no login at all.

## SD-015
**YouTube bot check blocks the VPS IP**

- **First seen:** 2026-10-06, before the YouTube source was written (feasibility test).
- **Symptom (Discord):** `⚠️ Couldn't play **…**: YouTube wants the bot to sign in again…` or
  `…YouTube cookies are not installed on it.` The other YouTube tracks are dropped from the queue
  with it, so one expired login does not post one error per track.
- **Symptom (yt-dlp):** `ERROR: [youtube] <id>: Sign in to confirm you're not a bot. Use
  --cookies-from-browser or --cookies for the authentication.`
- **Root cause:** YouTube rates the RackNerd address as a datacenter IP and refuses anonymous
  requests from it. Measured on 2026-10-06 with yt-dlp 2026.08.19: **1 of 5** videos resolved with
  no cookies, and every alternative player client (`tv`, `web_safari`, `mweb`, `android_vr`, `ios`,
  `web_embedded`) and the `bgutil` PO-token provider (2.0.1, loaded and serving) did no better:
  0 or 1 of 5. None of them changes the IP, and the IP is what is judged.
- **What works:** a cookies.txt from a signed-in YouTube session. Same five videos plus three more:
  **8 of 8** played (yt-dlp piping into ffmpeg, SD-017).
- **Status:** `manual`. Cookies eventually stop working: Google expires the session or rotates it
  from the browser it was exported from. The bot writes the refreshed jar back after every
  successful yt-dlp run (`cookieSession()` in `youtube.js`, per-run copy + atomic rename), which
  keeps a session alive for as long as YouTube keeps refreshing it, but it cannot sign in again.
- **Fix:** export again (Chrome, **Get cookies.txt LOCALLY**, on youtube.com while signed in) and
  run `cloud\set-youtube-cookies.ps1 -SetSecret -DeleteSource`. It checks the file is a signed-in
  session, installs it at `/etc/spotify-discord/youtube-cookies.txt` (600), proves it with three
  lookups from the VPS and updates the `YOUTUBE_COOKIES_B64` secret. No restart: the file is read
  on every track. Use a throwaway Google account; Google can flag an account used this way.
- **Saved for restore:** `YOUTUBE_COOKIES_B64` holds the whole file. `set-youtube-cookies.ps1
  -FromVps` copies the live, bot-refreshed file from the box into the secret and refuses unless
  the bytes it stores hash the same as the file on the VPS. `setup-cloud.sh` writes it back on a
  rebuild. Run `-FromVps` now and then, or the secret ages behind the live session.
- **Check:** `/status` in Discord says whether cookies are installed.

## SD-016
**yt-dlp version rot**

- **Root cause:** YouTube changes its player and its API often enough that a yt-dlp a few weeks
  old stops resolving videos. The same "installed `latest` once, never again" trap as SD-005.
- **Prevented by:** `yt-dlp-update.timer` (daily, `yt-dlp --update-to stable`), written by
  `setup-cloud.sh`. The updater renames the new zipapp over the old one, so a track that is
  streaming keeps the file it opened.
- **Check:** `systemctl list-timers yt-dlp-update.timer`, `journalctl -u yt-dlp-update -n 5`.

## SD-017
**ffmpeg fetching the googlevideo URL directly → HTTP 403**

- **Seen:** 2026-10-06 in the feasibility test. With cookies, yt-dlp resolved all six videos, but
  `ffmpeg -i <googlevideo URL>` was refused with `Server returned 403 Forbidden` for one of them
  (`c=WEB_EMBEDDED_PLAYER` in the URL); the other five played.
- **Prevented by:** `startYouTubeStream()` in `youtube.js` letting yt-dlp download and pipe the
  audio itself (`-o -`) into ffmpeg's stdin. yt-dlp sends the headers and range requests the URL
  expects; that way the same video, and all eight tested, played.
- **Do not "simplify" it** into `yt-dlp -g` + `ffmpeg -i <url>`, or into resolving the URL ahead of
  time to start faster: the URL is also bound to the IP and expires.

## SD-018
**a skipped YouTube track's yt-dlp keeps running (orphaned child)**

- **Seen:** 2026-10-06, testing `youtube.js` on the VPS before deploying. After `stop()` the test
  found `yt-dlp ... -o - -- https://www.youtube.com/watch?v=dQw4w9WgXcQ` still running, its temp
  cookie copy never cleaned up, and the Node process could not exit.
- **Root cause:** yt-dlp forks. The PyInstaller build (`yt-dlp_linux`) is a bootloader whose child
  is the real Python process, and both builds start a JS-runtime child for YouTube's player
  challenge. `child.kill()` only signals the pid Node spawned; SIGKILL cannot be forwarded, so the
  child was orphaned and went on downloading a track nobody was listening to. Measured with
  `kill -9` on the parent: 1 process left with the onefile build, 0 with the zipapp.
- **Prevented by:** both. `spawnYtDlp()` starts yt-dlp with `detached: true` (its own process
  group) and `killTree()` kills `-pid`, the whole group, whatever it forked. `setup-cloud.sh`
  installs the zipapp (`yt-dlp`, on the box's python3), which is also ~300 ms faster per run
  because it does not unpack itself.
- **Note:** systemd stops the bot's whole cgroup on `systemctl stop/restart`, so a bot restart
  never leaked; only a skip, a stop or a replaced track did.
