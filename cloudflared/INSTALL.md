# Quick Install Guide

## Portable Installers

| Script | Purpose | Sets up |
|--------|---------|---------|
| `install-tunnel.ps1` | Web tunnel | ffxivbe.org + chat/map hostnames, hidden boot/logon task |
| `install-ssh-tunnel.ps1` | SSH tunnel | pc.ffxivbe.org for remote SSH, hidden boot/logon task |
| `install-scheduled-tasks.ps1` | Auto-start only | Reinstall hidden boot/logon tasks for both tunnels |

These installers only manage the `ffxivbe-tunnel` and `ssh-tunnel` tasks. They do not stop or rewrite other Cloudflare tunnels used by other apps.

## Requirements

Before running any installer:
1. **Cloudflared CLI** installed (https://github.com/cloudflare/cloudflared/releases)
2. **PowerShell** (comes with Windows)

For browser verification:
1. **Node.js / npm** available on PATH
2. `pnpm` does not need to be preinstalled manually
3. The verification scripts will install `pnpm`, install the local Playwright dependency set, and install Chromium automatically when needed

---

## Web Tunnel Installer

```powershell
powershell -ExecutionPolicy Bypass -File install-tunnel.ps1
```

**No need to run as Administrator manually** - the installer will automatically elevate itself!

### What It Does

1. Checks cloudflared is installed
2. Authenticates with Cloudflare (opens browser)
3. Creates or reuses the tunnel
4. Creates configuration files
5. Creates Windows scheduled task
6. Creates desktop shortcut
7. Starts the tunnel

### After Installation

- Use the desktop shortcut **"Toggle Tunnel"** to start/stop
- Or run: `toggle-tunnel.bat`

---

## SSH Tunnel Installer

```powershell
powershell -ExecutionPolicy Bypass -File install-ssh-tunnel.ps1
```

### What It Does

1. Installs OpenSSH Server (if not present)
2. Configures and starts SSH service
3. Sets firewall rules
4. Creates or reuses the ssh-tunnel
5. Creates ssh-config.yml
6. Creates Windows scheduled task
7. Creates desktop shortcut
8. Starts the tunnel

### Options

```powershell
# Also set up SSH key authentication
powershell -ExecutionPolicy Bypass -File install-ssh-tunnel.ps1 -MacPublicKey "ssh-ed25519 AAAA..."
```

### Manual Steps

None for tunnel/DNS provisioning. The installer now writes `cert.pem` from `FFXIVBE_PEM_B64` and creates the DNS route headlessly with `cloudflared tunnel route dns`.

If you maintain separate Access or WAF policy outside this repo, keep that in your Cloudflare automation. The installer does not open the dashboard.

### After Installation

- Use the desktop shortcut **"Toggle SSH Tunnel"** to start/stop
- Or run: `toggle-ssh-tunnel.bat`

Connect from your Mac:
```bash
ssh windows-remote
```

(Requires `~/.ssh/config` with ProxyCommand - see SETUP_GUIDE.md)

---

## Scheduled Tasks Only

If you already have tunnels configured but just need to restore the auto-start behavior:

```powershell
powershell -ExecutionPolicy Bypass -File install-scheduled-tasks.ps1
```

This script:
- Checks if each tunnel's config exists
- Reinstalls scheduled tasks for both tunnels
- Starts both tunnels immediately
- Uses boot plus logon triggers so tunnels come back after restart

Use this after a format if you've restored the `.cloudflared` config files but lost the scheduled tasks.

For a full rebuild after formatting the PC, use `cloudflared\post-format-recovery.ps1` from the repo root instead of running the tunnel installers one by one.

## Verification bootstrap

`verify-console.ps1` calls the public-route verifier, and the public-route verifier now bootstraps its own browser-test dependencies:

- installs `pnpm` globally with `npm` if `pnpm` is missing
- runs `pnpm install` in `cloudflared\`
- runs `pnpm exec playwright install chromium`

This means a fresh machine does not need a prepopulated `cloudflared\node_modules` directory for verification to work.
