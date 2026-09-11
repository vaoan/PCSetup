@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: download-twitch-vod.bat
:: Double-click with a Twitch VOD link (twitch.tv/videos/...) in the clipboard.
:: Downloads it at up to 720p into the Videos folder and shows progress in this window.
:: All logic lives in download-twitch-vod.ps1 next to this file.

setlocal
set "PSModulePath="
title Twitch VOD download
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-twitch-vod.ps1"
endlocal
exit /b %errorlevel%
