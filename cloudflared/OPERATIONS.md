# Cloudflare Stack Operations

This document records the current Cloudflare stack, the recovery work completed in this chat, the install and uninstall lifecycle, the test coverage, the fixes applied, and the secret inputs the stack consumes.

It is written as an operator document, not a design note. Secret names are listed, but secret values are intentionally not included.

## Scope

This repo currently manages three Cloudflare tunnel families:

- `ffxivbe-tunnel`: public web origins such as `ffxivbe.org` and `chat.ffxivbe.org`
- `ssh-tunnel`: remote Windows SSH access
- `dev-console`: the WSL-backed console and developer tools stack exposed on:
  - `console.ffxivbe.org`
  - `dev.ffxivbe.org`
  - `code.ffxivbe.org`
  - `ttyd.ffxivbe.org`
  - `tools.ffxivbe.org`
  - `git.ffxivbe.org`

## Current architecture

### Web tunnel

- Config: `%USERPROFILE%\.cloudflared\config.yml`
- Scheduled task: `ffxivbe-tunnel`
- Process match: `cloudflared ... run ffxivbe-tunnel`

### SSH tunnel

- Config: `%USERPROFILE%\.cloudflared\ssh-config.yml`
- Scheduled task: `ssh-tunnel`
- Process match: `cloudflared ... run ssh-tunnel`

### Dev console tunnel

- Config: `%USERPROFILE%\.cloudflared\dev-config.yml`
- Scheduled task: `web-console`
- Helper scheduled task: `UpdateWSLPortProxy`
- Runtime assets:
  - `C:\Users\Heiner\Documents\Cloudflare\sshwifty\`
  - `C:\Users\Heiner\Documents\Cloudflare\launcher\`
- Process match: `cloudflared ... dev-config.yml`

### Local console routing

The current stack avoids Windows `netsh interface portproxy` for the dev web services.

Local listeners:

- `127.0.0.1:2222` -> `ssh-proxy.js` -> WSL SSH on port `22`
- `127.0.0.1:7681` -> `console-proxy.js` -> SSHwifty on `127.0.0.1:7682`
- `127.0.0.1:8080` -> `tcp-relay.js` -> WSL code-server on `8080`
- `127.0.0.1:7683` -> `tcp-relay.js` -> WSL ttyd proxy on `7683`
- `127.0.0.1:7686` -> `tcp-relay.js` -> WSL dashboard on `7686`
- `127.0.0.1:7687` -> `tcp-relay.js` -> WSL git proxy on `7687`

This is the main stability improvement from this chat. The dev origins are now repo-owned relays instead of brittle shared Windows portproxy state.

## WSL runtime

WSL distro:

- `Ubuntu-24.04`

Current code user:

- `ubuntu`

Current code-server service:

- `code-server@ubuntu`

Current code workspace:

- `/home/ubuntu/dev.code-workspace`

Current code route behavior:

- `https://code.ffxivbe.org/` redirects to `?workspace=/home/ubuntu/dev.code-workspace`

Current WSL services expected active:

- `ssh`
- `code-server@ubuntu`
- `ttyd-proxy`
- `ttyd-persistent`
- `ttyd-fresh`
- `dashboard`
- `ungit`
- `git-proxy`

## What was broken and what was fixed

### 1. SSHwifty was targeting unstable WSL addresses

Problem:

- SSHwifty presets were using raw WSL IPs such as `172.22.x.x:22`
- That failed whenever the WSL IP changed or the route stalled

Fix:

- All SSHwifty SSH presets are now rewritten to `127.0.0.1:2222`
- `ssh-proxy.js` owns the Windows-to-WSL SSH hop

Files:

- `cloudflared/start-console.ps1`
- `cloudflared/setup-console-windows.ps1`
- `cloudflared/verify-console.ps1`
- `cloudflared/ssh-proxy.js`

### 2. SSH private keys were exposed in launcher code

Problem:

- The launcher path had been embedding private key material in source

Fix:

- `console-proxy.js` now reads key files from `C:\Users\Heiner\Documents\Cloudflare\sshwifty\keys\...` at runtime
- `console-launcher.js` consumes the injected runtime map instead of hardcoded secrets
- Generated SSHWifty keys are created by `setup-console-wsl.sh`, not stored in git

