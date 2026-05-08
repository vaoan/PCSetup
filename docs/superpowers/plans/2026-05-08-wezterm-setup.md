# WezTerm Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install WezTerm as the primary developer terminal, configure it for Claude Code use, and wire it into the existing setup/context-menu/uninstall/exclusion scripts so the full configuration is restored by `run-all.bat` on a fresh Windows install.

**Architecture:** All changes slot into five existing files — no new numbered script. `2-setup-windows.bat` gains package installs, a Lua config deployment, and a PowerShell `$PROFILE` notification block. The context-menu install/uninstall scripts gain WezTerm registry entries. The exclusions script gains a Defender exclusion. CLAUDE.md is updated to reflect all changes.

**Tech Stack:** Windows batch (CMD), inline PowerShell temp-ps1 pattern (already used throughout `2-setup-windows.bat`), WezTerm Lua config, WinRT toast API (no external module), winget, Chocolatey.

---

## File Map

| File | Change type |
|---|---|
| `2-setup-windows.bat` | 4 insertions: font choco, PS7+WezTerm winget, `.wezterm.lua` deploy, `$PROFILE` append |
| `7-context-menu-terminal-install.bat` | Insert WezTerm context menu reg block before `Restarting Explorer` |
| `uninstall/context-menu-terminal.bat` | Insert WezTerm `reg delete` lines after Git Bash deletions |
| `10-setup-exclusions.bat` | Append WezTerm Defender exclusion line |
| `CLAUDE.md` | Edit 3 existing sections + append new WezTerm config section |

---

## Critical Pattern Reference

