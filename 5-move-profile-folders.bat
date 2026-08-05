@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check
setlocal EnableExtensions EnableDelayedExpansion

if "%PCSETUP_CI%"=="1" (
    echo SKIP: CI mode - skipping profile folder move
    exit /b 0
)

set "PSModulePath="

:: ============================================
:: CONFIGURATION
:: Loaded from profile-folders.config (next to this script)
:: ============================================
set "TARGET_DRIVE=Z:"
set "TARGET_PROFILE_FOLDER=%USERNAME%"
:: Set to 1 to move existing files, 0 to just change registry
set "MOVE_FILES=1"

set "CONFIG_FILE=%~dp0profile-folders.config"
if exist "%CONFIG_FILE%" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%CONFIG_FILE%") do (
        set "CFG_KEY=%%~A"
        set "CFG_VALUE=%%~B"
        if /I "!CFG_KEY!"=="TARGET_DRIVE" set "TARGET_DRIVE=!CFG_VALUE!"
        if /I "!CFG_KEY!"=="TARGET_PROFILE_FOLDER" set "TARGET_PROFILE_FOLDER=!CFG_VALUE!"
        if /I "!CFG_KEY!"=="MOVE_FILES" set "MOVE_FILES=!CFG_VALUE!"
    )
)

if "%TARGET_DRIVE%"=="" set "TARGET_DRIVE=Z:"
if "%TARGET_PROFILE_FOLDER%"=="" set "TARGET_PROFILE_FOLDER=%USERNAME%"
if /I "%TARGET_PROFILE_FOLDER%"=="AUTO" set "TARGET_PROFILE_FOLDER=%USERNAME%"
if "%MOVE_FILES%"=="" set "MOVE_FILES=1"
if not "%TARGET_DRIVE:~-1%"==":" set "TARGET_DRIVE=%TARGET_DRIVE%:"
set "PCSETUP_TARGET_BASE=%TARGET_DRIVE%\Users\%TARGET_PROFILE_FOLDER%"
set "PCSETUP_MOVE_FILES=%MOVE_FILES%"
:: ============================================