Files:

- `cloudflared/console-proxy.js`
- `cloudflared/console-launcher.js`
- `cloudflared/setup-console-wsl.sh`
- `cloudflared/setup-console-windows.ps1`

### 3. The quick-connect UI flow was failing

Problem:

- The launcher was failing on the SSHwifty login/auth flow
- A stale "Login button not found" path existed

Fix:

- The launcher path was updated to use the actual working auth flow
- The last auth step now uses the real button path instead of brittle assumptions
- Modal waits were widened for slower loads

Files:

- `cloudflared/console-launcher.js`

### 4. Public 502s were being caused by unstable origin routing

Problem:

- `code`, `ttyd`, `tools`, and `git` were intermittently returning Cloudflare 502 pages
- The original origin path depended on Windows portproxy and stale WSL-IP assumptions

Fix:

- Added `tcp-relay.js`
- `start-console.ps1` now starts relays on `8080`, `7683`, `7686`, `7687`
- `setup-console-windows.ps1` now writes dev tunnel origins to `127.0.0.1` relay ports
- `uninstall-console.ps1` now tears those relays down

Files:

- `cloudflared/tcp-relay.js`
- `cloudflared/start-console.ps1`
- `cloudflared/setup-console-windows.ps1`
- `cloudflared/uninstall-console.ps1`

### 5. The verifier was falsely passing or checking the wrong thing

Problems:

- The public route verifier accepted Cloudflare Access login pages as success
- It could also accept Cloudflare error pages if only the transport succeeded
- It was browser-testing `dev.ffxivbe.org` even though that route is SSH, not HTTP

Fixes:

- `verify-public-routes.mjs` now fails on:
  - Cloudflare Access login pages
  - Cloudflare error pages such as `502` or `504`
- `verify-public-routes.mjs` supports headed runs and saves screenshots for failures
- `verify-public-routes.ps1` no longer includes `dev.ffxivbe.org` in browser checks

Files:

- `cloudflared/verify-public-routes.mjs`
- `cloudflared/verify-public-routes.ps1`

### 6. Temporary Access bypass creation was too invasive

Problem:

- The verifier always created temporary Cloudflare Access bypass policies

Fix:

- `verify-public-routes.ps1` now checks whether the permanent IP allowlist already covers the current public IP
- It only creates temporary bypass policies when coverage is missing

Files:

- `cloudflared/verify-public-routes.ps1`

### 7. Uninstall was leaving WSL SSH behind

Problem:

- `uninstall-console.ps1` stopped other console services but left WSL `ssh` enabled

Fix:

- The uninstaller now stops and disables both `ssh` and `sshd` aliases, plus the detected code-server user service

Files:

- `cloudflared/uninstall-console.ps1`

### 8. Code-server was running in the wrong WSL environment

Problem:

- `code.ffxivbe.org` ran `code-server@root`
- That exposed the root environment instead of the actual coding user
- `codex` was available on Windows but not exposed as a normal WSL command in the code environment

Fix:

- `setup-console-wsl.sh` now detects the Linux code user and provisions:
  - `code-server@ubuntu`
  - `/home/ubuntu/dev.code-workspace`
  - user-scoped code-server config and settings
- WSL wrappers now expose:
  - `/usr/local/bin/codex`
  - `/usr/local/bin/claude`
- `start-console.ps1`, `setup-console-windows.ps1`, `uninstall-console.ps1`, and `verify-console.ps1` were updated to use the detected code user instead of hardcoding `root`

Files:

- `cloudflared/setup-console-wsl.sh`
- `cloudflared/start-console.ps1`
- `cloudflared/setup-console-windows.ps1`
- `cloudflared/uninstall-console.ps1`
- `cloudflared/verify-console.ps1`

## Install lifecycle

### Full rebuild order

Run from repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\uninstall-console.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\uninstall-tunnel.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\uninstall-ssh-tunnel.ps1

wsl -d Ubuntu-24.04 --user root -- bash -lc 'cd /mnt/z/Users/Heiner/Documents/PCSetup && bash cloudflared/setup-console-wsl.sh'

powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\install-tunnel.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\install-ssh-tunnel.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\setup-console-windows.ps1
```

### What `setup-console-wsl.sh` does

- installs or verifies WSL dependencies
- configures `sshd`
- generates SSHWifty keypairs under Windows `Documents\Cloudflare\sshwifty\keys`
- writes forced-command `authorized_keys`
- installs `/usr/local/bin/mount-windows-drives.sh`
- installs `/usr/local/bin/claude`
- installs `/usr/local/bin/codex`
- writes code-server config and workspace
- installs or configures:
  - `wetty`
  - `ttyd-persistent`
  - `ttyd-fresh`
  - `ttyd-proxy`
  - `dashboard`
  - `ungit`
  - `git-proxy`
- enables and starts the WSL services

### What `setup-console-windows.ps1` does

- reads `.secrets`
- writes `sshwifty.conf.json` from `SSHWIFTY_CONF_B64`
- rewrites SSHwifty presets to local SSH relay `127.0.0.1:2222`
- synchronizes generated preset key files into the SSHwifty config
- provisions the `dev-console` tunnel and DNS routes
- writes `%USERPROFILE%\.cloudflared\dev-config.yml`
- deploys launcher scripts to `C:\Users\Heiner\Documents\Cloudflare\`
- downloads the SSHwifty binary if missing
- installs scheduled tasks:
  - `web-console`
  - `UpdateWSLPortProxy`
- launches the live console stack through `start-console.ps1`

### What `start-console.ps1` does

- resolves the current WSL IP for SSH relay purposes
- forces SSHwifty presets to `127.0.0.1:2222`
- rewrites dev origins to local relay ports
- removes stale portproxy entries
- starts WSL services
- starts:
  - `ssh-proxy.js`
  - `tcp-relay.js` for `8080`, `7683`, `7686`, `7687`
  - SSHwifty
  - `console-proxy.js`
  - `cloudflared` dev tunnel

## Uninstall lifecycle

### `uninstall-console.ps1`

This script now:

- stops SSHwifty
- stops console proxy and relay processes
- clears listeners on:
  - `2222`
  - `7681`
  - `7683`
  - `7686`
  - `7687`
  - `8080`
- skips killing `svchost` listeners so it does not damage unrelated system services
- removes scheduled tasks:
  - `web-console`
  - `UpdateWSLPortProxy`
- removes deployed console files
- stops and disables WSL services including:
  - `ssh`
  - `code-server@<detected-user>`
  - `code-server@root`
  - `ttyd-*`
  - `dashboard`
  - `ungit`
  - `git-proxy`
- removes the dev tunnel DNS records
- attempts Cloudflare tunnel cleanup if `cert.pem` is available

### `uninstall-tunnel.ps1`

- removes `ffxivbe-tunnel` scheduled task
- stops the web tunnel process
- removes local config and credentials
- leaves Cloudflare-side tunnel registration unless manually deleted

### `uninstall-ssh-tunnel.ps1`

- removes `ssh-tunnel` scheduled task
- stops the SSH tunnel process
- removes local config and credentials
- stops and disables the Windows OpenSSH service

## Test and verification coverage used in this chat

### 1. Full post-install verifier

Primary command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\verify-console.ps1
```

It checks:

- scheduled task state
- tunnel processes
- local HTTP origins
- local relay listeners
- SSHwifty config targeting
- WSL service health
- public route reachability through Playwright
- artifact presence such as the dev tunnel log and pid file

Latest clean report from this chat:

- `C:\Users\Heiner\.cloudflared\reports\post-install-20260528-181156.md`

Result:

- `All 41 checks passed`

### 2. Public route Playwright checks

Used both headless and headed runs through:

- `cloudflared/verify-public-routes.ps1`
- `cloudflared/verify-public-routes.mjs`

Behavior now:

