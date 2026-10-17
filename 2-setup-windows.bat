@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Self-elevate script if not running as admin
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorLevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

SETLOCAL

:: Server Core has no winget (App Installer is not present and cannot be added), no Appx
:: surface worth speaking of, and no WSL - so the winget table, the direct-download GUI
:: installers and the WSL/Claude Code section cannot run in a container at all. The Scoop
:: table would technically install, but it is ~25 desktop apps and several GB per build.
if "%PCSETUP_CI%"=="1" (
    echo SKIP: CI mode - skipping Windows application setup
    exit /b 0
)

:: Windows PowerShell must not inherit PowerShell 7's PSModulePath. If it does, it finds the
:: Core-only Microsoft.PowerShell.Utility/Security first and refuses to load them - Get-FileHash
:: disappears and every Scoop install then dies with "URL ... is not valid".
set "PSModulePath="

SET SCRIPT=%TEMP%\temp-setup.ps1
if exist "%SCRIPT%" del "%SCRIPT%" >nul

:: Redirection goes FIRST on every line so a trailing standalone digit can never be parsed as a
:: file-handle redirect (that silently ate `$maxAttempts = 3` in 3-setup-node.bat).
>"%SCRIPT%" echo [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
>>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo # One-line live status for long native commands (installers, npm). Shared with
>>"%SCRIPT%" echo # sources\init-prereqs.ps1 - see sources\status-line.ps1.
>>"%SCRIPT%" echo . "%~dp0sources\status-line.ps1"
>>"%SCRIPT%" echo function Add-Failure([string]$name) { if (-not $failures.Contains($name)) { $null = $failures.Add($name) } }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo try { Set-ExecutionPolicy Bypass -Scope CurrentUser -Force -ErrorAction Stop } catch { Write-Host "Unable to set CurrentUser execution policy: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo try { Set-ExecutionPolicy Bypass -Scope LocalMachine -Force -ErrorAction Stop } catch { Write-Host "Unable to set LocalMachine execution policy: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Refresh-SetupEnvironment {
>>"%SCRIPT%" echo     $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
>>"%SCRIPT%" echo     $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
>>"%SCRIPT%" echo     $extra = @("$env:USERPROFILE\scoop\shims", "$env:ProgramData\scoop\shims")
>>"%SCRIPT%" echo     $env:Path = (@($machinePath, $userPath) + $extra ^| Where-Object { -not [string]::IsNullOrWhiteSpace($_) } ^| Select-Object -Unique) -join ';'
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Scoop apps go in for ALL users (scoop --global, %ProgramData%\scoop), and a per-user copy from
>>"%SCRIPT%" echo # before is moved over - see sources\scoop-global.ps1. Detection is by the 'current' manifest,
>>"%SCRIPT%" echo # NOT by matching "scoop list": a failed install stays listed forever (vlc sat uninstalled
>>"%SCRIPT%" echo # for weeks because the old regex matched it), and has no 'current' junction.
>>"%SCRIPT%" echo . "%~dp0sources\scoop-global.ps1"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Add-ScoopBucket([string]$bucket) {
>>"%SCRIPT%" echo     $names = @(^& scoop bucket list 2^>$null ^| ForEach-Object { $_.Name })
>>"%SCRIPT%" echo     if ($names -contains $bucket) { return }
>>"%SCRIPT%" echo     Write-Host "Adding Scoop bucket: $bucket" -ForegroundColor Cyan
>>"%SCRIPT%" echo     ^& scoop bucket add $bucket
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Install-ScoopApp([string]$package, [string]$displayName = $package) {
>>"%SCRIPT%" echo     Refresh-SetupEnvironment
>>"%SCRIPT%" echo     if (-not (Install-ScoopGlobalApp -Package $package -DisplayName $displayName)) { Add-Failure $displayName }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Telegram is the one Scoop app kept per-user on purpose: Scoop runs it in portable mode with its
>>"%SCRIPT%" echo # login (tdata) in the persist folder, which a global install would share with every account.
>>"%SCRIPT%" echo function Install-ScoopUserOnlyApp([string]$package, [string]$displayName = $package) {
>>"%SCRIPT%" echo     Refresh-SetupEnvironment
>>"%SCRIPT%" echo     if (Test-ScoopUserApp $package) { Write-Host "$displayName already installed for this user, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $displayName for this user only via Scoop..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try { ^& scoop install $package } catch { Write-Host "$displayName install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Test-ScoopUserApp $package) { Write-Host "$displayName installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "$displayName FAILED to install." -ForegroundColor Red; Add-Failure $displayName }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # With a Scope the check asks for that scope only, so a per-user copy of an app that should be
>>"%SCRIPT%" echo # machine-wide does not count as installed.
>>"%SCRIPT%" echo function Test-WingetApp([string]$id, [string]$scope) {
>>"%SCRIPT%" echo     $listArgs = @('list', '--id', $id, '-e', '--accept-source-agreements', '--disable-interactivity')
>>"%SCRIPT%" echo     if ($scope) { $listArgs += @('--scope', $scope) }
>>"%SCRIPT%" echo     ^& winget @listArgs ^> $null 2^>^&1
>>"%SCRIPT%" echo     return ($LASTEXITCODE -eq 0)
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Squirrel-style installers (Discord) hand off to an updater and return before the app is
>>"%SCRIPT%" echo # registered, so a check taken the instant the installer exits says FAILED for an app that is
>>"%SCRIPT%" echo # installed a few seconds later. Every post-install check polls for up to 90 s instead.
>>"%SCRIPT%" echo function Wait-InstalledCheck([scriptblock]$check, [int]$seconds = 90) {
>>"%SCRIPT%" echo     $deadline = (Get-Date).AddSeconds($seconds)
>>"%SCRIPT%" echo     $started = Get-Date
>>"%SCRIPT%" echo     while ($true) {
>>"%SCRIPT%" echo         if (^& $check) {
>>"%SCRIPT%" echo             $waited = [int]((Get-Date) - $started).TotalSeconds
>>"%SCRIPT%" echo             if ($waited -ge 5) { Write-Host "  (registered $waited s after the installer returned)" -ForegroundColor DarkGray }
>>"%SCRIPT%" echo             return $true
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         if ((Get-Date) -gt $deadline) { return $false }
>>"%SCRIPT%" echo         Start-Sleep -Seconds 5
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Some apps only make sense with specific hardware (the NVIDIA App on an NVIDIA GPU). A row can name
>>"%SCRIPT%" echo # the GPU vendor it requires; without that hardware the install is skipped, and with it a failed
>>"%SCRIPT%" echo # install is a warning rather than a failed script when the row is marked Optional.
>>"%SCRIPT%" echo function Test-GpuVendor([string]$vendor) {
>>"%SCRIPT%" echo     $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue ^| ForEach-Object { $_.Name })
>>"%SCRIPT%" echo     return [bool]($gpus ^| Where-Object { $_ -match $vendor })
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Install-WingetApp([string]$id, [string]$displayName = $id, [string]$source, [string]$requiresGpu, [bool]$optional = $false, [string]$scope) {
>>"%SCRIPT%" echo     if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Host "winget missing; cannot install $displayName." -ForegroundColor Red; Add-Failure $displayName; return }
>>"%SCRIPT%" echo     if (Test-WingetApp $id $scope) { Write-Host "$displayName already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     if ($requiresGpu -and -not (Test-GpuVendor $requiresGpu)) { Write-Host "$displayName skipped: no $requiresGpu GPU in this machine." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $displayName via winget..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     # Never trust winget's exit code: it returns nonzero for "no applicable upgrade"
>>"%SCRIPT%" echo     # and other benign states. Verify with winget list instead.
>>"%SCRIPT%" echo     $wingetArgs = @('install', '--id', $id, '-e', '--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity')
>>"%SCRIPT%" echo     if ($source) { $wingetArgs += @('--source', $source) }
>>"%SCRIPT%" echo     if ($scope) { $wingetArgs += @('--scope', $scope) }
>>"%SCRIPT%" echo     # winget prints nothing while captured, so the status line (net rate, installer cpu, its last line) is the only movement.
>>"%SCRIPT%" echo     try { $null = Invoke-CommandWithStatus -Label "Installing $displayName (winget)" -FilePath winget.exe -ArgumentList $wingetArgs -WatchProcess msiexec -WatchService msiserver } catch { Write-Host "$displayName install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Wait-InstalledCheck { Test-WingetApp $id $scope }) { Write-Host "$displayName installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     elseif ($optional) { Write-Host "$displayName did not install; optional, continuing." -ForegroundColor Yellow }
>>"%SCRIPT%" echo     else { Write-Host "$displayName FAILED to install." -ForegroundColor Red; Add-Failure $displayName }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Direct installers record a failure and let the run continue. They used to "throw",
>>"%SCRIPT%" echo # which aborted the whole script - one bad download meant every app after it (including
>>"%SCRIPT%" echo # the WSL setup) was never installed at all.
>>"%SCRIPT%" echo function Install-DirectMsi([string]$name, [string]$url, [string]$installedPath) {
>>"%SCRIPT%" echo     if (Test-Path $installedPath) { Write-Host "$name already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $name..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $tmp = $env:TEMP + '\' + ($name -replace '\W', '') + 'Setup.msi'
>>"%SCRIPT%" echo         if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
>>"%SCRIPT%" echo         curl.exe -L --progress-bar -o $tmp $url
>>"%SCRIPT%" echo         $null = Invoke-CommandWithStatus -Label "Installing $name (msi)" -FilePath msiexec.exe -ArgumentList "/i", $tmp, "/qn", "/norestart" -WatchProcess msiexec -WatchService msiserver
>>"%SCRIPT%" echo     } catch { Write-Host "$name install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Wait-InstalledCheck { Test-Path $installedPath }) { Write-Host "$name installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "$name FAILED to install." -ForegroundColor Red; Add-Failure $name }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Starting Windows setup..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Refresh-SetupEnvironment
>>"%SCRIPT%" echo if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo     Write-Host "Scoop is missing. Run 0-init-prereqs.bat first." -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo foreach ($bucket in 'extras', 'versions', 'nerd-fonts') { Add-ScoopBucket $bucket }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # winamp was removed from every Scoop bucket upstream, so it moved to winget below.
>>"%SCRIPT%" echo # discord is a direct download below (see there): Scoop's extras/discord manifest does NOT ship Discord's
>>"%SCRIPT%" echo # own build - it downloads github.com/portapps/discord-portable, a third-party portable
>>"%SCRIPT%" echo # repackage that lagged the official client by months (1.0.9232 vs 1.0.9251) and
>>"%SCRIPT%" echo # redirects Discord's data dir and self-updater. Discord force-updates and refuses to
>>"%SCRIPT%" echo # connect on stale builds, so the lag is a recurring breakage, not a cosmetic detail.
>>"%SCRIPT%" echo # Not in this list, on purpose: firefox and sharex keep their profile/upload accounts in Scoop's
>>"%SCRIPT%" echo # persist folder, which a global install shares with every account, so they come from their own
>>"%SCRIPT%" echo # machine-wide installers below (winget, data in each user's AppData). telegram stays per-user
>>"%SCRIPT%" echo # Scoop (see Install-ScoopUserOnlyApp).
>>"%SCRIPT%" echo $scoopApps = @('googlechrome','winrar','vlc','spotify','handbrake','notepadplusplus','qbittorrent','cloudflared','putty','winscp','bleachbit','wiztree','eartrumpet','sourcetree','vscode','github','ontopreplica','onlyoffice-desktopeditors','streamlabs-obs','clink')
>>"%SCRIPT%" echo foreach ($app in $scoopApps) { Install-ScoopApp $app }
>>"%SCRIPT%" echo Install-ScoopApp 'bulk-crap-uninstaller' 'Bulk Crap Uninstaller'
>>"%SCRIPT%" echo Install-ScoopApp 'JetBrainsMono-NF' 'JetBrainsMono Nerd Font'
>>"%SCRIPT%" echo Install-ScoopUserOnlyApp 'telegram' 'Telegram'
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Refresh-SetupEnvironment
>>"%SCRIPT%" echo if (Get-Command clink -ErrorAction SilentlyContinue) { Write-Host "Enabling Clink autorun for cmd.exe..." -ForegroundColor Cyan; ^& clink autorun install ^| Out-Null }
>>"%SCRIPT%" echo else { Write-Host "Clink not found; skipping autorun." -ForegroundColor Yellow }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # EarTrumpet from Scoop has no autostart: the Store build registers its own startup task, the
>>"%SCRIPT%" echo # portable one does not, so the tray mixer was gone after every reboot. The Run value points at
>>"%SCRIPT%" echo # Scoop's 'current' junction, so it survives "scoop update". Check, act, read back. HKLM, so every
>>"%SCRIPT%" echo # account gets the tray mixer; the old per-user value would start a second copy and goes.
>>"%SCRIPT%" echo $earExe = Join-Path (Get-ScoopGlobalDir) 'apps\eartrumpet\current\EarTrumpet.exe'
>>"%SCRIPT%" echo Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'EarTrumpet' -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo if (Test-Path $earExe) {
>>"%SCRIPT%" echo     $runKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
>>"%SCRIPT%" echo     $earValue = '"' + $earExe + '"'
>>"%SCRIPT%" echo     if ((Get-ItemProperty -Path $runKey -Name 'EarTrumpet' -ErrorAction SilentlyContinue).EarTrumpet -ne $earValue) {
>>"%SCRIPT%" echo         Set-ItemProperty -Path $runKey -Name 'EarTrumpet' -Value $earValue
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo     if ((Get-ItemProperty -Path $runKey -Name 'EarTrumpet' -ErrorAction SilentlyContinue).EarTrumpet -eq $earValue) { Write-Host "EarTrumpet starts at logon." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "EarTrumpet autostart FAILED." -ForegroundColor Red; Add-Failure 'EarTrumpet autostart' }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo else { Write-Host "EarTrumpet not installed; skipping autostart." -ForegroundColor Yellow }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Add an app by adding a row. Source is only needed for msstore-only packages. Scope = 'machine'
>>"%SCRIPT%" echo # forces the all-users installer and checks for that scope only; leave it out for packages whose
>>"%SCRIPT%" echo # manifest declares no scope (winget then finds "no applicable installer" for --scope machine) -
>>"%SCRIPT%" echo # those below install to Program Files anyway. Per-user-only packages (Claude Desktop, Kiro,
>>"%SCRIPT%" echo # Rufus, 2FAGuard, Discord, ...) are in sources\per-user-apps.ps1, run at every sign-in.
>>"%SCRIPT%" echo $wingetApps = @(
>>"%SCRIPT%" echo     @{ Id = 'Mozilla.Firefox';                 Name = 'Firefox'; Scope = 'machine' },
>>"%SCRIPT%" echo     @{ Id = 'ShareX.ShareX';                   Name = 'ShareX'; Scope = 'machine' },
>>"%SCRIPT%" echo     @{ Id = 'CodecGuide.K-LiteCodecPack.Mega'; Name = 'K-Lite Codec Pack Mega' },
>>"%SCRIPT%" echo     @{ Id = 'pCloudAG.pCloudDrive';            Name = 'pCloud Drive' },
>>"%SCRIPT%" echo     @{ Id = 'Devolutions.RemoteDesktopManager'; Name = 'Remote Desktop Manager' },
>>"%SCRIPT%" echo     @{ Id = 'AdGuard.AdGuard';                 Name = 'AdGuard' },
>>"%SCRIPT%" echo     @{ Id = 'Proton.ProtonVPN';                Name = 'ProtonVPN' },
>>"%SCRIPT%" echo     @{ Id = 'Microsoft.DirectX';               Name = 'DirectX Runtime' },
>>"%SCRIPT%" echo     @{ Id = 'Winamp.Winamp';                   Name = 'Winamp' },
>>"%SCRIPT%" echo     @{ Id = 'Microsoft.PowerShell';            Name = 'PowerShell 7' },
>>"%SCRIPT%" echo     @{ Id = 'wez.wezterm';                     Name = 'WezTerm' },
>>"%SCRIPT%" echo     @{ Id = 'Docker.DockerDesktop';            Name = 'Docker Desktop' },
>>"%SCRIPT%" echo     @{ Id = 'PatchMyPC.PatchMyPC';             Name = 'Patch My PC' },
>>"%SCRIPT%" echo     @{ Id = 'IObit.DriverBooster';             Name = 'Driver Booster' },
>>"%SCRIPT%" echo     @{ Id = 'XP8CLZL93F5Z4P';                  Name = 'NVIDIA App'; Source = 'msstore'; RequiresGpu = 'NVIDIA'; Optional = $true }
>>"%SCRIPT%" echo )
>>"%SCRIPT%" echo foreach ($entry in $wingetApps) { Install-WingetApp $entry.Id $entry.Name $entry.Source $entry.RequiresGpu ([bool]$entry.Optional) $entry.Scope }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Firefox and ShareX used to be per-user Scoop installs. Once the machine-wide copy is verified the
>>"%SCRIPT%" echo # Scoop one goes (its persist folder stays as a backup). ShareX's data moves to where the installed
>>"%SCRIPT%" echo # build reads it (Documents\ShareX) when that is still empty; a non-empty Scoop Firefox profile is
>>"%SCRIPT%" echo # not imported automatically, only pointed at - it was empty on this PC.
>>"%SCRIPT%" echo $scoopPersist = Join-Path (Get-ScoopUserDir) 'persist'
>>"%SCRIPT%" echo if (Test-WingetApp 'ShareX.ShareX' 'machine') {
>>"%SCRIPT%" echo     $sxOld = Join-Path $scoopPersist 'sharex\ShareX'
>>"%SCRIPT%" echo     $sxNew = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShareX'
>>"%SCRIPT%" echo     if ((Test-Path $sxOld) -and (Get-ChildItem $sxOld -Recurse -File -ErrorAction SilentlyContinue) -and -not (Test-Path $sxNew)) {
>>"%SCRIPT%" echo         Write-Host "Moving ShareX settings and history to $sxNew..." -ForegroundColor Cyan
>>"%SCRIPT%" echo         $null = ^& robocopy.exe $sxOld $sxNew /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo     $null = Remove-ScoopUserApp 'sharex' 'ShareX'
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo if (Test-WingetApp 'Mozilla.Firefox' 'machine') {
>>"%SCRIPT%" echo     $ffOld = Join-Path $scoopPersist 'firefox\profile'
>>"%SCRIPT%" echo     if ((Test-Path $ffOld) -and (Get-ChildItem $ffOld -Recurse -File -ErrorAction SilentlyContinue)) { Write-Host "The old Scoop Firefox profile is kept at $ffOld; open about:profiles to use it." -ForegroundColor Yellow }
>>"%SCRIPT%" echo     $null = Remove-ScoopUserApp 'firefox' 'Firefox'
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Driver Booster's installer registers elevated logon tasks (scheduler, auto-update, "SkipUAC")
>>"%SCRIPT%" echo # and launches the app. Strip every IObit autostart, task, service and background process; the
>>"%SCRIPT%" echo # app itself stays and runs normally when opened. Idempotent; exit 1 if anything survived.
>>"%SCRIPT%" echo ^& "%~dp0sources\remove-driver-booster-autostart.ps1"
>>"%SCRIPT%" echo if ($LASTEXITCODE -ne 0) { Add-Failure 'Driver Booster autostart cleanup' }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Discord, Discord Canary, Claude Desktop, Claude Code and the other per-user-only apps: see
>>"%SCRIPT%" echo # sources\per-user-apps.ps1 and the sign-in task registered near the end of this script.
>>"%SCRIPT%" echo Install-DirectMsi "Chrome Remote Desktop" "https://dl.google.com/dl/edgedl/chrome-remote-desktop/chromeremotedesktophost.msi" "${env:ProgramFiles(x86)}\Google\Chrome Remote Desktop"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Mudfish is NOT installed here: its installer stops on a driver-installation question that no
>>"%SCRIPT%" echo # silent switch answers, which blocked the whole unattended run. It lives in
>>"%SCRIPT%" echo # optional\setup-optional-software.bat, where installers are allowed to ask.
>>"%SCRIPT%" echo function Test-DokanInstalled {
>>"%SCRIPT%" echo     if (@("C:\Windows\System32\dokan2.dll", "C:\Windows\SysWOW64\dokan2.dll") ^| Where-Object { Test-Path $_ }) { return $true }
>>"%SCRIPT%" echo     return (Test-Path "C:\Program Files\Dokan")
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo function Ensure-DokanInstalled {
>>"%SCRIPT%" echo     if (Test-DokanInstalled) { return $true }
>>"%SCRIPT%" echo     Write-Host "Installing Dokan Library (required by IceDrive)..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try { $null = Invoke-CommandWithStatus -Label "Installing Dokan (winget)" -FilePath winget.exe -ArgumentList "install", "--id", "dokan-dev.Dokany", "-e", "--accept-source-agreements", "--accept-package-agreements", "--silent", "--disable-interactivity" -WatchProcess msiexec -WatchService msiserver } catch { }
>>"%SCRIPT%" echo     if (Test-DokanInstalled) { return $true }
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $release = Invoke-RestMethod "https://api.github.com/repos/dokan-dev/dokany/releases/latest" -Headers @{ 'User-Agent' = 'PCSetup' }
>>"%SCRIPT%" echo         $asset = $release.assets ^| Where-Object { $_.name -match '^^DokanSetup_.*_x64\.msi$' } ^| Select-Object -First 1
>>"%SCRIPT%" echo         if ($asset) {
>>"%SCRIPT%" echo             $dokanMsi = "$env:TEMP\DokanSetup.msi"
>>"%SCRIPT%" echo             ^& curl.exe -fL -o $dokanMsi $asset.browser_download_url --silent --show-error
>>"%SCRIPT%" echo             $null = Invoke-CommandWithStatus -Label "Installing Dokan (msi)" -FilePath msiexec.exe -ArgumentList "/i", $dokanMsi, "/qn", "/norestart" -WatchProcess msiexec -WatchService msiserver
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo     } catch { }
>>"%SCRIPT%" echo     if (Test-DokanInstalled) { return $true }
>>"%SCRIPT%" echo     $svcState = (sc.exe query dokan2 2^>$null ^| Out-String)
>>"%SCRIPT%" echo     if ($svcState -match "STOP_PENDING") { throw "Dokan driver is pending removal/update. Restart Windows, then re-run this setup script." }
>>"%SCRIPT%" echo     throw "Unable to install Dokan Library automatically."
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo function Test-IceDriveInstalled {
>>"%SCRIPT%" echo     return ((Test-Path "$env:ProgramFiles\Icedrive\Icedrive.exe") -or (Test-Path "${env:ProgramFiles(x86)}\Icedrive\Icedrive.exe") -or (Test-Path "$env:LOCALAPPDATA\Programs\Icedrive\Icedrive.exe"))
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo function Test-IceDriveInstaller([string]$path) {
>>"%SCRIPT%" echo     if (-not (Test-Path $path)) { return $false }
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $item = Get-Item $path -ErrorAction Stop
>>"%SCRIPT%" echo         if ($item.Length -lt 50000000) { return $false }
>>"%SCRIPT%" echo         $header = [System.IO.File]::ReadAllBytes($path)[0..1]
>>"%SCRIPT%" echo         if (($header[0] -ne 77) -or ($header[1] -ne 90)) { return $false }
>>"%SCRIPT%" echo         return ((Get-AuthenticodeSignature $path).Status -eq "Valid")
>>"%SCRIPT%" echo     } catch { return $false }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo # IceDrive bundles its own (older) Dokan driver and copies it with the shell copy UI, so if a newer
>>"%SCRIPT%" echo # dokan2.sys is already in System32\DRIVERS the installer stops on a "Confirm File Replace" dialog
>>"%SCRIPT%" echo # even with /S - that is what happened when Dokan was installed first. Order is therefore IceDrive
>>"%SCRIPT%" echo # first (nothing to replace on a fresh machine), Dokan repaired afterwards only if still missing.
>>"%SCRIPT%" echo # A machine that already has a Dokan driver from something else is the one case that cannot be
>>"%SCRIPT%" echo # made silent, so it is skipped with a pointer to the optional script rather than prompting.
>>"%SCRIPT%" echo if (Test-IceDriveInstalled) {
>>"%SCRIPT%" echo     Write-Host "IceDrive already installed, skipping..." -ForegroundColor Yellow
>>"%SCRIPT%" echo     if (-not (Test-DokanInstalled)) { try { Ensure-DokanInstalled ^| Out-Null } catch { Write-Host "Dokan repair failed: $($_.Exception.Message)" -ForegroundColor Yellow } }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo elseif (Test-DokanInstalled) {
>>"%SCRIPT%" echo     Write-Host "IceDrive skipped: a Dokan driver is already installed, and the IceDrive installer stops on a Confirm File Replace dialog for dokan2.sys even with /S. Install it from optional\setup-optional-software.bat." -ForegroundColor Yellow
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         Write-Host "Installing IceDrive..." -ForegroundColor Cyan
>>"%SCRIPT%" echo         $iceInstaller = "$env:TEMP\IcedriveSetup.exe"
>>"%SCRIPT%" echo         $iceReferrer = "https://icedrive.net/apps/desktop-laptop"
>>"%SCRIPT%" echo         $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
>>"%SCRIPT%" echo         if (Test-Path $iceInstaller) { Remove-Item $iceInstaller -Force -ErrorAction SilentlyContinue }
>>"%SCRIPT%" echo         $candidateUrls = @()
>>"%SCRIPT%" echo         try {
>>"%SCRIPT%" echo             $icePage = ^& curl.exe -fsSL -A $ua $iceReferrer
>>"%SCRIPT%" echo             $absolute = ([regex]::Matches($icePage, 'https://cdn\.icedrive\.net/static/apps/win/IcedriveSetup-v[\d.]+\.exe') ^| ForEach-Object { $_.Value }) ^| Select-Object -Unique
>>"%SCRIPT%" echo             if ($absolute) { $candidateUrls += $absolute }
>>"%SCRIPT%" echo             $relative = ([regex]::Matches($icePage, 'value="(win/IcedriveSetup-v[\d.]+\.exe)"') ^| ForEach-Object { $_.Groups[1].Value }) ^| Select-Object -Unique
>>"%SCRIPT%" echo             if ($relative) { $candidateUrls += ($relative ^| ForEach-Object { "https://cdn.icedrive.net/static/apps/$_" }) }
>>"%SCRIPT%" echo         } catch { }
>>"%SCRIPT%" echo         $candidateUrls += @("https://cdn.icedrive.net/static/apps/win/IcedriveSetup-v3.56.exe", "https://cdn.icedrive.net/static/apps/win/IcedriveSetup-v3.55.exe")
>>"%SCRIPT%" echo         $candidateUrls = $candidateUrls ^| Select-Object -Unique
>>"%SCRIPT%" echo         $ok = $false
>>"%SCRIPT%" echo         foreach ($candidate in $candidateUrls) {
>>"%SCRIPT%" echo             Write-Host "Downloading IceDrive installer from $candidate" -ForegroundColor Cyan
>>"%SCRIPT%" echo             try { ^& curl.exe -fL -A $ua -e $iceReferrer -o $iceInstaller $candidate --silent --show-error } catch { }
>>"%SCRIPT%" echo             if (Test-IceDriveInstaller $iceInstaller) { $ok = $true; break }
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         if (-not $ok) { throw "IceDrive installer download failed validation." }
>>"%SCRIPT%" echo         $null = Invoke-CommandWithStatus -Label "Installing IceDrive" -FilePath $iceInstaller -ArgumentList "/S /NORESTART"
>>"%SCRIPT%" echo         if (-not (Test-DokanInstalled)) {
>>"%SCRIPT%" echo             # The installer is never re-run here: a second pass would hit the file-replace dialog.
>>"%SCRIPT%" echo             Write-Host "Dokan missing after IceDrive install; installing it separately..." -ForegroundColor Yellow
>>"%SCRIPT%" echo             Ensure-DokanInstalled ^| Out-Null
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         if (-not (Wait-InstalledCheck { Test-IceDriveInstalled })) { throw "IceDrive installation finished but executable was not found." }
>>"%SCRIPT%" echo         if (-not (Test-DokanInstalled)) { throw "Dokan is still missing after automatic remediation." }
>>"%SCRIPT%" echo         Write-Host "IceDrive installed." -ForegroundColor Green
>>"%SCRIPT%" echo     } catch { Write-Host "IceDrive FAILED: $($_.Exception.Message)" -ForegroundColor Red; Add-Failure 'IceDrive' }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Deploying .wezterm.lua config..." -ForegroundColor Cyan
>>"%SCRIPT%" echo if (-not (Test-Path "$env:USERPROFILE\.wezterm.lua")) {
>>"%SCRIPT%" echo     $luaB64 = 'bG9jYWwgd2V6dGVybSA9IHJlcXVpcmUgJ3dlenRlcm0nCmxvY2FsIGNvbmZpZyA9IHdlenRlcm0uY29uZmlnX2J1aWxkZXIoKQoKY29uZmlnLnRlcm0gPSAneHRlcm0tMjU2Y29sb3InCmNvbmZpZy5zY3JvbGxiYWNrX2xpbmVzID0gMTAwMDAKCi0tIFVzZSBXZXpUZXJtJ3MgYnVuZGxlZCBKZXRCcmFpbnMgTW9ubyAobm8gTmVyZCBGb250IGluc3RhbGwgcmVxdWlyZWQpCi0tIFN3aXRjaCB0byAnSmV0QnJhaW5zTW9ubyBOZXJkIEZvbnQnIGFmdGVyIHJ1bm5pbmcgY2hvY28gaW5zdGFsbCBuZXJkLWZvbnRzLWpldGJyYWluc21vbm8KY29uZmlnLmZvbnQgPSB3ZXp0ZXJtLmZvbnQoJ0pldEJyYWlucyBNb25vJykKY29uZmlnLmZvbnRfc2l6ZSA9IDEyLjAKCmNvbmZpZy5jb2xvcl9zY2hlbWUgPSAnQ2F0cHB1Y2NpbiBNb2NoYScKY29uZmlnLndpbmRvd19iYWNrZ3JvdW5kX29wYWNpdHkgPSAwLjk1CmNvbmZpZy50ZXh0X2JhY2tncm91bmRfb3BhY2l0eSA9IDEuMApjb25maWcud2luZG93X2RlY29yYXRpb25zID0gJ1JFU0laRScKCmNvbmZpZy5hdWRpYmxlX2JlbGwgPSAnRGlzYWJsZWQnCmNvbmZpZy52aXN1YWxfYmVsbCA9IHsKICBmYWRlX2luX2R1cmF0aW9uX21zID0gNzUsCiAgZmFkZV9vdXRfZHVyYXRpb25fbXMgPSA3NSwKICB0YXJnZXQgPSAnQ3Vyc29yQ29sb3InLAp9CgotLSBEZWZhdWx0IHRvIFBTNyBpZiBpbnN0YWxsZWQsIGZhbGwgYmFjayB0byBQUzUKbG9jYWwgcHdzaCA9ICdDOlxcUHJvZ3JhbSBGaWxlc1xcUG93ZXJTaGVsbFxcN1xccHdzaC5leGUnCmxvY2FsIGRlZmF1bHRfc2hlbGwKbG9jYWwgZiA9IGlvLm9wZW4ocHdzaCwgJ3InKQppZiBmIHRoZW4KICBmOmNsb3NlKCkKICBkZWZhdWx0X3NoZWxsID0geyBwd3NoLCAnLU5vTG9nbycgfQplbHNlCiAgZGVmYXVsdF9zaGVsbCA9IHsgJ3Bvd2Vyc2hlbGwuZXhlJywgJy1Ob0xvZ28nIH0KZW5kCmNvbmZpZy5kZWZhdWx0X3Byb2cgPSBkZWZhdWx0X3NoZWxsCgpjb25maWcubGF1bmNoX21lbnUgPSB7CiAgeyBsYWJlbCA9ICdQb3dlclNoZWxsIDcnLCAgYXJncyA9IHsgcHdzaCwgJy1Ob0xvZ28nIH0gfSwKICB7IGxhYmVsID0gJ1Bvd2VyU2hlbGwgNScsICBhcmdzID0geyAncG93ZXJzaGVsbC5leGUnLCAnLU5vTG9nbycgfSB9LAogIHsgbGFiZWwgPSAnQ01EJywgICAgICAgICAgIGFyZ3MgPSB7ICdjbWQuZXhlJyB9IH0sCiAgeyBsYWJlbCA9ICdHaXQgQmFzaCcsICAgICAgYXJncyA9IHsgJ0M6XFxQcm9ncmFtIEZpbGVzXFxHaXRcXGJpblxcYmFzaC5leGUnLCAnLWknLCAnLWwnIH0gfSwKICB7IGxhYmVsID0gJ1dTTCcsICAgICAgICAgICBhcmdzID0geyAnd3NsLmV4ZScgfSB9LAp9Cgpjb25maWcua2V5cyA9IHsKICB7IGtleSA9ICd0JywgbW9kcyA9ICdDVFJMfFNISUZUJywgYWN0aW9uID0gd2V6dGVybS5hY3Rpb24uU3Bhd25UYWIgJ0N1cnJlbnRQYW5lRG9tYWluJyB9LAogIHsga2V5ID0gJ3cnLCBtb2RzID0gJ0NUUkx8U0hJRlQnLCBhY3Rpb24gPSB3ZXp0ZXJtLmFjdGlvbi5DbG9zZUN1cnJlbnRUYWIgeyBjb25maXJtID0gZmFsc2UgfSB9LAogIHsga2V5ID0gJ2QnLCBtb2RzID0gJ0NUUkx8U0hJRlQnLCBhY3Rpb24gPSB3ZXp0ZXJtLmFjdGlvbi5TcGxpdEhvcml6b250YWwgeyBkb21haW4gPSAnQ3VycmVudFBhbmVEb21haW4nIH0gfSwKICB7IGtleSA9ICdlJywgbW9kcyA9ICdDVFJMfFNISUZUJywgYWN0aW9uID0gd2V6dGVybS5hY3Rpb24uU3BsaXRWZXJ0aWNhbCAgIHsgZG9tYWluID0gJ0N1cnJlbnRQYW5lRG9tYWluJyB9IH0sCiAgeyBrZXkgPSAnTGVmdEFycm93JywgIG1vZHMgPSAnQ1RSTHxTSElGVCcsIGFjdGlvbiA9IHdlenRlcm0uYWN0aW9uLkFjdGl2YXRlUGFuZURpcmVjdGlvbiAnTGVmdCcgfSwKICB7IGtleSA9ICdSaWdodEFycm93JywgbW9kcyA9ICdDVFJMfFNISUZUJywgYWN0aW9uID0gd2V6dGVybS5hY3Rpb24uQWN0aXZhdGVQYW5lRGlyZWN0aW9uICdSaWdodCcgfSwKICB7IGtleSA9ICdVcEFycm93JywgICAgbW9kcyA9ICdDVFJMfFNISUZUJywgYWN0aW9uID0gd2V6dGVybS5hY3Rpb24uQWN0aXZhdGVQYW5lRGlyZWN0aW9uICdVcCcgfSwKICB7IGtleSA9ICdEb3duQXJyb3cnLCAgbW9kcyA9ICdDVFJMfFNISUZUJywgYWN0aW9uID0gd2V6dGVybS5hY3Rpb24uQWN0aXZhdGVQYW5lRGlyZWN0aW9uICdEb3duJyB9LAp9CgpyZXR1cm4gY29uZmln'
>>"%SCRIPT%" echo     $luaContent = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($luaB64))
>>"%SCRIPT%" echo     [System.IO.File]::WriteAllText("$env:USERPROFILE\.wezterm.lua", $luaContent, [System.Text.Encoding]::UTF8)
>>"%SCRIPT%" echo     Write-Host ".wezterm.lua written to $env:USERPROFILE" -ForegroundColor Green
>>"%SCRIPT%" echo } else { Write-Host ".wezterm.lua already exists, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Configuring PowerShell profile for WezTerm notifications..." -ForegroundColor Cyan
>>"%SCRIPT%" echo if (-not (Test-Path $PROFILE)) { New-Item -Path $PROFILE -ItemType File -Force ^| Out-Null }
>>"%SCRIPT%" echo $profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo if ($profileContent -notmatch '# WezTerm bell notification') {
>>"%SCRIPT%" echo     $profB64 = 'CiMgV2V6VGVybSBiZWxsIG5vdGlmaWNhdGlvbgokZ2xvYmFsOl9XZXpQcm9tcHRUaW1lciA9ICRudWxsCiRnbG9iYWw6X1dlek9yaWdQcm9tcHQgPSBHZXQtSXRlbSBmdW5jdGlvbjpwcm9tcHQgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUKCiRmdW5jdGlvbjpwcm9tcHQgPSB7CiAgICAkbGFzdEV4aXQgPSAkTEFTVEVYSVRDT0RFCiAgICBpZiAoJGdsb2JhbDpfV2V6UHJvbXB0VGltZXIgLW5lICRudWxsKSB7CiAgICAgICAgJGVsYXBzZWQgPSAoR2V0LURhdGUpIC0gJGdsb2JhbDpfV2V6UHJvbXB0VGltZXIKICAgICAgICBpZiAoJGVsYXBzZWQuVG90YWxTZWNvbmRzIC1nZSAxMCkgewogICAgICAgICAgICBbQ29uc29sZV06OldyaXRlKCJgYSIpCiAgICAgICAgICAgICR4bWwgPSAkbnVsbAogICAgICAgICAgICAkdG9hc3QgPSAkbnVsbAogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgJGFwcElkID0gJ3sxQUMxNEU3Ny0wMkU3LTRFNUQtQjc0NC0yRUIxQUU1MTk4Qjd9XFdpbmRvd3NQb3dlclNoZWxsXHYxLjBccG93ZXJzaGVsbC5leGUnCiAgICAgICAgICAgICAgICAkc3RhdHVzID0gaWYgKCRsYXN0RXhpdCAtZXEgMCkgeyAnZmluaXNoZWQnIH0gZWxzZSB7ICJmYWlsZWQgKGV4aXQgJGxhc3RFeGl0KSIgfQogICAgICAgICAgICAgICAgJG1zZyA9ICJDb21tYW5kICRzdGF0dXMgYWZ0ZXIgJChbaW50XSRlbGFwc2VkLlRvdGFsU2Vjb25kcylzIgogICAgICAgICAgICAgICAgJHhtbCA9IFtXaW5kb3dzLkRhdGEuWG1sLkRvbS5YbWxEb2N1bWVudCwgV2luZG93cy5EYXRhLlhtbC5Eb20sIENvbnRlbnRUeXBlPVdpbmRvd3NSdW50aW1lXTo6bmV3KCkKICAgICAgICAgICAgICAgICR4bWwuTG9hZFhtbCgiPHRvYXN0Pjx2aXN1YWw+PGJpbmRpbmcgdGVtcGxhdGU9J1RvYXN0VGV4dDAxJz48dGV4dCBpZD0nMSc+JG1zZzwvdGV4dD48L2JpbmRpbmc+PC92aXN1YWw+PC90b2FzdD4iKQogICAgICAgICAgICAgICAgJHRvYXN0ID0gW1dpbmRvd3MuVUkuTm90aWZpY2F0aW9ucy5Ub2FzdE5vdGlmaWNhdGlvbiwgV2luZG93cy5VSS5Ob3RpZmljYXRpb25zLCBDb250ZW50VHlwZT1XaW5kb3dzUnVudGltZV06Om5ldygkeG1sKQogICAgICAgICAgICAgICAgW1dpbmRvd3MuVUkuTm90aWZpY2F0aW9ucy5Ub2FzdE5vdGlmaWNhdGlvbk1hbmFnZXIsIFdpbmRvd3MuVUkuTm90aWZpY2F0aW9ucywgQ29udGVudFR5cGU9V2luZG93c1J1bnRpbWVdOjpDcmVhdGVUb2FzdE5vdGlmaWVyKCRhcHBJZCkuU2hvdygkdG9hc3QpCiAgICAgICAgICAgIH0gY2F0Y2ggewogICAgICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgICAgICBpZiAoJHRvYXN0KSB7CiAgICAgICAgICAgICAgICAgICAgICAgICRhcHBJZDIgPSAnTWljcm9zb2Z0LldpbmRvd3NUZXJtaW5hbF84d2VreWIzZDhiYndlIUFwcCcKICAgICAgICAgICAgICAgICAgICAgICAgW1dpbmRvd3MuVUkuTm90aWZpY2F0aW9ucy5Ub2FzdE5vdGlmaWNhdGlvbk1hbmFnZXIsIFdpbmRvd3MuVUkuTm90aWZpY2F0aW9ucywgQ29udGVudFR5cGU9V2luZG93c1J1bnRpbWVdOjpDcmVhdGVUb2FzdE5vdGlmaWVyKCRhcHBJZDIpLlNob3coJHRvYXN0KQogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0gY2F0Y2ggeyB9CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9CiAgICAkZ2xvYmFsOl9XZXpQcm9tcHRUaW1lciA9IEdldC1EYXRlCiAgICAkZ2xvYmFsOkxBU1RFWElUQ09ERSA9ICRsYXN0RXhpdAogICAgaWYgKCRnbG9iYWw6X1dlek9yaWdQcm9tcHQpIHsgJiAkZ2xvYmFsOl9XZXpPcmlnUHJvbXB0IH0gZWxzZSB7ICJQUyAkKCRleGVjdXRpb25Db250ZXh0LlNlc3Npb25TdGF0ZS5QYXRoLkN1cnJlbnRMb2NhdGlvbikkKCc+JyAqICgkbmVzdGVkUHJvbXB0TGV2ZWwgKyAxKSkgIiB9Cn0='
>>"%SCRIPT%" echo     $profBlock = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($profB64))
>>"%SCRIPT%" echo     Add-Content -Path $PROFILE -Value $profBlock -Encoding UTF8
>>"%SCRIPT%" echo     Write-Host "WezTerm notification block added to PowerShell profile." -ForegroundColor Green
>>"%SCRIPT%" echo } else { Write-Host "WezTerm notification already in PS profile, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Apps that can only be installed into one account (Discord, Discord Canary, Claude Desktop, Claude
>>"%SCRIPT%" echo # Code, Kiro, Rufus, 2FAGuard): sources\per-user-apps.ps1, registered as a task that runs at every
>>"%SCRIPT%" echo # user's sign-in, so a new account gets them without running setup. -RunNow also installs them for
>>"%SCRIPT%" echo # this account now (unelevated) and reports failures here.
>>"%SCRIPT%" echo ^& "%~dp0sources\register-per-user-apps.ps1" -RunNow
>>"%SCRIPT%" echo if ($LASTEXITCODE -ne 0) { Add-Failure 'Per-user apps (see %%LOCALAPPDATA%%\PCSetup\per-user-apps.log)' }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo if (Get-Command wsl -ErrorAction SilentlyContinue) { Write-Host "WSL already installed, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     Write-Host "Installing WSL..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     ^& wsl --install --no-launch
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo $wslReady = $false
>>"%SCRIPT%" echo $wslSkipReason = $null
>>"%SCRIPT%" echo $linuxDistros = @()
>>"%SCRIPT%" echo if (Get-Command wsl -ErrorAction SilentlyContinue) {
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $wslDistros = ^& wsl -l -q 2^>$null
>>"%SCRIPT%" echo         $linuxDistros = @($wslDistros ^| ForEach-Object { ($_.ToString() -replace '\x00', '').Trim() } ^| Where-Object { $_ -and $_ -notmatch '^^docker-desktop(-data)?$' })
>>"%SCRIPT%" echo         if ($linuxDistros.Count -gt 0) { $wslReady = $true } else { $wslSkipReason = "No Linux WSL distro is installed yet" }
>>"%SCRIPT%" echo     } catch { $wslSkipReason = "WSL check failed: $($_.Exception.Message)" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo if ($wslReady) {
>>"%SCRIPT%" echo     $wslDistro = $linuxDistros ^| Select-Object -First 1
>>"%SCRIPT%" echo     ^& wsl -d $wslDistro -e bash -lc "[ -x ~/.local/bin/claude ]"
>>"%SCRIPT%" echo     if ($LASTEXITCODE -eq 0) { Write-Host "Claude Code already installed in WSL, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo     else {
>>"%SCRIPT%" echo         Write-Host "Installing Claude Code in WSL..." -ForegroundColor Cyan
>>"%SCRIPT%" echo         ^& wsl -d $wslDistro -e bash -c "curl -fsSL https://claude.ai/install.sh | bash"
>>"%SCRIPT%" echo         ^& wsl -d $wslDistro -e bash -c "grep -q '.local/bin' ~/.bashrc || echo 'export PATH=\"\`$HOME/.local/bin:\`$PATH\"' >> ~/.bashrc"
>>"%SCRIPT%" echo         ^& wsl -d $wslDistro -e bash -lc "[ -x ~/.local/bin/claude ]"
>>"%SCRIPT%" echo         if ($LASTEXITCODE -eq 0) { Write-Host "Claude Code installed in WSL." -ForegroundColor Green }
>>"%SCRIPT%" echo         else { Write-Host "Claude Code in WSL FAILED to install." -ForegroundColor Red; Add-Failure 'Claude Code (WSL)' }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo } else { if ($wslSkipReason) { Write-Host "$wslSkipReason - skipping WSL setup." -ForegroundColor Yellow } else { Write-Host "WSL not ready yet - skipping WSL setup." -ForegroundColor Yellow } }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Windows setup finished with failures: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     Write-Host "Re-run this script to retry them." -ForegroundColor Yellow
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "All done! Restart your computer if WSL was just installed." -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "WIN_EXIT=%errorlevel%"
if %WIN_EXIT% neq 0 (
    echo.
    echo Setup finished with exit code %WIN_EXIT%.
    echo Generated script: %SCRIPT%
) else (
    del "%SCRIPT%" >nul 2>&1
)
ENDLOCAL & exit /b %WIN_EXIT%