set "SCRIPT=%TEMP%\temp-move-profile.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo $base = $env:PCSETUP_TARGET_BASE
>>"%SCRIPT%" echo $moveFiles = ($env:PCSETUP_MOVE_FILES -eq '1')
>>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo function Add-Failure([string]$name) { if (-not $failures.Contains($name)) { $null = $failures.Add($name) } }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "=============================================" -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host "  Windows Profile Folders Relocation Script" -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host "=============================================" -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host "Target location  : $base"
>>"%SCRIPT%" echo Write-Host "Move existing    : $moveFiles"
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Name = folder name under $base; User/Legacy = registry value names.
>>"%SCRIPT%" echo # Legacy '' means the folder has no entry in the old "Shell Folders" key.
>>"%SCRIPT%" echo $folders = @(
>>"%SCRIPT%" echo     @{ Name = 'Desktop';     User = 'Desktop';                                 Legacy = 'Desktop' },
>>"%SCRIPT%" echo     @{ Name = 'Documents';   User = 'Personal';                                Legacy = 'Personal' },
>>"%SCRIPT%" echo     @{ Name = 'Documents';   User = '{F42EE2D3-909F-4907-8871-4C22FC0BF756}';  Legacy = '' },
>>"%SCRIPT%" echo     @{ Name = 'Music';       User = 'My Music';                                Legacy = 'My Music' },
>>"%SCRIPT%" echo     @{ Name = 'Pictures';    User = 'My Pictures';                             Legacy = 'My Pictures' },
>>"%SCRIPT%" echo     @{ Name = 'Videos';      User = 'My Video';                                Legacy = 'My Video' },
>>"%SCRIPT%" echo     @{ Name = '3D Objects';  User = '{31C0DD25-9439-4F12-BF41-7FF4EDA38722}';  Legacy = '' },
>>"%SCRIPT%" echo     @{ Name = 'Favorites';   User = 'Favorites';                               Legacy = 'Favorites' },
>>"%SCRIPT%" echo     @{ Name = 'Contacts';    User = '{56784854-C6CB-462B-8169-88E350ACB882}';  Legacy = '' },
>>"%SCRIPT%" echo     @{ Name = 'Links';       User = '{BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968}';  Legacy = '' },
>>"%SCRIPT%" echo     @{ Name = 'Saved Games'; User = '{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}';  Legacy = '' },
>>"%SCRIPT%" echo     @{ Name = 'Searches';    User = '{7D1D3A04-DEBB-4115-95CF-2F29DA2920DA}';  Legacy = '' }
>>"%SCRIPT%" echo )
>>"%SCRIPT%" echo $userKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
>>"%SCRIPT%" echo $legacyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Creating target folders..." -ForegroundColor Cyan
>>"%SCRIPT%" echo foreach ($name in ($folders ^| ForEach-Object { $_.Name } ^| Select-Object -Unique)) {
>>"%SCRIPT%" echo     $dst = Join-Path $base $name
>>"%SCRIPT%" echo     if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force ^| Out-Null }
>>"%SCRIPT%" echo     if (-not (Test-Path $dst)) { Write-Host "  cannot create $dst" -ForegroundColor Red; Add-Failure "create $name" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo if ($moveFiles) {
>>"%SCRIPT%" echo     Write-Host ""
>>"%SCRIPT%" echo     Write-Host "Moving existing files (this may take a while)..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     # Dedupe by folder name with an explicit set. "Group-Object Name" cannot be used:
>>"%SCRIPT%" echo     # in Windows PowerShell 5.1 it does not resolve hashtable keys as properties, so all
>>"%SCRIPT%" echo     # 12 rows collapse into ONE group and only Desktop gets moved - while the registry
>>"%SCRIPT%" echo     # below still repoints all 11 folders. PowerShell 7 groups correctly, so this looks
>>"%SCRIPT%" echo     # fine when tested by hand in pwsh and silently loses files under the 5.1 the .bat runs.
>>"%SCRIPT%" echo     $seen = @{}
>>"%SCRIPT%" echo     foreach ($f in $folders) {
>>"%SCRIPT%" echo         if ($seen.ContainsKey($f.Name)) { continue }
>>"%SCRIPT%" echo         $seen[$f.Name] = $true
>>"%SCRIPT%" echo         $dst = Join-Path $base $f.Name
>>"%SCRIPT%" echo         # Read the CURRENT location from the registry, expanding %USERPROFILE% etc.
>>"%SCRIPT%" echo         $raw = (Get-ItemProperty -Path $userKey -Name $f.User -ErrorAction SilentlyContinue).($f.User)
>>"%SCRIPT%" echo         $src = if ($raw) { [Environment]::ExpandEnvironmentVariables($raw) } else { Join-Path $env:USERPROFILE $f.Name }
>>"%SCRIPT%" echo         if ($src -eq $dst) { Write-Host "  $($f.Name): already at target, skipping" -ForegroundColor Yellow; continue }
>>"%SCRIPT%" echo         if (-not (Test-Path $src)) { Write-Host "  $($f.Name): source not found ($src), skipping" -ForegroundColor Yellow; continue }
>>"%SCRIPT%" echo         Write-Host "  $($f.Name): $src -> $dst" -ForegroundColor Cyan
>>"%SCRIPT%" echo         ^& robocopy.exe $src $dst /E /MOVE /R:1 /W:1 /NP /NFL /NDL ^| Out-Null
>>"%SCRIPT%" echo         # robocopy exit codes: 0-7 are success//informational, 8+ are real failures.
>>"%SCRIPT%" echo         # The old version discarded this entirely, so files left behind because they
>>"%SCRIPT%" echo         # were open or access-denied were reported as a completed move.
>>"%SCRIPT%" echo         if ($LASTEXITCODE -ge 8) {
>>"%SCRIPT%" echo             Write-Host "    robocopy reported failures (exit $LASTEXITCODE); some files were left behind." -ForegroundColor Red
>>"%SCRIPT%" echo             Add-Failure "move $($f.Name)"
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo Write-Host "Updating registry..." -ForegroundColor Cyan
>>"%SCRIPT%" echo foreach ($f in $folders) {
>>"%SCRIPT%" echo     $dst = Join-Path $base $f.Name
>>"%SCRIPT%" echo     try { New-ItemProperty -Path $userKey -Name $f.User -Value $dst -PropertyType ExpandString -Force -ErrorAction Stop ^| Out-Null }
>>"%SCRIPT%" echo     catch { Write-Host "  $($f.User): $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     $back = (Get-ItemProperty -Path $userKey -Name $f.User -ErrorAction SilentlyContinue).($f.User)
>>"%SCRIPT%" echo     if ($back -ne $dst) { Write-Host "  $($f.User) did not persist" -ForegroundColor Red; Add-Failure "reg $($f.User)" }
>>"%SCRIPT%" echo     if ($f.Legacy) {
>>"%SCRIPT%" echo         try { New-ItemProperty -Path $legacyKey -Name $f.Legacy -Value $dst -PropertyType String -Force -ErrorAction Stop ^| Out-Null } catch { }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo Write-Host "New locations:" -ForegroundColor Green
>>"%SCRIPT%" echo foreach ($name in ($folders ^| ForEach-Object { $_.Name } ^| Select-Object -Unique)) { Write-Host ("  {0,-12} {1}" -f $name, (Join-Path $base $name)) }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Profile relocation finished with failures: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     Write-Host "Close any app holding those files (or log out/in) and re-run." -ForegroundColor Yellow
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Restarting Explorer to apply changes..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo Start-Sleep -Seconds ^2
>>"%SCRIPT%" echo if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
>>"%SCRIPT%" echo Write-Host "Done! If some apps still show old paths, restart them or log out/in." -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "PF_EXIT=%errorlevel%"
if %PF_EXIT% neq 0 (
    echo.
    echo Profile folder relocation finished with exit code %PF_EXIT%.
    echo Generated script: %SCRIPT%
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %PF_EXIT%
