# Project Instructions

## Script Requirements

When creating or editing any script file (`.bat`, `.cmd`, `.ps1`), ALWAYS include auto-elevation to Administrator at the top.

### For .bat and .cmd files:
```batch
@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
```

### For .ps1 files:
```powershell
# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
```

## Checklist
- [x] Every script must auto-elevate to admin
- [x] Scripts must be unattended (no pauses) - they should close automatically when finished
- [x] Use Chocolatey, winget, and npm for package installations
- [x] **`.v` is auto-updated** by the pre-commit git hook — no manual action needed

## Naming Convention

All scripts use **kebab-case** naming: `[N-]action-target.ext`

- Numbered prefix (`1-`, `2-`, etc.) indicates execution order after fresh Windows install
- Utility scripts have no number prefix (run as needed)

## Quick Install

One-liner that works on a fresh Windows machine before any setup is run:

```powershell
irm i.ffxivbe.org | iex
```

`irm` (Invoke-RestMethod) returns the script as a plain string, which `iex` executes directly. Do NOT use `iwr` (Invoke-WebRequest) — it returns a WebResponseObject that breaks `iex` in PS5.1.

The URL is served by a Cloudflare Worker (`cloudflared/install-worker/`) that proxies `remote-call.ps1` from GitHub raw. Free tier (100k req/day). To deploy the worker one-time: `cd cloudflared/install-worker && wrangler deploy`.

## Run All Scripts

### remote-call.ps1
Downloads the repo ZIP into memory, materializes the top-level `.bat`, `.config`, and `.v` files into a temporary folder under `%TEMP%`, writes a source manifest there, executes `run-all.bat` from that isolated temp workspace, and cleans up afterward. Use this when you want the latest remote setup flow without depending on the current local repo folder.

### run-all.bat
Master script that executes all numbered setup scripts in sequential order. Automatically finds and runs any script matching `[N]-*.bat` pattern, sorted by number.

**Auto-download & version check:** On each run, `run-all.bat` does the following (no Git required — uses PowerShell's `Invoke-WebRequest` only):
- If no numbered scripts are found → downloads the full repo ZIP from GitHub, extracts it, copies all files into the **same folder as `run-all.bat`**, then runs.
- If scripts exist → fetches `.v` from GitHub raw and compares to local `.v`. If remote version is higher, re-downloads and updates all scripts. If offline or same version, runs as-is.

**To release an update:** update `.v` with the current UTC ISO 8601 timestamp and push. Users will auto-update next time they run `run-all.bat`. Comparison uses PowerShell's `-gt` string operator (not CMD's `GTR`) — ISO 8601 strings are lexicographically sortable so this works correctly.

> **Important for editing:** When writing the download logic, use a single inline PowerShell `-Command` string — do NOT use grouped `echo` blocks or `^` line continuations to build a temp `.ps1` file. Parentheses in echoed PS code (`if (...)`, `try {`) break CMD's block parser. The inline approach avoids all quoting issues and has no moving parts.
>
> The `Copy-Item` call uses `-Exclude 'run-all.bat'` to skip overwriting the currently running script. Without this, CMD's internal file position pointer gets corrupted when the file is replaced mid-execution, causing execution to silently stop. By excluding it, the script falls through naturally to `:run_scripts` after the download. Do NOT use `start "" cmd /c` to relaunch — `start` from an elevated process does not inherit elevation (uses ShellExecute, not CreateProcess), which triggers UAC again and causes the window to flash and close.

### cloudflared/sync-secrets.bat
Pulls secrets from GitHub repository secrets to a local `.secrets` file (gitignored). Reads a decryption passphrase from `%USERPROFILE%\.pcsetup-sync-passphrase`, triggers `.github/workflows/sync-secrets.yml` via `gh workflow run`, waits for the workflow to complete, downloads the AES-256-CBC encrypted artifact, decrypts it with `openssl.exe` (bundled with Git for Windows), and writes `.secrets`.

