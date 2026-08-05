#Requires -Modules Pester

$ErrorActionPreference = 'Stop'
$IsCI = $env:PCSETUP_CI -eq '1'

BeforeAll {
    function Test-WingetPackageInstalled {
        param(
            [Parameter(Mandatory)]
            [string]$Id
        )

        $output = winget list --id $Id -e --accept-source-agreements 2>&1 | Out-String
        return ($LASTEXITCODE -eq 0 -and $output -match [regex]::Escape($Id))
    }

    function Test-ScoopPackageInstalled {
        param(
            [Parameter(Mandatory)]
            [string]$Package
        )

        if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) { return $false }
        # Deliberately not "scoop list": a failed install stays listed forever with an empty
        # Version and Info='Install failed', so matching that text reports a broken app as
        # present. "scoop prefix" resolves the 'current' junction, which a failed install lacks.
        $prefix = & scoop prefix $Package 2>$null 6>$null
        return ($LASTEXITCODE -eq 0 -and $prefix -and (Test-Path $prefix))
    }

    function Get-CloudflaredPublicRoutes {
        $script = Get-Content (Join-Path $PSScriptRoot '..\cloudflared\verify-public-routes.mjs') -Raw
        $matches = [regex]::Matches($script, "\['([^']+)',\s*'([^']+)'\]")
        foreach ($match in $matches) {
            [pscustomobject]@{
                Hostname = $match.Groups[1].Value
                Url      = $match.Groups[2].Value
            }
        }
    }
}

# -----------------------------
# 0 - init-prereqs
# -----------------------------
Describe "0-init-prereqs" {
    It "script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\0-init-prereqs.bat") | Should -BeTrue
    }
    It "Scoop installed" {
        (scoop --version 2>&1) | Should -Match '\S+'
    }
    It "Chocolatey installed" {
        (choco --version 2>&1) | Should -Match '\d+\.\d+'
    }
    It "Git installed" {
        (git --version 2>&1) | Should -Match 'git version'
    }
    It "Git binary exists" {
        ((Get-Command git -ErrorAction SilentlyContinue).Source) | Should -Not -BeNullOrEmpty
    }
    It "GitHub CLI installed" {
        (gh --version 2>&1 | Out-String) | Should -Match 'gh version'
    }
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
    It "initialization owns WSL prerequisites for console routes" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\sources\init-prereqs.ps1") -Raw
        $script | Should -Match 'Enable-WslPrerequisites'
        $script | Should -Match 'Microsoft-Windows-Subsystem-Linux'
        $script | Should -Match 'VirtualMachinePlatform'
        $script | Should -Match 'HypervisorPlatform'
        $script | Should -Match 'Microsoft-Hyper-V-All'
        $script | Should -Match 'Ubuntu-24\.04'
        $script | Should -Match 'Microsoft\.WSL'
        $script | Should -Match 'Canonical\.Ubuntu\.2404'
        $script | Should -Match 'ubuntu2404\.exe'
        $script | Should -Match "install', '--root"
        $script | Should -Match 'hypervisorlaunchtype auto'
        $script | Should -Match "--install', '--no-distribution"
        $script | Should -Match "--install'\)"
    }
    It ".NET 6 desktop runtime installed" -Skip:($IsCI) {
        (dotnet --list-runtimes 2>&1 | Out-String) | Should -Match 'Microsoft\.WindowsDesktop\.App 6\.'
    }
    It ".NET 8 desktop runtime installed" -Skip:($IsCI) {
        (dotnet --list-runtimes 2>&1 | Out-String) | Should -Match 'Microsoft\.WindowsDesktop\.App 8\.'
    }
    It ".NET 9 desktop runtime installed" -Skip:($IsCI) {
        (dotnet --list-runtimes 2>&1 | Out-String) | Should -Match 'Microsoft\.WindowsDesktop\.App 9\.'
    }
}

# -----------------------------
# 1 - delete-node-modules
# -----------------------------
Describe "1-delete-node-modules" {
    It "script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\1-delete-node-modules.bat") | Should -BeTrue
    }
}

