@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: download-instagram-post.bat
:: Double-click with an Instagram reel or post link in the clipboard.
:: Reels/videos go to the Videos folder, photo posts to Pictures. Progress shows in this window.
:: Needs a one-time cookie export from Chrome (see download-instagram-post.ps1 header).
:: All logic lives in download-instagram-post.ps1 next to this file.

setlocal
set "PSModulePath="
title Instagram download
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-instagram-post.ps1"
endlocal
exit /b %errorlevel%
