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

set "SCRIPT=%TEMP%\temp-takeownership.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo function Add-Failure([string]$name) { if (-not $failures.Contains($name)) { $null = $failures.Add($name) } }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # These values are written with the .NET registry API rather than reg.exe or the
>>"%SCRIPT%" echo # PowerShell registry provider, because every other route mangles them:
>>"%SCRIPT%" echo #  * From the batch layer, quote parity put the command separator outside the quotes,
>>"%SCRIPT%" echo #    so CMD split the line and reg.exe stored a truncated command - Take Ownership
>>"%SCRIPT%" echo #    ran takeown but never icacls, leaving permissions half-applied.
>>"%SCRIPT%" echo #  * reg.exe called from PowerShell drops empty-string arguments (so /d "" for
>>"%SCRIPT%" echo #    HasLUAShield became "Invalid syntax") and mangles embedded double quotes.
>>"%SCRIPT%" echo #  * The PowerShell registry provider treats the file-class key named "*" as a
>>"%SCRIPT%" echo #    wildcard, so New-Item hangs enumerating HKCR.
>>"%SCRIPT%" echo # SetValue takes the string verbatim - no parser in between.
>>"%SCRIPT%" echo function Set-HkcrValue([string]$subKey, [string]$name, [string]$value) {
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $k = [Microsoft.Win32.Registry]::ClassesRoot.CreateSubKey($subKey)
>>"%SCRIPT%" echo         if (-not $k) { throw "CreateSubKey returned null" }
>>"%SCRIPT%" echo         $k.SetValue($name, $value, [Microsoft.Win32.RegistryValueKind]::String)
>>"%SCRIPT%" echo         $k.Close()
>>"%SCRIPT%" echo         return $true
>>"%SCRIPT%" echo     } catch { Write-Host "  $subKey ($name): $($_.Exception.Message)" -ForegroundColor Yellow; Add-Failure "$subKey\$name"; return $false }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo function Get-HkcrValue([string]$subKey, [string]$name) {
>>"%SCRIPT%" echo     $k = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($subKey)
>>"%SCRIPT%" echo     if (-not $k) { return $null }
>>"%SCRIPT%" echo     $v = $k.GetValue($name)
>>"%SCRIPT%" echo     $k.Close()
>>"%SCRIPT%" echo     return $v
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo function Remove-HkcrKey([string]$subKey) {
>>"%SCRIPT%" echo     try { [Microsoft.Win32.Registry]::ClassesRoot.DeleteSubKeyTree($subKey, $false) } catch { }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Enabling Long Paths support..." -ForegroundColor Cyan
>>"%SCRIPT%" echo $fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
>>"%SCRIPT%" echo try { Set-ItemProperty -Path $fsKey -Name LongPathsEnabled -Value 1 -Type DWord -Force -ErrorAction Stop } catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo if ((Get-ItemProperty $fsKey -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled -eq 1) { Write-Host "Long paths enabled." -ForegroundColor Green }
>>"%SCRIPT%" echo else { Write-Host "LongPathsEnabled did not persist." -ForegroundColor Red; Add-Failure 'LongPathsEnabled' }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Adding 'Take Ownership' to context menu..." -ForegroundColor Cyan
>>"%SCRIPT%" echo foreach ($k in '*\shell\TakeOwnership', '*\shell\runas', 'Directory\shell\TakeOwnership', 'Directory\shell\runas', 'Drive\shell\runas') { Remove-HkcrKey $k }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $amp = ([char]38).ToString() * 2
>>"%SCRIPT%" echo $q = ([char]34).ToString()
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Install-TakeOwnership([string]$key, [hashtable]$values, [string]$command) {
>>"%SCRIPT%" echo     foreach ($n in $values.Keys) { $null = Set-HkcrValue $key $n $values[$n] }
>>"%SCRIPT%" echo     $null = Set-HkcrValue "$key\command" '' $command
>>"%SCRIPT%" echo     $null = Set-HkcrValue "$key\command" 'IsolatedCommand' $command
>>"%SCRIPT%" echo     $back = Get-HkcrValue "$key\command" ''
>>"%SCRIPT%" echo     if ($back -ne $command) { Write-Host "  $key\command did not persist intact" -ForegroundColor Red; Add-Failure "$key\command" }
>>"%SCRIPT%" echo     elseif ($back -notmatch 'icacls') { Write-Host "  $key\command is missing the icacls half" -ForegroundColor Red; Add-Failure "$key\command" }
>>"%SCRIPT%" echo     else { Write-Host "  HKCR\$key OK" -ForegroundColor Green }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Files
>>"%SCRIPT%" echo $fileCmd = "powershell -windowstyle hidden -command ${q}Start-Process cmd -ArgumentList '/c takeown /f \${q}%%1\${q} $amp icacls \${q}%%1\${q} /grant *S-1-3-4:F /t /c /l' -Verb runAs${q}"
>>"%SCRIPT%" echo Install-TakeOwnership '*\shell\TakeOwnership' @{ '' = 'Take Ownership'; 'HasLUAShield' = ''; 'NoWorkingDirectory' = ''; 'NeverDefault' = '' } $fileCmd
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Directories - recursive, excluded from the system folders you must never reown
>>"%SCRIPT%" echo $dirCmd = "powershell -windowstyle hidden -command ${q}Start-Process cmd -ArgumentList '/c takeown /f \${q}%%1\${q} /r /d y $amp icacls \${q}%%1\${q} /grant *S-1-3-4:F /t /c /l /q' -Verb runAs${q}"
>>"%SCRIPT%" echo $dirApplies = 'NOT (System.ItemPathDisplay:="C:\Users" OR System.ItemPathDisplay:="C:\ProgramData" OR System.ItemPathDisplay:="C:\Windows" OR System.ItemPathDisplay:="C:\Windows\System32" OR System.ItemPathDisplay:="C:\Program Files" OR System.ItemPathDisplay:="C:\Program Files (x86)")'
>>"%SCRIPT%" echo Install-TakeOwnership 'Directory\shell\TakeOwnership' @{ '' = 'Take Ownership'; 'HasLUAShield' = ''; 'NoWorkingDirectory' = ''; 'Position' = 'middle'; 'AppliesTo' = $dirApplies } $dirCmd
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Drives - the 'runas' verb self-elevates; the path needs a trailing backslash
>>"%SCRIPT%" echo $driveCmd = "cmd.exe /c takeown /f ${q}%%1\${q} /r /d y $amp icacls ${q}%%1\${q} /grant *S-1-3-4:F /t /c"
>>"%SCRIPT%" echo Install-TakeOwnership 'Drive\shell\runas' @{ '' = 'Take Ownership'; 'HasLUAShield' = ''; 'NoWorkingDirectory' = ''; 'Position' = 'middle'; 'AppliesTo' = 'NOT (System.ItemPathDisplay:="C:\")' } $driveCmd
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Take Ownership setup finished with failures: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Done!" -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "TO_EXIT=%errorlevel%"
if %TO_EXIT% neq 0 (
    echo.
    echo Take Ownership setup finished with exit code %TO_EXIT%.
    echo Generated script: %SCRIPT%
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %TO_EXIT%
