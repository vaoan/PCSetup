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

### sync-secrets.bat
Pulls secrets from GitHub repository secrets to a local `.secrets` file (gitignored). Reads a decryption passphrase from `%USERPROFILE%\.pcsetup-sync-passphrase`, triggers `.github/workflows/sync-secrets.yml` via `gh workflow run`, waits for the workflow to complete, downloads the AES-256-CBC encrypted artifact, decrypts it with `openssl.exe` (bundled with Git for Windows), and writes `.secrets`.

**Prerequisites:** `gh auth login` must have been run. Git for Windows must be installed. `%USERPROFILE%\.pcsetup-sync-passphrase` must exist (see `.secrets.example` first-time setup instructions).

To add a new secret:
1. Add it in GitHub → Settings → Secrets and variables → Actions
2. Add it to the `env:` block and `run:` output section in `.github/workflows/sync-secrets.yml`
3. Add a placeholder line to `.secrets.example`

## Setup Scripts (Run in Order)

### 1-delete-node-modules.bat
Recursively finds and deletes all `node_modules` folders on all fixed hard drives. Useful for reclaiming disk space.

### 2-setup-windows.bat
Main Windows setup script. Installs Chocolatey and a comprehensive set of applications including browsers, development tools, media players, and utilities. Also installs Discord Canary, Chrome Remote Desktop, WSL, Claude Code, and the main Windows runtimes.

**Installed packages:** Chrome, Discord, DirectX, 7zip, WinRAR, VLC, K-Lite Codec Pack, Spotify, HandBrake, ShareX, Python, Notepad++, Telegram, pCloud, RDM, qBittorrent, Cloudflared, Warp, Winamp, Firefox, PuTTY, WinSCP, BleachBit, Bulk Crap Uninstaller, WizTree, EarTrumpet, Git, Sourcetree, VS Code, GitHub Desktop, GitHub CLI, OnTopReplica, OnlyOffice, NVIDIA App, VC++ Redistributables, .NET runtimes, Streamlabs OBS, ProtonVPN, 2FAGuard, Claude Desktop, Kiro, Claude Code, WezTerm, PowerShell 7, JetBrainsMono Nerd Font

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
| `console.ffxivbe.org` | SSH web client (sshwifty) with 6 quick-connect presets |
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
          → WSL ungit (systemd: ungit, rootPath /mnt/z/Github)
```

### First-time setup (after a fresh Windows install)

1. **Run WSL setup (once):**
   ```
   wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/scripts/setup-console-wsl.sh
   ```
2. **Authenticate cloudflared** (one-time, browser login):
   ```
   cloudflared tunnel login
   ```
3. **Populate secrets** — run `sync-secrets.bat` (requires `SSHWIFTY_CONF_B64` in GitHub Secrets).
4. **Run Windows setup** (creates tunnel, DNS, and downloads sshwifty automatically):
   ```
   scripts\setup-console-windows.ps1
   ```
5. **Start the console:**
   ```
   start-console.bat
   ```

### Daily use

Run `start-console.bat` after each login (or reboot) to refresh all WSL portproxies and restart all services. The `CloudflaredDevTunnel` and `UpdateWSLPortProxy` scheduled tasks also run at logon automatically.

### Console scripts

| File | Purpose |
|---|---|
| `start-console.bat` | One-click launcher (calls `scripts\start-console.ps1`) |
| `scripts/start-console.ps1` | Refreshes portproxies, restarts all services + cloudflared |
| `scripts/setup-console-windows.ps1` | First-time Windows setup: provisions tunnel + DNS, writes configs, creates scheduled tasks |
| `scripts/setup-console-wsl.sh` | First-time WSL setup: sshd, authorized_keys, code-server, ttyd services |
| `scripts/console-proxy.js` | Node.js proxy (Windows 7681→7682) that injects the quick-connect panel |
| `scripts/console-launcher.js` | Quick-connect panel UI injected into sshwifty's HTML |
| `scripts/ttyd-proxy.js` | Node.js landing page + proxy (WSL 7683→7684/7685) for ttyd.ffxivbe.org |
| `scripts/dashboard.js` | Node.js static server (WSL 7686) for tools.ffxivbe.org |
| `scripts/ungit.service` | Managed via setup-console-wsl.sh — ungit web Git UI (WSL 7687) |
| `uninstall/uninstall-console.ps1` | Full teardown: kills services, removes tasks/portproxies/files, deletes Cloudflare DNS + tunnel |
| `uninstall/uninstall-console.bat` | Admin wrapper for uninstall-console.ps1 |

### WSL services

| Service | Port | Description |
|---|---|---|
| `ssh` | 22 | OpenSSH server |
| `dashboard` | 7686 | Dev Tools dashboard (tools.ffxivbe.org) |
| `code-server@root` | 8080 | VS Code server |
| `ttyd-proxy` | 7683 | Landing page + router for ttyd.ffxivbe.org |
| `ttyd-persistent` | 7684 | ttyd → `tmux new-session -A -s phone` |
| `ttyd-fresh` | 7685 | ttyd → `bash -l` |
| `ungit` | 7687 | Ungit web Git UI (git.ffxivbe.org) |
| `wetty` | 7681 | Fallback web terminal (unused by default) |

### Cloudflare tunnel

Tunnel name: `dev-console` — ID: `9c355567-7511-43af-bfcd-25e765106b16`

### Secrets required

| Secret | Description | How to encode |
|---|---|---|
| `SSHWIFTY_CONF_B64` | `sshwifty.conf.json` (contains embedded SSH private keys) | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\Documents\Cloudflare\sshwifty\sshwifty.conf.json")) \| clip` |

Cloudflare tunnel credentials are **not stored in secrets** — `setup-console-windows.ps1` creates a fresh tunnel automatically using `cert.pem` from `cloudflared tunnel login`.

### SSH presets (authorized_keys forced commands)

Each preset uses a unique ED25519 key embedded in `sshwifty.conf.json`. The forced command determines the session type:

| Preset | tmux session | Directory |
|---|---|---|
| WSL Persistent | `console` | `~` |
| WSL Fresh | *(plain bash)* | `~` |
| Candystore Persistent | `candystore` | `/mnt/z/Github/candystore` |
| Candystore Fresh | *(plain bash)* | `/mnt/z/Github/candystore` |
| Eclipse-con Persistent | `eclipse-con` | `/mnt/z/Github/eclipse-con` |
| Eclipse-con Fresh | *(plain bash)* | `/mnt/z/Github/eclipse-con` |

Persistent = `tmux new-session -A` (attach or create). Fresh = `exec bash -l` (new shell every time).

## Source Files (`sources/`)

Backup registry files that can be imported directly if the batch scripts don't work.

### sources/Add_Take_Ownership_to_context_menu.reg
Original Take Ownership registry file. Double-click to import if `9-context-menu-take-ownership.bat` fails.

### sources/Longpath.reg
Enables Windows long paths support. Already handled by `9-context-menu-take-ownership.bat`.
