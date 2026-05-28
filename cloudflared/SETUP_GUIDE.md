# Cloudflare Tunnel Setup Guide

Complete guide to set up the Cloudflare Tunnel after formatting your computer or setting up on a new machine.

## Prerequisites

1. **Cloudflared CLI**
   - Install via Chocolatey: `choco install cloudflared`
   - Or download from: https://github.com/cloudflare/cloudflared/releases
   - Verify: `cloudflared --version`

2. **Cloudflare Account**
   - Domain: `ffxivbe.org` (or your domain)

## Step 1: Cloudflare Authentication

1. Login to Cloudflare:
   ```bash
   cloudflared tunnel login
   ```
   - This opens a browser window
   - Select your domain (`ffxivbe.org`)
   - This creates `~/.cloudflared/cert.pem`

## Step 3: Create or Reuse Tunnel

### Option A: Create New Tunnel
```bash
cloudflared tunnel create ffxivbe-tunnel
```
- Note the Tunnel ID (you'll need it)

### Option B: Reuse Existing Tunnel
If you have the tunnel ID from before:
```bash
# List existing tunnels
cloudflared tunnel list

# If tunnel exists, you can reuse it
# Otherwise create a new one
cloudflared tunnel create ffxivbe-tunnel
```

**Save the Tunnel ID** - you'll need it for configuration.

## Step 4: Configure Tunnel

1. Create tunnel config directory:
   ```bash
   mkdir -p .cloudflared
   ```

2. Create/edit `.cloudflared/config.yml`:
   ```yaml
   tunnel: YOUR_TUNNEL_ID_HERE
   credentials-file: C:\Users\Heiner\.cloudflared\YOUR_TUNNEL_ID_HERE.json

    ingress:
      - hostname: ffxivbe.org
        service: http://127.0.0.1:7542
      - hostname: www.ffxivbe.org
        service: http://127.0.0.1:7542
      - hostname: chat.ffxivbe.org
        service: http://127.0.0.1:3000
     - service: http_status:404
   ```

3. Replace `YOUR_TUNNEL_ID_HERE` with your actual tunnel ID (from Step 3)

4. The credentials file should be at:
   ```
   C:\Users\Heiner\.cloudflared\YOUR_TUNNEL_ID_HERE.json
   ```
   - This is created automatically when you create the tunnel
   - If missing, you may need to recreate the tunnel

## Step 5: Update DNS Records

1. Go to Cloudflare Dashboard → DNS → Records
2. For `ffxivbe.org`:
   - Type: `CNAME`
   - Name: `@` (or `ffxivbe.org`)
   - Target: `YOUR_TUNNEL_ID.cfargotunnel.com`
   - Proxy: Enabled (orange cloud)
3. For `www.ffxivbe.org`:
   - Type: `CNAME`
   - Name: `www`
   - Target: `YOUR_TUNNEL_ID.cfargotunnel.com`
   - Proxy: Enabled (orange cloud)

## Step 6: Test Tunnel Manually

1. Make sure the local services are running:
   - app web stack on `7542`
   - chat backend on `3000`

2. Run tunnel manually to test:
   ```bash
   cloudflared tunnel --config C:\Users\Heiner\.cloudflared\config.yml run ffxivbe-tunnel
   ```
   - Keep this running
   - Test: Open https://ffxivbe.org in browser
   - Should show your local service

3. If working, stop the tunnel (Ctrl+C)

## Step 7: Set Up Scheduled Task + Desktop Shortcut

Run the installer which handles both:
```bash
powershell -ExecutionPolicy Bypass -File install-tunnel.ps1
```

Or if you only need to reinstall the scheduled task:
```bash
powershell -ExecutionPolicy Bypass -File install-scheduled-tasks.ps1
```

This creates:
- A Windows scheduled task that runs the tunnel hidden at login
- A "Toggle Tunnel" desktop shortcut

## Step 8: Verify Everything Works

1. Test public URL:
- Open https://ffxivbe.org in browser
- Should show your local service
   - Also test `https://chat.ffxivbe.org`

2. Test toggle shortcut:
   - Double-click `Toggle Tunnel.lnk` on desktop
   - Should start/stop the tunnel

## Troubleshooting

### Tunnel not connecting
- Check the local origins are running:
  - `curl http://127.0.0.1:7542`
  - `curl http://127.0.0.1:3000`
- Verify tunnel config: `cloudflared tunnel info ffxivbe-tunnel`
- Check credentials file exists at path in config.yml

### DNS not resolving
- Wait 5-10 minutes for DNS propagation
- Verify DNS records in Cloudflare dashboard
- Check CNAME points to `TUNNEL_ID.cfargotunnel.com`

### Task not starting
- Check Task Scheduler: `taskschd.msc`
- Look for "ffxivbe-tunnel" task
- Verify it's enabled and set to run at logon

### 503/1033 errors
- Tunnel not connected - restart it
- Local service not running - start the `7542` or `3000` origin that matches the hostname
- Check firewall isn't blocking the local loopback origin

## Quick Reference

**Essential Files:**
- `C:\Users\Heiner\.cloudflared\config.yml` - Web tunnel configuration
- `C:\Users\Heiner\.cloudflared\ssh-config.yml` - SSH tunnel configuration
- `C:\Users\Heiner\.cloudflared\TUNNEL_ID.json` - Tunnel credentials

**Toggle Commands:**
- `toggle-tunnel.bat` - Toggle web tunnel on/off
- `toggle-ssh-tunnel.bat` - Toggle SSH tunnel on/off

**Project Location:**
- `Z:\Users\Heiner\Documents\Cloudflare`

## Notes

- The tunnel runs hidden in the background via scheduled task
- It starts automatically on login
- Use the toggle shortcut to start/stop manually
- Local services must be running for the relevant hostnames to work
- DNS changes may take a few minutes to propagate




---

## SSH Remote Access Setup

This section explains how to set up SSH access to your Windows PC via Cloudflare Tunnel, allowing you to connect from anywhere (e.g., from a Mac).

### Quick Install (Recommended)

**One-command setup (auto-elevates to Administrator):**
```bash
powershell -ExecutionPolicy Bypass -File install-ssh-tunnel.ps1
```

This automatically:
- Installs and configures OpenSSH Server
- Creates ssh-config.yml
- Creates the ssh-tunnel scheduled task
- Starts the tunnel

**Note:** Some Cloudflare Dashboard steps are still manual (DNS, Zero Trust route, WAF rule) - the script will remind you of these.

To also set up SSH key authentication:
```bash
powershell -ExecutionPolicy Bypass -File install-ssh-tunnel.ps1 -MacPublicKey "ssh-ed25519 AAAA... your-key"
```

### Manual Setup (Step by Step)

If you prefer manual setup, follow the steps below.

### Prerequisites for SSH

1. **OpenSSH Server** must be installed and running on Windows
2. **A separate Cloudflare Tunnel** for SSH (dashboard-managed, not locally-managed)
3. **WAF bypass rule** in Cloudflare to prevent bot protection from blocking the connection

### Step 1: Install OpenSSH Server on Windows

Run these commands in an **Administrator PowerShell**:

```powershell
# Install OpenSSH Server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# Start and enable the service
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Allow SSH through firewall for all networks (including Public)
Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Profile Any
```

### Step 2: Create SSH Tunnel (Dashboard-Managed)

The SSH tunnel must be **dashboard-managed** (not locally-managed like ffxivbe-tunnel) so Cloudflare can route traffic properly.

1. Create the tunnel:
   ```bash
   cloudflared tunnel create ssh-tunnel
   ```
   - Note the Tunnel ID (e.g., `8dffdb51-77cc-43ca-8dc8-8a0c720607a5`)

2. Create config file `C:\Users\Heiner\.cloudflared\ssh-config.yml`:
   ```yaml
   tunnel: YOUR_SSH_TUNNEL_ID
   credentials-file: C:\Users\Heiner\.cloudflared\YOUR_SSH_TUNNEL_ID.json

   ingress:
     - hostname: pc.ffxivbe.org
       service: ssh://localhost:22
     - service: http_status:404
   ```

3. Go to **Cloudflare Zero Trust Dashboard** (https://one.dash.cloudflare.com/):
   - Navigate to **Networks** → **Tunnels** (under Connectors)
   - Click on **ssh-tunnel**
   - Go to **Published application routes** tab
   - Add: `pc.ffxivbe.org` → `ssh://localhost:22`

### Step 3: Configure DNS

Add a CNAME record for `pc.ffxivbe.org`:

1. Go to **Cloudflare Dashboard** (https://dash.cloudflare.com/) → **DNS** → **Records**
2. Add CNAME:
   - Name: `pc`
   - Target: `YOUR_SSH_TUNNEL_ID.cfargotunnel.com`
   - Proxy: Enabled (orange cloud)

### Step 4: Disable Bot Protection for SSH Hostname

**Important:** Cloudflare's bot protection will block the websocket connection. Create a bypass rule:

1. Go to **Cloudflare Dashboard** → **Security** → **WAF**
2. Click **Custom rules** → **Create rule**
3. Configure:
   - Rule name: `Allow SSH tunnel`
   - Field: `Hostname`
   - Operator: `equals`
   - Value: `pc.ffxivbe.org`
   - Action: **Skip** → check all boxes
4. Deploy

### Step 5: Set Up SSH Key Authentication (Recommended)

For passwordless login:

1. On your Mac, generate an SSH key:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
   cat ~/.ssh/id_ed25519.pub
   ```

2. On Windows, add the public key to the **administrators** authorized_keys file:
   ```powershell
   # Create the file with your Mac's public key
   echo "ssh-ed25519 AAAA... your-mac-user@hostname" > C:\ProgramData\ssh\administrators_authorized_keys

   # Set correct permissions
   icacls 'C:\ProgramData\ssh\administrators_authorized_keys' /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'

   # Restart SSH service
   Restart-Service sshd
   ```

   **Note:** Windows uses `C:\ProgramData\ssh\administrators_authorized_keys` for admin users, not `~/.ssh/authorized_keys`.

### Step 6: Create Scheduled Task for SSH Tunnel

Run in Administrator PowerShell:

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -Command `"cloudflared tunnel --config C:\Users\Heiner\.cloudflared\ssh-config.yml run ssh-tunnel`""
$trigger = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName "ssh-tunnel" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
```

### Step 7: Connect from Mac

On your Mac:

1. Install cloudflared:
   ```bash
   brew install cloudflared
   ```

2. Add SSH config (`~/.ssh/config`):
   ```
   Host windows-remote
       HostName pc.ffxivbe.org
       User Heiner
       ProxyCommand cloudflared access tcp --hostname %h --listener -
   ```

3. Connect:
   ```bash
   ssh windows-remote
   ```

   Or manually:
   ```bash
   cloudflared access tcp --hostname pc.ffxivbe.org --listener localhost:2222 &
   sleep 3
   ssh -p 2222 Heiner@127.0.0.1
   ```

### SSH Tunnel Reference

**Toggle SSH Tunnel:**
- Double-click **"Toggle SSH Tunnel"** shortcut on desktop
- Or run: `toggle-ssh-tunnel.bat`

**Tunnel IDs:**
- ffxivbe-tunnel: `c552cb9c-62bd-4c8b-9ec6-16627b1b8af3` (locally-managed, for web)
- ssh-tunnel: `8dffdb51-77cc-43ca-8dc8-8a0c720607a5` (dashboard-managed, for SSH)

**Config Files:**
- Web tunnel: `C:\Users\Heiner\.cloudflared\config.yml`
- SSH tunnel: `C:\Users\Heiner\.cloudflared\ssh-config.yml`

**DNS Records:**
- `ffxivbe.org` → `c552cb9c-62bd-4c8b-9ec6-16627b1b8af3.cfargotunnel.com`
- `www.ffxivbe.org` → `c552cb9c-62bd-4c8b-9ec6-16627b1b8af3.cfargotunnel.com`
- `pc.ffxivbe.org` → `8dffdb51-77cc-43ca-8dc8-8a0c720607a5.cfargotunnel.com`

**Scheduled Tasks:**
- `ffxivbe-tunnel` - Web tunnel (auto-starts at login)
- `ssh-tunnel` - SSH tunnel (auto-starts at login)

**Restore scheduled tasks only:**
```bash
powershell -ExecutionPolicy Bypass -File install-scheduled-tasks.ps1
```

This reinstalls both scheduled tasks without running the full installers. Useful if you restored config files from backup but lost the tasks.
