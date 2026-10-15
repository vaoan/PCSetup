# Cloudflare Tunnels

Cloudflare Tunnel setup for web proxying and SSH remote access.

## Quick Setup

After a format there is exactly **one** thing to run:

```powershell
.\setup-cloudflare.bat
```

It checks `.secrets` (syncing them when missing), installs `cloudflared` from the official MSI,
then brings up, in order: the web tunnel (`www`/`chat`), the SSH tunnel (`pc`, with OpenSSH Server
and the Mac key), the WSL console services, the console tunnel with DNS and Access gating, the
`ConsoleHealth` watchdog - and finally runs `verify-console.ps1`. Every step checks before it acts,
so re-running it is also the repair. If WSL still needs a reboot it registers itself to run again
at the next sign-in. Log: `%LOCALAPPDATA%\PCSetup\setup-cloudflare.log`.

Run the repo-level prereq bootstrap first on a fresh Windows install:

```powershell
..\0-init-prereqs.bat
```

That script keeps Chocolatey available for compatibility, but the current setup prefers Scoop/winget and centralizes shared prerequisites such as WSL, Git, nvm/Node, .NET desktop runtimes, Java, redistributables, and package-manager buckets.

## Building Blocks

`setup-cloudflare.ps1` runs these; they are listed so you know what each piece does, not as
separate installs. Re-run `setup-cloudflare.bat` instead of picking one.

### Web Tunnel (www.ffxiv.be)
```powershell
powershell -ExecutionPolicy Bypass -File install-tunnel.ps1
```
Exposes the local `ffxivbe` web stack via `www.ffxiv.be`, including `chat.ffxiv.be`.

### SSH Tunnel (pc.ffxiv.be)
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

The public hostname leg uses Playwright through `verify-public-routes.ps1`. It temporarily removes/restores Cloudflare Access policies for the protected console routes, rejects Access login pages and Cloudflare error pages, rejects placeholder fallback pages, and checks the real `code.ffxiv.be/?folder=/mnt/z/Users/Heiner/Documents/PCSetup` workspace after the base code route passes.

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

- **Domain**: `ffxiv.be`
- **SSH Hostname**: `pc.ffxiv.be`
- **Tunnel Configs**: `C:\Users\Heiner\.cloudflared\`
- **Verification Reports**: `C:\Users\Heiner\.cloudflared\reports\`
- **Console presets**: `console.ffxiv.be` exposes WSL plus the repo quick-connect presets for `Libra`, `Eclipse-con`, `Puck`, `AeleOS`, `Orrery`, `PCSetup`, and `FFXIV Profiles` in persistent and fresh variants.

## Setup After Format

Run `setup-cloudflare.bat`. It replaced `install-all.bat` and `post-format-recovery.ps1`
(2026-09-30); re-running it is also how you repair a single piece.

See **[SETUP_GUIDE.md](SETUP_GUIDE.md)** for detailed steps.
See **[INSTALL.md](INSTALL.md)** for installer details.
See **[OPERATIONS.md](OPERATIONS.md)** for the full recovery history, current architecture, install/uninstall lifecycle, verification flow, and secret inventory.
