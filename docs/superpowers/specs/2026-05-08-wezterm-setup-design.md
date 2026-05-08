# WezTerm Setup Design

**Date:** 2026-05-08  
**Status:** Approved  
**Goal:** Install and configure WezTerm as the primary developer terminal on Windows, with context menu integration and full restoration support via the existing numbered setup scripts.

---

## Background

The user (frontend developer) needs an iTerm2-equivalent terminal on Windows for use with Claude Code. Key requirements:

- Resize without breaking TUI/rich output from Claude Code
- Visual flash + Windows toast notification when a command finishes
- Multiple shell profiles (PowerShell 7, WSL, Git Bash, CMD) in one app
- Plugin/extension ecosystem
- Full restoration from scratch via the existing `run-all.bat` flow

**Choice: WezTerm** — GPU-accelerated, Lua-configured, purpose-built for stable TUI rendering. Closest to iTerm2 in power and philosophy on Windows.

---

## Architecture

No new numbered script is created. All changes slot into existing scripts to preserve the sequential setup flow. The five affected files are:

| File | What changes |
|---|---|
| `2-setup-windows.bat` | Install WezTerm, PowerShell 7, JetBrainsMono Nerd Font; deploy `.wezterm.lua`; write PowerShell `$PROFILE` for notifications |
| `7-context-menu-terminal-install.bat` | Add WezTerm as-admin context menu entries |
| `uninstall/context-menu-terminal.bat` | Add WezTerm `reg delete` entries |
| `10-setup-exclusions.bat` | Add WezTerm Defender exclusion |
| `CLAUDE.md` | Update docs for scripts 2, 7, 10; add WezTerm config section |

---

## Section 1: Installation (`2-setup-windows.bat`)

### New packages added to the existing winget/choco block

```
winget install Microsoft.PowerShell          # PowerShell 7 (pwsh.exe)
winget install wez.wezterm                   # WezTerm terminal
choco install nerd-fonts-jetbrainsmono -y    # JetBrainsMono Nerd Font (for Claude Code icons)
```

All three use idempotency guards (`if (Get-Command ... -ErrorAction SilentlyContinue)` / `Test-Path`) so re-running the script is safe.

### WezTerm config file: `%USERPROFILE%\.wezterm.lua`

Deployed inline via PowerShell `Set-Content` in the same temp `.ps1` block. Only written if not already present (idempotent). Contents:

```lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Rendering
config.term = 'xterm-256color'
config.scrollback_lines = 10000

-- Font: JetBrainsMono Nerd Font for Claude Code icon rendering
config.font = wezterm.font('JetBrainsMono Nerd Font')
config.font_size = 12.0

-- Appearance: Catppuccin Mocha (dark theme)
config.color_scheme = 'Catppuccin Mocha'
config.window_background_opacity = 0.95
config.text_background_opacity = 1.0
config.window_decorations = 'RESIZE'

-- Visual bell: flashes the tab bar when terminal bell fires (e.g. command done)
config.audible_bell = 'Disabled'
config.visual_bell = {
  fade_in_duration_ms = 75,
  fade_out_duration_ms = 75,
  target = 'CursorColor',
}

-- Profiles
config.default_prog = { 'pwsh.exe', '-NoLogo' }
config.launch_menu = {
  { label = 'PowerShell 7',  args = { 'pwsh.exe', '-NoLogo' } },
  { label = 'PowerShell 5',  args = { 'powershell.exe', '-NoLogo' } },
  { label = 'CMD',           args = { 'cmd.exe' } },
  { label = 'Git Bash',      args = { 'C:\\Program Files\\Git\\bin\\bash.exe', '-i', '-l' } },
  { label = 'WSL',           args = { 'wsl.exe' } },
}

-- Tabs + panes keybindings
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
```

### PowerShell `$PROFILE` for command-done notifications

Appended to `$PROFILE` (created if absent) in the same PS block. Only appended if the marker comment `# WezTerm bell notification` is not already present (idempotent).

**Behavior matches iTerm2:** notification fires only when:
- The command took **≥ 10 seconds**, AND
- The WezTerm window does not currently have focus (avoids spam when you're watching the output)

```powershell
# WezTerm bell notification
$global:_WezPromptTimer = $null
function prompt {
    $lastExit = $LASTEXITCODE
    if ($global:_WezPromptTimer -ne $null) {
        $elapsed = (Get-Date) - $global:_WezPromptTimer
        if ($elapsed.TotalSeconds -ge 10) {
            # Ring terminal bell — WezTerm flashes the tab bar
            [Console]::Write("`a")
            # Windows toast via WinRT (no external module required)
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
```

---

## Section 2: Context Menu (`7-context-menu-terminal-install.bat`)

Three new registry blocks added after the existing Git Bash block, one for each target (Directory Background, Directory, Drive):

- **Key name:** `OpenWezTermAdmin`
- **Label:** `Open in WezTerm as Administrator`
- **Icon:** `%LOCALAPPDATA%\Programs\WezTerm\wezterm-gui.exe`
- **Command:** `powershell -WindowStyle Hidden -Command "Start-Process '%LOCALAPPDATA%\Programs\WezTerm\wezterm-gui.exe' -ArgumentList 'start --cwd \"%V\"' -Verb RunAs"`

---

## Section 3: Uninstall (`uninstall/context-menu-terminal.bat`)

Three new `reg delete` lines added for `OpenWezTermAdmin` under:
- `HKEY_CLASSES_ROOT\Directory\Background\shell\OpenWezTermAdmin`
- `HKEY_CLASSES_ROOT\Directory\shell\OpenWezTermAdmin`
- `HKEY_CLASSES_ROOT\Drive\shell\OpenWezTermAdmin`

---

## Section 4: Defender Exclusion (`10-setup-exclusions.bat`)

```batch
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '$env:LOCALAPPDATA\Programs\WezTerm'"
```

Consistent pattern with XIVLauncher exclusions already in the file. WezTerm's GPU acceleration DLLs can be flagged by Defender; the exclusion prevents false positives from blocking startup.

---

## Section 5: CLAUDE.md Updates

- `### 2-setup-windows.bat` — add `WezTerm, PowerShell 7, JetBrainsMono Nerd Font` to the installed packages list; add a note about `.wezterm.lua` and `$PROFILE` being written
- `### 7-context-menu-terminal-install.bat` — add `"Open in WezTerm as Administrator"` to the listed context menu entries
- `### 10-setup-exclusions.bat` — add WezTerm to the exclusions list
- New section `### WezTerm configuration` — document config location (`%USERPROFILE%\.wezterm.lua`), profiles available, key bindings, and notification behavior

---

## Key Bindings Reference

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Shift+W` | Close tab |
| `Ctrl+Shift+D` | Split pane horizontal |
| `Ctrl+Shift+E` | Split pane vertical |
| `Ctrl+Shift+Arrow` | Navigate between panes |

---

## Idempotency

Every installation step is guarded so re-running `run-all.bat` on an already-configured machine is safe:
- WezTerm/PS7/font: winget/choco skip if already installed
- `.wezterm.lua`: only written if `%USERPROFILE%\.wezterm.lua` does not exist
- `$PROFILE` notification block: only appended if `# WezTerm bell notification` marker is absent

---

## Restoration Flow

On a fresh Windows install, running `run-all.bat` produces a fully configured WezTerm terminal:
1. Script 2 installs WezTerm + PS7 + font + writes config + writes PS profile
2. Script 7 adds all four context menu entries (CMD, PS, Git Bash, **WezTerm**)
3. Script 10 adds Defender exclusion
