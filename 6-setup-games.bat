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
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Installing game-related applications..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo     Write-Host "Scoop is missing. Run 0-init-prereqs.bat first." -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Exact install test. Parsing "scoop list" text needs a regex whose ^^ anchor does not
>>"%SCRIPT%" echo # survive being echoed out of a batch file; "scoop prefix" just exits non-zero instead.
>>"%SCRIPT%" echo function Test-ScoopApp([string]$package) {
>>"%SCRIPT%" echo     # 6^> too: Scoop reports "Could not find app path" via Write-Host, so 2^> alone
>>"%SCRIPT%" echo     # leaves a scary-looking line on the console for every not-yet-installed app.
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
>>"%SCRIPT%" echo function Install-ScoopApp([string]$package, [string]$displayName, [string]$bucket) {
>>"%SCRIPT%" echo     if (Test-ScoopApp $package) { Write-Host "$displayName already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $displayName via Scoop..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     $spec = if ($bucket) { "$bucket/$package" } else { $package }
>>"%SCRIPT%" echo     try { ^& scoop install $spec } catch { Write-Host "$displayName install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Test-ScoopApp $package) { Write-Host "$displayName installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "$displayName FAILED to install." -ForegroundColor Red; $null = $failures.Add($displayName) }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Test-WingetApp([string]$id) {
>>"%SCRIPT%" echo     ^& winget list --id $id -e --accept-source-agreements ^> $null 2^>^&1
>>"%SCRIPT%" echo     return ($LASTEXITCODE -eq 0)
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Install-WingetApp([string]$id, [string]$displayName) {
>>"%SCRIPT%" echo     if (Test-WingetApp $id) { Write-Host "$displayName already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $displayName via winget..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     ^& winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
>>"%SCRIPT%" echo     if (Test-WingetApp $id) { Write-Host "$displayName installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "$displayName FAILED to install." -ForegroundColor Red; $null = $failures.Add($displayName) }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # steam/epic-games-launcher/prismlauncher live in the "games" bucket, which
>>"%SCRIPT%" echo # 0-init-prereqs.bat does not add. Without it Scoop cannot resolve them at all.
>>"%SCRIPT%" echo Add-ScoopBucket "games"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Install game platforms via Scoop. Java is installed by 0-init-prereqs.bat.
>>"%SCRIPT%" echo # Bucket-qualified: "steam" also exists in the versions bucket, and an ambiguous
>>"%SCRIPT%" echo # name makes Scoop pick whichever bucket sorts first.
>>"%SCRIPT%" echo Install-ScoopApp "steam" "Steam" "games"
>>"%SCRIPT%" echo Install-ScoopApp "epic-games-launcher" "Epic Games Launcher" "games"
>>"%SCRIPT%" echo Install-ScoopApp "prismlauncher" "Prism Launcher" "games"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Install-WingetApp "Overwolf.CurseForge" "CurseForge"
>>"%SCRIPT%" echo Install-WingetApp "goatcorp.XIVLauncher" "XIVLauncher"
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # FFXIV TexTools (Modding Tool) - not on any package manager
>>"%SCRIPT%" echo $ttPath = "$env:LOCALAPPDATA\TexTools"
>>"%SCRIPT%" echo $ttExe = Join-Path $ttPath "FFXIV_TexTools.exe"
>>"%SCRIPT%" echo if (Test-Path $ttExe) { Write-Host "TexTools already installed, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     Write-Host "Installing TexTools..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $ttRel = Invoke-RestMethod "https://api.github.com/repos/TexTools/FFXIV_TexTools_UI/releases/latest" -Headers @{ "User-Agent" = "PCSetup" }
>>"%SCRIPT%" echo         # Releases since v3.1.1.3b ship the portable zip only - the installer asset is gone,
>>"%SCRIPT%" echo         # so fall back to extracting the zip (it has no top-level folder) rather than
>>"%SCRIPT%" echo         # handing curl an empty URL.
>>"%SCRIPT%" echo         $ttInst = $ttRel.assets ^| Where-Object { $_.name -like "Install_TexTools*.exe" } ^| Select-Object -First 1
>>"%SCRIPT%" echo         if ($ttInst) {
>>"%SCRIPT%" echo             $ttFile = "$env:TEMP\Install_TexTools.exe"
>>"%SCRIPT%" echo             curl.exe -L --progress-bar -o $ttFile $ttInst.browser_download_url
>>"%SCRIPT%" echo             Start-Process $ttFile -ArgumentList "/S" -Wait
>>"%SCRIPT%" echo         } else {
>>"%SCRIPT%" echo             $ttZipAsset = $ttRel.assets ^| Where-Object { $_.name -like "*.zip" } ^| Select-Object -First 1
>>"%SCRIPT%" echo             if (-not $ttZipAsset) { throw "No TexTools installer or zip asset in release $($ttRel.tag_name)" }
>>"%SCRIPT%" echo             $ttZip = "$env:TEMP\FFXIV_TexTools.zip"
>>"%SCRIPT%" echo             curl.exe -L --progress-bar -o $ttZip $ttZipAsset.browser_download_url
>>"%SCRIPT%" echo             New-Item -ItemType Directory -Path $ttPath -Force ^| Out-Null
>>"%SCRIPT%" echo             Expand-Archive -Path $ttZip -DestinationPath $ttPath -Force
>>"%SCRIPT%" echo             Remove-Item $ttZip -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo     } catch { Write-Host "TexTools install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Test-Path $ttExe) { Write-Host "TexTools installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "TexTools FAILED to install." -ForegroundColor Red; $null = $failures.Add("TexTools") }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # FFLogs Uploader - not on any package manager. Its electron-builder installer lands in
>>"%SCRIPT%" echo # "Programs\FF Logs Uploader"; checking only the old paths re-downloaded 178 MB every run.
>>"%SCRIPT%" echo $ffDirs = @("$env:LOCALAPPDATA\Programs\FF Logs Uploader", "$env:LOCALAPPDATA\Programs\fflogs", "$env:LOCALAPPDATA\FFLogs")
>>"%SCRIPT%" echo if ($ffDirs ^| Where-Object { Test-Path $_ }) { Write-Host "FFLogs already installed, skipping..." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     Write-Host "Installing FFLogs Uploader..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $ffRel = Invoke-RestMethod "https://api.github.com/repos/RPGLogs/Uploaders-fflogs/releases/latest" -Headers @{ "User-Agent" = "PCSetup" }
>>"%SCRIPT%" echo         $ffAsset = $ffRel.assets ^| Where-Object { $_.name -like "*.exe" } ^| Select-Object -First 1
>>"%SCRIPT%" echo         if (-not $ffAsset) { throw "No FFLogs installer asset in release $($ffRel.tag_name)" }
>>"%SCRIPT%" echo         $ffFile = "$env:TEMP\FFLogs-Setup.exe"
>>"%SCRIPT%" echo         curl.exe -L --progress-bar -o $ffFile $ffAsset.browser_download_url
>>"%SCRIPT%" echo         Start-Process $ffFile -ArgumentList "/S" -Wait
>>"%SCRIPT%" echo     } catch { Write-Host "FFLogs install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if ($ffDirs ^| Where-Object { Test-Path $_ }) { Write-Host "FFLogs Uploader installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "FFLogs Uploader FAILED to install." -ForegroundColor Red; $null = $failures.Add("FFLogs Uploader") }
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
