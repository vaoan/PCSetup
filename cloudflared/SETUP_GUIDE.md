# Cloudflare Tunnel Setup Guide

Complete guide to set up the Cloudflare Tunnel after formatting your computer or setting up on a new machine.

## Prerequisites

1. **Repo prerequisite bootstrap**
   ```powershell
   .\0-init-prereqs.bat
   ```
   Run this from the repo root before Cloudflare setup on a fresh machine. It keeps Chocolatey installed for compatibility, but uses Scoop/winget for most current installs and prepares the shared base: Scoop buckets including `extras`, WSL/Ubuntu 24.04, Git, GitHub CLI, nvm/Node/npm, .NET desktop runtimes, Java, Visual C++ redistributables, and related prerequisites.

2. **Cloudflared CLI**
   - `cloudflared\install-all.bat` installs the official MSI when missing
   - Expected path: `C:\Program Files (x86)\cloudflared\cloudflared.exe`
   - Verify: `cloudflared --version`

3. **Cloudflare Account**
   - Domain: `ffxivbe.org` (or your domain)

## Recommended Full Install

After a format, use the single installer instead of piecing together tunnel commands manually:

```powershell
.\cloudflared\install-all.bat
```

It syncs secrets if needed, restores `cert.pem` from `FFXIVBE_PEM_B64`, installs cloudflared from the official MSI, installs WSL prerequisites, configures the web/SSH/console tunnels, starts them, installs boot/logon scheduled tasks, checks console stack readiness, and runs verification.

Use the lower-level scripts only for targeted repair:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\install-tunnel.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\install-ssh-tunnel.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\setup-console-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\install-scheduled-tasks.ps1
```

## What The Installer Owns

### Web tunnel

- Config: `%USERPROFILE%\.cloudflared\config.yml`
- Task: `ffxivbe-tunnel`
- Routes: `ffxivbe.org`, `www.ffxivbe.org`, `chat.ffxivbe.org`

### SSH tunnel

- Config: `%USERPROFILE%\.cloudflared\ssh-config.yml`
- Task: `ssh-tunnel`
- Route: `pc.ffxivbe.org`
- Origin: Windows OpenSSH on `localhost:22`

### Console tunnel

- Config: `%USERPROFILE%\.cloudflared\dev-config.yml`
- Tasks: `web-console`, `UpdateWSLPortProxy`
- WSL distro: `Ubuntu-24.04`
- Routes: `console.ffxivbe.org`, `code.ffxivbe.org`, `ttyd.ffxivbe.org`, `tools.ffxivbe.org`, `git.ffxivbe.org`
- Local relays:
  - `127.0.0.1:2222` -> WSL SSH
  - `127.0.0.1:8080` -> WSL code-server
  - `127.0.0.1:7683` -> WSL ttyd proxy
  - `127.0.0.1:7686` -> WSL tools dashboard
  - `127.0.0.1:7687` -> WSL git proxy

The relays are repo-owned Node processes. They connect directly to the current WSL IP instead of shelling through `wsl nc` or depending on stale Windows portproxy entries.

## Verification

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\verify-console.ps1
```

This verifies scheduled tasks, tunnel processes, local origins, local relay listeners, WSL services, local code-server folder switching, and public routes.

The public route verifier:
- bootstraps `pnpm`, Playwright dependencies, and Chromium when missing
- temporarily removes/restores Cloudflare Access policies for protected console routes
- rejects Cloudflare Access login pages as failures
- rejects Cloudflare `1103`, `502`, `504`, and other Cloudflare error pages
- rejects placeholder fallback pages
- verifies `https://code.ffxivbe.org/?folder=/mnt/z/Users/Heiner/Documents/PCSetup` after the base code route passes
- fails the code folder check if expected folder content is missing or if any subresource returns a 5xx response

## Clean-Image Validation

For staging or fresh-image validation, use the repo smoke test instead of piecing the steps together manually:

```powershell
powershell -ExecutionPolicy Bypass -File .\cloudflared\test-clean-install.ps1
```

That script:
- optionally syncs `.secrets`
- uninstalls the current Cloudflare stack
- reruns `post-format-recovery.ps1`
- finishes with `verify-console.ps1`

The verifier now bootstraps `pnpm`, reinstalls the Playwright dependency set, and installs Chromium automatically if those browser-test dependencies are missing.

## Windows Container Validation

For the non-Cloudflare remote-install validation path, build the Windows test image:

```powershell
docker build -f .\Dockerfile.test .
```

That image pulls the installer from:

- `https://i.ffxivbe.org/`

What that means operationally:

- the container does not fetch the installer from the local repo
- the container exercises the public Cloudflare-hosted installer entrypoint
- the Worker bootstrap then pulls `remote-call.ps1` from GitHub `main`
- if the remote install behavior changes, commit and push `main` before rerunning the clean-image validation
- if you only patch files locally and retest without pushing, the container will still execute the old online installer

Latest verified result from this chat:

- `docker build --no-cache -f .\Dockerfile.test .` completed successfully
- the install phase succeeded from `https://i.ffxivbe.org/?branch=main`
- the container test suite passed with `15` tests passed and `0` failed
- the final CI bootstrap uses a direct Node version-directory fallback when `nvm use` is unreliable under Windows Server Core

Host prerequisites:

- Docker Desktop running
- Docker Desktop switched to Windows containers
- Windows optional feature `Containers` enabled
- Windows optional feature `Microsoft-Hyper-V-All` enabled

Important:

- after enabling those Windows features, you must reboot before the Windows Docker engine can run the build successfully
- without the reboot, Docker can show the `desktop-windows` context but still fail with Windows engine `500` errors

Current Worker deployment caveat:

- the live installer endpoint is already online and working
- however, `wrangler deploy` is currently blocked on this machine because the authenticated Wrangler account does not match the account configured in `cloudflared/install-worker/wrangler.toml`
- practical effect:
  - changes to `remote-call.ps1` go live after a `git push` to `main`
  - changes to `cloudflared/install-worker/index.js` require Wrangler authentication against the correct Cloudflare account before redeploy

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

### 1103/502/503/1033 errors
- Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\verify-public-routes.ps1`; do not trust browser tests that stop at a Cloudflare Access login page.
- Tunnel not connected: restart with `powershell -NoProfile -ExecutionPolicy Bypass -File .\cloudflared\start-console.ps1`.
- Local service not running: start the origin that matches the hostname.
- For `code.ffxivbe.org` folder changes, verify both `http://127.0.0.1:8080/` and `http://127.0.0.1:8080/?folder=/mnt/z/Users/Heiner/Documents/PCSetup`.
- If local code-server works but public folder switching returns 502, check the `tcp-relay.js` process for port `8080` and rerun `setup-console-windows.ps1` so the relay targets the current WSL IP.
- Placeholder pages are not valid recovery. The verifier rejects pages that say a route is online while WSL is pending.

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

**Note:** Tunnel and DNS provisioning are automated from the repo secrets. Keep external WAF or Zero Trust policy changes in Cloudflare automation if you maintain them outside this repo.

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
