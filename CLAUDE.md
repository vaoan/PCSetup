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
- [ ] Every script must auto-elevate to admin
- [ ] Scripts should be unattended (no pauses unless explicitly requested)
- [ ] Use Chocolatey and npm for package installations

## Naming Convention

All scripts use **kebab-case** naming: `[N-]action-target.ext`

- Numbered prefix (`1-`, `2-`, etc.) indicates execution order after fresh Windows install
- Utility scripts have no number prefix (run as needed)

## Setup Scripts (Run in Order)

### 1-setup-windows.bat
Main Windows setup script. Installs Chocolatey and a comprehensive set of applications including browsers, development tools, media players, and utilities. Also installs Discord Canary, Chrome Remote Desktop, WSL, Node.js LTS via nvm, and removes Windows AI features.

**Installed packages:** Chrome, Discord, DirectX, 7zip, WinRAR, Steam, VLC, K-Lite Codec Pack, Spotify, HandBrake, ShareX, Python, Notepad++, Telegram, pCloud, RDM, qBittorrent, Cloudflared, Warp, Winamp, Firefox, PuTTY, WinSCP, BleachBit, Bulk Crap Uninstaller, Streamlabs OBS, Prism Launcher, Temurin JDK 17/8, EarTrumpet, Git, Sourcetree, VS Code, GitHub Desktop, OnTopReplica, OnlyOffice, nvm, NVIDIA App, VC++ Redistributables, .NET runtimes, Driver Booster, ProtonVPN

### 2-fix-execution-policy.bat
Sets PowerShell execution policy to `RemoteSigned` for the current user, allowing scripts like Claude Code to run in PowerShell.

### 3-move-profile-folders.bat
Relocates Windows user profile folders (Desktop, Documents, Downloads, Music, Pictures, Videos, etc.) to a different drive (default: Z:). Updates registry entries and optionally moves existing files. Run early before accumulating files.

### 4-setup-work.bat
Work environment setup. Installs work-related applications via Chocolatey and Winget.

**Installed packages:** Slack, AWS CLI, Linear, Figma

### 5-context-menu-terminal-install.bat
Adds "Open in Terminal as Administrator" and "Open in PowerShell as Administrator" to the Windows Explorer context menu (right-click menu) for directories, directory backgrounds, and drives.

### 6-fix-steam-icons.bat
Fixes broken Steam game shortcut icons on the desktop. Scans for Steam URL shortcuts, downloads missing icons from Steam CDN, and clears the Windows icon cache. Run after Steam games are installed and shortcuts created.

### 7-delete-node-modules.bat
Recursively finds and deletes all `node_modules` folders on the drive where the script is located. Useful for reclaiming disk space.

### 8-context-menu-take-ownership.bat
Enables Windows long paths support and adds "Take Ownership" to the context menu for files, folders, and drives. Useful for fixing permission issues on files/folders you can't access.

## Uninstall Scripts (`uninstall/`)

### uninstall/context-menu-terminal.bat
Removes the context menu entries added by `5-context-menu-terminal-install.bat`.

### uninstall/context-menu-take-ownership.bat
Removes the "Take Ownership" context menu entries added by `8-context-menu-take-ownership.bat`.
