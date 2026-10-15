@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: THE Cloudflare setup: tunnels, OpenSSH, web console, watchdog, verification.
:: One double-click after a format; safe to re-run. See setup-cloudflare.ps1.
setlocal
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-cloudflare.ps1"
set "RC=%errorlevel%"
endlocal & exit /b %RC%