`2-setup-windows.bat` builds a temp PS1 file using `echo ... >>"%SCRIPT%"` lines. Every line added must follow these rules (from CLAUDE.md):
- Parentheses in echoed PS code must be escaped: `^(` and `^)`
- CMD `>` inside echoed text must be escaped: `^>`
- Dollar signs `$` do NOT need escaping in CMD echo (they're PS-only)
- The file is executed at line 229: `powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"`

For complex multi-line content (the Lua config, the PS profile block), use **Base64 encoding** — compute the Base64 of the content string in PowerShell, store it in a single echo line, and decode at runtime. This avoids all escaping issues with `{`, `}`, `(`, `)`, `'`, backticks.

---

### Task 1: Add Nerd Font, PowerShell 7, and WezTerm package installs to `2-setup-windows.bat`

**Files:**
- Modify: `2-setup-windows.bat:56` (after `choco install streamlabs-obs` line)
- Modify: `2-setup-windows.bat:176` (after `winget install Rufus.Rufus` line)

- [ ] **Step 1: Add JetBrainsMono Nerd Font choco install after line 56**

Open `2-setup-windows.bat`. Find this line (currently line 56):
```
echo choco install streamlabs-obs -y>>"%SCRIPT%"
```
Insert immediately after it:
```batch
echo Write-Host "Installing JetBrainsMono Nerd Font..." -ForegroundColor Cyan>>"%SCRIPT%"
echo choco install nerd-fonts-jetbrainsmono -y>>"%SCRIPT%"
```

- [ ] **Step 2: Add PS7 and WezTerm winget installs after the Rufus winget line**

Find this line (currently line 176):
```
echo winget install --id Rufus.Rufus -e --accept-source-agreements --accept-package-agreements --silent>>"%SCRIPT%"
```
Insert immediately after it:
```batch
echo Write-Host "Installing PowerShell 7..." -ForegroundColor Cyan>>"%SCRIPT%"
echo if ^(Get-Command pwsh -ErrorAction SilentlyContinue^) { Write-Host "PowerShell 7 already installed, skipping..." -ForegroundColor Yellow } else { winget install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements --silent }>>"%SCRIPT%"
echo Write-Host "Installing WezTerm..." -ForegroundColor Cyan>>"%SCRIPT%"
echo if ^(Test-Path "$env:LOCALAPPDATA\Programs\WezTerm\wezterm-gui.exe"^) { Write-Host "WezTerm already installed, skipping..." -ForegroundColor Yellow } else { winget install --id wez.wezterm -e --accept-source-agreements --accept-package-agreements --silent }>>"%SCRIPT%"
```

- [ ] **Step 3: Verify the file parses without CMD syntax errors**

Run:
```powershell
# This just checks CMD can parse the file — does not execute setup
cmd /c "2-setup-windows.bat" 2>&1 | Select-Object -First 5
```
Expected: The script elevates and either continues or exits — it should NOT print "was unexpected at this time" syntax errors. If it does, a `^` escape is missing. (You can Ctrl+C immediately after running to abort actual installs.)

- [ ] **Step 4: Commit**

```
git add 2-setup-windows.bat
git commit -m "feat(setup): install WezTerm, PowerShell 7, and JetBrainsMono Nerd Font"
```

---

### Task 2: Deploy `.wezterm.lua` config from `2-setup-windows.bat`

**Files:**
- Modify: `2-setup-windows.bat` (after the WezTerm winget install lines added in Task 1)

The Lua config contains curly braces, parentheses, and single quotes — use Base64 to avoid CMD escaping nightmares.

- [ ] **Step 1: Compute the Base64 string for the Lua config**

Run this in PowerShell to get the Base64 string:
```powershell
$lua = @'
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.term = 'xterm-256color'
config.scrollback_lines = 10000

config.font = wezterm.font('JetBrainsMono Nerd Font')
config.font_size = 12.0

config.color_scheme = 'Catppuccin Mocha'
config.window_background_opacity = 0.95
config.text_background_opacity = 1.0
config.window_decorations = 'RESIZE'

config.audible_bell = 'Disabled'
config.visual_bell = {
  fade_in_duration_ms = 75,
  fade_out_duration_ms = 75,
  target = 'CursorColor',
}

config.default_prog = { 'pwsh.exe', '-NoLogo' }
config.launch_menu = {
  { label = 'PowerShell 7',  args = { 'pwsh.exe', '-NoLogo' } },
  { label = 'PowerShell 5',  args = { 'powershell.exe', '-NoLogo' } },
  { label = 'CMD',           args = { 'cmd.exe' } },
  { label = 'Git Bash',      args = { 'C:\\Program Files\\Git\\bin\\bash.exe', '-i', '-l' } },
  { label = 'WSL',           args = { 'wsl.exe' } },
}

config.keys = {
  { key = 't', mods = 'CTRL|SHIFT', action = wezterm.action.SpawnTab 'CurrentPaneDomain' },
  { key = 'w', mods = 'CTRL|SHIFT', action = wezterm.action.CloseCurrentTab { confirm = false } },
  { key = 'd', mods = 'CTRL|SHIFT', action = wezterm.action.SplitHorizontal { domain = 'CurrentPaneDomain' } },
  { key = 'e', mods = 'CTRL|SHIFT', action = wezterm.action.SplitVertical   { domain = 'CurrentPaneDomain' } },
  { key = 'LeftArrow',  mods = 'CTRL|SHIFT', action = wezterm.action.ActivatePaneDirection 'Left' },
  { key = 'RightArrow', mods = 'CTRL|SHIFT', action = wezterm.action.ActivatePaneDirection 'Right' },
  { key = 'UpArrow',    mods = 'CTRL|SHIFT', action = wezterm.action.ActivatePaneDirection 'Up' },
  { key = 'DownArrow',  mods = 'CTRL|SHIFT', action = wezterm.action.ActivatePaneDirection 'Down' },
}

return config
'@
[Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($lua))
```
Copy the output — it will be a long single-line Base64 string. Call it `<LUA_B64>` below.

- [ ] **Step 2: Insert the config deployment block after the WezTerm winget install lines**

In `2-setup-windows.bat`, immediately after the four lines added in Task 1 Step 2, insert:
```batch
echo Write-Host "Deploying .wezterm.lua config..." -ForegroundColor Cyan>>"%SCRIPT%"
echo if ^(-not ^(Test-Path "$env:USERPROFILE\.wezterm.lua"^)^) {>>"%SCRIPT%"
echo     $luaB64 = '<LUA_B64>'>>"%SCRIPT%"
echo     $luaContent = [System.Text.Encoding]::UTF8.GetString^([Convert]::FromBase64String^($luaB64^)^)>>"%SCRIPT%"
echo     [System.IO.File]::WriteAllText^("$env:USERPROFILE\.wezterm.lua", $luaContent, [System.Text.Encoding]::UTF8^)>>"%SCRIPT%"
echo     Write-Host ".wezterm.lua written to $env:USERPROFILE" -ForegroundColor Green>>"%SCRIPT%"
echo } else { Write-Host ".wezterm.lua already exists, skipping..." -ForegroundColor Yellow }>>"%SCRIPT%"
```
Replace `<LUA_B64>` with the actual Base64 string from Step 1.

- [ ] **Step 3: Verify the config deployment logic by testing it in isolation**

Run this in PowerShell (safe — doesn't install anything, just tests the deploy logic):
```powershell
$luaB64 = '<LUA_B64>'  # paste the same Base64 string here
$luaContent = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($luaB64))
# Verify the decoded content starts with the expected Lua line
if ($luaContent -match "^local wezterm = require 'wezterm'") {
    Write-Host "Base64 decode OK — content starts correctly" -ForegroundColor Green
} else {
    Write-Host "FAIL: decoded content unexpected" -ForegroundColor Red
    $luaContent | Select-Object -First 3
}
```
Expected: `Base64 decode OK — content starts correctly`

- [ ] **Step 4: Commit**

```
git add 2-setup-windows.bat
git commit -m "feat(setup): deploy .wezterm.lua config on install"
```

---

### Task 3: Add PowerShell `$PROFILE` notification block to `2-setup-windows.bat`

**Files:**
- Modify: `2-setup-windows.bat` (after the `.wezterm.lua` deployment block added in Task 2)

Same Base64 pattern — the PS profile block contains `$`, `{`, `}`, and backticks which are all unsafe in CMD echo.

- [ ] **Step 1: Compute the Base64 string for the PS profile block**

Run in PowerShell:
```powershell
$profileBlock = @'

# WezTerm bell notification
$global:_WezPromptTimer = $null
function prompt {
    $lastExit = $LASTEXITCODE
    if ($global:_WezPromptTimer -ne $null) {
        $elapsed = (Get-Date) - $global:_WezPromptTimer
        if ($elapsed.TotalSeconds -ge 10) {
            [Console]::Write("`a")
            try {
                $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
                $status = if ($lastExit -eq 0) { 'finished' } else { "failed (exit $lastExit)" }
                $msg = "Command $status after $([int]$elapsed.TotalSeconds)s"
                $xml = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime]::new()
                $xml.LoadXml("<toast><visual><binding template='ToastText01'><text id='1'>$msg</text></binding></visual></toast>")
                $toast = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime]::new($xml)
                [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]::CreateToastNotifier($appId).Show($toast)
            } catch { }
        }
    }
    $global:_WezPromptTimer = Get-Date
    $global:LASTEXITCODE = $lastExit
    "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
}
'@
[Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($profileBlock))
```
Copy the output — call it `<PROFILE_B64>`.

- [ ] **Step 2: Insert the `$PROFILE` append block after the `.wezterm.lua` block**

In `2-setup-windows.bat`, immediately after the config deployment block added in Task 2, insert:
```batch
echo Write-Host "Configuring PowerShell profile for WezTerm notifications..." -ForegroundColor Cyan>>"%SCRIPT%"
echo if ^(-not ^(Test-Path $PROFILE^)^) { New-Item -Path $PROFILE -ItemType File -Force ^| Out-Null }>>"%SCRIPT%"
echo $profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue>>"%SCRIPT%"
echo if ^($profileContent -notmatch '# WezTerm bell notification'^) {>>"%SCRIPT%"
echo     $profB64 = '<PROFILE_B64>'>>"%SCRIPT%"
echo     $profBlock = [System.Text.Encoding]::UTF8.GetString^([Convert]::FromBase64String^($profB64^)^)>>"%SCRIPT%"
echo     Add-Content -Path $PROFILE -Value $profBlock -Encoding UTF8>>"%SCRIPT%"
echo     Write-Host "WezTerm notification block added to PowerShell profile." -ForegroundColor Green>>"%SCRIPT%"
echo } else { Write-Host "WezTerm notification already in PS profile, skipping..." -ForegroundColor Yellow }>>"%SCRIPT%"
```
Replace `<PROFILE_B64>` with the Base64 string from Step 1.

- [ ] **Step 3: Verify the `$PROFILE` block decodes correctly**

Run in PowerShell:
```powershell
$profB64 = '<PROFILE_B64>'  # paste same Base64
$decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($profB64))
if ($decoded -match '# WezTerm bell notification') {
    Write-Host "Profile block decode OK" -ForegroundColor Green
} else {
    Write-Host "FAIL: marker not found in decoded block" -ForegroundColor Red
}
```
Expected: `Profile block decode OK`

- [ ] **Step 4: Commit**

```
git add 2-setup-windows.bat
git commit -m "feat(setup): add WezTerm command-done notification to PS profile"
```

---

### Task 4: Add WezTerm context menu entries to `7-context-menu-terminal-install.bat`

**Files:**
- Modify: `7-context-menu-terminal-install.bat` (before line 68: `echo Restarting Explorer...`)

- [ ] **Step 1: Find the insertion point**

Open `7-context-menu-terminal-install.bat`. Find this block near the end:
```batch
echo Restarting Explorer...
powershell -Command "Stop-Process -Name explorer -Force; Start-Process explorer" >nul 2>&1
```

- [ ] **Step 2: Insert the WezTerm context menu block before `Restarting Explorer`**

```batch
echo Adding "Open in WezTerm as Administrator" to context menu...

