@echo off
:: Auto-elevate to Administrator (keeping the dropped file path)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -ArgumentList '\"%~1\"' -Verb RunAs"
    exit /b
)

:: compress-video.bat
:: Re-encodes a video to AV1 in place (about half the size, no visible loss). Three ways to use it:
::   - drop a video file onto this .bat
::   - run it with the file as the argument:  compress-video.bat "Z:\...\video.mp4"
::   - copy the file path (Explorer: Shift+right-click, Copy as path) and double-click this .bat
:: All logic lives in download-video.ps1 next to this file (-CompressFile); a Twitch download
:: does the same step by itself, so this is for files that were downloaded before that existed.

setlocal
set "PSModulePath="
title Compress Video
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-video.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-video.ps1" -CompressFile "%~1"
)
endlocal
exit /b %errorlevel%
