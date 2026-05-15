# Cloudflare Tunnels

Cloudflare Tunnel setup for web proxying and SSH remote access.

## Quick Setup (Auto-Installers)

### Web Tunnel (ffxivbe.org)
```powershell
powershell -ExecutionPolicy Bypass -File install-tunnel.ps1
```
Exposes local port 9000 via `ffxivbe.org`.

### SSH Tunnel (pc.ffxivbe.org)
```powershell
powershell -ExecutionPolicy Bypass -File install-ssh-tunnel.ps1
```
SSH remote access to your Windows PC. Some Cloudflare Dashboard steps are manual (script will remind you).

### Restore Auto-Start Only
```powershell
powershell -ExecutionPolicy Bypass -File install-scheduled-tasks.ps1
```
Reinstall scheduled tasks without full setup.

## Usage

### Desktop Shortcuts
- **Toggle Tunnel** - Start/stop web tunnel
- **Toggle SSH Tunnel** - Start/stop SSH tunnel

### Batch Files
- `toggle-tunnel.bat` - Toggle web tunnel
- `toggle-ssh-tunnel.bat` - Toggle SSH tunnel

### Task Scheduler
- Press `Win + R`, type `taskschd.msc`
- Find `ffxivbe-tunnel` or `ssh-tunnel`
- Right-click to Start/Stop

## Configuration

- **Domain**: `ffxivbe.org`
- **SSH Hostname**: `pc.ffxivbe.org`
- **Tunnel Configs**: `C:\Users\Heiner\.cloudflared\`

## Setup After Format

1. Install **cloudflared**: https://github.com/cloudflare/cloudflared/releases
2. Run `install-tunnel.ps1` (web tunnel)
3. Run `install-ssh-tunnel.ps1` (SSH tunnel)

See **[SETUP_GUIDE.md](SETUP_GUIDE.md)** for detailed steps.
See **[INSTALL.md](INSTALL.md)** for installer details.
