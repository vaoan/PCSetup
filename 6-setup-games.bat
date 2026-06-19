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

SET SCRIPT=%TEMP%\temp-games-setup.ps1
if exist "%SCRIPT%" del "%SCRIPT%" >nul

(
echo Set-ExecutionPolicy Bypass -Scope Process -Force
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo.
echo Write-Host "Installing game-related applications..." -ForegroundColor Cyan
echo Write-Host ""
echo.
echo function Install-ScoopApp([string]$package, [string]$displayName = $package^) {
echo     if ^(-not ^(Get-Command scoop -ErrorAction SilentlyContinue^)^) { throw "Scoop is missing. Run 0-init-prereqs.bat first." }
echo     $installed = ^& scoop list 2^>^$null ^| Out-String
echo     if ^($installed -match "(?m)^\s*$([regex]::Escape($package))\s+"^) { Write-Host "$displayName already installed, skipping..." -ForegroundColor Yellow; return }
echo     Write-Host "Installing $displayName via Scoop..." -ForegroundColor Cyan
echo     try { ^& scoop install $package } catch { Write-Host "$displayName install failed: $($_.Exception.Message)" -ForegroundColor Yellow }
echo }
echo.
echo # Install game platforms via Scoop. Java is installed by 0-init-prereqs.bat.
echo Install-ScoopApp "steam" "Steam"
echo Install-ScoopApp "epic-games-launcher" "Epic Games Launcher"
echo Install-ScoopApp "prismlauncher" "Prism Launcher"
echo.
echo # CurseForge via winget
echo winget install --id Overwolf.CurseForge -e --accept-package-agreements --accept-source-agreements
echo.
echo # XIVLauncher via winget ^(auto-skips if installed^)
echo winget install --id goatcorp.XIVLauncher -e --accept-package-agreements --accept-source-agreements
echo.
echo # FFXIV TexTools ^(Modding Tool^) - not on any package manager
echo $ttPath = "$env:LOCALAPPDATA\TexTools"
echo if ^(-not ^(Test-Path $ttPath^)^) {
echo     Write-Host "Installing TexTools..." -ForegroundColor Cyan
echo     $ttAsset = ^(Invoke-RestMethod "https://api.github.com/repos/TexTools/FFXIV_TexTools_UI/releases/latest"^).assets ^| Where-Object { $_.name -like "Install_TexTools*" } ^| Select-Object -First 1
echo     curl.exe -L --progress-bar -o "$env:TEMP\Install_TexTools.exe" $ttAsset.browser_download_url
echo     Start-Process "$env:TEMP\Install_TexTools.exe" -ArgumentList "/S" -Wait
echo } else { Write-Host "TexTools already installed, skipping..." -ForegroundColor Yellow }
echo.
echo # FFLogs Uploader - not on any package manager
echo if ^(-not ^(^(Test-Path "$env:LOCALAPPDATA\FFLogs"^) -or ^(Test-Path "$env:LOCALAPPDATA\Programs\fflogs"^)^)^) {
echo     Write-Host "Installing FFLogs Uploader..." -ForegroundColor Cyan
echo     $ffAsset = ^(Invoke-RestMethod "https://api.github.com/repos/RPGLogs/Uploaders-fflogs/releases/latest"^).assets ^| Where-Object { $_.name -like "*.exe" } ^| Select-Object -First 1
echo     curl.exe -L --progress-bar -o "$env:TEMP\FFLogs-Setup.exe" $ffAsset.browser_download_url
echo     Start-Process "$env:TEMP\FFLogs-Setup.exe" -ArgumentList "/S" -Wait
echo } else { Write-Host "FFLogs already installed, skipping..." -ForegroundColor Yellow }
echo.
echo Write-Host ""
echo Write-Host "Game setup complete!" -ForegroundColor Green
) > "%SCRIPT%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
ENDLOCAL
