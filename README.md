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

1. Reinstall the base machine setup.
   ```powershell
   .\run-all.bat
   ```
2. Restore secrets used by the scripts.
   ```powershell
   .\cloudflared\sync-secrets.bat
   ```
3. Install or refresh the tunnel runtime.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\cloudflared\post-format-recovery.ps1
   ```
4. If you only need the web and SSH tunnel tasks, reinstall those directly.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\cloudflared\install-tunnel.ps1
   powershell -ExecutionPolicy Bypass -File .\cloudflared\install-ssh-tunnel.ps1
   powershell -ExecutionPolicy Bypass -File .\cloudflared\install-scheduled-tasks.ps1
   ```
5. Restore the console tools if needed.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\cloudflared\setup-console-windows.ps1
   ```
   This ends by running `cloudflared\verify-console.ps1` and writing a report to `%USERPROFILE%\.cloudflared\reports\`.

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
4. Run `post-format-recovery.ps1`.
5. Start Docker Desktop if the local origin stack needs it.
6. Start the console stack with `cloudflared\start-console.bat`.
7. Verify with `cloudflared\verify-console.ps1`.

## Verification

Use these checks after recovery:

```powershell
try { (Invoke-WebRequest -UseBasicParsing https://ffxivbe.org -TimeoutSec 20).StatusCode } catch { $_.Exception.Response.StatusCode.value__ }
try { (Invoke-WebRequest -UseBasicParsing https://chat.ffxivbe.org -TimeoutSec 20).StatusCode } catch { $_.Exception.Response.StatusCode.value__ }
```

## References

- `cloudflared/README.md`
- `cloudflared/INSTALL.md`
- `cloudflared/SETUP_GUIDE.md`
- `cloudflared/post-format-recovery.ps1`