- fails on Cloudflare Access login pages
- fails on Cloudflare 502/504 pages
- can save screenshots for failing pages
- can run headed for visible debugging
- auto-installs `pnpm` if missing
- auto-runs `pnpm install` in `cloudflared\`
- auto-installs Playwright Chromium before executing the route checks

### 3. Direct HTTP and local origin checks

Repeated during debugging:

- `curl.exe` to public routes
- local HTTP probes to:
  - `127.0.0.1:8080`
  - `127.0.0.1:7683`
  - `127.0.0.1:7686`
  - `127.0.0.1:7687`
  - `127.0.0.1:7681`
- WSL `systemctl is-active` checks
- scheduled task state checks
- process command-line checks
- port-listener checks

### 4. Public installer worker

The public bootstrap URL is now fronted by a Cloudflare Worker:

- Worker name: `pcsetup-install`
- Public installer URL: `https://i.ffxivbe.org/`
- Fallback workers.dev URL: `https://pcsetup-install.vaoan-pcsetup-20260528.workers.dev`
- Worker source: `cloudflared/install-worker/index.js`
- Wrangler config: `cloudflared/install-worker/wrangler.toml`

Behavior:

- fetches `https://raw.githubusercontent.com/vaoan/PCSetup/refs/heads/main/remote-call.ps1`
- returns the PowerShell script as plain text with `Cache-Control: no-cache`

Release model:

- `workers_dev = true`
- `i.ffxivbe.org` is attached as a Worker custom domain, not a legacy route
- `wrangler deploy --config cloudflared/install-worker/wrangler.toml` now succeeds end to end

Validation used:

- Cloudflare API `PUT /accounts/{account_id}/workers/domains`
- `wrangler deploy` confirmation showing both:
  - `https://pcsetup-install.vaoan-pcsetup-20260528.workers.dev`
  - `i.ffxivbe.org (custom domain - zone name: ffxivbe.org)`
- direct `curl.exe --resolve i.ffxivbe.org:443:104.21.13.129 https://i.ffxivbe.org/` returning the `remote-call.ps1` content

### 5. SSHwifty and browser-path debugging

Used during the fixes:

- UI button path testing
- headed Playwright runs to confirm visible 502 pages
- SSHwifty auth wizard tracing
- launcher-side instrumentation

## Secret inputs

The current scripts read the following secret names from `.secrets`:

- `FFXIVBE_PEM_B64`
  - base64-encoded Cloudflare `cert.pem`
  - written to `%USERPROFILE%\.cloudflared\cert.pem`
  - used for Cloudflare tunnel and DNS automation
- `CLOUDFLARE_TUNNEL_TOKEN`
  - web tunnel token
- `GH_PAT`
  - GitHub token for authenticated git/bootstrap cases
- `SSHWIFTY_CONF_B64`
  - base64-encoded baseline SSHwifty config
  - used by `setup-console-windows.ps1`
- `CLOUDFLARE_FFXIVBE_ZERO_TRUST_API_TOKEN`
  - reserved Zero Trust admin token
- `CLOUDFLARE_ACCOUNT_API_TOKEN`
  - account-scoped Cloudflare API token used by tunnel, DNS, Access, and policy automation

### Additional secret-like runtime material

These are not stored in git and are generated or deployed locally:

- `C:\Users\Heiner\Documents\Cloudflare\sshwifty\keys\*`
  - SSH private keys for the console presets
- `%USERPROFILE%\.pcsetup-sync-passphrase`
  - passphrase used to decrypt the synced `.secrets` bundle

### Secret security changes from this chat

- Private SSH keys are no longer embedded in source files
- Key material is now read from local files at runtime
- The documentation and verification flow refer to secret names only, never values

## Secret sync status

### Local state

The required local keys are present in `.secrets`:

- `FFXIVBE_PEM_B64`
- `CLOUDFLARE_TUNNEL_TOKEN`
- `GH_PAT`
- `SSHWIFTY_CONF_B64`
- `CLOUDFLARE_FFXIVBE_ZERO_TRUST_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_API_TOKEN`

### Sync workflow status