# -----------------------------
# 2 - setup-windows
# -----------------------------
Describe "2-setup-windows" {
    It "Python installed" {
        (python --version 2>&1) | Should -Match 'Python \d+\.\d+'
    }
    It "7-Zip installed" {
        (Get-Command 7z -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "Notepad++ installed" {
        (Get-Command notepad++ -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "PuTTY installed" {
        (Get-Command putty -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "VS Code installed" {
        (Get-Command code -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "cloudflared installed (MSI)" {
        (Get-Command cloudflared -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "cloudflared runs" {
        (cloudflared --version 2>&1) | Should -Match 'cloudflared version'
    }
    # GUI/winget-only — skip in CI containers
    # These are Scoop apps now. The old assertions hardcoded the Chocolatey-era
    # 'C:\Program Files\...' paths, so they stayed red no matter what the setup script did -
    # which is why VLC being genuinely uninstalled went unnoticed.
    It "WinRAR installed" -Skip:($IsCI) {
        $installed = (Test-ScoopPackageInstalled -Package 'winrar') -or
            (Test-Path 'C:\Program Files\WinRAR\WinRAR.exe')
        [bool]$installed | Should -BeTrue
    }
    It "VLC installed" -Skip:($IsCI) {
        $installed = (Test-ScoopPackageInstalled -Package 'vlc') -or
            (Test-Path 'C:\Program Files\VideoLAN\VLC\vlc.exe')
        [bool]$installed | Should -BeTrue
    }
    It "Firefox installed" -Skip:($IsCI) {
        $installed = (Get-Command firefox -ErrorAction SilentlyContinue) -or
            (Test-Path "$env:ProgramFiles\Mozilla Firefox\firefox.exe") -or
            (Test-Path "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe") -or
            (Test-WingetPackageInstalled -Id 'Mozilla.Firefox')
        [bool]$installed | Should -BeTrue
    }
    It "WinSCP installed" -Skip:($IsCI) {
        (Get-Command winscp -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "EarTrumpet installed" -Skip:($IsCI) {
        (Get-Command EarTrumpet -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "Sourcetree installed" -Skip:($IsCI) {
        $installed = (Get-Command SourceTree -ErrorAction SilentlyContinue) -or
            (Test-Path "$env:LOCALAPPDATA\SourceTree\SourceTree.exe") -or
            (Test-Path "$env:ProgramFiles\Atlassian\Sourcetree\SourceTree.exe") -or
            (Test-WingetPackageInstalled -Id 'Atlassian.Sourcetree')
        [bool]$installed | Should -BeTrue
    }
    It "GitHub Desktop installed" -Skip:($IsCI) {
        $installed = (Get-Command GitHubDesktop -ErrorAction SilentlyContinue) -or (Test-Path "$env:LOCALAPPDATA\GitHubDesktop\GitHubDesktop.exe")
        $installed | Should -BeTrue
    }
    It "ProtonVPN installed" -Skip:($IsCI) {
        $installed = (Get-Command protonvpn -ErrorAction SilentlyContinue) -or
            (Test-Path "$env:ProgramFiles\Proton\VPN\ProtonVPN.exe") -or
            (Test-Path "$env:ProgramFiles\Proton\VPN\Proton VPN.exe") -or
            (Test-WingetPackageInstalled -Id 'Proton.ProtonVPN')
        [bool]$installed | Should -BeTrue
    }
    It "AdGuard installed" -Skip:($IsCI) {
        $installed = (Get-Command Adguard -ErrorAction SilentlyContinue) -or
            (Get-Command AdGuard -ErrorAction SilentlyContinue) -or
            (Test-Path "$env:ProgramFiles\Adguard\Adguard.exe") -or
            (Test-Path "$env:ProgramFiles\AdGuard\AdGuard.exe") -or
            (Test-WingetPackageInstalled -Id 'AdGuard.AdGuard')
        [bool]$installed | Should -BeTrue
    }
    It "Streamlabs OBS installed" -Skip:($IsCI) {
        $installed = (Test-ScoopPackageInstalled -Package 'streamlabs-obs') -or
            (Get-Command streamlabs-obs -ErrorAction SilentlyContinue) -or
            (Test-Path "$env:ProgramFiles\Streamlabs OBS\Streamlabs OBS.exe") -or
            (Test-Path "$env:ProgramFiles\Streamlabs\Streamlabs Desktop\Streamlabs Desktop.exe") -or
            (Test-WingetPackageInstalled -Id 'Streamlabs.Streamlabs')
        [bool]$installed | Should -BeTrue
    }
    It "PowerShell 7 installed" -Skip:($IsCI) {
        $installed = (Get-Command pwsh -ErrorAction SilentlyContinue) -or
            (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe') -or
            (Test-WingetPackageInstalled -Id 'Microsoft.PowerShell')
        [bool]$installed | Should -BeTrue
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
        $installed = (Get-Command steam -ErrorAction SilentlyContinue) -or (Test-Path "${env:ProgramFiles(x86)}\Steam\steam.exe")
        $installed | Should -BeTrue
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
        (Get-Item -LiteralPath $key -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
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
    It "runs RemoveWindowsAI unattended with all options" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\99-remove-windows-ai.bat") -Raw
        $script | Should -Match 'RemoveWindowsAi\.ps1'
        $script | Should -Match '-nonInteractive'
        $script | Should -Match '-AllOptions'
        $script | Should -Match '-backupMode'
        $script | Should -Match '-EnableLogging'
        $script | Should -Match 'powershell\.exe'
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
    It "single full installer entrypoint exists" {
        Test-Path (Join-Path $PSScriptRoot "..\cloudflared\install-all.bat") | Should -BeTrue
        Test-Path (Join-Path $PSScriptRoot "..\cloudflared\install-all.ps1") | Should -BeTrue
    }

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
    }

    It "console verifier uses Access-aware public route wrapper" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\verify-console.ps1") -Raw
        $script | Should -Match 'verify-public-routes\.ps1'
        $script | Should -Match 'powershell -NoProfile -ExecutionPolicy Bypass -File \$scriptPath -ReportDir \$ReportDir'
        $script | Should -Not -Match '& node \$scriptPath \$ReportDir'
    }

    It "console verifier checks local code-server folder switching" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\verify-console.ps1") -Raw
        $script | Should -Match 'code-server folder switch PCSetup'
        $script | Should -Match 'http://127\.0\.0\.1:8080/\?folder=/mnt/z/Users/Heiner/Documents/PCSetup'
    }

    It "WSL console setup installs Node 22 and repairs ungit" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\setup-console-wsl.sh") -Raw
        $script | Should -Match 'https://deb\.nodesource\.com/setup_22\.x'
        $script | Should -Match 'NODE_MAJOR'
        $script | Should -Match 'validate_ungit'
        $script | Should -Match 'npm uninstall -g ungit'
        $script | Should -Match 'npm install -g ungit@1\.5\.30'
        $script | Should -Match 'Ungit started'
    }

    It "post-format recovery exits incomplete when WSL blocks console setup" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\post-format-recovery.ps1") -Raw
        $script | Should -Match 'Ensure-WslPrerequisites'
        $script | Should -Match 'Complete-WithConsoleBlocked'
        $script | Should -Match 'exit 2'
        $script | Should -Match 'Public console routes will keep failing'
        $script | Should -Match 'Microsoft\.WSL'
        $script | Should -Match 'Canonical\.Ubuntu\.2404'
        $script | Should -Match 'ubuntu2404\.exe'
        $script | Should -Match "install', '--root"
        $script | Should -Match 'HypervisorPlatform'
        $script | Should -Match 'Microsoft-Hyper-V-All'
        $script | Should -Match "--install', '--no-distribution"
        $script | Should -Match "--install'\)"
        $script | Should -Not -Match 'setup-console-fallback\.ps1'
        $script | Should -Not -Match 'Fallback public routes are online'
    }

    It "install-all gates completion on console stack readiness" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\install-all.ps1") -Raw
        $script | Should -Match 'Assert-ConsoleStackReady'
        $script | Should -Match 'Test-ConsoleStackReady'
        $script | Should -Match 'AllowIncompleteConsole'
        $script | Should -Not -Match 'Test-ConsoleFallbackReady'
        $script | Should -Not -Match 'ConsoleFallbackActive'
        $script | Should -Match 'Ensure-WslInstallables'
        $script | Should -Match 'foreach \(\$scope in ''CurrentUser'', ''LocalMachine''\)'
        $script | Should -Match 'Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope \$scope -Force -ErrorAction Stop'
        $script | Should -Match 'Get-ExecutionPolicy -Scope \$scope'
        $script | Should -Match 'process-scope override'
        $script | Should -Match 'Microsoft\.WSL'
        $script | Should -Match 'Canonical\.Ubuntu\.2404'
        $script | Should -Match 'ubuntu2404\.exe'
        $script | Should -Match "install', '--root"
        $script | Should -Match 'HypervisorPlatform'
        $script | Should -Match 'Microsoft-Hyper-V-All'
        $script | Should -Match 'hypervisorlaunchtype auto'
        $script | Should -Match 'dev-config\.yml'
        $script | Should -Match '7687'
        $script.IndexOf('Assert-ConsoleStackReady') | Should -BeLessThan $script.IndexOf('Cloudflare full install complete')
    }

    It "public verifier rejects console fallback placeholders" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\verify-public-routes.mjs") -Raw
        $script | Should -Match 'looksLikeFallbackPage'
        $script | Should -Match 'placeholder fallback page'
        $script | Should -Match 'Route online'
        $script | Should -Match 'WSL setup is pending'
    }

    It "console scripts use official cloudflared MSI path" {
        $setupScript = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\setup-console-windows.ps1") -Raw
        $startScript = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\start-console.ps1") -Raw
        $setupScript | Should -Match 'C:\\Program Files \(x86\)\\cloudflared\\cloudflared\.exe'
        $startScript | Should -Match 'C:\\Program Files \(x86\)\\cloudflared\\cloudflared\.exe'
        $setupScript | Should -Not -Match 'chocolatey\\lib\\cloudflared'
        $startScript | Should -Not -Match 'chocolatey\\lib\\cloudflared'
    }

    It "Windows TCP relay connects directly to WSL IP for code-server stability" {
        $relayScript = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\tcp-relay.js") -Raw
        $startScript = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\start-console.ps1") -Raw
        $relayScript | Should -Match 'target-host'
        $relayScript | Should -Match 'net\.connect'
        $relayScript | Should -Not -Match ([regex]::Escape("spawn('wsl'"))
        $startScript | Should -Match '--target-host=\$wslIp'
    }

    It "public route verifier bootstraps pnpm and Chromium" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\verify-public-routes.ps1") -Raw
        $script | Should -Match 'Ensure-Pnpm'
        $script | Should -Match 'npm\.cmd install -g pnpm'
        $script | Should -Match 'pnpm install'
        $script | Should -Match "PNPM_CONFIG_CONFIRM_MODULES_PURGE = 'false'"
        $script | Should -Match "\$env:CI = 'true'"
        $script | Should -Match 'playwright install chromium'
    }

    It "public route verifier temporarily disables Access during checks" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\verify-public-routes.ps1") -Raw
        $script | Should -Match 'New-CloudflareEveryoneBypassPolicy'
        $script | Should -Match 'Remove-CloudflareAccessPolicy'
        $script | Should -Match 'Temporary public route verifier bypass'
        $script | Should -Match 'Start-Sleep -Seconds 60'
        $script | Should -Match 'finally'
    }

    It "public route verifier rejects Cloudflare Access login pages" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\verify-public-routes.mjs") -Raw
        $script | Should -Match 'isCloudflareAccessLoginUrl'
        $script | Should -Match 'hitAccessLogin'
        $script | Should -Match 'Cloudflare Access login page'
    }

    It "public route verifier exercises code-server folder switching" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\cloudflared\verify-public-routes.mjs") -Raw
        $script | Should -Match 'codeFolderChecks'
        $script | Should -Match 'code\.ffxivbe\.org folder switch PCSetup'
        $script | Should -Match 'folder=/mnt/z/Users/Heiner/Documents/PCSetup'
        $script | Should -Match 'failOnSubresourceErrors'
        $script | Should -Match 'subresource 5xx'
        $script | Should -Match 'expected folder content missing'
        $script | Should -Match "name === 'code\.ffxivbe\.org' && lastResult\.Passed"
    }

    It "public installable endpoints pass full verifier" -Skip:($IsCI) {
        $routes = @(Get-CloudflaredPublicRoutes)
        $routes.Count | Should -BeGreaterThan 0

        $reportDir = Join-Path $env:TEMP ("pcsetup-public-routes-" + [Guid]::NewGuid().ToString('N'))
        $verifier = Join-Path $PSScriptRoot "..\cloudflared\verify-public-routes.ps1"
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $verifier -ReportDir $reportDir 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $latestJson = Join-Path $reportDir 'public-routes-latest.json'
        if (Test-Path $latestJson) {
            $result = Get-Content $latestJson -Raw | ConvertFrom-Json
            $failures = @($result.Results | Where-Object { -not $_.Passed } | ForEach-Object {
                '{0}: {1}' -f $_.Name, $_.Detail
            })
            @($failures) | Should -BeNullOrEmpty
        }

        $output | Should -Not -Match 'Cloudflare Access login page'
        $output | Should -Not -Match 'Error\s*1103|cloudflare tunnel error|bad gateway|gateway timeout|host error'
        $exitCode | Should -Be 0
    }
}
