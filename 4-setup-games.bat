@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

SETLOCAL
SET SCRIPT=%TEMP%\temp-games-setup.ps1
if exist "%SCRIPT%" del "%SCRIPT%" >nul

(
echo Set-ExecutionPolicy Bypass -Scope Process -Force
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo.
echo Write-Host "Installing game-related applications..." -ForegroundColor Cyan
echo Write-Host ""
echo.
echo # Install game platforms and Java via Chocolatey
echo choco install steam epicgameslauncher prismlauncher temurin17 temurin8 -y
echo.
echo # XIVLauncher ^(Custom FFXIV Launcher^)
echo if ^(Test-Path "$env:LOCALAPPDATA\XIVLauncher"^) {
echo     Write-Host "XIVLauncher already installed, skipping..." -ForegroundColor Yellow
echo } else {
echo     Write-Host "Installing XIVLauncher..." -ForegroundColor Cyan
echo     $xivRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/goatcorp/FFXIVQuickLauncher/releases/latest"
echo     $xivAsset = $xivRelease.assets ^| Where-Object { $_.name -like "*Setup.exe" } ^| Select-Object -First 1
echo     $xivInstaller = "$env:TEMP\XIVLauncher-Setup.exe"
echo     Invoke-WebRequest -Uri $xivAsset.browser_download_url -OutFile $xivInstaller
echo     Start-Process -FilePath $xivInstaller -ArgumentList "/S" -Wait
echo     Write-Host "XIVLauncher installed!" -ForegroundColor Green
echo }
echo.
echo # FFLogs Uploader
echo $fflogsPath1 = "$env:LOCALAPPDATA\FFLogs"
echo $fflogsPath2 = "$env:LOCALAPPDATA\Programs\fflogs"
echo if ^(^(Test-Path $fflogsPath1^) -or ^(Test-Path $fflogsPath2^)^) {
echo     Write-Host "FFLogs already installed, skipping..." -ForegroundColor Yellow
echo } else {
echo     Write-Host "Installing FFLogs Uploader..." -ForegroundColor Cyan
echo     $fflogsRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/RPGLogs/Uploaders-fflogs/releases/latest"
echo     $fflogsAsset = $fflogsRelease.assets ^| Where-Object { $_.name -like "*.exe" } ^| Select-Object -First 1
echo     $fflogsInstaller = "$env:TEMP\FFLogs-Setup.exe"
echo     Invoke-WebRequest -Uri $fflogsAsset.browser_download_url -OutFile $fflogsInstaller
echo     Start-Process -FilePath $fflogsInstaller -ArgumentList "/S" -Wait
echo     Write-Host "FFLogs Uploader installed!" -ForegroundColor Green
echo }
echo.
echo Write-Host ""
echo Write-Host "Game setup complete!" -ForegroundColor Green
) > "%SCRIPT%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
ENDLOCAL
