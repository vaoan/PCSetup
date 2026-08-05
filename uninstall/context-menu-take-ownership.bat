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
set "PSModulePath="

set "SCRIPT=%TEMP%\temp-uninstall-takeownership.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # .NET registry API: the file-class key is literally named "*", which the PowerShell
>>"%SCRIPT%" echo # registry provider treats as a wildcard (it hangs enumerating HKCR).
>>"%SCRIPT%" echo function Remove-HkcrKey([string]$subKey) {
>>"%SCRIPT%" echo     try { [Microsoft.Win32.Registry]::ClassesRoot.DeleteSubKeyTree($subKey, $false) } catch { }
>>"%SCRIPT%" echo     if ([Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($subKey)) {
>>"%SCRIPT%" echo         Write-Host "  still present: HKCR\$subKey" -ForegroundColor Red
>>"%SCRIPT%" echo         $null = $failures.Add($subKey)
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Removing 'Take Ownership' from context menu..." -ForegroundColor Cyan
>>"%SCRIPT%" echo foreach ($k in '*\shell\TakeOwnership', 'Directory\shell\TakeOwnership', 'Drive\shell\runas') { Remove-HkcrKey $k }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Long paths support is deliberately left enabled: 9-context-menu-take-ownership.bat
>>"%SCRIPT%" echo # turns it on, but other tooling depends on it and turning it back off would break
>>"%SCRIPT%" echo # deep node_modules trees. Remove it by hand if you really want it off.
>>"%SCRIPT%" echo Write-Host "Leaving LongPathsEnabled untouched (other tooling relies on it)." -ForegroundColor Yellow
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
    echo Take Ownership uninstall finished with exit code %UN_EXIT%.
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %UN_EXIT%
