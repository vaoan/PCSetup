@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: download-youtube-video.bat
:: Double-click with a YouTube link (youtube.com/watch?v=... or youtu.be/...) in the clipboard.
:: Downloads it at up to 720p into the Videos folder and shows progress in this window.
:: All logic lives in download-youtube-video.ps1 next to this file.

setlocal
set "PSModulePath="
title YouTube download
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-youtube-video.ps1"
endlocal
exit /b %errorlevel%
