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

:: ============================================
:: CONFIGURATION - Change these as needed
:: ============================================
set "TARGET_DRIVE=Z:"
set "PCSETUP_DL_TARGET=%TARGET_DRIVE%\Downloads"
:: Set to 1 to move existing files, 0 to just change registry
set "PCSETUP_DL_MOVE=1"
:: ============================================

set "SCRIPT=%TEMP%\temp-move-downloads.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo $dst = $env:PCSETUP_DL_TARGET
>>"%SCRIPT%" echo $moveFiles = ($env:PCSETUP_DL_MOVE -eq '1')
>>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo $guid = '{374DE290-123F-4565-9164-39C4925E467B}'
>>"%SCRIPT%" echo $userKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "=============================================" -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host "  Move Downloads Folder" -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host "=============================================" -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host "Target: $dst"
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Read the CURRENT location instead of assuming %%USERPROFILE%%\Downloads. Re-running
>>"%SCRIPT%" echo # the old version pointed robocopy /MOVE at a source that had already been relocated.
>>"%SCRIPT%" echo $raw = (Get-ItemProperty -Path $userKey -Name $guid -ErrorAction SilentlyContinue).$guid
>>"%SCRIPT%" echo $src = if ($raw) { [Environment]::ExpandEnvironmentVariables($raw) } else { Join-Path $env:USERPROFILE 'Downloads' }
>>"%SCRIPT%" echo Write-Host "Current: $src"
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force ^| Out-Null }
>>"%SCRIPT%" echo if (-not (Test-Path $dst)) { Write-Host "Cannot create $dst" -ForegroundColor Red; exit 1 }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo if ($src -eq $dst) { Write-Host "Downloads is already at the target, nothing to move." -ForegroundColor Yellow }
>>"%SCRIPT%" echo elseif (-not $moveFiles) { Write-Host "MOVE_FILES=0, leaving existing files where they are." -ForegroundColor Yellow }
>>"%SCRIPT%" echo elseif (-not (Test-Path $src)) { Write-Host "Source $src not found, nothing to move." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     Write-Host "Moving existing files (this may take a while)..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     ^& robocopy.exe $src $dst /E /MOVE /R:1 /W:1 /NP /NFL /NDL ^| Out-Null
>>"%SCRIPT%" echo     # robocopy 0-7 = success//informational, 8+ = real failure. Previously discarded.
>>"%SCRIPT%" echo     if ($LASTEXITCODE -ge 8) { Write-Host "robocopy reported failures (exit $LASTEXITCODE); some files were left behind." -ForegroundColor Red; $null = $failures.Add('file move') }
>>"%SCRIPT%" echo     else { Write-Host "Files moved." -ForegroundColor Green }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo Write-Host "Updating registry..." -ForegroundColor Cyan
>>"%SCRIPT%" echo try { New-ItemProperty -Path $userKey -Name $guid -Value $dst -PropertyType ExpandString -Force -ErrorAction Stop ^| Out-Null }
>>"%SCRIPT%" echo catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo $back = (Get-ItemProperty -Path $userKey -Name $guid -ErrorAction SilentlyContinue).$guid
>>"%SCRIPT%" echo if ($back -ne $dst) { Write-Host "Registry value did not persist (is '$back')." -ForegroundColor Red; $null = $failures.Add('registry') }
>>"%SCRIPT%" echo else { Write-Host "Downloads now points at $dst" -ForegroundColor Green }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Finished with failures: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Restarting Explorer to apply changes..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo Start-Sleep -Seconds ^2
>>"%SCRIPT%" echo if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
>>"%SCRIPT%" echo Write-Host "Done!" -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "DL_EXIT=%errorlevel%"
if %DL_EXIT% neq 0 (
    echo.
    echo Downloads relocation finished with exit code %DL_EXIT%.
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %DL_EXIT%
