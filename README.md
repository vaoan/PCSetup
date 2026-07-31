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
2. Install, start, and schedule the full Cloudflare stack.
   ```powershell
   .\cloudflared\install-all.bat
   ```
   This syncs secrets when needed, installs cloudflared from the official MSI path, configures the web/SSH/console tunnels, starts them, installs scheduled tasks, verifies WSL console readiness, and runs verification.
3. If you only need the web and SSH tunnel tasks, reinstall those directly.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\cloudflared\install-tunnel.ps1
   powershell -ExecutionPolicy Bypass -File .\cloudflared\install-ssh-tunnel.ps1
   powershell -ExecutionPolicy Bypass -File .\cloudflared\install-scheduled-tasks.ps1
   ```
4. Restore the console tools only if needed.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\cloudflared\setup-console-windows.ps1
   ```
   This ends by running `cloudflared\verify-console.ps1` and writing a report to `%USERPROFILE%\.cloudflared\reports\`.

## Clean-Image Staging

Use this when you want to validate that the Cloudflare stack can be rebuilt from repo state on a fresh machine image:

```powershell
powershell -ExecutionPolicy Bypass -File .\cloudflared\test-clean-install.ps1
```

What it does:
- syncs `.secrets` from the GitHub encrypted artifact
- uninstalls the existing console/web/ssh Cloudflare stack
- runs `cloudflared\post-format-recovery.ps1`
- runs the full `cloudflared\verify-console.ps1` report

The browser-verification leg now auto-installs `pnpm`, restores the local Playwright dependency set, and installs Chromium if they are missing.

For containerized validation of the non-Cloudflare setup path, use the Windows test image:

```powershell
docker build -f .\Dockerfile.test .
```

That container path uses `https://i.ffxivbe.org/` as the public installer entrypoint, so the clean image exercises the real remote bootstrap URL instead of a raw GitHub URL.

Windows container prerequisites on the host:
- Docker Desktop must be switched to Windows containers
- Windows optional feature `Containers` must be enabled
- Windows optional feature `Microsoft-Hyper-V-All` must be enabled
- a reboot is required after enabling those features before the Windows Docker engine will become healthy

That container path is intentionally limited to non-Cloudflare, container-safe setup assertions after the installer runs. It does not exercise the host-only Cloudflare recovery/runtime pieces such as WSL, Scheduled Tasks, OpenSSH Server, Defender exclusions, or desktop shortcuts.

Latest verified result from this chat:
- `docker build --no-cache -f .\Dockerfile.test .` completed successfully
- the container installed from `https://i.ffxivbe.org/?branch=main`
- the container suite passed with `15` tests passed and `0` failed

Important operational note:
- `i.ffxivbe.org` is the public entrypoint, but the script it serves is sourced from `origin/main`
- if the remote install behavior changes, the fix must be committed and pushed to GitHub before re-testing the clean-image path
- local-only fixes do not affect the installer; the container always consumes what is online on GitHub `main`

## What Each Tunnel Needs

### `ffxivbe-tunnel`

Requires these local origins to exist:
- `chat.ffxivbe.org` -> `http://127.0.0.1:3000`

The tunnel installer and recovery script only manage the `ffxivbe-tunnel` task and its config. They do not stop or rewrite other Cloudflare tunnels.

### `ssh-tunnel`

Requires:
- OpenSSH Server on Windows
- `pc.ffxivbe.org` routed to `ssh://localhost:22`

### `dev-tunnel`

This is optional and belongs to the dev-console workflow. Install it only if that separate project is present.

## Suggested Reinstall Order

1. Install Windows packages and base tooling.
2. Sync secrets.
3. Restore Cloudflared authentication.
4. Run `cloudflared\install-all.bat`.
5. Start Docker Desktop if the local origin stack needs it.
6. Start the console stack with `cloudflared\start-console.bat`.
7. Verify with `cloudflared\verify-console.ps1`.

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
- `cloudflared/post-format-recovery.ps1`
