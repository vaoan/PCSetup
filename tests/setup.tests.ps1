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
    It "turns dark mode on first, before any package manager work" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\sources\init-prereqs.ps1") -Raw
        $script | Should -Match 'function Set-DarkMode'
        # Applies the shipped theme (instant, same as double-clicking it) and writes the two
        # Personalize values the locked Settings page would have written.
        $script | Should -Match 'Resources\\Themes\\dark\.theme'
        $script | Should -Match 'AppsUseLightTheme'
        $script | Should -Match 'SystemUsesLightTheme'
        $script | Should -Match 'ImmersiveColorSet'
        # It must run before the git bootstrap so the desktop is dark while the rest installs.
        $script.IndexOf('Set-DarkMode') | Should -BeLessThan $script.IndexOf("Install-BootstrapTool -Name 'git'")
        # Server Core has no theme engine or desktop session; the step skips there.
        $script | Should -Match "PCSETUP_CI -eq '1'\) \{[^}]*skipping dark mode"
    }
    It "DISM feature enables run behind the shared live status line and are verified" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\sources\init-prereqs.ps1") -Raw
        $helper = Get-Content (Join-Path $PSScriptRoot "..\sources\status-line.ps1") -Raw
        # The helper is shared with the generated scripts of 2/3/6, so it lives in sources\
        # (already on remote-call.ps1's allowlist) and step 0 dot-sources it.
        $script | Should -Match "\. \(Join-Path \`$PSScriptRoot 'status-line\.ps1'\)"
        $script | Should -Not -Match 'function Invoke-CommandWithStatus'
        $helper | Should -Match 'function Invoke-CommandWithStatus'
        $script | Should -Match 'function Enable-WindowsFeature'
        $script | Should -Match "Enable-WindowsFeature -FeatureName 'NetFx3'"
        $script | Should -Match "-WatchProcess @\('TiWorker', 'TrustedInstaller'\)"
        # The download half of a DISM enable runs in svchost-hosted services; they are resolved
        # to PIDs through Win32_Service so the CPU figure moves during that phase too.
        $script | Should -Match "-WatchService @\('wuauserv', 'DoSvc', 'BITS', 'TrustedInstaller'\)"
        $helper | Should -Match 'Win32_Service'
        # No bare dism call may remain: it draws its own bar, which cannot tell "downloading
        # from Windows Update" from "hung", and nothing verified the feature afterwards.
        $script | Should -Not -Match '& dism\.exe'
        # The silent capture wrapper (wsl --install, distro registration) goes through the
        # status line too, and no Start-Process -Wait is left in step 0.
        $script | Should -Match 'function Invoke-ProcessCapture[\s\S]*Invoke-CommandWithStatus -Label'
        $code = (($script -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $code | Should -Not -Match 'Start-Process[^\n]*-Wait'
        $helper | Should -Match 'RedirectStandardOutput\s*=\s*\$stdout'
        # Without touching .Handle, .ExitCode is $null once the process has exited (5.1 quirk),
        # and DISM's 3010 "reboot required" would be lost.
        $helper | Should -Match '\$null = \$proc\.Handle'
        # The signals that move while DISM's own percentage sits still.
        $helper | Should -Match 'GetAllNetworkInterfaces'
        $helper | Should -Match 'TotalProcessorTime'
    }
    It "status line runs a command to completion with exit code, output and empty args dropped" {
        . (Join-Path $PSScriptRoot "..\sources\status-line.ps1")
        $fake = Join-Path $env:TEMP "pcsetup-test-fake-$([guid]::NewGuid().ToString('N')).ps1"
        Set-Content $fake -Value @'
foreach ($p in 5, 37.8, 100) { [Console]::Out.Write("`r[=== $p% ===] "); Start-Sleep -Milliseconds 400 }
[Console]::Out.WriteLine()
'The operation completed successfully.'
[Console]::Error.WriteLine('warning on stderr')
exit 7
'@
        try {
            # An empty element in -ArgumentList used to be a Start-Process binding error; a caller
            # that builds arguments from variables can hand one over.
            $r = Invoke-CommandWithStatus -Label 'Fake install' -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '', '-ExecutionPolicy', 'Bypass', '-File', $fake) -WatchProcess @('powershell') -WatchService @('Dnscache', 'no-such-service')
            $r.ExitCode | Should -Be 7
            Get-ProgressPercent $r.Output | Should -Be 100
            $r.Output | Should -Match 'completed successfully'
            $r.Error | Should -Match 'warning on stderr'
            $r.Elapsed.TotalSeconds | Should -BeGreaterThan 1
        }
        finally { Remove-Item $fake -Force -ErrorAction SilentlyContinue }
    }
    It "status helpers parse DISM's redirected output and dism.log" {
        . (Join-Path $PSScriptRoot "..\sources\status-line.ps1")
        # Captured from `dism /Online /Enable-Feature /FeatureName:NetFx3` with stdout redirected:
        # the bar keeps coming, one CR-prefixed line per refresh.
        $dism = "Enabling feature(s)`r`n`r[           0.1%           ] `r`n`r[=====   35.0%       ] `r`n`r[=========70.5%===   ] `r`n"
        Get-ProgressPercent $dism | Should -Be 70.5
        Get-ProgressPercent "Deployment Image Servicing and Management tool`r`nVersion: 10.0.26100" | Should -BeNullOrEmpty
        Get-ProgressPercent '' | Should -BeNullOrEmpty

        # Real dism.log tail: CSI noise, PID/TID and "- CClass::Method" suffixes, and the bare
        # "DISM.EXE:" footer lines that must be skipped in favour of the last real message.
        $log = Join-Path $env:TEMP "pcsetup-test-dism-$([guid]::NewGuid().ToString('N')).log"
        @(
            "2026-09-18 02:57:08, Info                  DISM   DISM Package Manager: PID=33208 TID=42832 Loaded servicing stack for online use. - CDISMPackageManager::CreateCbsSession",
            "2026-09-18 02:57:08, Info                  CSI    00000001 Shim considered [l:123]'\??\C:\WINDOWS\WinSxS\amd64_microsoft-windows-servicingstack'",
            "2026-09-18 02:57:08, Info                  DISM   DISM.EXE: Image session has been closed. Reboot required=no.",
            "2026-09-18 02:57:08, Info                  DISM   DISM.EXE: "
        ) | Set-Content $log
        try {
            Get-DismLogMessage $log | Should -Be 'DISM.EXE: Image session has been closed. Reboot required=no.'
            Set-Content $log "2026-09-18 02:57:08, Info                  DISM   DISM Package Manager: PID=1 TID=2 Finalizing CBS core. - CDISMPackageManager::Finalize"
            Get-DismLogMessage $log | Should -Be 'DISM Package Manager: Finalizing CBS core.'
            Get-DismLogMessage (Join-Path $env:TEMP 'does-not-exist-pcsetup.log') | Should -Be ''
        }
        finally { Remove-Item $log -Force -ErrorAction SilentlyContinue }
    }
    It "dark mode is on for the current user" -Skip:($IsCI) {
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        (Get-ItemProperty $k).AppsUseLightTheme   | Should -Be 0
        (Get-ItemProperty $k).SystemUsesLightTheme | Should -Be 0
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
    It "direct installers run behind the shared status line, never a silent Start-Process -Wait" {
        $bat = Get-Content (Join-Path $PSScriptRoot "..\2-setup-windows.bat") -Raw
        $bat | Should -Match '>>"%SCRIPT%" echo \. "%~dp0sources\\status-line\.ps1"'
        $bat | Should -Not -Match 'Start-Process[^\r\n]*-Wait'
        $bat | Should -Match 'Invoke-CommandWithStatus -Label "Installing \$name" -FilePath \$tmp'
        $bat | Should -Match 'Invoke-CommandWithStatus -Label "Installing Dokan \(msi\)"[^\r\n]*-WatchProcess msiexec -WatchService msiserver'
        $bat | Should -Match 'Invoke-CommandWithStatus -Label "Installing IceDrive"'
    }
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
    It "Patch My PC declared in the winget table" {
        $script = Get-Content (Join-Path $PSScriptRoot "..\2-setup-windows.bat") -Raw
        $script | Should -Match "Id = 'PatchMyPC\.PatchMyPC'"
    }
    It "Patch My PC installed" -Skip:($IsCI) {
        $installed = (Test-Path "$env:ProgramFiles\Patch My PC\Patch My PC Home Updater\PatchMyPC-HomeUpdater.exe") -or
            (Test-WingetPackageInstalled -Id 'PatchMyPC.PatchMyPC')
        [bool]$installed | Should -BeTrue
    }
}

