# Quick Install Guide

## Portable Installers

| Script | Purpose | Sets up |
|--------|---------|---------|
| `install-tunnel.ps1` | Web tunnel | ffxivbe.org on port 9000 |
| `install-ssh-tunnel.ps1` | SSH tunnel | pc.ffxivbe.org for remote SSH |
| `install-scheduled-tasks.ps1` | Auto-start only | Reinstall scheduled tasks for both tunnels |

## Requirements

Before running any installer:
1. **Cloudflared CLI** installed (https://github.com/cloudflare/cloudflared/releases)
2. **PowerShell** (comes with Windows)

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

### Manual Steps Required

Some Cloudflare Dashboard configuration cannot be automated:

1. **DNS Record**: Add CNAME `pc` -> `TUNNEL_ID.cfargotunnel.com`
2. **Zero Trust Route**: Add `pc.ffxivbe.org` -> `ssh://localhost:22`
3. **WAF Bypass Rule**: Skip all for hostname `pc.ffxivbe.org`

The script will remind you of these steps after installation.

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

Use this after a format if you've restored the `.cloudflared` config files but lost the scheduled tasks.