:: WezTerm - Directory Background
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenWezTermAdmin" /ve /d "Open in WezTerm as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenWezTermAdmin" /v "Icon" /d "%LOCALAPPDATA%\Programs\WezTerm\wezterm-gui.exe" /f
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenWezTermAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process '%LOCALAPPDATA%\\Programs\\WezTerm\\wezterm-gui.exe' -ArgumentList 'start --cwd \"\"%%V\"\"' -Verb RunAs\"" /f

:: WezTerm - Directory
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenWezTermAdmin" /ve /d "Open in WezTerm as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenWezTermAdmin" /v "Icon" /d "%LOCALAPPDATA%\Programs\WezTerm\wezterm-gui.exe" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenWezTermAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process '%LOCALAPPDATA%\\Programs\\WezTerm\\wezterm-gui.exe' -ArgumentList 'start --cwd \"\"%%V\"\"' -Verb RunAs\"" /f

:: WezTerm - Drive
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenWezTermAdmin" /ve /d "Open in WezTerm as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenWezTermAdmin" /v "Icon" /d "%LOCALAPPDATA%\Programs\WezTerm\wezterm-gui.exe" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenWezTermAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process '%LOCALAPPDATA%\\Programs\\WezTerm\\wezterm-gui.exe' -ArgumentList 'start --cwd \"\"%%V\"\"' -Verb RunAs\"" /f

