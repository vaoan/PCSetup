# Cloudflare Tunnels

Cloudflare Tunnel setup for web proxying and SSH remote access.

## Quick Setup

After a format, run one script:

```powershell
.\install-all.bat
```

It syncs secrets when needed, installs `cloudflared` from the official MSI location, configures the web and SSH tunnels, restores the WSL-backed console tunnel, starts the stack, installs the boot/logon scheduled tasks, and runs verification.

Run the repo-level prereq bootstrap first on a fresh Windows install:

```powershell
..\0-init-prereqs.bat
```

That script keeps Chocolatey available for compatibility, but the current setup prefers Scoop/winget and centralizes shared prerequisites such as WSL, Git, nvm/Node, .NET desktop runtimes, Java, redistributables, and package-manager buckets.

## Maintenance Installers

### Web Tunnel (ffxivbe.org)
```powershell
powershell -ExecutionPolicy Bypass -File install-tunnel.ps1
```
Exposes the local `ffxivbe` web stack via `ffxivbe.org`, including `chat.ffxivbe.org`.

### SSH Tunnel (pc.ffxivbe.org)
```powershell
powershell -ExecutionPolicy Bypass -File install-ssh-tunnel.ps1
```
SSH remote access to your Windows PC. DNS routing is provisioned headlessly from the secrets bundle; no browser dashboard step is required.

### Restore Auto-Start Only
```powershell
powershell -ExecutionPolicy Bypass -File install-scheduled-tasks.ps1
```
Reinstall scheduled tasks without full setup. The tasks start at boot and logon, and stay hidden.
These installers only manage the `ffxivbe-tunnel` and `ssh-tunnel` tasks and do not stop other Cloudflare tunnels.

### Post-Install Verification
```powershell
powershell -ExecutionPolicy Bypass -File verify-console.ps1
```
Runs the full post-install report:
- scheduled task state
- tunnel processes
- local HTTP origins
- WSL service state
- local code-server folder switching
- public hostname checks

The public hostname leg uses Playwright through `verify-public-routes.ps1`. It temporarily removes/restores Cloudflare Access policies for the protected console routes, rejects Access login pages and Cloudflare error pages, rejects placeholder fallback pages, and checks the real `code.ffxivbe.org/?folder=/mnt/z/Users/Heiner/Documents/PCSetup` workspace after the base code route passes.

Reports are written to:
- `%USERPROFILE%\.cloudflared\reports\latest.md`
- `%USERPROFILE%\.cloudflared\reports\latest.json`

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
- Both tasks are hidden and configured with boot plus logon triggers.

## Configuration

- **Domain**: `ffxivbe.org`
- **SSH Hostname**: `pc.ffxivbe.org`
- **Tunnel Configs**: `C:\Users\Heiner\.cloudflared\`
- **Verification Reports**: `C:\Users\Heiner\.cloudflared\reports\`
- **Console presets**: `console.ffxivbe.org` exposes WSL plus the repo quick-connect presets for `Candystore`, `Eclipse-con`, and `PCSetup` in persistent and fresh variants.

## Setup After Format

Run `install-all.bat`. Use the individual installers only when repairing one specific piece.

See **[SETUP_GUIDE.md](SETUP_GUIDE.md)** for detailed steps.
See **[INSTALL.md](INSTALL.md)** for installer details.
See **[OPERATIONS.md](OPERATIONS.md)** for the full recovery history, current architecture, install/uninstall lifecycle, verification flow, and secret inventory.
