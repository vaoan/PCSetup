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

:: Win11Debloat and the OneDrive cleanup lean on Get-AppxPackage / Get-ScheduledTask, which live
:: in modules. An inherited PowerShell 7 PSModulePath makes Windows PowerShell refuse to load
:: them, so the debloat would appear to run and remove nothing.
set "PSModulePath="

set "SCRIPT=%TEMP%\temp-debloat.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
>>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo function Add-Failure([string]$name) { if (-not $failures.Contains($name)) { $null = $failures.Add($name) } }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $targets = 'Microsoft.OneDrive','Microsoft.YourPhone','Microsoft.WindowsCamera','Microsoft.Windows.Photos','Microsoft.ZuneMusic','Microsoft.RemoteDesktop','Microsoft.Whiteboard'
>>"%SCRIPT%" echo function Get-RemainingTargets {
>>"%SCRIPT%" echo     if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return $null }
>>"%SCRIPT%" echo     return @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue ^| Where-Object { $targets -contains $_.Name } ^| ForEach-Object { $_.Name } ^| Select-Object -Unique)
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $before = Get-RemainingTargets
>>"%SCRIPT%" echo if ($null -eq $before) { Write-Host "Get-AppxPackage unavailable; cannot manage Appx packages." -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo Write-Host "Target apps present before: $(if ($before.Count) { $before -join ', ' } else { 'none' })" -ForegroundColor Cyan
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Running Win11Debloat (RunDefaults + Remove apps + Silent)..." -ForegroundColor Cyan
>>"%SCRIPT%" echo $debloat = Join-Path $env:TEMP 'Win11Debloat.ps1'
>>"%SCRIPT%" echo try { Invoke-WebRequest -Uri 'https://debloat.raphi.re/' -OutFile $debloat -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop }
>>"%SCRIPT%" echo catch { Write-Host "Could not download Win11Debloat: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo # Saved to a file and size-checked first: piping irm straight into a scriptblock would
>>"%SCRIPT%" echo # happily execute a captive-portal page or an error body as if it were the script.
>>"%SCRIPT%" echo if ((Get-Item $debloat).Length -lt 1000) { Write-Host "Downloaded Win11Debloat is too small to be real." -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo try { ^& $debloat -RunDefaults -RemoveApps -Apps ($targets -join ',') -Silent }
>>"%SCRIPT%" echo catch { Write-Host "Win11Debloat reported: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Removing OneDrive leftovers..." -ForegroundColor Cyan
>>"%SCRIPT%" echo $oneDriveExe = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'
>>"%SCRIPT%" echo if (Test-Path $oneDriveExe) {
>>"%SCRIPT%" echo     Start-Process -FilePath $oneDriveExe -ArgumentList '/shutdown' -Wait -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo     Start-Process -FilePath $oneDriveExe -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo foreach ($setup in @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe")) {
>>"%SCRIPT%" echo     if (Test-Path $setup) { Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Start-Sleep -Seconds ^2
>>"%SCRIPT%" echo Get-Process OneDrive,OneDriveStandaloneUpdater,FileCoAuth -ErrorAction SilentlyContinue ^| Stop-Process -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo Get-AppxPackage -AllUsers Microsoft.OneDrive -ErrorAction SilentlyContinue ^| Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
>>"%SCRIPT%" echo if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force ^| Out-Null }
>>"%SCRIPT%" echo New-ItemProperty -Path $policyPath -Name 'DisableFileSyncNGSC' -PropertyType DWord -Value 1 -Force ^| Out-Null
>>"%SCRIPT%" echo foreach ($runPath in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
>>"%SCRIPT%" echo     Remove-ItemProperty -Path $runPath -Name 'OneDrive' -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Get-ScheduledTask -ErrorAction SilentlyContinue ^| Where-Object { $_.TaskName -like 'OneDrive*' } ^| Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo foreach ($nsPath in @('Registry::HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}','Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}')) {
>>"%SCRIPT%" echo     if (Test-Path $nsPath) { New-ItemProperty -Path $nsPath -Name 'System.IsPinnedToNameSpaceTree' -PropertyType DWord -Value 0 -Force ^| Out-Null }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo Start-Sleep -Seconds ^2
>>"%SCRIPT%" echo Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' -Recurse -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' -Recurse -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo foreach ($folder in @("$env:UserProfile\OneDrive", "$env:LocalAppData\Microsoft\OneDrive", "$env:ProgramData\Microsoft OneDrive", "$env:SystemDrive\OneDriveTemp")) {
>>"%SCRIPT%" echo     if (Test-Path $folder) { Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Start-Sleep -Seconds ^1
>>"%SCRIPT%" echo if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Verify rather than trusting the remote script's exit code.
>>"%SCRIPT%" echo $after = Get-RemainingTargets
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo Write-Host "Target apps still present: $(if ($after.Count) { $after -join ', ' } else { 'none' })" -ForegroundColor Cyan
>>"%SCRIPT%" echo if ($after.Count -gt 0) { Write-Host "Some apps survived removal - they are often reprovisioned until the next reboot." -ForegroundColor Yellow; foreach ($a in $after) { Add-Failure $a } }
>>"%SCRIPT%" echo if (Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe')) { Write-Host "OneDrive.exe is still present." -ForegroundColor Yellow; Add-Failure 'OneDrive' }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Debloat finished with leftovers: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     Write-Host "Reboot and re-run to clear reprovisioned apps." -ForegroundColor Yellow
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Done! All targeted apps removed." -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "DB_EXIT=%errorlevel%"
if %DB_EXIT% neq 0 (
    echo.
    echo Debloat finished with exit code %DB_EXIT%.
    echo Generated script: %SCRIPT%
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %DB_EXIT%
