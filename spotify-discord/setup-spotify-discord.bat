@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: One-click installer for the Spotify -> Discord voice bridge.
:: Order matters:
::   1) mirrored WSL networking (prereq: fixes Discord voice + OAuth callback,
::      and rewires the console off Windows TCP relays) -- may restart WSL
::   2) WSL install (go-librespot + bot + systemd services)
::   3) Windows scheduled task so the bridge is always available at logon
set "DIR=/mnt/z/Users/Heiner/Documents/PCSetup/spotify-discord"
set "WINDIR=%~dp0"

echo [1/3] Ensuring WSL mirrored networking...
powershell -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%setup-wsl-mirrored.ps1"

echo [2/3] Running Spotify-Discord WSL setup...
wsl -d Ubuntu-24.04 --user root bash "%DIR%/setup-spotify-discord-wsl.sh"

echo [3/3] Installing Windows scheduled task...
powershell -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%install-scheduled-task.ps1"

echo.
echo If a one-time Spotify login was requested above, run:
echo     powershell -ExecutionPolicy Bypass -File "%WINDIR%login-spotify.ps1"
echo.