```

**Note on the WezTerm exe path:** WezTerm installs to `%LOCALAPPDATA%\Programs\WezTerm\wezterm-gui.exe` when installed via winget for the current user (the default). The Icon value uses the full path; the command uses it too. Both `%LOCALAPPDATA%` variables expand at registry write time (when the BAT runs as admin) to the correct user path.

- [ ] **Step 3: Verify registry keys are syntactically valid by doing a dry-run check**

```powershell
# Read the file and check the new block is present
$content = Get-Content "7-context-menu-terminal-install.bat" -Raw
if ($content -match 'OpenWezTermAdmin') {
    Write-Host "WezTerm context menu block found in script" -ForegroundColor Green
} else {
    Write-Host "FAIL: block not found" -ForegroundColor Red
}
```
Expected: `WezTerm context menu block found in script`

- [ ] **Step 4: Commit**

```
git add 7-context-menu-terminal-install.bat
git commit -m "feat(context-menu): add Open in WezTerm as Administrator"
```

---

### Task 5: Add WezTerm uninstall entries to `uninstall/context-menu-terminal.bat`

**Files:**
- Modify: `uninstall/context-menu-terminal.bat` (after the Git Bash delete lines, before the classic context menu restore)

- [ ] **Step 1: Find the insertion point**

Open `uninstall/context-menu-terminal.bat`. Find:
```batch
echo Removing "Open Git Bash here as Administrator" from context menu...

