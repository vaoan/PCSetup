# PCSetup Recovery Guide

This repository is the Windows-side recovery kit for this PC.

It restores:
- Cloudflare tunnel installers and scheduled tasks
- SSH access
- The console / tooling stack
- Basic Windows setup scripts
- Post-format recovery steps

It does not own unrelated app repositories. If a hostname depends on a separate local service, that service must be restored from its own project first.

## After A Format

Run these in order from `Z:\Users\Heiner\Documents\PCSetup`:

1. Reinstall the base machine setup and mandatory prerequisites.
   ```powershell
   .\0-init-prereqs.bat
   .\run-all.bat
   ```
   The init step is the required first pass for package managers and shared prerequisites. It keeps Chocolatey available, but prefers Scoop/winget for current installs and prepares WSL, Node, Git, nvm, .NET desktop runtimes, Java, redistributables, and other common prerequisites before the later scripts run.
2. Bring the whole Cloudflare setup online - **one** double-click, nothing else to run:
   ```powershell
   .\cloudflared\setup-cloudflare.bat
   ```
   It checks `.secrets` (syncing them when missing), installs cloudflared from the official MSI,
   sets up the web tunnel (`www`/`chat`), the SSH tunnel (`pc`, with OpenSSH Server and the Mac key),
   the web console (`console`/`dev`/`code`/`ttyd`/`tools`/`git`, WSL side and Windows side, Access
   gating), the `ConsoleHealth` watchdog, and then runs `verify-console.ps1`. Safe to re-run: every
   step checks before it acts. If WSL still needs a reboot it says so and runs itself again at the
   next sign-in. Log: `%LOCALAPPDATA%\PCSetup\setup-cloudflare.log`; verification report:
   `%USERPROFILE%\.cloudflared\reports\latest.md`.

   The other scripts in `cloudflared\` are its building blocks, not separate installs.

## Clean-Image Staging

Use this when you want to validate that the Cloudflare stack can be rebuilt from repo state on a fresh machine image:

```powershell
powershell -ExecutionPolicy Bypass -File .\cloudflared\test-clean-install.ps1
```

What it does:
- syncs `.secrets` from the GitHub encrypted artifact
- uninstalls the existing console/web/ssh Cloudflare stack
- runs `cloudflared\setup-cloudflare.ps1`
- runs the full `cloudflared\verify-console.ps1` report

The browser-verification leg now auto-installs `pnpm`, restores the local Playwright dependency set, and installs Chromium if they are missing.

For containerized validation of the non-Cloudflare setup path, use the Windows test image:

```powershell
docker build -f .\Dockerfile.test .
```

That container path uses `https://i.ffxiv.be/` as the public installer entrypoint, so the clean image exercises the real remote bootstrap URL instead of a raw GitHub URL.

Windows container prerequisites on the host:
- Docker Desktop must be switched to Windows containers
- Windows optional feature `Containers` must be enabled
- Windows optional feature `Microsoft-Hyper-V-All` must be enabled
- a reboot is required after enabling those features before the Windows Docker engine will become healthy

That container path is intentionally limited to non-Cloudflare, container-safe setup assertions after the installer runs. It does not exercise the host-only Cloudflare recovery/runtime pieces such as WSL, Scheduled Tasks, OpenSSH Server, Defender exclusions, or desktop shortcuts.

Latest verified result from this chat:
- `docker build --no-cache -f .\Dockerfile.test .` completed successfully
- the container installed from `https://i.ffxiv.be/?branch=main`
- the container suite passed with `15` tests passed and `0` failed

Important operational note:
- `i.ffxiv.be` is the public entrypoint, but the script it serves is sourced from `origin/main`
- if the remote install behavior changes, the fix must be committed and pushed to GitHub before re-testing the clean-image path
- local-only fixes do not affect the installer; the container always consumes what is online on GitHub `main`

## What Each Tunnel Needs

### `ffxivbe-tunnel`

Requires these local origins to exist:
- `chat.ffxiv.be` -> `http://127.0.0.1:7543` (`chat-proxy.js`, buffering in front of the ChatAnywhere plugin on 3000)

The tunnel installer and recovery script only manage the `ffxivbe-tunnel` task and its config. They do not stop or rewrite other Cloudflare tunnels.

### `ssh-tunnel`

Requires:
- OpenSSH Server on Windows
- `pc.ffxiv.be` routed to `ssh://localhost:22`

### `dev-tunnel`

This is optional and belongs to the dev-console workflow. Install it only if that separate project is present.

## Suggested Reinstall Order

1. Install Windows packages and base tooling (`0-init-prereqs.bat`, `run-all.bat`).
2. Run `cloudflared\setup-cloudflare.bat`. It syncs secrets if needed, authenticates from
   `.secrets` (no browser login), starts everything, and verifies.
3. Start Docker Desktop if the local origin stack for `www` needs it.

## Verification

Use these checks after recovery:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\verify-console.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\verify-public-routes.ps1
```

The public verifier temporarily disables Cloudflare Access policies for the console hostnames, waits for propagation, runs browser checks, and restores the original policies in `finally`. It must not count Cloudflare Access login pages, Cloudflare 1103/502/504 pages, or placeholder fallback pages as success.

The code-server public check first verifies `https://code.ffxiv.be/`. If that passes, it also opens `https://code.ffxiv.be/?folder=/mnt/z/Users/Heiner/Documents/PCSetup` and fails on missing folder content or any 5xx subresource response.

For the repo test suite, use the pinned Pester entrypoint instead of calling `Invoke-Pester` directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

That script installs and loads Pester 5 automatically so the repo tests run consistently on fresh machines.

## References

- `cloudflared/README.md`
- `cloudflared/INSTALL.md`
- `cloudflared/SETUP_GUIDE.md`
- `cloudflared/setup-cloudflare.ps1`
