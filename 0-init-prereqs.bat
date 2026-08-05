@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

setlocal

:: Windows PowerShell must not inherit PowerShell 7's PSModulePath, or it finds the Core-only
:: Microsoft.PowerShell.Utility/Security first and refuses to load them - Invoke-RestMethod and
:: Get-FileHash then vanish and the bootstrap fails in confusing ways. Clearing it here (inside
:: setlocal) makes powershell.exe rebuild its own default.
set "PSModulePath="

set "SCRIPT=%~dp0sources\init-prereqs.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: Missing prerequisite script: %SCRIPT%
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if %errorlevel% neq 0 (
    echo.
    echo Prerequisite initialization failed with exit code %errorlevel%.
    exit /b %errorlevel%
)
endlocal
