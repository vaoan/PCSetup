@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

SETLOCAL

if "%PCSETUP_CI%"=="1" (
    echo SKIP: CI mode - skipping games setup
    exit /b 0
)

:: Windows PowerShell must not inherit PowerShell 7's PSModulePath. If it does, it finds
:: the Core-only copies of Microsoft.PowerShell.Utility/Security first and refuses to load
:: them, so Get-FileHash disappears and every Scoop install dies with "URL ... is not valid".
:: Clearing it here (inside SETLOCAL) makes powershell.exe rebuild its own default.
set "PSModulePath="

SET SCRIPT=%TEMP%\temp-games-setup.ps1
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
>>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo # One-line live status for long native commands (installers, npm). Shared with
>>"%SCRIPT%" echo # sources\init-prereqs.ps1 - see sources\status-line.ps1.
>>"%SCRIPT%" echo . "%~dp0sources\status-line.ps1"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Installing game-related applications..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo     Write-Host "Scoop is missing. Run 0-init-prereqs.bat first." -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Scoop apps go in for ALL users (scoop --global) and a per-user copy from before is moved over;
>>"%SCRIPT%" echo # the install test is the 'current' manifest, never "scoop list" text. See sources\scoop-global.ps1.
>>"%SCRIPT%" echo . "%~dp0sources\scoop-global.ps1"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Add-ScoopBucket([string]$bucket) {
>>"%SCRIPT%" echo     $names = @(^& scoop bucket list 2^>$null ^| ForEach-Object { $_.Name })
>>"%SCRIPT%" echo     if ($names -contains $bucket) { return }
>>"%SCRIPT%" echo     Write-Host "Adding Scoop bucket: $bucket" -ForegroundColor Cyan
>>"%SCRIPT%" echo     ^& scoop bucket add $bucket
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Install-ScoopApp([string]$package, [string]$displayName, [string]$bucket) {
>>"%SCRIPT%" echo     $spec = if ($bucket) { "$bucket/$package" } else { $package }
>>"%SCRIPT%" echo     if (-not (Install-ScoopGlobalApp -Package $spec -DisplayName $displayName)) { $null = $failures.Add($displayName) }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Same grace period as 2-setup-windows.bat: an installer that hands off to an updater is not
>>"%SCRIPT%" echo # registered the instant it returns.
>>"%SCRIPT%" echo function Wait-InstalledCheck([scriptblock]$check, [int]$seconds = 90) {
>>"%SCRIPT%" echo     $deadline = (Get-Date).AddSeconds($seconds)
>>"%SCRIPT%" echo     while ($true) {
>>"%SCRIPT%" echo         if (^& $check) { return $true }
>>"%SCRIPT%" echo         if ((Get-Date) -gt $deadline) { return $false }
>>"%SCRIPT%" echo         Start-Sleep -Seconds 5
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # steam/epic-games-launcher/prismlauncher live in the "games" bucket, which
>>"%SCRIPT%" echo # 0-init-prereqs.bat does not add. Without it Scoop cannot resolve them at all.
>>"%SCRIPT%" echo Add-ScoopBucket "games"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Game platforms via Scoop, for all users. Java is installed by 0-init-prereqs.bat.
>>"%SCRIPT%" echo # Bucket-qualified: an ambiguous name makes Scoop pick whichever bucket sorts first.
>>"%SCRIPT%" echo Install-ScoopApp "epic-games-launcher" "Epic Games Launcher" "games"
>>"%SCRIPT%" echo Install-ScoopApp "prismlauncher" "Prism Launcher" "games"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Steam is NOT a Scoop app any more. A global Scoop install lives in %%ProgramData%%\scoop, which
>>"%SCRIPT%" echo # only administrators can write, and Steam has to write to its own folder to update itself and
>>"%SCRIPT%" echo # download games; its userdata also sat in the shared persist folder. Valve's installer puts it in
>>"%SCRIPT%" echo # Program Files (x86)\Steam with the permissions Steam needs, once for every account.
>>"%SCRIPT%" echo $steamDir = Join-Path ${env:ProgramFiles(x86)} 'Steam'
>>"%SCRIPT%" echo $steamExe = Join-Path $steamDir 'steam.exe'
>>"%SCRIPT%" echo if (Test-Path -LiteralPath $steamExe) { Write-Host "Steam already installed for all users, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     Write-Host "Installing Steam for all users via winget..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     $null = Invoke-CommandWithStatus -Label "Installing Steam (winget)" -FilePath winget.exe -ArgumentList "install", "--id", "Valve.Steam", "-e", "--scope", "machine", "--silent", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"
>>"%SCRIPT%" echo     if (Wait-InstalledCheck { Test-Path -LiteralPath $steamExe }) { Write-Host "Steam installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "Steam FAILED to install." -ForegroundColor Red; $null = $failures.Add("Steam") }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo # Moving off the old per-user Scoop Steam: its userdata and the library list (D:\SteamLibrary,
>>"%SCRIPT%" echo # Z:\SteamLibrary, ...) are copied in when the new install has none yet, with the old install path
>>"%SCRIPT%" echo # in libraryfolders.vdf rewritten to the new one. Games in other libraries stay where they are.
>>"%SCRIPT%" echo # Then the Scoop copy is removed; its persist folder stays as the backup. Steam must be closed.
>>"%SCRIPT%" echo if ((Test-Path -LiteralPath $steamExe) -and (Test-ScoopUserApp 'steam')) {
>>"%SCRIPT%" echo     if (Get-Process steam -ErrorAction SilentlyContinue) { Write-Host "Steam is running; close it and re-run to move the old Scoop Steam over." -ForegroundColor Yellow; $null = $failures.Add("Steam (close it to finish the move)") }
>>"%SCRIPT%" echo     else {
>>"%SCRIPT%" echo         $oldPersist = Join-Path (Get-ScoopUserDir) 'persist\steam'
>>"%SCRIPT%" echo         $oldUserdata = Join-Path $oldPersist 'userdata'
>>"%SCRIPT%" echo         $newUserdata = Join-Path $steamDir 'userdata'
>>"%SCRIPT%" echo         if ((Test-Path -LiteralPath $oldUserdata) -and -not (Get-ChildItem -LiteralPath $newUserdata -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo             Write-Host "Copying Steam userdata..." -ForegroundColor Cyan
>>"%SCRIPT%" echo             $null = ^& robocopy.exe $oldUserdata $newUserdata /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         $oldVdf = Join-Path $oldPersist 'steamapps\libraryfolders.vdf'
>>"%SCRIPT%" echo         $newVdf = Join-Path $steamDir 'steamapps\libraryfolders.vdf'
>>"%SCRIPT%" echo         if ((Test-Path -LiteralPath $oldVdf) -and -not (Test-Path -LiteralPath $newVdf)) {
>>"%SCRIPT%" echo             $oldPath = (Join-Path (Get-ScoopUserDir) 'apps\steam\current').Replace('\', '\\')
>>"%SCRIPT%" echo             $vdf = [IO.File]::ReadAllText($oldVdf).Replace($oldPath, $steamDir.Replace('\', '\\'))
>>"%SCRIPT%" echo             New-Item -ItemType Directory -Path (Split-Path $newVdf) -Force ^| Out-Null
>>"%SCRIPT%" echo             [IO.File]::WriteAllText($newVdf, $vdf, (New-Object Text.UTF8Encoding($false)))
>>"%SCRIPT%" echo             Write-Host "Steam library folders carried over." -ForegroundColor Green
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         if (-not (Remove-ScoopUserApp 'steam' 'Steam')) { $null = $failures.Add("Steam (old Scoop copy)") }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # CurseForge, XIVLauncher, TexTools and FFLogs Uploader install per user only; they are in
>>"%SCRIPT%" echo # sources\per-user-apps.ps1, which 2-setup-windows.bat runs now and at every user's sign-in.
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # NCSOFT's PURPLE launcher (purple.plaync.com/download). Installed by winget (Nullsoft, so
>>"%SCRIPT%" echo # --silent passes /S; no dialog, nothing launched) but NOT verified by it: the uninstall
>>"%SCRIPT%" echo # entry it writes (Purple_plaync) has no DisplayVersion, so "winget list --id NCSoft.Purple"
>>"%SCRIPT%" echo # never finds it and Install-WingetApp would report a good install as failed every run.
>>"%SCRIPT%" echo function Get-PurpleLauncher {
>>"%SCRIPT%" echo     $dirs = @()
>>"%SCRIPT%" echo     $loc = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Purple_plaync' -ErrorAction SilentlyContinue).InstallLocation
>>"%SCRIPT%" echo     if ($loc) { $dirs += $loc }
>>"%SCRIPT%" echo     $dirs += "${env:ProgramFiles(x86)}\NC\Purple"
>>"%SCRIPT%" echo     foreach ($d in $dirs) { $exe = Join-Path $d 'PurpleLauncher.exe'; if (Test-Path -LiteralPath $exe) { return $exe } }
>>"%SCRIPT%" echo     return $null
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo if (Get-PurpleLauncher) { Write-Host "PURPLE (NCSOFT) already installed, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     Write-Host "Installing PURPLE (NCSOFT) via winget..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     $null = Invoke-CommandWithStatus -Label "Installing PURPLE (winget)" -FilePath winget.exe -ArgumentList "install", "--id", "NCSoft.Purple", "-e", "--silent", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"
>>"%SCRIPT%" echo     if (Wait-InstalledCheck { [bool](Get-PurpleLauncher) }) { Write-Host "PURPLE (NCSOFT) installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "PURPLE (NCSOFT) FAILED to install." -ForegroundColor Red; $null = $failures.Add("PURPLE (NCSOFT)") }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Game setup finished with failures: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Game setup complete!" -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "GAMES_EXIT=%errorlevel%"
del "%SCRIPT%" >nul 2>&1
ENDLOCAL & exit /b %GAMES_EXIT%