# ─────────────────────────────────────────────
# 3 — setup-node
# ─────────────────────────────────────────────
Describe "3-setup-node" {
    It "npm installs run behind the shared status line and show their output tail on failure" {
        $bat = Get-Content (Join-Path $PSScriptRoot "..\3-setup-node.bat") -Raw
        $bat | Should -Match '>>"%SCRIPT%" echo \. "%~dp0sources\\status-line\.ps1"'
        $bat | Should -Not -Match 'Start-Process[^\r\n]*-Wait'
        $bat | Should -Match '\$proc = Invoke-CommandWithStatus -Label "Installing \$displayName \(npm\)"'
        # The output is captured now, so a failed attempt must still show what npm said.
        $bat | Should -Match '\$tail = @\(\(\$proc\.Output \+ \$proc\.Error\)'
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
    BeforeAll {
        $script:moveBat   = Join-Path $PSScriptRoot '..\5-move-profile-folders.bat'
        $script:generated = Join-Path $env:TEMP 'temp-move-profile.ps1'

        # Runs a COPY of the script from a temp folder with its own profile-folders.config, under
        # PCSETUP_GENERATE_ONLY so nothing is relocated on the test machine. PCSETUP_CI is cleared
        # for the child: its CI guard exits before the drive check and would mask what is under test.
        function Invoke-MoveProfileGenerateOnly {
            param([Parameter(Mandatory)][string]$TargetDrive)
            $dir = Join-Path $env:TEMP ('pcsetup-move-profile-test-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $bat = Join-Path $dir '5-move-profile-folders.bat'
            Copy-Item -LiteralPath $script:moveBat -Destination $bat
            Set-Content -LiteralPath (Join-Path $dir 'profile-folders.config') -Encoding ASCII -Value @(
                "TARGET_DRIVE=$TargetDrive", 'TARGET_PROFILE_FOLDER=PCSetupTest', 'MOVE_FILES=0')
            Remove-Item -LiteralPath $script:generated -Force -ErrorAction SilentlyContinue
            $savedCI = $env:PCSETUP_CI
            $env:PCSETUP_GENERATE_ONLY = '1'
            $env:PCSETUP_CI = $null
            try {
                $output = & cmd.exe /c "`"$bat`"" 2>&1 | Out-String
                $exit = $LASTEXITCODE
            }
            finally {
                $env:PCSETUP_GENERATE_ONLY = $null
                $env:PCSETUP_CI = $savedCI
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
            [pscustomobject]@{
                Output    = $output
                ExitCode  = $exit
                Generated = (Test-Path -LiteralPath $script:generated)
            }
        }

        # A drive letter nothing on this machine answers to. DriveInfo lists mapped and
        # removable drives too, which Get-PSDrive can miss.
        $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
        $script:absentDrive = [string]([char[]]'DEFGHIJKLMNOPQRSTUVWXY' |
            Where-Object { $used -notcontains [string]$_ -and -not (Test-Path -LiteralPath "$($_):\") } |
            Select-Object -First 1)
    }

    It "Desktop relocated to Z drive" -Skip:($IsCI) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $desktop | Should -Match '^Z:\\'
    }

    It "skips with exit 0 and touches nothing when the target drive is absent" {
        $script:absentDrive | Should -Not -BeNullOrEmpty
        $r = Invoke-MoveProfileGenerateOnly -TargetDrive "$($script:absentDrive):"
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'SKIP'
        $r.Output | Should -Match ([regex]::Escape("$($script:absentDrive):"))
        $r.Generated | Should -BeFalse -Because 'an absent drive must stop the script before the relocation script is even written'
    }

    It "generates a parseable relocation script when the target drive exists" {
        $r = Invoke-MoveProfileGenerateOnly -TargetDrive $env:SystemDrive
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match 'SKIP'
        $r.Generated | Should -BeTrue
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:generated, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It "aborts before the registry step when a target folder could not be created" {
        # The failure this guards: with the drive present but unwritable, every folder creation
        # failed and the registry was STILL repointed at the missing paths before exiting 1.
        $r = Invoke-MoveProfileGenerateOnly -TargetDrive $env:SystemDrive
        $r.Generated | Should -BeTrue
        $text = Get-Content -LiteralPath $script:generated -Raw
        $create = $text.IndexOf('Creating target folders')
        $reg    = $text.IndexOf('Updating registry')
        $guard  = $text.IndexOf('registry left untouched')
        $create | Should -BeGreaterThan -1
        $reg    | Should -BeGreaterThan $create
        $guard  | Should -BeGreaterThan $create -Because 'the guard must come after the folder creation loop'
        $guard  | Should -BeLessThan $reg -Because 'the guard must run before the registry is written'
        $text.Substring($guard, $reg - $guard) | Should -Match '\bexit 1\b'
    }
}

# ─────────────────────────────────────────────
# 6 — setup-games (skipped in CI)
# ─────────────────────────────────────────────
Describe "6-setup-games" {
    It "TexTools and FFLogs installers run behind the shared status line" {
        $bat = Get-Content (Join-Path $PSScriptRoot "..\6-setup-games.bat") -Raw
        $bat | Should -Match '>>"%SCRIPT%" echo \. "%~dp0sources\\status-line\.ps1"'
        $bat | Should -Not -Match 'Start-Process[^\r\n]*-Wait'
        $bat | Should -Match 'Invoke-CommandWithStatus -Label "Installing TexTools"'
        $bat | Should -Match 'Invoke-CommandWithStatus -Label "Installing FFLogs Uploader"'
    }
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

# -----------------------------
# update-all (utility, no number prefix)
# -----------------------------
Describe "update-all" {
    BeforeAll {
        $script:updateAllBat = Join-Path $PSScriptRoot "..\update-all.bat"
        $script:updateAllText = if (Test-Path $script:updateAllBat) { Get-Content $script:updateAllBat -Raw } else { '' }
    }
    It "script exists" {
        Test-Path $script:updateAllBat | Should -BeTrue
    }
    It "clears PSModulePath before spawning Windows PowerShell" {
        $script:updateAllText | Should -Match 'set "PSModulePath="'
    }
    It "puts redirection first on every generated line" {
        # `echo ... 3>>"%SCRIPT%"` eats a trailing standalone digit as a file handle (see 3-setup-node.bat).
        $trailing = ($script:updateAllText -split "`r?`n") | Where-Object { $_ -match '^\s*echo\b.*>>\s*"%SCRIPT%"\s*$' }
        $trailing | Should -BeNullOrEmpty
    }
    It "updates every package manager the setup scripts install with" {
        $script:updateAllText | Should -Match 'scoop update \*'
        $script:updateAllText | Should -Match 'winget upgrade'
        $script:updateAllText | Should -Match 'choco upgrade all'
        $script:updateAllText | Should -Match 'npm\.cmd install -g \$name@latest'
    }
    It "runs Patch My PC silently as the final sweep" {
        $script:updateAllText | Should -Match 'PatchMyPC-HomeUpdater\.exe'
        $script:updateAllText | Should -Match "'/s'"
    }
    It "never upgrades WSL through winget (restarting the VM kills the WSL-hosted console services)" {
        $script:updateAllText | Should -Match "'Microsoft\.WSL'"
    }
    It "generated winget parser reads a captured upgrade table" {
        # The parser is extracted from the GENERATED file, so this exercises what CMD's echo
        # actually wrote. The first version lost its '^' anchors to CMD and returned zero rows
        # while winget itself listed 21 upgrades - which no static check on the .bat could see.
        $generated = Join-Path $env:TEMP 'temp-update-all.ps1'
        Remove-Item $generated -Force -ErrorAction SilentlyContinue
        $env:PCSETUP_GENERATE_ONLY = '1'
        try { & cmd.exe /c "`"$script:updateAllBat`"" | Out-Null } finally { $env:PCSETUP_GENERATE_ONLY = $null }
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($generated, [ref]$tokens, [ref]$errors)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertFrom-WingetTable' }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty
        Invoke-Expression $fn.Extent.Text
        $fixture = @(
            "   -`r   \`r   |`r   /`rName                        Id                          Version      Available    Source",
            "-------------------------------------------------------------------------------------------------",
            "AdGuard                     AdGuard.AdGuard             7.22.5282.0  8.0.5570     winget",
            "Windows Subsystem for Linux Microsoft.WSL               2.7.11.0     2.7.13       winget",
            "Docker Desktop              Docker.DockerDesktop        4.85.0       4.91.0       winget",
            "3 upgrades available.",
            "",
            "The following packages have an upgrade available, but require explicit targeting for upgrade:",
            "Name                        Id                          Version      Available    Source",
            "-------------------------------------------------------------------------------------------------",
            "Something Pinned            Vendor.Pinned               1.0          2.0          winget"
        )
        $rows = ConvertFrom-WingetTable $fixture
        @($rows | ForEach-Object { $_.Id }) | Should -Be @('AdGuard.AdGuard', 'Microsoft.WSL', 'Docker.DockerDesktop')
        @($rows | ForEach-Object { $_.Name })[1] | Should -Be 'Windows Subsystem for Linux'
        (ConvertFrom-WingetTable @('No installed package found matching input criteria.')).Count | Should -Be 0
    }
    It "consumes the outdated lists by variable, never by piping the function directly" {
        # Both helpers return a collection. In Windows PowerShell 5.1 a function's output is
        # unrolled one level, so `Get-WingetOutdated | Where-Object` hands Where-Object the whole
        # ArrayList as ONE object: `$_.Id` then member-enumerates into an array, the skip table
        # never matches, and the failure printed the merged nonsense
        # "Winamp Windows Subsystem for Linux (Winamp.Winamp Microsoft.WSL) still outdated".
        # `Get-ScoopOutdated` has the mirror problem: one outdated app comes back as a bare
        # PSCustomObject whose .Count is empty in 5.1, which printed "Scoop: updated 0 of .".
        $generated = Join-Path $env:TEMP 'temp-update-all.ps1'
        Remove-Item $generated -Force -ErrorAction SilentlyContinue
        $env:PCSETUP_GENERATE_ONLY = '1'
        try { & cmd.exe /c "`"$script:updateAllBat`"" | Out-Null } finally { $env:PCSETUP_GENERATE_ONLY = $null }
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($generated, [ref]$tokens, [ref]$errors)
        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-WingetOutdated', 'Get-ScoopOutdated') }, $true)
        @($calls).Count | Should -BeGreaterThan 2
        foreach ($call in $calls) {
            $pipeline = $call.Parent
            $pipeline.PipelineElements.Count | Should -Be 1 -Because "$($call.Extent.Text) at line $($call.Extent.StartLineNumber) must not feed a pipeline"
            $assignment = $pipeline.Parent
            while ($assignment -and $assignment -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { $assignment = $assignment.Parent }
            $assignment | Should -Not -BeNullOrEmpty -Because "$($call.Extent.Text) at line $($call.Extent.StartLineNumber) must be assigned to a variable first"
            $assignment.Right.Extent.Text | Should -Match '^@\(' -Because "$($call.Extent.Text) at line $($call.Extent.StartLineNumber) must be wrapped in @() so one row still has a Count"
        }
    }
    It "generated winget parser gives one row a Count of 1" {
        $generated = Join-Path $env:TEMP 'temp-update-all.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($generated, [ref]$tokens, [ref]$errors)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertFrom-WingetTable' }, $true) | Select-Object -First 1
        Invoke-Expression $fn.Extent.Text
        $one = @(ConvertFrom-WingetTable @(
            "Name   Id            Version Available    Source",
            "--------------------------------------------------",
            "Winamp Winamp.Winamp 5.92.0  5.92.0.10042 winget",
            "1 upgrades available."
        ))
        $one.Count | Should -Be 1
        $one[0].Id | Should -Be 'Winamp.Winamp'
        $one[0].Name | Should -Be 'Winamp'
    }
    It "generated script parses under Windows PowerShell 5.1" {
        # PCSETUP_GENERATE_ONLY makes the .bat write the PowerShell file and stop, so the real
        # CMD echo/escape processing is exercised without upgrading anything on this machine.
        $generated = Join-Path $env:TEMP 'temp-update-all.ps1'
        Remove-Item $generated -Force -ErrorAction SilentlyContinue
        $env:PCSETUP_GENERATE_ONLY = '1'
        try { & cmd.exe /c "`"$script:updateAllBat`"" | Out-Null } finally { $env:PCSETUP_GENERATE_ONLY = $null }
        Test-Path $generated | Should -BeTrue
        $probe = "`$t=`$null;`$e=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$generated',[ref]`$t,[ref]`$e);if(`$e){`$e|ForEach-Object{`$_.ToString()};exit 1}"
        $out = & powershell.exe -NoProfile -NonInteractive -Command $probe 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
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
