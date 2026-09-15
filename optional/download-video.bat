@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: download-video.bat
:: Double-click with a Twitch VOD, YouTube video or Instagram reel/post link in the clipboard.
:: Detects the site, installs what that site needs, downloads into Videos (Pictures for
:: Instagram photo posts) and shows progress in this window.
:: All logic lives in download-video.ps1 next to this file.

setlocal
set "PSModulePath="
title Download Video
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-video.ps1"
endlocal
exit /b %errorlevel%
