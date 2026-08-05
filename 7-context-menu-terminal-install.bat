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

set "SCRIPT=%TEMP%\temp-ctxmenu.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo function Add-Failure([string]$name) { if (-not $failures.Contains($name)) { $null = $failures.Add($name) } }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # HKCR is not a PowerShell drive by default.
>>"%SCRIPT%" echo if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo     New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script ^| Out-Null
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Set-ShellEntry([string]$root, [string]$key, [string]$label, [string]$icon, [string]$command) {
>>"%SCRIPT%" echo     $base = "HKCR:\$root\shell\$key"
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         New-Item -Path $base -Force -ErrorAction Stop ^| Out-Null
>>"%SCRIPT%" echo         New-Item -Path "$base\command" -Force -ErrorAction Stop ^| Out-Null
>>"%SCRIPT%" echo         Set-ItemProperty -Path $base -Name '(default)' -Value $label -ErrorAction Stop
>>"%SCRIPT%" echo         if ($icon) { Set-ItemProperty -Path $base -Name 'Icon' -Value $icon -ErrorAction Stop }
>>"%SCRIPT%" echo         Set-ItemProperty -Path "$base\command" -Name '(default)' -Value $command -ErrorAction Stop
>>"%SCRIPT%" echo     } catch { Write-Host "  $root\$key : $($_.Exception.Message)" -ForegroundColor Yellow; Add-Failure "$root\$key"; return }
>>"%SCRIPT%" echo     # Verify by reading back, not by trusting the write.
>>"%SCRIPT%" echo     $back = (Get-ItemProperty -Path "$base\command" -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
>>"%SCRIPT%" echo     if ($back -ne $command) { Write-Host "  $root\$key did not persist" -ForegroundColor Red; Add-Failure "$root\$key" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Remove-ShellEntry([string]$root, [string]$key) {
>>"%SCRIPT%" echo     $base = "HKCR:\$root\shell\$key"
>>"%SCRIPT%" echo     if (Test-Path $base) { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $roots = @('Directory\Background', 'Directory', 'Drive')
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Enabling classic context menu (always show full menu)..." -ForegroundColor Cyan
>>"%SCRIPT%" echo $classicKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
>>"%SCRIPT%" echo New-Item -Path $classicKey -Force ^| Out-Null
>>"%SCRIPT%" echo Set-ItemProperty -Path $classicKey -Name '(default)' -Value '' -Force
>>"%SCRIPT%" echo if (-not (Test-Path $classicKey)) { Write-Host "Classic context menu key missing." -ForegroundColor Red; Add-Failure 'classic context menu' }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Adding 'Open in Terminal as Administrator'..." -ForegroundColor Cyan
:: %%V (not %V) so CMD emits a literal %V for Explorer to substitute. Inside a PowerShell
:: single-quoted string a double quote needs no escaping, so "" here really is two of them.
>>"%SCRIPT%" echo $cmdCommand = 'powershell -WindowStyle Hidden -Command "Start-Process cmd -ArgumentList ''/k cd /d ""%%V""'' -Verb RunAs"'
>>"%SCRIPT%" echo foreach ($r in $roots) { Set-ShellEntry $r 'OpenTerminalAdmin' 'Open in Terminal as Administrator' 'cmd.exe' $cmdCommand }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Adding 'Open in PowerShell as Administrator'..." -ForegroundColor Cyan
>>"%SCRIPT%" echo $psCommand = 'powershell -WindowStyle Hidden -Command "Start-Process powershell -ArgumentList ''-NoExit -Command cd ''''""%%V""'''''' -Verb RunAs"'
>>"%SCRIPT%" echo foreach ($r in $roots) { Set-ShellEntry $r 'OpenPowerShellAdmin' 'Open in PowerShell as Administrator' 'powershell.exe' $psCommand }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Git is installed by Scoop now, so the old hardcoded 'C:\Program Files\Git\git-bash.exe'
>>"%SCRIPT%" echo # points at nothing on a fresh machine and the menu entry silently does nothing.
>>"%SCRIPT%" echo # Resolve the real location instead, and skip the entry entirely if Git is absent.
>>"%SCRIPT%" echo $gitBash = $null
>>"%SCRIPT%" echo $gitCandidates = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo if (Get-Command scoop -ErrorAction SilentlyContinue) {
>>"%SCRIPT%" echo     $p = ^& scoop prefix git 2^>$null 6^>$null
>>"%SCRIPT%" echo     if ($LASTEXITCODE -eq 0 -and $p) { $null = $gitCandidates.Add((Join-Path $p 'git-bash.exe')) }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo if ($gitCmd) { $null = $gitCandidates.Add((Join-Path (Split-Path (Split-Path $gitCmd.Source -Parent) -Parent) 'git-bash.exe')) }
>>"%SCRIPT%" echo $null = $gitCandidates.Add("$env:ProgramFiles\Git\git-bash.exe")
>>"%SCRIPT%" echo $null = $gitCandidates.Add("${env:ProgramFiles(x86)}\Git\git-bash.exe")
>>"%SCRIPT%" echo $gitBash = $gitCandidates ^| Where-Object { $_ -and (Test-Path $_) } ^| Select-Object -First 1
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Removing default 'Git Bash Here' entries..." -ForegroundColor Cyan
>>"%SCRIPT%" echo foreach ($r in 'Directory\Background', 'Directory') { Remove-ShellEntry $r 'git_shell' }
>>"%SCRIPT%" echo if ($gitBash) {
>>"%SCRIPT%" echo     Write-Host "Adding 'Open Git Bash here as Administrator' -> $gitBash" -ForegroundColor Cyan
>>"%SCRIPT%" echo     $gitCommand = 'powershell -WindowStyle Hidden -Command "Start-Process ''' + $gitBash + ''' -ArgumentList ''--cd=""%%V""'' -Verb RunAs"'
>>"%SCRIPT%" echo     foreach ($r in $roots) { Set-ShellEntry $r 'OpenGitBashAdmin' 'Open Git Bash here as Administrator' $gitBash $gitCommand }
>>"%SCRIPT%" echo } else {
>>"%SCRIPT%" echo     Write-Host "git-bash.exe not found; skipping the Git Bash entry." -ForegroundColor Yellow
>>"%SCRIPT%" echo     foreach ($r in $roots) { Remove-ShellEntry $r 'OpenGitBashAdmin' }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $wezTerm = @("$env:ProgramFiles\WezTerm\wezterm-gui.exe", "${env:ProgramFiles(x86)}\WezTerm\wezterm-gui.exe") ^| Where-Object { Test-Path $_ } ^| Select-Object -First 1
>>"%SCRIPT%" echo if (-not $wezTerm -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo     $p = ^& scoop prefix wezterm 2^>$null 6^>$null
>>"%SCRIPT%" echo     if ($LASTEXITCODE -eq 0 -and $p -and (Test-Path (Join-Path $p 'wezterm-gui.exe'))) { $wezTerm = Join-Path $p 'wezterm-gui.exe' }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Removing WezTerm installer default (non-admin) entries..." -ForegroundColor Cyan
>>"%SCRIPT%" echo foreach ($r in $roots) { Remove-ShellEntry $r 'Open WezTerm here' }
>>"%SCRIPT%" echo if ($wezTerm) {
>>"%SCRIPT%" echo     Write-Host "Adding 'Open in WezTerm as Administrator' -> $wezTerm" -ForegroundColor Cyan
>>"%SCRIPT%" echo     $wezCommand = 'powershell -WindowStyle Hidden -Command "Start-Process ''' + $wezTerm + ''' -ArgumentList ''start'',''--no-auto-connect'',''--cwd'',''%%V'' -Verb RunAs"'
>>"%SCRIPT%" echo     foreach ($r in $roots) { Set-ShellEntry $r 'OpenWezTermAdmin' 'Open in WezTerm as Administrator' $wezTerm $wezCommand }
>>"%SCRIPT%" echo } else {
>>"%SCRIPT%" echo     Write-Host "wezterm-gui.exe not found; skipping the WezTerm entry." -ForegroundColor Yellow
>>"%SCRIPT%" echo     foreach ($r in $roots) { Remove-ShellEntry $r 'OpenWezTermAdmin' }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Restarting Explorer..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo Start-Sleep -Seconds ^2
>>"%SCRIPT%" echo if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Context menu setup finished with failures: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Done!" -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "CM_EXIT=%errorlevel%"
if %CM_EXIT% neq 0 (
    echo.
    echo Context menu setup finished with exit code %CM_EXIT%.
    echo Generated script: %SCRIPT%
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %CM_EXIT%
