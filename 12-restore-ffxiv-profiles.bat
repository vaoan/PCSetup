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

:: Restores the FFXIV profiles after a format (Profiles, XIVLauncher, XIVProfiles, FFXIVConfig,
:: MINION) from the private GitHub backups with GH_TOKEN from <drive>:\secrets.txt. Runs after
:: script 5 so Documents is already where it belongs. No secrets.txt = skipped, not failed.
if "%PCSETUP_CI%"=="1" (
    echo SKIP: CI mode - no private repos to restore
    exit /b 0
)
set "PSModulePath="

set "SCRIPT=%TEMP%\temp-restore-ffxiv.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo if (Test-Path -LiteralPath "%~dp0sources\start-log.ps1") { . "%~dp0sources\start-log.ps1" }
>>"%SCRIPT%" echo ^& "%~dp0sources\restore-ffxiv-profiles.ps1" -SkipWhenNoToken
>>"%SCRIPT%" echo exit $LASTEXITCODE

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "FX_EXIT=%errorlevel%"
if %FX_EXIT% neq 0 (
    echo.
    echo FFXIV profile restore finished with exit code %FX_EXIT%.
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %FX_EXIT%
