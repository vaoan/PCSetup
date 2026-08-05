@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator (preserving the chosen action across elevation)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -ArgumentList '%1' -Verb RunAs"
    exit /b
)
:after_admin_check

setlocal
set "PSModulePath="

:: Accepts "backup" or "restore" as an argument so it can run unattended, per the repo's
:: no-pauses rule. With no argument it still prompts, which is the interactive convenience path.
set "ACTION=%~1"
if /I "%ACTION%"=="backup"  goto :have_action
if /I "%ACTION%"=="restore" goto :have_action
if /I "%ACTION%"=="1" set "ACTION=backup" & goto :have_action
if /I "%ACTION%"=="2" set "ACTION=restore" & goto :have_action

echo.
echo  Start Menu Backup/Restore Tool
echo  ===============================
echo.
echo  [1] Backup current Start Menu layout
echo  [2] Restore Start Menu layout from backup
echo.
set "choice="
set /p choice="Select option (1 or 2): "
if "%choice%"=="1" set "ACTION=backup"
if "%choice%"=="2" set "ACTION=restore"
if not defined ACTION (
    echo Invalid option. Pass "backup" or "restore" to run unattended.
    endlocal & exit /b 1
)

:have_action
set "PCSETUP_SM_ACTION=%ACTION%"
set "PCSETUP_SM_BACKUP=%~dp0start-menu-backup.bin"

set "SCRIPT=%TEMP%\temp-start-menu.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo $action = $env:PCSETUP_SM_ACTION
>>"%SCRIPT%" echo $backup = $env:PCSETUP_SM_BACKUP
>>"%SCRIPT%" echo $startMenu = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin'
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo if ($action -eq 'backup') {
>>"%SCRIPT%" echo     Write-Host "Backing up Start Menu layout..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     if (-not (Test-Path $startMenu)) { Write-Host "Start Menu file not found: $startMenu" -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo     try { Copy-Item $startMenu $backup -Force -ErrorAction Stop } catch { Write-Host "Backup failed: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo     # Verify by size, not by the copy not throwing: a 0-byte backup would restore an
>>"%SCRIPT%" echo     # empty Start Menu and the old script would still have printed SUCCESS.
>>"%SCRIPT%" echo     if (-not (Test-Path $backup) -or (Get-Item $backup).Length -lt 1) { Write-Host "Backup file is missing or empty." -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo     if ((Get-Item $backup).Length -ne (Get-Item $startMenu).Length) { Write-Host "Backup size does not match the source." -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo     Write-Host "Backed up $((Get-Item $backup).Length) bytes to $backup" -ForegroundColor Green
>>"%SCRIPT%" echo     exit 0
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Restoring Start Menu layout..." -ForegroundColor Cyan
>>"%SCRIPT%" echo if (-not (Test-Path $backup)) {
>>"%SCRIPT%" echo     Write-Host "Backup file not found: $backup" -ForegroundColor Red
>>"%SCRIPT%" echo     Write-Host "Run this script with 'backup' first." -ForegroundColor Yellow
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo if ((Get-Item $backup).Length -lt 1) { Write-Host "Backup file is empty; refusing to restore." -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo $dir = Split-Path $startMenu -Parent
>>"%SCRIPT%" echo if (-not (Test-Path $dir)) { Write-Host "Start Menu state folder not found: $dir" -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo Write-Host "Stopping Start Menu..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo Start-Sleep -Seconds ^2
>>"%SCRIPT%" echo try { Copy-Item $backup $startMenu -Force -ErrorAction Stop } catch { Write-Host "Restore failed: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo if ((Get-Item $startMenu).Length -ne (Get-Item $backup).Length) { Write-Host "Restored file size does not match the backup." -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo Write-Host "Start Menu layout restored. Press the Windows key to see it." -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "SM_EXIT=%errorlevel%"
if %SM_EXIT% neq 0 (
    echo.
    echo Start Menu %ACTION% finished with exit code %SM_EXIT%.
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %SM_EXIT%
