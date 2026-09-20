@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: repair-discord.bat
:: Double-click when Discord opens and closes itself, or dies at first launch with
:: "A fatal Javascript error occured". Removes the stale pinned-update keys from settings.json,
:: reinstalls (normal mode) when the updater database is unregistered, then launches Discord and
:: watches it for 30 s. Arguments are passed through: -Channel canary, -Reinstall, -NoLaunch.
:: All logic lives in repair-discord.ps1 next to this file.

setlocal
set "PSModulePath="
title Repair Discord
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-discord.ps1" %*
endlocal
exit /b %errorlevel%
