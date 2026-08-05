@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
setlocal
:: Windows PowerShell must not inherit a PS7 PSModulePath - it then refuses to load
:: the Core-only Microsoft.PowerShell.Utility and ConvertFrom-Json disappears.
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-secrets.ps1"
endlocal
