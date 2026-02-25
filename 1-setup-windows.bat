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
echo choco install googlechrome discord directx 7zip.install winrar vlc k-litecodecpackmega spotify handbrake sharex `>>"%SCRIPT%"
echo python notepadplusplus telegram.install pcloud rdm qbittorrent cloudflared warp winamp firefox putty winscp `>>"%SCRIPT%"
echo bleachbit bulk-crap-uninstaller wiztree streamlabs-obs eartrumpet git.install sourcetree `>>"%SCRIPT%"
echo vscode github-desktop gh ontopreplica onlyoffice nvm nvidia-app vcredist-all dotnet-6.0-desktopruntime `>>"%SCRIPT%"
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
echo if ((Test-Path "$env:ProgramFiles\IceDrive\IceDrive.exe") -or (Test-Path "${env:ProgramFiles(x86)}\IceDrive\IceDrive.exe")) { Write-Host "IceDrive already installed, skipping..." -ForegroundColor Yellow } else {>>"%SCRIPT%"
echo     Write-Host "Installing IceDrive..." -ForegroundColor Cyan>>"%SCRIPT%"
echo     $icePage = Invoke-WebRequest -Uri "https://icedrive.net/apps/desktop-laptop" -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }>>"%SCRIPT%"
echo     $iceRel = ([regex]::Match($icePage.Content, 'win/IcedriveSetup-v[\d.]+\.exe')).Value>>"%SCRIPT%"
echo     if (-not $iceRel) { throw "Unable to find IceDrive installer URL." }>>"%SCRIPT%"
echo     $iceUrl = "https://cdn.icedrive.net/static/apps/$iceRel">>"%SCRIPT%"
echo     $iceInstaller = "$env:TEMP\IcedriveSetup.exe">>"%SCRIPT%"
echo     Invoke-WebRequest -Uri $iceUrl -OutFile $iceInstaller>>"%SCRIPT%"
echo     Start-Process -FilePath $iceInstaller -ArgumentList "/S" -Wait>>"%SCRIPT%"
echo }>>"%SCRIPT%"
echo Write-Host "Installing 2FAGuard..." -ForegroundColor Cyan>>"%SCRIPT%"
echo winget install --id timokoessler.2FAGuard -e --accept-source-agreements --accept-package-agreements --silent>>"%SCRIPT%"
echo Write-Host "Installing Claude Desktop..." -ForegroundColor Cyan>>"%SCRIPT%"
echo winget install --id Anthropic.Claude -e --accept-source-agreements --accept-package-agreements --silent>>"%SCRIPT%"
echo refreshenv>>"%SCRIPT%"
echo nvm install lts 2^>^$null>>"%SCRIPT%"
echo nvm use lts 2^>^$null>>"%SCRIPT%"
echo Write-Host "Installing Claude Code..." -ForegroundColor Cyan>>"%SCRIPT%"
echo irm https://claude.ai/install.ps1 ^| iex>>"%SCRIPT%"
echo if (-not ($env:PATH -split ';' ^| Where-Object { $_ -eq "$env:USERPROFILE\.local\bin" })) {>>"%SCRIPT%"
echo     [Environment]::SetEnvironmentVariable('PATH', [Environment]::GetEnvironmentVariable('PATH', 'User') + ";$env:USERPROFILE\.local\bin", 'User')>>"%SCRIPT%"
echo }>>"%SCRIPT%"
echo Write-Host "Installing OpenAI Codex CLI..." -ForegroundColor Cyan>>"%SCRIPT%"
echo cmd /c npm.cmd install -g @openai/codex 2^>^$null>>"%SCRIPT%"
echo Write-Host "Installing GitHub Copilot CLI..." -ForegroundColor Cyan>>"%SCRIPT%"
echo cmd /c npm.cmd install -g @github/copilot 2^>^$null>>"%SCRIPT%"
echo gh extension install github/gh-copilot 2^>^$null>>"%SCRIPT%"
echo Write-Host "`n Setup complete." -ForegroundColor Green>>"%SCRIPT%"
echo if (Get-Command wsl -ErrorAction SilentlyContinue) { Write-Host "WSL already installed, skipping..." -ForegroundColor Yellow } else {>>"%SCRIPT%"
echo     Write-Host "Installing WSL..." -ForegroundColor Cyan>>"%SCRIPT%"
echo     wsl --install --no-launch>>"%SCRIPT%"
echo }>>"%SCRIPT%"
echo if ((Get-Command wsl -ErrorAction SilentlyContinue) -and (wsl -l -q 2^>^$null)) {>>"%SCRIPT%"
echo     Write-Host "Installing Claude Code in WSL..." -ForegroundColor Cyan>>"%SCRIPT%"
echo     wsl -e bash -c "curl -fsSL https://claude.ai/install.sh ^| bash">>"%SCRIPT%"
echo     wsl -e bash -c "grep -q '.local/bin' ~/.bashrc ^|^| echo 'export PATH=\"\`$HOME/.local/bin:\`$PATH\"' ^>^> ~/.bashrc">>"%SCRIPT%"
echo } else { Write-Host "WSL not ready yet - run this script again after restart to install Claude Code in WSL" -ForegroundColor Yellow }>>"%SCRIPT%"
echo Write-Host "`n All done! Restart your computer if WSL was installed." -ForegroundColor Green>>"%SCRIPT%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
ENDLOCAL