reg delete "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenGitBashAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Directory\shell\OpenGitBashAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Drive\shell\OpenGitBashAdmin" /f 2>nul

echo Restoring Windows 11 modern context menu...
```

- [ ] **Step 2: Insert WezTerm delete lines between the Git Bash block and the context menu restore**

```batch
echo Removing "Open in WezTerm as Administrator" from context menu...

reg delete "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenWezTermAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Directory\shell\OpenWezTermAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Drive\shell\OpenWezTermAdmin" /f 2>nul

```

- [ ] **Step 3: Verify**

```powershell
$content = Get-Content "uninstall\context-menu-terminal.bat" -Raw
if ($content -match 'OpenWezTermAdmin') {
    Write-Host "WezTerm uninstall entries found" -ForegroundColor Green
} else {
    Write-Host "FAIL" -ForegroundColor Red
}
```
Expected: `WezTerm uninstall entries found`

- [ ] **Step 4: Commit**

```
git add uninstall/context-menu-terminal.bat
git commit -m "feat(uninstall): remove WezTerm context menu entries on uninstall"
```

---

### Task 6: Add WezTerm Defender exclusion to `10-setup-exclusions.bat`

**Files:**
- Modify: `10-setup-exclusions.bat` (after the existing XIVLauncher exclusion lines)

- [ ] **Step 1: Find the insertion point**

Open `10-setup-exclusions.bat`. Find:
```batch
:: FINAL FANTASY XIV
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath 'C:\Program Files (x86)\SquareEnix\FINAL FANTASY XIV - A Realm Reborn'"
```

- [ ] **Step 2: Insert WezTerm exclusion after the FFXIV line**

```batch
:: WezTerm (GPU acceleration DLLs can be flagged by Defender)
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '$env:LOCALAPPDATA\Programs\WezTerm'"
```

- [ ] **Step 3: Verify**

```powershell
$content = Get-Content "10-setup-exclusions.bat" -Raw
if ($content -match 'WezTerm') {
    Write-Host "WezTerm exclusion found" -ForegroundColor Green
} else {
    Write-Host "FAIL" -ForegroundColor Red
}
```
Expected: `WezTerm exclusion found`

- [ ] **Step 4: Commit**

```
git add 10-setup-exclusions.bat
git commit -m "feat(exclusions): add Windows Defender exclusion for WezTerm"
```

---

### Task 7: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (4 edits)

- [ ] **Step 1: Update `### 2-setup-windows.bat` installed packages list**

Find:
```
**Installed packages:** Chrome, Discord, DirectX, 7zip, WinRAR, VLC, K-Lite Codec Pack, Spotify, HandBrake, ShareX, Python, Notepad++, Telegram, pCloud, RDM, qBittorrent, Cloudflared, Warp, Winamp, Firefox, PuTTY, WinSCP, BleachBit, Bulk Crap Uninstaller, WizTree, EarTrumpet, Git, Sourcetree, VS Code, GitHub Desktop, GitHub CLI, OnTopReplica, OnlyOffice, NVIDIA App, VC++ Redistributables, .NET runtimes, Streamlabs OBS, ProtonVPN, 2FAGuard, Claude Desktop, Kiro, Claude Code
```
Replace with:
```
**Installed packages:** Chrome, Discord, DirectX, 7zip, WinRAR, VLC, K-Lite Codec Pack, Spotify, HandBrake, ShareX, Python, Notepad++, Telegram, pCloud, RDM, qBittorrent, Cloudflared, Warp, Winamp, Firefox, PuTTY, WinSCP, BleachBit, Bulk Crap Uninstaller, WizTree, EarTrumpet, Git, Sourcetree, VS Code, GitHub Desktop, GitHub CLI, OnTopReplica, OnlyOffice, NVIDIA App, VC++ Redistributables, .NET runtimes, Streamlabs OBS, ProtonVPN, 2FAGuard, Claude Desktop, Kiro, Claude Code, WezTerm, PowerShell 7, JetBrainsMono Nerd Font

Also deploys `%USERPROFILE%\.wezterm.lua` (GPU-accelerated config with Catppuccin Mocha theme, multi-shell profiles, Ctrl+Shift keybindings for tabs/panes) and appends a WezTerm bell-notification block to `$PROFILE` (fires a Windows toast + tab flash when a command takes ≥ 10 seconds).
```

