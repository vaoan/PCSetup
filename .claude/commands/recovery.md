# Post-Format Recovery

Guide the user through restoring their Windows PC configuration after a format.

## What to Restore

1. **SSH Tunnel** (pc.ffxivbe.org) - Remote SSH access via Cloudflare
2. **Web Tunnel** (ffxivbe.org) - Web proxy to localhost:9000
3. **Claude Code Session** - Persistent tmux session with auto-start

## Recovery Steps

### Step 1: Check Prerequisites

Ask the user to confirm they have installed:
- [ ] **cloudflared** - https://github.com/cloudflare/cloudflared/releases (Windows amd64 .msi)
- [ ] **MSYS2** - https://www.msys2.org/ (then run: `pacman -Syu && pacman -S tmux`)
- [ ] **Node.js** - via nvm4w or direct install
- [ ] **Claude Code** - `npm install -g @anthropic-ai/claude-code`

### Step 2: SSH Tunnel Setup (Priority - enables remote access)

Run in PowerShell as Administrator:
```powershell
cd "Z:\Users\Heiner\Documents\PCSetup\cloudflared"
.\install-ssh-tunnel.ps1 -MacPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho heinerangarita@Heiners-MacBook-Air.local"
```

This will:
- Install OpenSSH Server
- Create ssh-config.yml
- Create scheduled task (ssh-tunnel)
- Configure SSH key authentication
- Create desktop shortcut

### Step 3: Web Tunnel Setup (Optional)

If the user needs the web proxy to localhost:9000:
```powershell
.\install-tunnel.ps1
```

This will:
- Create config.yml
- Create scheduled task (ffxivbe-tunnel)
- Create desktop shortcut

### Step 4: Claude Code Persistent Sessions (Optional)

```powershell
cd "Z:\Users\Heiner\Documents\PCSetup\cloudflared"
.\install-claude-session.ps1
```

## Verification

After setup, verify everything works:

```powershell
# Check scheduled tasks
Get-ScheduledTask -TaskName "ssh-tunnel" | Select TaskName, State
Get-ScheduledTask -TaskName "ffxivbe-tunnel" | Select TaskName, State
Get-ScheduledTask -TaskName "claude-session" | Select TaskName, State

# Test SSH from Mac
ssh windows-remote
```

## Key Information

- **SSH Tunnel ID**: `8dffdb51-77cc-43ca-8dc8-8a0c720607a5`
- **Web Tunnel ID**: `c552cb9c-62bd-4c8b-9ec6-16627b1b8af3`
- **Mac SSH Key**: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho`

## Mac SSH Config (already configured on Mac)

```
Host windows-remote
    HostName pc.ffxivbe.org
    User Heiner
    ProxyCommand cloudflared access tcp --hostname %h --listener -
```
