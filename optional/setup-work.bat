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

set "SCRIPT=%TEMP%\temp-work-setup.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
>>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo function Add-Failure([string]$name) { if (-not $failures.Contains($name)) { $null = $failures.Add($name) } }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "=== Work Apps Setup ===" -ForegroundColor Cyan
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Refresh-SetupEnvironment {
>>"%SCRIPT%" echo     $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
>>"%SCRIPT%" echo     $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
>>"%SCRIPT%" echo     $extra = @("$env:USERPROFILE\scoop\shims", "$env:ProgramData\scoop\shims")
>>"%SCRIPT%" echo     $env:Path = (@($machinePath, $userPath) + $extra ^| Where-Object { -not [string]::IsNullOrWhiteSpace($_) } ^| Select-Object -Unique) -join ';'
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Detection via "scoop prefix", not the text of "scoop list": a failed install stays
>>"%SCRIPT%" echo # listed forever with Info='Install failed' and would be read as already installed.
>>"%SCRIPT%" echo function Test-ScoopApp([string]$package) {
>>"%SCRIPT%" echo     $prefix = ^& scoop prefix $package 2^>$null 6^>$null
>>"%SCRIPT%" echo     return ($LASTEXITCODE -eq 0 -and $prefix -and (Test-Path $prefix))
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo function Install-ScoopApp([string]$package, [string]$displayName = $package) {
>>"%SCRIPT%" echo     Refresh-SetupEnvironment
>>"%SCRIPT%" echo     if (Test-ScoopApp $package) { Write-Host "$displayName already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $displayName via Scoop..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try { ^& scoop install $package } catch { Write-Host "$displayName install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Test-ScoopApp $package) { Write-Host "$displayName installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "$displayName FAILED to install." -ForegroundColor Red; Add-Failure $displayName }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Test-WingetApp([string]$id) {
>>"%SCRIPT%" echo     ^& winget list --id $id -e --accept-source-agreements ^> $null 2^>^&1
>>"%SCRIPT%" echo     return ($LASTEXITCODE -eq 0)
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo function Install-WingetApp([string]$id, [string]$displayName = $id) {
>>"%SCRIPT%" echo     if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Host "winget missing; cannot install $displayName." -ForegroundColor Red; Add-Failure $displayName; return }
>>"%SCRIPT%" echo     if (Test-WingetApp $id) { Write-Host "$displayName already installed, skipping..." -ForegroundColor Yellow; return }
>>"%SCRIPT%" echo     Write-Host "Installing $displayName via winget..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     # -e (exact id) matters: without it winget can match a different package entirely.
>>"%SCRIPT%" echo     try { ^& winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements } catch { Write-Host "$displayName install error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     if (Test-WingetApp $id) { Write-Host "$displayName installed." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "$displayName FAILED to install." -ForegroundColor Red; Add-Failure $displayName }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Refresh-SetupEnvironment
>>"%SCRIPT%" echo if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo     Write-Host "Scoop is missing. Run 0-init-prereqs.bat first." -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Install-ScoopApp 'slack' 'Slack'
>>"%SCRIPT%" echo Install-ScoopApp 'aws' 'AWS CLI'
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $wingetApps = @(
>>"%SCRIPT%" echo     @{ Id = 'LinearOrbit.Linear';    Name = 'Linear' },
>>"%SCRIPT%" echo     @{ Id = 'Figma.Figma';           Name = 'Figma' },
>>"%SCRIPT%" echo     @{ Id = 'Docker.DockerDesktop';  Name = 'Docker Desktop' },
>>"%SCRIPT%" echo     @{ Id = 'Codeium.Windsurf';      Name = 'Windsurf' }
>>"%SCRIPT%" echo )
>>"%SCRIPT%" echo foreach ($entry in $wingetApps) { Install-WingetApp $entry.Id $entry.Name }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "=== Setup finished with failures: $($failures -join ', ') ===" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "=== Setup Complete ===" -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "WK_EXIT=%errorlevel%"
if %WK_EXIT% neq 0 (
    echo.
    echo Work setup finished with exit code %WK_EXIT%.
    echo Generated script: %SCRIPT%
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %WK_EXIT%
