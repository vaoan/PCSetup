#Requires -Modules Pester

$ErrorActionPreference = 'Stop'
$IsCI = $env:PCSETUP_CI -eq '1'

# ─────────────────────────────────────────────
# 1 — delete-node-modules
# ─────────────────────────────────────────────
Describe "1-delete-node-modules" {
    It "script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\1-delete-node-modules.bat") | Should -BeTrue
    }
}

# ─────────────────────────────────────────────
# 2 — setup-windows
# ─────────────────────────────────────────────
Describe "2-setup-windows" {
    It "Chocolatey installed" {
        (choco --version 2>&1) | Should -Match '\d+\.\d+'
    }
    It "Git installed" {
        (git --version 2>&1) | Should -Match 'git version'
    }
    It "Git binary exists" {
        Test-Path 'C:\Program Files\Git\bin\git.exe' | Should -BeTrue
    }
    It "Python installed" {
        (python --version 2>&1) | Should -Match 'Python \d+\.\d+'
    }
    It "7-Zip installed" {
        Test-Path 'C:\Program Files\7-Zip\7z.exe' | Should -BeTrue
    }
    It "Notepad++ installed" {
        Test-Path 'C:\Program Files\Notepad++\notepad++.exe' | Should -BeTrue
    }
    It "PuTTY installed" {
        Test-Path 'C:\Program Files\PuTTY\putty.exe' | Should -BeTrue
    }
    It "VS Code installed" {
        Test-Path 'C:\Program Files\Microsoft VS Code\Code.exe' | Should -BeTrue
    }
    It "GitHub CLI installed" {
        (gh --version 2>&1) | Should -Match 'gh version'
    }
    It "cloudflared installed (MSI)" {
        Test-Path 'C:\Program Files (x86)\cloudflared\cloudflared.exe' | Should -BeTrue
    }
    It "cloudflared runs" {
        (& 'C:\Program Files (x86)\cloudflared\cloudflared.exe' --version 2>&1) | Should -Match 'cloudflared version'
    }
    It ".NET 6 desktop runtime installed" -Skip:($IsCI) {
        (dotnet --list-runtimes 2>&1) | Should -Match 'Microsoft\.WindowsDesktop\.App 6\.'
    }
    It ".NET 8 desktop runtime installed" -Skip:($IsCI) {
        (dotnet --list-runtimes 2>&1) | Should -Match 'Microsoft\.WindowsDesktop\.App 8\.'
    }
    It ".NET 9 desktop runtime installed" -Skip:($IsCI) {
        (dotnet --list-runtimes 2>&1) | Should -Match 'Microsoft\.WindowsDesktop\.App 9\.'
    }
    # GUI/winget-only — skip in CI containers
    It "WinRAR installed" -Skip:($IsCI) {
        Test-Path 'C:\Program Files\WinRAR\WinRAR.exe' | Should -BeTrue
    }
    It "VLC installed" -Skip:($IsCI) {
        (choco list --local-only 2>&1) | Should -Match 'vlc'
    }
    It "Firefox installed" -Skip:($IsCI) {
        Test-Path 'C:\Program Files\Mozilla Firefox\firefox.exe' | Should -BeTrue
    }
    It "WinSCP installed" -Skip:($IsCI) {
        (choco list --local-only 2>&1) | Should -Match 'winscp'
    }
    It "EarTrumpet installed" -Skip:($IsCI) {
        (choco list --local-only 2>&1) | Should -Match 'eartrumpet'
    }
    It "Sourcetree installed" -Skip:($IsCI) {
        (choco list --local-only 2>&1) | Should -Match 'sourcetree'
    }
    It "GitHub Desktop installed" -Skip:($IsCI) {
        (choco list --local-only 2>&1) | Should -Match 'github-desktop'
    }
    It "ProtonVPN installed" -Skip:($IsCI) {
        (choco list --local-only 2>&1) | Should -Match 'protonvpn'
    }
    It "Streamlabs OBS installed" -Skip:($IsCI) {
        (choco list --local-only 2>&1) | Should -Match 'streamlabs-obs'
    }
    It "PowerShell 7 installed" -Skip:($IsCI) {
        Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe' | Should -BeTrue
    }
    It "WezTerm installed" -Skip:($IsCI) {
        Test-Path 'C:\Program Files\WezTerm\wezterm-gui.exe' | Should -BeTrue
    }
    It ".wezterm.lua deployed" -Skip:($IsCI) {
        Test-Path "$env:USERPROFILE\.wezterm.lua" | Should -BeTrue
    }
    It "Claude Desktop installed" -Skip:($IsCI) {
        Test-Path "$env:LOCALAPPDATA\AnthropicClaude\claude.exe" | Should -BeTrue
    }
    It "Claude Code installed" -Skip:($IsCI) {
        (Get-Command claude -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────
# 3 — setup-node
# ─────────────────────────────────────────────
Describe "3-setup-node" {
    It "nvm installed" {
        $onPath = (Get-Command nvm -ErrorAction SilentlyContinue) -ne $null
        $atPath = Test-Path "$env:APPDATA\nvm\nvm.exe"
        ($onPath -or $atPath) | Should -BeTrue
    }
    It "Node.js installed" {
        (node --version 2>&1) | Should -Match 'v\d+'
    }
    It "npm installed" {
        (npm --version 2>&1) | Should -Match '\d+\.\d+'
    }
}

# ─────────────────────────────────────────────
# 4 — fix-execution-policy
# ─────────────────────────────────────────────
Describe "4-fix-execution-policy" {
    It "CurrentUser policy is RemoteSigned" {
        (Get-ExecutionPolicy -Scope CurrentUser) | Should -Be 'RemoteSigned'
    }
}

# ─────────────────────────────────────────────
# 5 — move-profile-folders (skipped in CI)
# ─────────────────────────────────────────────
Describe "5-move-profile-folders" {
    It "Desktop relocated to Z drive" -Skip:($IsCI) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $desktop | Should -Match '^Z:\\'
    }
}

# ─────────────────────────────────────────────
# 6 — setup-games (skipped in CI)
# ─────────────────────────────────────────────
Describe "6-setup-games" {
    It "Steam installed" -Skip:($IsCI) {
        (choco list --local-only 2>&1) | Should -Match 'steam'
    }
}

# ─────────────────────────────────────────────
# 7 — context-menu-terminal-install
# ─────────────────────────────────────────────
Describe "7-context-menu-terminal-install" {
    It "classic context menu enabled" {
        $key = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
        (Get-Item $key -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "Open Terminal as Admin entry exists" {
        $key = 'HKLM:\SOFTWARE\Classes\Directory\shell\OpenTerminalAdmin'
        (Get-Item $key -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "Open PowerShell as Admin entry exists" {
        $key = 'HKLM:\SOFTWARE\Classes\Directory\shell\OpenPowerShellAdmin'
        (Get-Item $key -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "Open Git Bash entry exists" {
        $key = 'HKLM:\SOFTWARE\Classes\Directory\shell\OpenGitBashAdmin'
        (Get-Item $key -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "Open WezTerm as Admin entry exists" {
        $key = 'HKLM:\SOFTWARE\Classes\Directory\shell\OpenWezTermAdmin'
        (Get-Item $key -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────
# 8 — fix-steam-icons (no reliable artifact)
# ─────────────────────────────────────────────
Describe "8-fix-steam-icons" {
    It "script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\8-fix-steam-icons.bat") | Should -BeTrue
    }
}

# ─────────────────────────────────────────────
# 9 — context-menu-take-ownership
# ─────────────────────────────────────────────
Describe "9-context-menu-take-ownership" {
    It "long paths enabled" {
        $val = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction SilentlyContinue).LongPathsEnabled
        $val | Should -Be 1
    }
    It "Take Ownership entry exists for files" {
        $key = 'HKLM:\SOFTWARE\Classes\*\shell\TakeOwnership'
        (Get-Item $key -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────
# 10 — setup-exclusions (Defender — skipped in CI)
# ─────────────────────────────────────────────
Describe "10-setup-exclusions" {
    It "XIVLauncher Defender exclusion added" -Skip:($IsCI) {
        (Get-MpPreference).ExclusionPath | Should -Contain "$env:APPDATA\XIVLauncher"
    }
    It "WezTerm Defender exclusion added" -Skip:($IsCI) {
        (Get-MpPreference).ExclusionPath | Should -Contain "$env:PROGRAMFILES\WezTerm"
    }
}

# ─────────────────────────────────────────────
# 11 — setup-win11debloat
# ─────────────────────────────────────────────
Describe "11-setup-win11debloat" {
    It "script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\11-setup-win11debloat.bat") | Should -BeTrue
    }
    It "OneDrive not running" -Skip:($IsCI) {
        $proc = Get-Process OneDrive -ErrorAction SilentlyContinue
        $proc | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────
# 99 — remove-windows-ai
# ─────────────────────────────────────────────
Describe "99-remove-windows-ai" {
    It "script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\99-remove-windows-ai.bat") | Should -BeTrue
    }
}

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# cloudflared scheduled tasks
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Describe "cloudflared scheduled tasks" {
    It "web installer uses boot plus logon triggers" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\install-tunnel.ps1") -Raw
        $script | Should -Match 'New-ScheduledTaskTrigger -AtStartup'
        $script | Should -Match 'New-ScheduledTaskTrigger -AtLogOn -User \$env:USERNAME'
        $script | Should -Match 'MultipleInstances IgnoreNew'
        $script | Should -Match 'wscript\.exe'
        $script | Should -Match 'launcher\.vbs'
    }

    It "ssh installer uses boot plus logon triggers" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\install-ssh-tunnel.ps1") -Raw
        $script | Should -Match 'New-ScheduledTaskTrigger -AtStartup'
        $script | Should -Match 'New-ScheduledTaskTrigger -AtLogOn -User \$env:USERNAME'
        $script | Should -Match 'MultipleInstances IgnoreNew'
        $script | Should -Match 'wscript\.exe'
        $script | Should -Match 'launcher\.vbs'
    }
}

Describe "cloudflared staging recovery" {
    It "clean-install smoke test script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\cloudflared\test-clean-install.ps1") | Should -BeTrue
    }

    It "clean-install smoke test runs uninstall then recovery then full verification" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\test-clean-install.ps1") -Raw
        $script | Should -Match 'sync-secrets\.ps1'
        $script | Should -Match 'uninstall-console\.ps1'
        $script | Should -Match 'uninstall-tunnel\.ps1'
        $script | Should -Match 'uninstall-ssh-tunnel\.ps1'
        $script | Should -Match 'post-format-recovery\.ps1'
        $script | Should -Match 'verify-console\.ps1'
    }

    It "post-format recovery ends with full verification" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\post-format-recovery.ps1") -Raw
        $script | Should -Match 'verify-console\.ps1'
        $script | Should -Not -Match 'verify-public-routes\.ps1'
    }

    It "public route verifier bootstraps pnpm and Chromium" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\verify-public-routes.ps1") -Raw
        $script | Should -Match 'Ensure-Pnpm'
        $script | Should -Match 'npm\.cmd install -g pnpm'
        $script | Should -Match 'pnpm install'
        $script | Should -Match 'playwright install chromium'
    }
}