- [ ] **Step 2: Update `### 7-context-menu-terminal-install.bat`**

Find:
```
Enables the classic Windows context menu (always shows full menu instead of Windows 11's simplified version) and adds "Open in Terminal as Administrator", "Open in PowerShell as Administrator", and "Open Git Bash here as Administrator" to the context menu for directories, directory backgrounds, and drives.
```
Replace with:
```
Enables the classic Windows context menu (always shows full menu instead of Windows 11's simplified version) and adds "Open in Terminal as Administrator", "Open in PowerShell as Administrator", "Open Git Bash here as Administrator", and "Open in WezTerm as Administrator" to the context menu for directories, directory backgrounds, and drives.
```

- [ ] **Step 3: Update `### 10-setup-exclusions.bat` exclusions list**

Find:
```
**Exclusions added:** XIVLauncher/Dalamud (`%APPDATA%\XIVLauncher`), FINAL FANTASY XIV game folder
```
Replace with:
```
**Exclusions added:** XIVLauncher/Dalamud (`%APPDATA%\XIVLauncher`), FINAL FANTASY XIV game folder, WezTerm (`%LOCALAPPDATA%\Programs\WezTerm`)
```

- [ ] **Step 4: Add a new WezTerm configuration section after the `### 10-setup-exclusions.bat` section**

Insert after the `### 10-setup-exclusions.bat` block and before `### 11-setup-win11debloat.bat`:

```markdown
### WezTerm configuration

WezTerm is installed by `2-setup-windows.bat`. Its config lives at `%USERPROFILE%\.wezterm.lua` and is deployed by the same script (only if the file doesn't already exist).

**Profiles available** (launch menu via `Ctrl+Shift+L` or right-click the `+` button):
- PowerShell 7 (default)
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
```

- [ ] **Step 5: Verify CLAUDE.md contains all new sections**

```powershell
$c = Get-Content "CLAUDE.md" -Raw
$checks = @('WezTerm', 'PowerShell 7', 'JetBrainsMono', 'OpenWezTermAdmin', 'LOCALAPPDATA.*Programs.*WezTerm', 'WezTerm configuration')
foreach ($pat in $checks) {
    $hit = $c -match $pat
    Write-Host ("$pat : " + $(if ($hit) { "OK" } else { "MISSING" })) -ForegroundColor $(if ($hit) { "Green" } else { "Red" })
}
```
Expected: all six lines print `OK`.

- [ ] **Step 6: Commit**

```
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for WezTerm installation and config"
```

---

### Task 8: Final verification and summary commit

- [ ] **Step 1: Check all five files were modified**

```powershell
git diff --name-only HEAD~5 HEAD
```
Expected output includes all five files:
```
2-setup-windows.bat
7-context-menu-terminal-install.bat
CLAUDE.md
10-setup-exclusions.bat
uninstall/context-menu-terminal.bat
```

- [ ] **Step 2: Spot-check `2-setup-windows.bat` for the four new blocks**

```powershell
$bat = Get-Content "2-setup-windows.bat" -Raw
$markers = @(
    'nerd-fonts-jetbrainsmono',
    'Microsoft.PowerShell',
    'wez.wezterm',
    '\.wezterm\.lua',
    'WezTerm bell notification'
)
foreach ($m in $markers) {
    $hit = $bat -match $m
    Write-Host ("$m : " + $(if ($hit) { "OK" } else { "MISSING" })) -ForegroundColor $(if ($hit) { "Green" } else { "Red" })
}
```
Expected: all five print `OK`.

- [ ] **Step 3: Spot-check context menu and uninstall symmetry**

```powershell
$install   = (Get-Content "7-context-menu-terminal-install.bat" -Raw) -match 'OpenWezTermAdmin'
$uninstall = (Get-Content "uninstall\context-menu-terminal.bat" -Raw) -match 'OpenWezTermAdmin'
Write-Host "Install script has WezTerm: $install"
Write-Host "Uninstall script has WezTerm: $uninstall"
```
Expected: both `True`.

- [ ] **Step 4: Push to remote (optional — confirm with user first)**

```
git push
```
