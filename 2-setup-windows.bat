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
>>"%SCRIPT%" echo # Detection is by "scoop prefix", NOT by matching the text of "scoop list".
>>"%SCRIPT%" echo # A failed install STAYS in "scoop list" forever with an empty Version and
>>"%SCRIPT%" echo # Info='Install failed', so the old regex matched it and reported "already installed,
>>"%SCRIPT%" echo # skipping" on every subsequent run - vlc was stuck uninstalled for exactly this reason.
>>"%SCRIPT%" echo # "scoop prefix" resolves the 'current' junction, which a failed install does not have.
>>"%SCRIPT%" echo function Test-ScoopApp([string]$package) {
>>"%SCRIPT%" echo     $prefix = ^& scoop prefix $package 2^>$null 6^>$null
>>"%SCRIPT%" echo     return ($LASTEXITCODE -eq 0 -and $prefix -and (Test-Path $prefix))
>>"%SCRIPT%" echo }
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
>>"%SCRIPT%" echo     if (Test-ScoopApp $package) { Write-Host "$displayName already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $displayName via Scoop..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     # scoop install self-heals a previous failed install (it purges and retries).
>>"%SCRIPT%" echo     try { ^& scoop install $package } catch { Write-Host "$displayName install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Test-ScoopApp $package) { Write-Host "$displayName installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "$displayName FAILED to install." -ForegroundColor Red; Add-Failure $displayName }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Test-WingetApp([string]$id) {
>>"%SCRIPT%" echo     ^& winget list --id $id -e --accept-source-agreements ^> $null 2^>^&1
>>"%SCRIPT%" echo     return ($LASTEXITCODE -eq 0)
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Install-WingetApp([string]$id, [string]$displayName = $id, [string]$source) {
>>"%SCRIPT%" echo     if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Host "winget missing; cannot install $displayName." -ForegroundColor Red; Add-Failure $displayName; return }
>>"%SCRIPT%" echo     if (Test-WingetApp $id) { Write-Host "$displayName already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $displayName via winget..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     # Never trust winget's exit code: it returns nonzero for "no applicable upgrade"
>>"%SCRIPT%" echo     # and other benign states. Verify with winget list instead.
>>"%SCRIPT%" echo     $wingetArgs = @('install', '--id', $id, '-e', '--accept-source-agreements', '--accept-package-agreements', '--silent')
>>"%SCRIPT%" echo     if ($source) { $wingetArgs += @('--source', $source) }
>>"%SCRIPT%" echo     try { ^& winget @wingetArgs } catch { Write-Host "$displayName install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Test-WingetApp $id) { Write-Host "$displayName installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "$displayName FAILED to install." -ForegroundColor Red; Add-Failure $displayName }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Direct installers record a failure and let the run continue. They used to "throw",
>>"%SCRIPT%" echo # which aborted the whole script - one bad download meant every app after it (including
>>"%SCRIPT%" echo # Claude Code and the WSL setup) was never installed at all.
>>"%SCRIPT%" echo function Install-DirectExe([string]$name, [string]$url, [string]$silentArgs, [string]$installedPath) {
>>"%SCRIPT%" echo     if (Test-Path $installedPath) { Write-Host "$name already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $name..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $tmp = $env:TEMP + '\' + ($name -replace '\W', '') + 'Setup.exe'
>>"%SCRIPT%" echo         if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
>>"%SCRIPT%" echo         curl.exe -L --progress-bar -o $tmp $url
>>"%SCRIPT%" echo         Start-Process -FilePath $tmp -ArgumentList $silentArgs -Wait
>>"%SCRIPT%" echo     } catch { Write-Host "$name install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Test-Path $installedPath) { Write-Host "$name installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "$name FAILED to install." -ForegroundColor Red; Add-Failure $name }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Install-DirectMsi([string]$name, [string]$url, [string]$installedPath) {
>>"%SCRIPT%" echo     if (Test-Path $installedPath) { Write-Host "$name already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $name..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $tmp = $env:TEMP + '\' + ($name -replace '\W', '') + 'Setup.msi'
>>"%SCRIPT%" echo         if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
>>"%SCRIPT%" echo         curl.exe -L --progress-bar -o $tmp $url
>>"%SCRIPT%" echo         Start-Process msiexec.exe -ArgumentList "/i", $tmp, "/qn", "/norestart" -Wait
>>"%SCRIPT%" echo     } catch { Write-Host "$name install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Test-Path $installedPath) { Write-Host "$name installed." -ForegroundColor Green }
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
>>"%SCRIPT%" echo # discord also moved to winget: Scoop's extras/discord manifest does NOT ship Discord's
>>"%SCRIPT%" echo # own build - it downloads github.com/portapps/discord-portable, a third-party portable
>>"%SCRIPT%" echo # repackage that lagged the official client by months (1.0.9232 vs 1.0.9251) and
>>"%SCRIPT%" echo # redirects Discord's data dir and self-updater. Discord force-updates and refuses to
>>"%SCRIPT%" echo # connect on stale builds, so the lag is a recurring breakage, not a cosmetic detail.
>>"%SCRIPT%" echo $scoopApps = @('googlechrome','winrar','vlc','spotify','handbrake','sharex','notepadplusplus','telegram','qbittorrent','cloudflared','firefox','putty','winscp','bleachbit','wiztree','eartrumpet','sourcetree','vscode','github','ontopreplica','onlyoffice-desktopeditors','streamlabs-obs','clink')
>>"%SCRIPT%" echo foreach ($app in $scoopApps) { Install-ScoopApp $app }
>>"%SCRIPT%" echo Install-ScoopApp 'bulk-crap-uninstaller' 'Bulk Crap Uninstaller'
>>"%SCRIPT%" echo Install-ScoopApp 'JetBrainsMono-NF' 'JetBrainsMono Nerd Font'
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Refresh-SetupEnvironment
>>"%SCRIPT%" echo if (Get-Command clink -ErrorAction SilentlyContinue) { Write-Host "Enabling Clink autorun for cmd.exe..." -ForegroundColor Cyan; ^& clink autorun install ^| Out-Null }
>>"%SCRIPT%" echo else { Write-Host "Clink not found; skipping autorun." -ForegroundColor Yellow }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Add an app by adding a row. Source is only needed for msstore-only packages.
>>"%SCRIPT%" echo $wingetApps = @(
>>"%SCRIPT%" echo     @{ Id = 'Discord.Discord';                 Name = 'Discord' },
>>"%SCRIPT%" echo     @{ Id = 'CodecGuide.K-LiteCodecPack.Mega'; Name = 'K-Lite Codec Pack Mega' },
>>"%SCRIPT%" echo     @{ Id = 'pCloudAG.pCloudDrive';            Name = 'pCloud Drive' },
>>"%SCRIPT%" echo     @{ Id = 'Devolutions.RemoteDesktopManager'; Name = 'Remote Desktop Manager' },
>>"%SCRIPT%" echo     @{ Id = 'Cloudflare.Warp';                 Name = 'Cloudflare WARP' },
>>"%SCRIPT%" echo     @{ Id = 'AdGuard.AdGuard';                 Name = 'AdGuard' },
>>"%SCRIPT%" echo     @{ Id = 'Proton.ProtonVPN';                Name = 'ProtonVPN' },
>>"%SCRIPT%" echo     @{ Id = 'Microsoft.DirectX';               Name = 'DirectX Runtime' },
>>"%SCRIPT%" echo     @{ Id = 'Winamp.Winamp';                   Name = 'Winamp' },
>>"%SCRIPT%" echo     @{ Id = 'timokoessler.2FAGuard';           Name = '2FAGuard' },
>>"%SCRIPT%" echo     @{ Id = 'Anthropic.Claude';                Name = 'Claude Desktop' },
>>"%SCRIPT%" echo     @{ Id = 'Amazon.Kiro';                     Name = 'Kiro' },
>>"%SCRIPT%" echo     @{ Id = 'Rufus.Rufus';                     Name = 'Rufus' },
>>"%SCRIPT%" echo     @{ Id = 'Microsoft.PowerShell';            Name = 'PowerShell 7' },
>>"%SCRIPT%" echo     @{ Id = 'wez.wezterm';                     Name = 'WezTerm' },
>>"%SCRIPT%" echo     @{ Id = 'Docker.DockerDesktop';            Name = 'Docker Desktop' },
>>"%SCRIPT%" echo     @{ Id = 'XP8CLZL93F5Z4P';                  Name = 'NVIDIA App'; Source = 'msstore' }
>>"%SCRIPT%" echo )
>>"%SCRIPT%" echo foreach ($entry in $wingetApps) { Install-WingetApp $entry.Id $entry.Name $entry.Source }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Install-DirectExe "Discord Canary" "https://discord.com/api/download/canary?platform=win" "/S" "$env:LOCALAPPDATA\DiscordCanary"
>>"%SCRIPT%" echo Install-DirectMsi "Chrome Remote Desktop" "https://dl.google.com/dl/edgedl/chrome-remote-desktop/chromeremotedesktophost.msi" "${env:ProgramFiles(x86)}\Google\Chrome Remote Desktop"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $mudfishInstalled = (Test-Path "${env:ProgramFiles(x86)}\Mudfish Cloud VPN\mudfish.exe") -or (Test-Path "$env:ProgramFiles\Mudfish Cloud VPN\mudfish.exe") -or (Test-Path "$env:LOCALAPPDATA\Mudfish Cloud VPN\mudfish.exe")
>>"%SCRIPT%" echo if ($mudfishInstalled) { Write-Host "Mudfish already installed, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         Write-Host "Resolving Mudfish download..." -ForegroundColor Cyan
>>"%SCRIPT%" echo         $mudfishPage = ^& curl.exe -fsSL "https://mudfish.net/download"
>>"%SCRIPT%" echo         $mudfishMatch = [regex]::Match($mudfishPage, '/download\?filename=mudfish-[0-9.]+-x86_64-win2k-setup\.exe')
>>"%SCRIPT%" echo         if (-not $mudfishMatch.Success) { throw "Mudfish Windows installer link not found." }
>>"%SCRIPT%" echo         $mudfishFile = $mudfishMatch.Value -replace '^^/download\?filename=', ''
>>"%SCRIPT%" echo         Install-DirectExe "Mudfish" "https://mudfish.net/releases/$mudfishFile" "/S" "${env:ProgramFiles(x86)}\Mudfish Cloud VPN"
>>"%SCRIPT%" echo     } catch { Write-Host "Mudfish FAILED: $($_.Exception.Message)" -ForegroundColor Red; Add-Failure 'Mudfish' }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Test-DokanInstalled {
>>"%SCRIPT%" echo     if (@("C:\Windows\System32\dokan2.dll", "C:\Windows\SysWOW64\dokan2.dll") ^| Where-Object { Test-Path $_ }) { return $true }
>>"%SCRIPT%" echo     return (Test-Path "C:\Program Files\Dokan")
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo function Ensure-DokanInstalled {
>>"%SCRIPT%" echo     if (Test-DokanInstalled) { return $true }
>>"%SCRIPT%" echo     Write-Host "Installing Dokan Library (required by IceDrive)..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try { ^& winget install --id dokan-dev.Dokany -e --accept-source-agreements --accept-package-agreements --silent } catch { }
>>"%SCRIPT%" echo     if (Test-DokanInstalled) { return $true }
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $release = Invoke-RestMethod "https://api.github.com/repos/dokan-dev/dokany/releases/latest" -Headers @{ 'User-Agent' = 'PCSetup' }
>>"%SCRIPT%" echo         $asset = $release.assets ^| Where-Object { $_.name -match '^^DokanSetup_.*_x64\.msi$' } ^| Select-Object -First 1
>>"%SCRIPT%" echo         if ($asset) {
>>"%SCRIPT%" echo             $dokanMsi = "$env:TEMP\DokanSetup.msi"
>>"%SCRIPT%" echo             ^& curl.exe -fL -o $dokanMsi $asset.browser_download_url --silent --show-error
>>"%SCRIPT%" echo             Start-Process msiexec.exe -ArgumentList "/i", $dokanMsi, "/qn", "/norestart" -Wait
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
>>"%SCRIPT%" echo if ((Test-IceDriveInstalled) -and (Test-DokanInstalled)) { Write-Host "IceDrive and Dokan already installed, skipping..." -ForegroundColor Yellow }
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
>>"%SCRIPT%" echo         Ensure-DokanInstalled ^| Out-Null
>>"%SCRIPT%" echo         $ok = $false
>>"%SCRIPT%" echo         foreach ($candidate in $candidateUrls) {
>>"%SCRIPT%" echo             Write-Host "Downloading IceDrive installer from $candidate" -ForegroundColor Cyan
>>"%SCRIPT%" echo             try { ^& curl.exe -fL -A $ua -e $iceReferrer -o $iceInstaller $candidate --silent --show-error } catch { }
>>"%SCRIPT%" echo             if (Test-IceDriveInstaller $iceInstaller) { $ok = $true; break }
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         if (-not $ok) { throw "IceDrive installer download failed validation." }
>>"%SCRIPT%" echo         Start-Process -FilePath $iceInstaller -ArgumentList "/S /NORESTART" -Wait
>>"%SCRIPT%" echo         if (-not (Test-DokanInstalled)) {
>>"%SCRIPT%" echo             Write-Host "Dokan missing after IceDrive install. Repairing and retrying..." -ForegroundColor Yellow
>>"%SCRIPT%" echo             Ensure-DokanInstalled ^| Out-Null
>>"%SCRIPT%" echo             Start-Process -FilePath $iceInstaller -ArgumentList "/S /NORESTART" -Wait
>>"%SCRIPT%" echo             Start-Sleep -Seconds ^3
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         if (-not (Test-IceDriveInstalled)) { throw "IceDrive installation finished but executable was not found." }
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
>>"%SCRIPT%" echo $rufusExe = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Rufus.Rufus_Microsoft.Winget.Source_8wekyb3d8bbwe\rufus.exe"
>>"%SCRIPT%" echo if (Test-Path $rufusExe) {
>>"%SCRIPT%" echo     $rufusShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) "Rufus.lnk"
>>"%SCRIPT%" echo     $wshShell = New-Object -ComObject WScript.Shell
>>"%SCRIPT%" echo     $shortcut = $wshShell.CreateShortcut($rufusShortcut)
>>"%SCRIPT%" echo     $shortcut.TargetPath = $rufusExe
>>"%SCRIPT%" echo     $shortcut.WorkingDirectory = Split-Path $rufusExe
>>"%SCRIPT%" echo     $shortcut.IconLocation = "$rufusExe,0"
>>"%SCRIPT%" echo     $shortcut.Save()
>>"%SCRIPT%" echo     Write-Host "Rufus desktop shortcut created." -ForegroundColor Green
>>"%SCRIPT%" echo } else { Write-Host "Rufus executable not found; skipping desktop shortcut." -ForegroundColor Yellow }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
>>"%SCRIPT%" echo if (-not ($userPath -split ';' ^| Where-Object { $_ -eq "$env:USERPROFILE\.local\bin" })) {
>>"%SCRIPT%" echo     [Environment]::SetEnvironmentVariable('PATH', $userPath + ";$env:USERPROFILE\.local\bin", 'User')
>>"%SCRIPT%" echo     $env:PATH = $env:PATH + ";$env:USERPROFILE\.local\bin"
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Host "Claude Code already installed, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     Write-Host "Installing Claude Code..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try { irm https://claude.ai/install.ps1 ^| iex } catch { Write-Host "Claude Code install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     $env:PATH = $env:PATH + ";$env:USERPROFILE\.local\bin"
>>"%SCRIPT%" echo     if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Host "Claude Code installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "Claude Code FAILED to install." -ForegroundColor Red; Add-Failure 'Claude Code' }
>>"%SCRIPT%" echo }
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
