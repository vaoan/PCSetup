@echo off
:: Self-elevate script if not running as admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

IF EXIST "C:\ProgramData\chocolatey\lib\vcredist2005" (
    echo Removing previous lock files for vcredist2005...
    rmdir /s /q "C:\ProgramData\chocolatey\lib\vcredist2005"
)

SETLOCAL
SET SCRIPT=%TEMP%\temp-setup.ps1
if exist "%SCRIPT%" del "%SCRIPT%" >nul
echo Set-ExecutionPolicy Bypass -Scope Process -Force>>"%SCRIPT%"
echo [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072>>"%SCRIPT%"
echo iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))>>"%SCRIPT%"
echo choco install googlechrome discord directx 7zip.install winrar steam vlc k-litecodecpackmega spotify handbrake sharex `>>"%SCRIPT%"
echo python notepadplusplus telegram.install pcloud rdm qbittorrent cloudflared warp winamp firefox putty winscp `>>"%SCRIPT%"
echo bleachbit bulk-crap-uninstaller streamlabs-obs prismlauncher temurin17 temurin8 eartrumpet git.install sourcetree `>>"%SCRIPT%"
echo vscode github-desktop ontopreplica onlyoffice nvm nvidia-app vcredist-all dotnet-6.0-desktopruntime `>>"%SCRIPT%"
echo dotnet-8.0-desktopruntime dotnet-9.0-desktopruntime dotnet-desktopruntime driverbooster protonvpn --ignore-checksums -y>>"%SCRIPT%"
echo if (Test-Path "$env:LOCALAPPDATA\DiscordCanary") { Write-Host "Discord Canary already installed, skipping..." -ForegroundColor Yellow } else {>>"%SCRIPT%"
echo     Write-Host "Installing Discord Canary..." -ForegroundColor Cyan>>"%SCRIPT%"
echo     $discordCanary = "$env:TEMP\DiscordCanarySetup.exe">>"%SCRIPT%"
echo     Invoke-WebRequest -Uri "https://discord.com/api/downloads/distributions/app/installers/latest?channel=canary&platform=win&arch=x64" -OutFile $discordCanary>>"%SCRIPT%"
echo     Start-Process -FilePath $discordCanary -ArgumentList "-s" -Wait>>"%SCRIPT%"
echo }>>"%SCRIPT%"
echo if (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome Remote Desktop") { Write-Host "Chrome Remote Desktop already installed, skipping..." -ForegroundColor Yellow } else {>>"%SCRIPT%"
echo     Write-Host "Installing Chrome Remote Desktop..." -ForegroundColor Cyan>>"%SCRIPT%"
echo     $chromeRD = "$env:TEMP\chromeremotedesktophost.msi">>"%SCRIPT%"
echo     Invoke-WebRequest -Uri "https://dl.google.com/edgedl/chrome-remote-desktop/chromeremotedesktophost.msi" -OutFile $chromeRD>>"%SCRIPT%"
echo     Start-Process msiexec.exe -ArgumentList "/i", $chromeRD, "/qn" -Wait>>"%SCRIPT%"
echo }>>"%SCRIPT%"
echo Write-Host "Installing 2FAGuard..." -ForegroundColor Cyan>>"%SCRIPT%"
echo winget install --id timokoessler.2FAGuard -e --accept-source-agreements --accept-package-agreements --silent>>"%SCRIPT%"
echo Write-Host "Installing Claude Desktop..." -ForegroundColor Cyan>>"%SCRIPT%"
echo winget install --id Anthropic.Claude -e --accept-source-agreements --accept-package-agreements --silent>>"%SCRIPT%"
echo refreshenv>>"%SCRIPT%"
echo nvm install lts 2^>^$null>>"%SCRIPT%"
echo nvm use lts 2^>^$null>>"%SCRIPT%"
echo cmd /c npm.cmd install -g @anthropic-ai/claude-code @openai/codex 2^>^$null>>"%SCRIPT%"
echo Write-Host "`n Setup complete." -ForegroundColor Green>>"%SCRIPT%"
echo if (Get-Command wsl -ErrorAction SilentlyContinue) { Write-Host "WSL already installed, skipping..." -ForegroundColor Yellow } else {>>"%SCRIPT%"
echo     Write-Host "Installing WSL..." -ForegroundColor Cyan>>"%SCRIPT%"
echo     wsl --install --no-launch>>"%SCRIPT%"
echo }>>"%SCRIPT%"
echo Write-Host "`n All done! Restart your computer if WSL was installed." -ForegroundColor Green>>"%SCRIPT%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
ENDLOCAL