Attempted command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\sync-secrets.ps1
```

Initial result:

- failed with GitHub workflow dispatch `HTTP 403`
- message: repository admin rights are required to trigger the `sync-secrets.yml` workflow

Root cause:

- `gh` was authenticated, but the active account was `furrycolombia-sys`
- that account only had `READ` permission on `vaoan/PCSetup`
- another account, `vaoan`, was already logged into `gh` and had the required `workflow` token scope plus repo `ADMIN`

Remediation:

```powershell
gh auth switch --user vaoan
gh repo view --json nameWithOwner,viewerPermission
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\sync-secrets.ps1
```

Verified result:

- active `gh` account switched to `vaoan`
- repo permission became `ADMIN`
- `sync-secrets.ps1` completed successfully
- workflow run id: `26609113583`
- local `.secrets` refreshed from the encrypted artifact
- `6` secrets synced

Operational meaning:

- this machine can run the encrypted secret-sync flow as long as `gh` is using the `vaoan` identity
- the failure mode was account selection, not a broken sync implementation
- if sync fails again with `403`, check `gh auth status` and `gh repo view --json viewerPermission` before changing the scripts

## Current expected steady state

After a clean install:

- tasks:
  - `ffxivbe-tunnel`
  - `ssh-tunnel`
  - `web-console`
  - `UpdateWSLPortProxy`
  - all should be `Ready` or `Running`
- tunnel processes:
  - exactly one web tunnel process
  - exactly one SSH tunnel process
  - exactly one dev tunnel process
- WSL code environment:
  - `code-server@ubuntu active enabled`
  - `code-server@root inactive disabled`
- commands available in WSL as `ubuntu`:
  - `codex`
  - `claude`
- public routes:
  - `ffxivbe.org`
  - `www.ffxivbe.org`
  - `chat.ffxivbe.org`
  - `console.ffxivbe.org`
  - `code.ffxivbe.org`
  - `ttyd.ffxivbe.org`
  - `tools.ffxivbe.org`
  - `git.ffxivbe.org`

## Operator commands

### Rebuild and verify

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\uninstall-console.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\uninstall-tunnel.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\uninstall-ssh-tunnel.ps1
wsl -d Ubuntu-24.04 --user root -- bash -lc 'cd /mnt/z/Users/Heiner/Documents/PCSetup && bash cloudflared/setup-console-wsl.sh'
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\install-tunnel.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\install-ssh-tunnel.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\setup-console-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\verify-console.ps1
```

### Clean-image staging validation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\test-clean-install.ps1
```

This is the repo-owned smoke test for fresh-machine validation. It:

- syncs secrets unless `-SkipSecretSync` is passed
- uninstalls the current Cloudflare stack unless `-SkipUninstall` is passed
- runs `post-format-recovery.ps1`
- finishes with `verify-console.ps1`

This is the staging path that should be used to prove the stack can reinstall cleanly from repo state.

### Repo test harness

Use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Do not rely on the machine-default `Invoke-Pester` entrypoint. This repo's test file uses modern Pester syntax, and `tests/run-tests.ps1` installs and imports Pester 5 automatically when needed.

### Windows container validation

Use:

```powershell
docker build -f .\Dockerfile.test .
```

This path now pulls the remote bootstrap from:

- `https://i.ffxivbe.org/`

Host prerequisites for this Windows container path:

- Docker Desktop must be running
- Docker Desktop must be switched to `desktop-windows`
- Windows optional feature `Containers` must be enabled
- Windows optional feature `Microsoft-Hyper-V-All` must be enabled
- the host must be rebooted after enabling those features

Observed failure mode from this chat:

- Docker Desktop could switch contexts, but the Windows engine returned `500` on `_ping` and `info`
- root cause was both `Containers` and `Microsoft-Hyper-V-All` being disabled
- after enabling them with `Enable-WindowsOptionalFeature -Online ... -NoRestart`, Windows reported `RestartNeeded : True`
- until reboot, `docker build -f .\Dockerfile.test .` could not run against the Windows engine

This is a non-Cloudflare, container-safe validation path only. It does not attempt to prove host-only features such as:

- WSL startup and service wiring
- Windows Scheduled Tasks
- OpenSSH Server installation on the host
- Defender exclusion changes
- desktop shortcuts
- real Cloudflare tunnel runtime on the host

The actual Cloudflare staging proof stays on the host-side smoke test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\test-clean-install.ps1
```

### Headed public-route debugging

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\verify-public-routes.ps1 -Headed
```

### Restart only the console stack

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\start-console.ps1
```

### Sync secrets if GitHub permissions allow

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\sync-secrets.ps1
```
