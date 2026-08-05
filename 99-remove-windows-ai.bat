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

:: Server Core has no Copilot/Recall to remove, and the remote script targets Appx packages
:: that do not exist there.
if "%PCSETUP_CI%"=="1" (
    echo SKIP: CI mode - skipping Windows AI removal
    exit /b 0
)

:: Get-AppxPackage and friends live in modules the remote script relies on; an inherited
:: PowerShell 7 PSModulePath makes Windows PowerShell refuse to load them.
set "PSModulePath="

set "SCRIPT=%TEMP%\temp-remove-ai.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
>>"%SCRIPT%" echo $url = 'https://raw.githubusercontent.com/zoicware/RemoveWindowsAI/main/RemoveWindowsAi.ps1'
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Get-AiPackageCount {
>>"%SCRIPT%" echo     if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return -1 }
>>"%SCRIPT%" echo     $names = 'Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider', 'MicrosoftWindows.Client.CoPilot', 'MicrosoftWindows.Client.AIX'
>>"%SCRIPT%" echo     return @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue ^| Where-Object { $n = $_.Name; $names ^| Where-Object { $n -like "$_*" } }).Count
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $before = Get-AiPackageCount
>>"%SCRIPT%" echo Write-Host "Windows AI packages present before: $before" -ForegroundColor Cyan
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Downloading RemoveWindowsAI..." -ForegroundColor Cyan
>>"%SCRIPT%" echo $local = Join-Path $env:TEMP 'RemoveWindowsAi.ps1'
>>"%SCRIPT%" echo try {
>>"%SCRIPT%" echo     Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
>>"%SCRIPT%" echo } catch {
>>"%SCRIPT%" echo     Write-Host "Could not download RemoveWindowsAI: $($_.Exception.Message)" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo # Downloaded to a file first, then size-checked: piping irm straight into a scriptblock
>>"%SCRIPT%" echo # meant a captive-portal HTML page or a 404 body was executed as if it were the script.
>>"%SCRIPT%" echo if ((Get-Item $local).Length -lt 1000) { Write-Host "Downloaded file is too small to be the real script." -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Removing Windows AI features..." -ForegroundColor Cyan
>>"%SCRIPT%" echo try { ^& $local -nonInteractive -backupMode -EnableLogging -AllOptions }
>>"%SCRIPT%" echo catch { Write-Host "RemoveWindowsAI reported: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $after = Get-AiPackageCount
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($before -lt 0) { Write-Host "Could not enumerate Appx packages; cannot verify." -ForegroundColor Yellow; exit 0 }
>>"%SCRIPT%" echo Write-Host "Windows AI packages present after: $after (was $before)" -ForegroundColor Cyan
>>"%SCRIPT%" echo if ($after -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Some AI packages are still installed. A reboot then a re-run usually clears them." -ForegroundColor Yellow
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Done! No Windows AI packages remain." -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "AI_EXIT=%errorlevel%"
if %AI_EXIT% neq 0 (
    echo.
    echo Windows AI removal finished with exit code %AI_EXIT%.
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %AI_EXIT%
