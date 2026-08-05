@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator (same check as the install scripts; "net session" was the odd
:: one out and does not work identically under all shells)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

setlocal
set "PSModulePath="

set "SCRIPT=%TEMP%\temp-uninstall-ctxmenu.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # .NET registry API: the PowerShell provider would treat a class key named "*" as a
>>"%SCRIPT%" echo # wildcard, and reg.exe from the batch layer gives no usable success signal here.
>>"%SCRIPT%" echo function Remove-HkcrKey([string]$subKey) {
>>"%SCRIPT%" echo     try { [Microsoft.Win32.Registry]::ClassesRoot.DeleteSubKeyTree($subKey, $false) } catch { }
>>"%SCRIPT%" echo     if ([Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($subKey)) {
>>"%SCRIPT%" echo         Write-Host "  still present: HKCR\$subKey" -ForegroundColor Red
>>"%SCRIPT%" echo         $null = $failures.Add($subKey)
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $roots = @('Directory\Background', 'Directory', 'Drive')
>>"%SCRIPT%" echo foreach ($entry in 'OpenTerminalAdmin', 'OpenPowerShellAdmin', 'OpenGitBashAdmin', 'OpenWezTermAdmin') {
>>"%SCRIPT%" echo     Write-Host "Removing $entry..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     foreach ($r in $roots) { Remove-HkcrKey "$r\shell\$entry" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Restoring Windows 11 modern context menu..." -ForegroundColor Cyan
>>"%SCRIPT%" echo $classicKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
>>"%SCRIPT%" echo if (Test-Path $classicKey) { Remove-Item $classicKey -Recurse -Force -ErrorAction SilentlyContinue }
>>"%SCRIPT%" echo if (Test-Path $classicKey) { Write-Host "  classic-menu key still present" -ForegroundColor Red; $null = $failures.Add('classic menu CLSID') }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Restarting Explorer..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo Start-Sleep -Seconds ^2
>>"%SCRIPT%" echo if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Uninstall finished with leftovers: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Done!" -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "UN_EXIT=%errorlevel%"
if %UN_EXIT% neq 0 (
    echo.
    echo Context menu uninstall finished with exit code %UN_EXIT%.
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %UN_EXIT%
