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

:: Set-ExecutionPolicy lives in Microsoft.PowerShell.Security. If Windows PowerShell inherits
:: PowerShell 7's PSModulePath it finds the Core-only copy first, refuses to load it, and the
:: cmdlet does not exist - this script then "succeeded" while changing nothing at all.
set "PSModulePath="

set "SCRIPT=%TEMP%\temp-execpolicy.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo $target = 'RemoteSigned'
>>"%SCRIPT%" echo if (-not (Get-Command Set-ExecutionPolicy -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo     Write-Host "Set-ExecutionPolicy is unavailable (Microsoft.PowerShell.Security failed to load)." -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $current = Get-ExecutionPolicy -Scope CurrentUser
>>"%SCRIPT%" echo if ($current -eq $target) { Write-Host "CurrentUser execution policy is already $target." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     Write-Host "Setting CurrentUser execution policy to $target (was $current)..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try { Set-ExecutionPolicy -ExecutionPolicy $target -Scope CurrentUser -Force -ErrorAction Stop }
>>"%SCRIPT%" echo     catch { Write-Host "Failed to set execution policy: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Verify the value actually stuck.
>>"%SCRIPT%" echo $now = Get-ExecutionPolicy -Scope CurrentUser
>>"%SCRIPT%" echo if ($now -ne $target) {
>>"%SCRIPT%" echo     Write-Host "CurrentUser execution policy is '$now', expected '$target'." -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # The scope that actually applies is the most restrictive one that is set. A Group
>>"%SCRIPT%" echo # Policy scope outranks CurrentUser, so the write can succeed while the effective
>>"%SCRIPT%" echo # policy stays Restricted - report that instead of claiming success.
>>"%SCRIPT%" echo $effective = Get-ExecutionPolicy
>>"%SCRIPT%" echo Write-Host "CurrentUser: $now   Effective: $effective" -ForegroundColor Green
>>"%SCRIPT%" echo if ($effective -in @('Restricted', 'AllSigned')) {
>>"%SCRIPT%" echo     Write-Host "Effective policy is still '$effective' - a higher-precedence scope is overriding it:" -ForegroundColor Red
>>"%SCRIPT%" echo     Get-ExecutionPolicy -List ^| Format-Table -AutoSize ^| Out-String ^| Write-Host
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Execution policy updated. You can now run 'claude' directly in PowerShell." -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "EP_EXIT=%errorlevel%"
if %EP_EXIT% neq 0 (
    echo.
    echo Execution policy setup failed with exit code %EP_EXIT%.
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %EP_EXIT%