**Prerequisites:** `gh auth login` must have been run. Git for Windows must be installed. `%USERPROFILE%\.pcsetup-sync-passphrase` must exist (see `.secrets.example` first-time setup instructions).

To add a new secret:
1. Add it in GitHub → Settings → Secrets and variables → Actions
2. Add it to the `env:` block and `run:` output section in `.github/workflows/sync-secrets.yml`
3. Add a placeholder line to `.secrets.example`

## Testing

### Flow 1 — Windows setup (Docker)

Runs the full install inside a Windows Server Core container and verifies all packages with Pester. Requires Docker Desktop in Windows containers mode.

```batch
test-local.bat            # test against main branch
test-local.bat my-branch  # test against a specific branch
```

The `PCSETUP_CI=1` env var is set inside the container. Scripts 5 and 6 detect it and skip their body (profile folder relocation and game launchers don't work in containers).

### Flow 2 — Console service verifier

Run after `cloudflared\start-console.bat` to verify all local services are healthy without opening Cloudflare tunnels:

```powershell
cloudflared\verify-console.ps1
```

Checks port connectivity, HTTP 200 responses, and WSL systemd service status. Exits 0 if all pass, 1 if any fail.

## Setup Scripts (Run in Order)

### 1-delete-node-modules.bat
Recursively finds and deletes all `node_modules` folders on all fixed hard drives. Useful for reclaiming disk space.

### 2-setup-windows.bat
Main Windows setup script. Installs Chocolatey and a comprehensive set of applications including browsers, development tools, media players, and utilities. Also installs Discord Canary, Chrome Remote Desktop, WSL, Claude Code, and the main Windows runtimes.

**Installed packages:** Chrome, Discord, DirectX, 7zip, WinRAR, VLC, K-Lite Codec Pack, Spotify, HandBrake, ShareX, Python, Notepad++, Telegram, pCloud, RDM, qBittorrent, Cloudflared, Warp, Winamp, Firefox, PuTTY, WinSCP, BleachBit, Bulk Crap Uninstaller, WizTree, EarTrumpet, Git, Sourcetree, VS Code, GitHub Desktop, GitHub CLI, OnTopReplica, OnlyOffice, NVIDIA App, VC++ Redistributables, .NET runtimes, Streamlabs OBS, ProtonVPN, 2FAGuard, Claude Desktop, Kiro, Claude Code, WezTerm, Clink (autorun-enabled for cmd.exe), PowerShell 7, JetBrainsMono Nerd Font

Also deploys `%USERPROFILE%\.wezterm.lua` (GPU-accelerated config with Catppuccin Mocha theme, multi-shell profiles, Ctrl+Shift keybindings for tabs/panes) and appends a WezTerm bell-notification block to `$PROFILE` (fires a Windows toast + tab flash when a command takes ≥ 10 seconds).

### 3-setup-node.bat
Dedicated Node.js setup step. Refreshes environment variables before and after installing `nvm`, installs Node.js LTS with `nvm`, refreshes the environment again after `nvm use lts`, then installs npm-based CLI tools.

**Installed packages:** nvm, Node.js LTS, OpenAI Codex CLI, GitHub Copilot CLI, gh-copilot extension (when GitHub CLI is authenticated)

### 4-fix-execution-policy.bat
Sets PowerShell execution policy to `RemoteSigned` for the current user, allowing scripts like Claude Code to run in PowerShell.

### 5-move-profile-folders.bat
Relocates Windows user profile folders (Desktop, Documents, Music, Pictures, Videos, etc.) to a different drive (default: Z:). Updates registry entries and optionally moves existing files. Run early before accumulating files. Note: Downloads folder is handled separately in `optional/move-downloads-folder.bat`.

### 6-setup-games.bat
Game-related applications setup. Installs gaming platforms, launchers, and tools. Checks if XIVLauncher and FFLogs are already installed before downloading.

**Installed packages:** Steam, Epic Games Launcher, Prism Launcher, CurseForge (via winget), Temurin JDK 17/8, XIVLauncher (Custom FFXIV Launcher), TexTools (FFXIV Modding Tool), FFLogs Uploader

### 7-context-menu-terminal-install.bat
Enables the classic Windows context menu (always shows full menu instead of Windows 11's simplified version) and adds "Open in Terminal as Administrator", "Open in PowerShell as Administrator", "Open Git Bash here as Administrator", and "Open in WezTerm as Administrator" to the context menu for directories, directory backgrounds, and drives. Also removes the default non-admin "Open WezTerm here" entries added by WezTerm's own installer (so only the admin entry appears).

### 8-fix-steam-icons.bat
Fixes broken Steam game shortcut icons on the desktop. Scans for Steam URL shortcuts, downloads missing icons from Steam CDN, and clears the Windows icon cache. Run after Steam games are installed and shortcuts created.

### 9-context-menu-take-ownership.bat
Enables Windows long paths support and adds "Take Ownership" to the context menu for files, folders, and drives. Useful for fixing permission issues on files/folders you can't access.

### 10-setup-exclusions.bat
Adds Windows Security (Defender) folder exclusions to prevent false positives and DLL blocking for trusted applications. Run after installing applications that need exclusions.

**Exclusions added:** XIVLauncher/Dalamud (`%APPDATA%\XIVLauncher`), FINAL FANTASY XIV game folder, WezTerm (`%PROGRAMFILES%\WezTerm`)

### WezTerm configuration

WezTerm is installed by `2-setup-windows.bat` via winget to `%PROGRAMFILES%\WezTerm\` (system-wide, since setup runs as admin). Its config lives at `%USERPROFILE%\.wezterm.lua` and is deployed by the same script (only if the file doesn't already exist).

**Font:** Uses WezTerm's bundled `JetBrains Mono` by default (no install needed). Automatically switches to `JetBrainsMono Nerd Font` once `choco install nerd-fonts-jetbrainsmono` has run — just change the font line in `.wezterm.lua`.

**Default shell:** Auto-detects PS7 at `C:\Program Files\PowerShell\7\pwsh.exe`; falls back to `powershell.exe` (PS5) if PS7 is not installed.

**Profiles available** (launch menu via `Ctrl+Shift+L` or right-click the `+` button):
- PowerShell 7 (if installed, otherwise PS5 is used as default)
- PowerShell 5
- CMD
- Git Bash
- WSL

**Key bindings:**

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Shift+W` | Close tab |
| `Ctrl+Shift+D` | Split pane horizontal |
| `Ctrl+Shift+E` | Split pane vertical |
| `Ctrl+Shift+Arrow` | Navigate between panes |

**Notifications:** The PowerShell `$PROFILE` is modified by `2-setup-windows.bat` to ring the terminal bell and show a Windows toast notification whenever a command takes ≥ 10 seconds to complete. WezTerm flashes the tab bar in response to the bell. To modify the threshold, edit `$PROFILE` and change `10` in `$elapsed.TotalSeconds -ge 10`.

To manually edit the WezTerm config: `code $env:USERPROFILE\.wezterm.lua` or ask Claude Code to modify it.

### 11-setup-win11debloat.bat
Runs Win11Debloat in unattended mode to apply default tweaks and remove common optional apps (OneDrive, Phone Link, Camera, Photos, Media Player, Remote Desktop, Whiteboard). It also runs OneDrive's built-in uninstaller, removes its startup entry, disables reinstallation via policy, and deletes leftover local OneDrive folders.

### 99-remove-windows-ai.bat
Removes Windows AI features (Copilot, Recall, etc.) using the RemoveWindowsAI script from zoicware.

## Optional Scripts (`optional/`)

### optional/setup-work.bat
Work environment setup. Installs work-related applications via Chocolatey and Winget.

**Installed packages:** Slack, AWS CLI, Linear, Figma

### optional/move-downloads-folder.bat
Relocates the Windows Downloads folder to a different drive (default: Z:). Separated from the main profile folders script for users who prefer Downloads on the system drive.

### optional/setup-start-menu.bat
Backup and restore tool for Windows 11 Start Menu pinned apps layout. Option [1] backs up your current Start Menu layout to `start-menu-backup.bin` in the same folder. Option [2] restores the layout from the backup file. Use this to preserve your pinned apps arrangement across Windows reinstalls.

### optional/setup-makeplace.bat
Downloads and installs Re:MakePlace (community-maintained fork) directly from GitHub. Re:MakePlace is a standalone FFXIV housing layout preview/editor tool that lets you design and share housing layouts. Installs to `%LOCALAPPDATA%\ReMakePlace` since the app requires write permissions. Downloads 7-Zip portable if not already installed. Does not require Chocolatey. Launches the app after installation.

**Installed packages:** Re:MakePlace (from GitHub), 7-Zip (signed installer, if needed)

## Uninstall Scripts (`uninstall/`)

### uninstall/context-menu-terminal.bat
Removes the context menu entries added by `7-context-menu-terminal-install.bat`.

### uninstall/context-menu-take-ownership.bat
Removes the "Take Ownership" context menu entries added by `9-context-menu-take-ownership.bat`.

## Web Console

Four hostnames served through a single Cloudflare Zero Trust tunnel, all requiring Cloudflare Access authentication.

### Hostnames

| Hostname | Purpose |
|---|---|
| `tools.ffxivbe.org` | Dashboard — links to all dev tools |
| `console.ffxivbe.org` | SSH web client (sshwifty) with 8 quick-connect presets |
| `dev.ffxivbe.org` | Direct SSH to WSL (for native SSH clients) |
| `code.ffxivbe.org` | VS Code in the browser (code-server) |
| `ttyd.ffxivbe.org` | Phone-friendly terminal — landing page with Persistent/Fresh buttons |
| `git.ffxivbe.org` | Ungit — visual web Git UI, shows all repos under `/mnt/z/Github` |

### Architecture

```
Browser (Cloudflare Access auth)
  → Cloudflare tunnel
      tools.ffxivbe.org → Windows:7686
        → netsh portproxy (Windows:7686 → WSL IP:7686)
          → WSL dashboard.js (Node.js, static HTML landing page)

      console.ffxivbe.org → Windows:7681
        → console-proxy.js (injects quick-connect panel)
          → sshwifty_windows_amd64.exe (Windows:7682, SSH client UI)
            → netsh portproxy (Windows:2222 → WSL IP:22)
              → WSL sshd (authorized_keys forced commands → tmux/bash)

      dev.ffxivbe.org → ssh://Windows:22
        → netsh portproxy (Windows:22 → WSL IP:22)
          → WSL sshd

      code.ffxivbe.org → Windows:8080
        → netsh portproxy (Windows:8080 → WSL IP:8080)
          → WSL code-server (systemd: code-server@root)

      ttyd.ffxivbe.org → Windows:7683
        → netsh portproxy (Windows:7683 → WSL IP:7683)
          → WSL ttyd-proxy.js (Node.js landing page)
              /persistent → WSL ttyd-persistent (7684) → tmux session 'phone'
              /fresh      → WSL ttyd-fresh (7685)      → bash -l

      git.ffxivbe.org → Windows:7687
        → netsh portproxy (Windows:7687 → WSL IP:7687)
          → WSL git-proxy.js (Node.js repo list landing page, port 7687)
              / → repo list (scans /mnt/z/Github for .git dirs)
              /* → WSL ungit (port 7688, git graph viewer)
```

### First-time setup (after a fresh Windows install)

1. **Run WSL setup (once):**
   ```
   wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/cloudflared/setup-console-wsl.sh
   ```
2. **Authenticate cloudflared** (one-time, browser login):
   ```
   cloudflared tunnel login
   ```
3. **Populate secrets** — run `cloudflared\sync-secrets.bat` (requires `SSHWIFTY_CONF_B64` in GitHub Secrets).
4. **Run Windows setup** (creates tunnel, DNS, and downloads sshwifty automatically):
   ```
   cloudflared\setup-console-windows.ps1
   ```
5. **Start the console:**
   ```
   cloudflared\start-console.bat
   ```

### Daily use

Run `cloudflared\start-console.bat` after each login (or reboot) to refresh all WSL portproxies and restart all services. The `CloudflaredDevTunnel` and `UpdateWSLPortProxy` scheduled tasks also run at logon automatically.

### Console scripts

| File | Purpose |
|---|---|
| `cloudflared/start-console.bat` | One-click launcher (calls `start-console.ps1`) |
| `cloudflared/start-console.ps1` | Refreshes portproxies, restarts all services + cloudflared |
| `cloudflared/verify-console.ps1` | Verifies all console services are healthy (ports, HTTP 200, WSL systemd) — run after start-console.bat |
| `cloudflared/set-access-sessions.ps1` | Sets `session_duration` on every Zero Trust Access app (default `730h` ≈ 1 month). Requires `CLOUDFLARE_ACCOUNT_API_TOKEN` in `.secrets`. |
| `cloudflared/setup-console-windows.ps1` | First-time Windows setup: provisions tunnel + DNS, writes configs, creates scheduled tasks |
| `cloudflared/setup-console-wsl.sh` | First-time WSL setup: sshd, authorized_keys, code-server, ttyd services |
| `cloudflared/console-proxy.js` | Node.js proxy (Windows 7681→7682) that injects the quick-connect panel |
| `cloudflared/console-launcher.js` | Quick-connect panel UI injected into sshwifty's HTML |
| `cloudflared/ttyd-proxy.js` | Node.js landing page + proxy (WSL 7683→7684/7685) for ttyd.ffxivbe.org |
| `cloudflared/dashboard.js` | Node.js static server (WSL 7686) for tools.ffxivbe.org |
| `cloudflared/git-proxy.js` | Node.js repo list landing page + proxy (WSL 7687→7688) for git.ffxivbe.org |
| `cloudflared/sync-secrets.bat` | Syncs secrets from GitHub → local `.secrets` file |
| `cloudflared/sync-secrets.ps1` | Secrets sync implementation |
| `cloudflared/uninstall-console.ps1` | Full teardown: kills services, removes tasks/portproxies/files, deletes Cloudflare DNS + tunnel |
| `cloudflared/uninstall-console.bat` | Admin wrapper for uninstall-console.ps1 |

### WSL services

| Service | Port | Description |
|---|---|---|
| `ssh` | 22 | OpenSSH server |
| `dashboard` | 7686 | Dev Tools dashboard (tools.ffxivbe.org) |
| `code-server@root` | 8080 | VS Code server |
| `ttyd-proxy` | 7683 | Landing page + router for ttyd.ffxivbe.org |
| `ttyd-persistent` | 7684 | ttyd → `tmux new-session -A -s phone` |
| `ttyd-fresh` | 7685 | ttyd → `bash -l` |
| `git-proxy` | 7687 | Repo list landing page + proxy to ungit (git.ffxivbe.org) |
| `ungit` | 7688 | Ungit git graph viewer (internal, behind git-proxy) |
| `wetty` | 7681 | Fallback web terminal (unused by default) |

### Cloudflare tunnel

Tunnel name: `dev-console` — ID: `9c355567-7511-43af-bfcd-25e765106b16`

### Secrets required

| Secret | Description | How to encode |
|---|---|---|
| `SSHWIFTY_CONF_B64` | `sshwifty.conf.json` (contains embedded SSH private keys) | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\Documents\Cloudflare\sshwifty\sshwifty.conf.json")) \| clip` |

Cloudflare tunnel credentials are **not stored in secrets** — `cloudflared/setup-console-windows.ps1` creates a fresh tunnel automatically using `cert.pem` from `cloudflared tunnel login`.

### SSH presets (authorized_keys forced commands)

Each preset uses a unique ED25519 key embedded in `sshwifty.conf.json`. The forced command determines the session type:

| Preset | tmux session | Directory |
|---|---|---|
| WSL Persistent | `console` | `~` |
| WSL Fresh | *(plain bash)* | `~` |
| Candystore Persistent | `candyshop` | `/mnt/z/Github/candystore` |
| Candystore Fresh | *(plain bash)* | `/mnt/z/Github/candystore` |
| Eclipse-con Persistent | `eclipse-con` | `/mnt/z/Github/eclipse-con` |
| Eclipse-con Fresh | *(plain bash)* | `/mnt/z/Github/eclipse-con` |
| PCSetup Persistent | `pcsetup` | `/mnt/z/Users/Heiner/Documents/PCSetup` |
| PCSetup Fresh | *(plain bash)* | `/mnt/z/Users/Heiner/Documents/PCSetup` |

Persistent = `tmux new-session -A` (attach or create). Fresh = `exec bash -l` (new shell every time).

## Cloudflare SSH & Remote Access

Two tunnels that run as Windows scheduled tasks, separate from the web console.

### Tunnels

| Tunnel | Hostname | Purpose |
|--------|----------|---------|
| `ffxivbe-tunnel` | ffxivbe.org and subdomains | Web services proxy (reverse proxy on :7542) |
| `ssh-tunnel` | pc.ffxivbe.org | SSH remote access from Mac |

Tunnel IDs (persist in Cloudflare, survive PC formats):
- `ffxivbe-tunnel`: `c552cb9c-62bd-4c8b-9ec6-16627b1b8af3`
- `ssh-tunnel`: `8dffdb51-77cc-43ca-8dc8-8a0c720607a5`

#### ffxivbe-tunnel hostnames

All main app routes go through a local reverse proxy on port 7542. The PC setup does not manage local Supabase services.

| Hostname | Backend |
|---|---|
| `ffxivbe.org` / `www.ffxivbe.org` | `localhost:7542` |
| `chat.ffxivbe.org` | `localhost:3000` |

Config lives at `cloudflared/.cloudflared/config.yml` in this repo and is deployed to `C:\Users\Heiner\.cloudflared\config.yml` by `install-tunnel.ps1`.

### Post-Format Recovery

Run after a fresh Windows install to restore tunnels and Claude Code sessions:

```powershell
cd "Z:\Users\Heiner\Documents\PCSetup\cloudflared"
.\post-format-recovery.ps1
```

Or run individual steps:

```powershell
.\install-ssh-tunnel.ps1    # SSH tunnel + OpenSSH
.\install-tunnel.ps1        # Web tunnel
.\install-claude-session.ps1  # Claude Code tmux sessions
```

> **Note on cloudflared installation:** Scripts auto-install the official signed MSI. Do NOT install via Chocolatey — Smart App Control blocks unsigned executables.

### Claude Code Persistent Sessions (MSYS2/tmux)

| Session | Project | Type |
|---------|---------|------|
| `claude` | Z:\Users\Heiner\Documents\PCSetup\cloudflared | Claude Code |
| `claimangel` | Z:\Github\ClaimAngel\frontend | Claude Code |
| `snd` | Z:\Users\Heiner\Documents\Luas\SND | Bash only |

Sessions start automatically at Windows login. Accessible via `ssh windows-remote` from Mac, then:
```bash
claude        # attach to claude session
claimangel    # attach to claimangel session
snd           # attach to snd session
sessions      # list all tmux sessions
```
Detach: `Ctrl+B`, then `D`.

> **Browser-based MCPs don't work in remote sessions** (Playwright, Chrome DevTools require a local display). All other Claude Code functionality works fine.

### Windows Scheduled Tasks

| Task Name | Trigger | Purpose |
|-----------|---------|---------|
| `ffxivbe-tunnel` | At logon | Web tunnel to ffxivbe.org |
| `ssh-tunnel` | At logon | SSH tunnel to pc.ffxivbe.org |
| `claude-session` | At logon | Claude Code tmux (cloudflared project) |
| `claimangel-session` | At logon | Claude Code tmux (ClaimAngel project) |
| `snd-session` | At logon | Bash tmux (SND project) |

### Mac SSH Config

```bash
brew install cloudflared

# Add to ~/.ssh/config
Host windows-remote
    HostName pc.ffxivbe.org
    User Heiner
    ProxyCommand cloudflared access tcp --hostname %h --listener -
```

Mac SSH public key (already in authorized_keys):
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho heinerangarita@Heiners-MacBook-Air.local
```

### Cloudflare Dashboard (Already Configured — Persists)

Already set up, survives PC formats:
1. DNS CNAMEs pointing to tunnel IDs
2. Zero Trust route for SSH tunnel (`pc.ffxivbe.org` → ssh://localhost:22)
3. WAF bypass rule for `pc.ffxivbe.org`

### cloudflared/ Scripts

| File | Purpose |
|---|---|
| `cloudflared/post-format-recovery.ps1` | Master recovery script — does everything |
| `cloudflared/install-tunnel.ps1` | Web tunnel installer (standalone) |
| `cloudflared/install-ssh-tunnel.ps1` | SSH tunnel + OpenSSH installer |
| `cloudflared/install-claude-session.ps1` | Claude Code tmux sessions installer |
| `cloudflared/install-scheduled-tasks.ps1` | Reinstall scheduled tasks only |
| `cloudflared/toggle-tunnel.bat` | Start/stop web tunnel |
| `cloudflared/toggle-ssh-tunnel.bat` | Start/stop SSH tunnel |
| `cloudflared/toggle-claude-session.bat` | Start/stop any Claude/tmux session |
| `cloudflared/manage-tunnel.ps1` | Status checker for web tunnel |
| `cloudflared/uninstall-tunnel.ps1` | Stops task, kills processes, leaves config/DNS intact |
| `cloudflared/create-shortcuts.ps1` | Creates desktop shortcuts |
| `cloudflared/start-claude-session.sh` | MSYS2 script to start/attach tmux session |
| `cloudflared/claude-aliases.sh` | Bash aliases (claude, claimangel, snd, etc.) |
| `cloudflared/.cloudflared/config.yml` | ffxivbe-tunnel routing config |

### Troubleshooting

```powershell
# Tunnel not connecting — check task status
Get-ScheduledTask -TaskName "ssh-tunnel" | Select State
Get-ScheduledTask -TaskName "ffxivbe-tunnel" | Select State

# SSH "Permission denied" — re-add SSH key
$key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho heinerangarita@Heiners-MacBook-Air.local"
Set-Content -Path "C:\ProgramData\ssh\administrators_authorized_keys" -Value $key
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
Restart-Service sshd

# Claude session not starting
Get-ScheduledTask -TaskName "claude-session" | Select State
Start-ScheduledTask -TaskName "claude-session"

# Cloudflared blocked by Smart App Control
# → Uninstall Chocolatey version, install from official MSI:
choco uninstall cloudflared -y
Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi' -OutFile "$env:TEMP\cloudflared.msi"
Start-Process msiexec.exe -ArgumentList '/i', "$env:TEMP\cloudflared.msi", '/quiet' -Wait
```

## Source Files (`sources/`)

Backup registry files that can be imported directly if the batch scripts don't work.

### sources/Add_Take_Ownership_to_context_menu.reg
Original Take Ownership registry file. Double-click to import if `9-context-menu-take-ownership.bat` fails.

### sources/Longpath.reg
Enables Windows long paths support. Already handled by `9-context-menu-take-ownership.bat`.
