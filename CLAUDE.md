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

## Web Console (`console.ffxivbe.org`)

Mobile-friendly SSH web console backed by sshwifty, a Cloudflare Zero Trust tunnel, and a Node.js proxy that injects a quick-connect panel. Six presets (WSL, Candystore, Eclipse-con × Persistent/Fresh) are accessible via a single click instead of the native 5-click flow.

### Architecture

```
Browser (Cloudflare Access auth)
  → Cloudflare tunnel (console.ffxivbe.org → localhost:7681)
    → console-proxy.js (injects quick-connect panel into HTML)
      → sshwifty_windows_amd64.exe (port 7682, SSH client UI)
        → netsh portproxy (localhost:2222 → WSL IP:22)
          → WSL Ubuntu-24.04 sshd (authorized_keys forced commands)
            → tmux session (Persistent) or plain bash (Fresh)
```

### First-time setup (after a fresh Windows install)

1. **Run WSL setup (once):**
   ```
   wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/scripts/setup-console-wsl.sh
   ```
2. **Populate secrets** — run `sync-secrets.bat` (requires `SSHWIFTY_CONF_B64` and `CLOUDFLARE_DEV_CREDENTIALS_B64` in GitHub Secrets).
3. **Download sshwifty binary** — `sshwifty_windows_amd64.exe` from GitHub releases v0.4.6-beta-release. Place at `%USERPROFILE%\Documents\Cloudflare\sshwifty\sshwifty_windows_amd64.exe`.
4. **Run Windows setup:**
   ```
   scripts\setup-console-windows.ps1
   ```
5. **Start the console:**
   ```
   start-console.bat
   ```

### Daily use

Run `start-console.bat` after each login (or reboot) to refresh the WSL port-proxy and restart all services. The `CloudflaredDevTunnel` and `UpdateWSLPortProxy` scheduled tasks also run at logon automatically.

### Console scripts

| File | Purpose |
|---|---|
| `start-console.bat` | One-click launcher (calls `scripts\start-console.ps1`) |
| `scripts/start-console.ps1` | Updates portproxy, restarts sshwifty + proxy + cloudflared |
| `scripts/setup-console-windows.ps1` | First-time Windows setup: writes configs, creates scheduled tasks |
| `scripts/setup-console-wsl.sh` | First-time WSL setup: sshd, authorized_keys, mount script |
| `scripts/console-proxy.js` | Node.js proxy (port 7681→7682) that injects the quick-connect panel |
| `scripts/console-launcher.js` | Quick-connect panel UI injected into sshwifty's HTML |

### Secrets required

| Secret | Description | How to encode |
|---|---|---|
| `SSHWIFTY_CONF_B64` | `sshwifty.conf.json` (contains embedded SSH private keys) | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\Documents\Cloudflare\sshwifty\sshwifty.conf.json")) \| clip` |
| `CLOUDFLARE_DEV_CREDENTIALS_B64` | Cloudflare tunnel credentials JSON | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\.cloudflared\c28375cb-0b8f-433b-aed6-48fb1d0090e9.json")) \| clip` |

### Cloudflare tunnel routes (tunnel `c28375cb-0b8f-433b-aed6-48fb1d0090e9`)

| Hostname | Target |
|---|---|
| `console.ffxivbe.org` | `localhost:7681` (sshwifty via proxy) |
| `dev.ffxivbe.org` | `ssh://localhost:22` (WSL SSH direct) |
| `code.ffxivbe.org` | `localhost:8080` (VS Code server) |
| `zellij.ffxivbe.org` | `localhost:7683` (zellij web) |

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
