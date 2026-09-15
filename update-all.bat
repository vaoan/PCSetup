@echo off
if /I "%PCSETUP_GENERATE_ONLY%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

setlocal

:: Windows PowerShell must not inherit PowerShell 7's PSModulePath. If it does, it finds the
:: Core-only Microsoft.PowerShell.Utility/Security first and refuses to load them, so cmdlets
:: start disappearing. Clearing it here (inside setlocal) makes powershell.exe rebuild its own.
set "PSModulePath="

set "SCRIPT=%TEMP%\temp-update-all.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

:: Updates everything the numbered setup scripts install, through the package manager that
:: installed it, then runs Patch My PC as a sweep for the direct-download apps (Discord Canary,
:: Chrome Remote Desktop, Mudfish, IceDrive...). Same shape as every other script here:
:: check -> act -> verify -> record. Nothing is trusted on exit code alone; every manager is
:: asked again afterwards what is still outdated, and that list is the failure list.
::
:: Redirection goes FIRST on every line (`>>"%SCRIPT%" echo ...`): written the other way round,
:: a line ending in a standalone digit is read by CMD as a file-handle redirect. Inside these
:: lines `|` `>` `&` are escaped with `^` only OUTSIDE double quotes; inside quotes they are
:: already literal and a caret would be stored verbatim.
>"%SCRIPT%" echo [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
>>"%SCRIPT%" echo [Console]::OutputEncoding = [Text.Encoding]::UTF8
>>"%SCRIPT%" echo $ErrorActionPreference = 'Continue'
>>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo $notes = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo $logDir = Join-Path $env:LOCALAPPDATA 'PCSetup'
>>"%SCRIPT%" echo New-Item -ItemType Directory -Path $logDir -Force ^| Out-Null
>>"%SCRIPT%" echo $logPath = Join-Path $logDir 'update-all.log'
>>"%SCRIPT%" echo # The window closes on its own when done, so the transcript is the only durable record.
>>"%SCRIPT%" echo try { Start-Transcript -Path $logPath -Append ^| Out-Null } catch { Write-Host "Transcript unavailable: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo $started = Get-Date
>>"%SCRIPT%" echo Write-Host "Starting update-all at $started" -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host "Log: $logPath" -ForegroundColor DarkGray
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Refresh-SetupEnvironment {
>>"%SCRIPT%" echo     $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
>>"%SCRIPT%" echo     $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
>>"%SCRIPT%" echo     $pathParts = @($machinePath, $userPath) ^| Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
>>"%SCRIPT%" echo     $env:Path = ($pathParts -join ';')
>>"%SCRIPT%" echo     foreach ($scope in 'Machine', 'User') {
>>"%SCRIPT%" echo         foreach ($name in 'NVM_HOME', 'NVM_SYMLINK') {
>>"%SCRIPT%" echo             $value = [Environment]::GetEnvironmentVariable($name, $scope)
>>"%SCRIPT%" echo             if (-not [string]::IsNullOrWhiteSpace($value)) { Set-Item -Path "Env:$name" -Value $value }
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo     $npmPrefix = ^& cmd.exe /c "npm.cmd prefix -g" 2^>$null
>>"%SCRIPT%" echo     if ($npmPrefix -and (Test-Path $npmPrefix)) { $env:Path = "$npmPrefix;$env:Path" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo function Add-Failure([string]$text) { Write-Host "FAILED: $text" -ForegroundColor Red; $null = $failures.Add($text) }
>>"%SCRIPT%" echo function Add-Note([string]$text) { Write-Host $text -ForegroundColor Yellow; $null = $notes.Add($text) }
>>"%SCRIPT%" echo function Write-Section([string]$title) { Write-Host ""; Write-Host "== $title ==" -ForegroundColor Cyan }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # ---------------------------------------------------------------- Scoop
>>"%SCRIPT%" echo # scoop status returns objects. A row with an empty Latest Version is a manifest that was
>>"%SCRIPT%" echo # removed upstream (nothing to update to), and a held package is held on purpose.
>>"%SCRIPT%" echo function Get-ScoopOutdated { @(scoop status 6^>$null ^| Where-Object { $_.'Latest Version' -and ($_.Info -notmatch 'Held') }) }
>>"%SCRIPT%" echo Write-Section "Scoop"
>>"%SCRIPT%" echo if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) { Add-Note "Scoop not installed; skipping (0-init-prereqs.bat installs it)." }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         scoop update 2^>^&1 ^| Out-Host
>>"%SCRIPT%" echo         # @() on every call: with one outdated app the bare row has no .Count in 5.1 ("updated 0 of .").
>>"%SCRIPT%" echo         $before = @(Get-ScoopOutdated)
>>"%SCRIPT%" echo         if ($before.Count -eq 0) { Write-Host "Scoop: everything up to date." -ForegroundColor Green }
>>"%SCRIPT%" echo         else {
>>"%SCRIPT%" echo             $names = ($before ^| ForEach-Object { $_.Name }) -join ', '
>>"%SCRIPT%" echo             Write-Host "Scoop: $($before.Count) outdated: $names" -ForegroundColor Cyan
>>"%SCRIPT%" echo             scoop update * 2^>^&1 ^| Out-Host
>>"%SCRIPT%" echo             $after = @(Get-ScoopOutdated)
>>"%SCRIPT%" echo             foreach ($row in $after) { Add-Failure "scoop: $($row.Name) still $($row.'Installed Version'), latest $($row.'Latest Version') - close the app if it is running and re-run" }
>>"%SCRIPT%" echo             Write-Host "Scoop: updated $($before.Count - $after.Count) of $($before.Count)." -ForegroundColor Green
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         $removed = @(scoop status 6^>$null ^| Where-Object { $_.Info -match 'Manifest removed' })
>>"%SCRIPT%" echo         foreach ($row in $removed) { Add-Note "scoop: $($row.Name) has no manifest any more (removed upstream), so it cannot be updated this way." }
>>"%SCRIPT%" echo     } catch { Add-Failure "scoop: $($_.Exception.Message)" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # ---------------------------------------------------------------- winget
>>"%SCRIPT%" echo # Deliberately not `winget upgrade --all`: the list is parsed and each app is upgraded by
>>"%SCRIPT%" echo # ID so that entries in this table are never touched. Add a row to skip something else.
>>"%SCRIPT%" echo $wingetSkip = @{
>>"%SCRIPT%" echo     'Microsoft.WSL' = 'upgrading WSL restarts the VM, which kills every WSL-hosted console service (code-server, ttyd, ungit, dashboard, sshd)'
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo # Pure parser so the test suite can feed it a captured table. No regex anchors here: a
>>"%SCRIPT%" echo # caret outside double quotes is eaten by CMD on the way into this file, so the anchored
>>"%SCRIPT%" echo # blank-line regex lost its anchor, matched every line, and ended the loop at the first row.
>>"%SCRIPT%" echo function ConvertFrom-WingetTable([string[]]$lines) {
>>"%SCRIPT%" echo     # Column offsets come from the header line; winget pads the table to fixed widths.
>>"%SCRIPT%" echo     $idCol = -1; $verCol = -1
>>"%SCRIPT%" echo     $result = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo     foreach ($raw in $lines) {
>>"%SCRIPT%" echo         # The progress spinner is written with bare carriage returns; keep what follows the last one.
>>"%SCRIPT%" echo         $line = $raw.Substring($raw.LastIndexOf([char]13) + 1)
>>"%SCRIPT%" echo         if ($idCol -lt 0) {
>>"%SCRIPT%" echo             if ($line.StartsWith('Name') -and $line -match 'Name\s+Id\s+Version') { $idCol = $line.IndexOf('Id'); $verCol = $line.IndexOf('Version') }
>>"%SCRIPT%" echo             continue
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         if ($line.StartsWith('-----')) { continue }
>>"%SCRIPT%" echo         # First blank line or the count line ends the table; the second table (packages that
>>"%SCRIPT%" echo         # "require explicit targeting") is left alone on purpose.
>>"%SCRIPT%" echo         if ([string]::IsNullOrWhiteSpace($line) -or $line -match 'upgrades? available') { break }
>>"%SCRIPT%" echo         if ($line.Length -le $verCol) { continue }
>>"%SCRIPT%" echo         $id = $line.Substring($idCol, $verCol - $idCol).Trim()
>>"%SCRIPT%" echo         if ($id) { $null = $result.Add(@{ Id = $id; Name = $line.Substring(0, $idCol).Trim() }) }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo     return ,$result
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo # Streams the rows out one by one; callers collect with @(...) and only then pipe. Piping the
>>"%SCRIPT%" echo # function directly handed Where-Object the whole list as ONE object, so the skip table never
>>"%SCRIPT%" echo # matched and $app.Name printed both names merged ("Winamp Windows Subsystem for Linux").
>>"%SCRIPT%" echo function Get-WingetOutdated {
>>"%SCRIPT%" echo     $lines = @(^& winget upgrade --accept-source-agreements 2^>$null)
>>"%SCRIPT%" echo     $rows = ConvertFrom-WingetTable $lines
>>"%SCRIPT%" echo     return @($rows)
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Section "winget"
>>"%SCRIPT%" echo if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Add-Note "winget not available; skipping." }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $outdated = @(Get-WingetOutdated)
>>"%SCRIPT%" echo         if ($outdated.Count -eq 0) { Write-Host "winget: everything up to date." -ForegroundColor Green }
>>"%SCRIPT%" echo         else {
>>"%SCRIPT%" echo             $ids = ($outdated ^| ForEach-Object { $_.Id }) -join ', '
>>"%SCRIPT%" echo             Write-Host "winget: $($outdated.Count) outdated: $ids" -ForegroundColor Cyan
>>"%SCRIPT%" echo             foreach ($app in $outdated) {
>>"%SCRIPT%" echo                 if ($wingetSkip.ContainsKey($app.Id)) { Add-Note "winget: skipping $($app.Id) - $($wingetSkip[$app.Id])"; continue }
>>"%SCRIPT%" echo                 Write-Host "winget: upgrading $($app.Name) ($($app.Id))..." -ForegroundColor Cyan
>>"%SCRIPT%" echo                 ^& winget upgrade --id $app.Id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2^>^&1 ^| Out-Host
>>"%SCRIPT%" echo             }
>>"%SCRIPT%" echo             # Never trust winget's exit code (nonzero for benign states): ask it again instead.
>>"%SCRIPT%" echo             $after = @(Get-WingetOutdated)
>>"%SCRIPT%" echo             $still = @($after ^| Where-Object { -not $wingetSkip.ContainsKey($_.Id) })
>>"%SCRIPT%" echo             foreach ($app in $still) { Add-Failure "winget: $($app.Name) ($($app.Id)) still outdated" }
>>"%SCRIPT%" echo             $attempted = @($outdated ^| Where-Object { -not $wingetSkip.ContainsKey($_.Id) })
>>"%SCRIPT%" echo             Write-Host "winget: updated $($attempted.Count - $still.Count) of $($attempted.Count)." -ForegroundColor Green
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo     } catch { Add-Failure "winget: $($_.Exception.Message)" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # ---------------------------------------------------------------- Chocolatey
>>"%SCRIPT%" echo # --limit-output rows are name, current, available, pinned separated by a pipe. Split on
>>"%SCRIPT%" echo # the character so no pipe literal has to survive CMD's parser on the way into this file.
>>"%SCRIPT%" echo function Get-ChocoOutdated {
>>"%SCRIPT%" echo     $rows = @(^& choco outdated --limit-output 2^>$null)
>>"%SCRIPT%" echo     @($rows ^| ForEach-Object { $parts = $_.Split([char]124); if ($parts.Count -ge 4 -and $parts[3] -eq 'false') { $parts[0] } })
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Section "Chocolatey"
>>"%SCRIPT%" echo if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { Add-Note "Chocolatey not installed; skipping (0-init-prereqs.bat installs it)." }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $before = Get-ChocoOutdated
>>"%SCRIPT%" echo         if ($before.Count -eq 0) { Write-Host "Chocolatey: everything up to date." -ForegroundColor Green }
>>"%SCRIPT%" echo         else {
>>"%SCRIPT%" echo             Write-Host "Chocolatey: $($before.Count) outdated: $($before -join ', ')" -ForegroundColor Cyan
>>"%SCRIPT%" echo             ^& choco upgrade all -y --no-progress 2^>^&1 ^| Out-Host
>>"%SCRIPT%" echo             $after = Get-ChocoOutdated
>>"%SCRIPT%" echo             foreach ($name in $after) { Add-Failure "choco: $name still outdated" }
>>"%SCRIPT%" echo             Write-Host "Chocolatey: updated $($before.Count - $after.Count) of $($before.Count)." -ForegroundColor Green
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo     } catch { Add-Failure "choco: $($_.Exception.Message)" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # ---------------------------------------------------------------- npm
>>"%SCRIPT%" echo # `npm update -g` stays inside the semver range recorded at install time, so a new major
>>"%SCRIPT%" echo # of a CLI would never arrive. Each outdated package is reinstalled at @latest instead.
>>"%SCRIPT%" echo function Get-NpmOutdated {
>>"%SCRIPT%" echo     $json = (^& cmd.exe /c "npm.cmd outdated -g --json" 2^>$null ^| Out-String).Trim()
>>"%SCRIPT%" echo     if (-not $json) { return @() }
>>"%SCRIPT%" echo     try { $obj = $json ^| ConvertFrom-Json } catch { return @() }
>>"%SCRIPT%" echo     @($obj.PSObject.Properties ^| Where-Object { $_.Value.current -ne $_.Value.latest } ^| ForEach-Object { $_.Name })
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Section "npm global packages"
>>"%SCRIPT%" echo Refresh-SetupEnvironment
>>"%SCRIPT%" echo if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { Add-Note "npm not installed; skipping (0-init-prereqs.bat installs nvm and Node)." }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $before = Get-NpmOutdated
>>"%SCRIPT%" echo         if ($before.Count -eq 0) { Write-Host "npm: everything up to date." -ForegroundColor Green }
>>"%SCRIPT%" echo         else {
>>"%SCRIPT%" echo             Write-Host "npm: $($before.Count) outdated: $($before -join ', ')" -ForegroundColor Cyan
>>"%SCRIPT%" echo             foreach ($name in $before) { ^& cmd.exe /c "npm.cmd install -g $name@latest --no-fund --no-audit" 2^>^&1 ^| Out-Host }
>>"%SCRIPT%" echo             $after = Get-NpmOutdated
>>"%SCRIPT%" echo             foreach ($name in $after) { Add-Failure "npm: $name still outdated" }
>>"%SCRIPT%" echo             Write-Host "npm: updated $($before.Count - $after.Count) of $($before.Count)." -ForegroundColor Green
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo     } catch { Add-Failure "npm: $($_.Exception.Message)" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # ---------------------------------------------------------------- Patch My PC
>>"%SCRIPT%" echo # Sweeps the direct-download apps no package manager owns (Discord Canary, Chrome Remote
>>"%SCRIPT%" echo # Desktop, Mudfish, IceDrive...). /s = scan, update everything it recognises, exit, no GUI.
>>"%SCRIPT%" echo # The exe is resolved from the MSI's uninstall entry first, then the default install path.
>>"%SCRIPT%" echo function Resolve-PatchMyPC {
>>"%SCRIPT%" echo     $exeName = 'PatchMyPC-HomeUpdater.exe'
>>"%SCRIPT%" echo     $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
>>"%SCRIPT%" echo     $candidates = @()
>>"%SCRIPT%" echo     foreach ($entry in (Get-ItemProperty $keys -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo         if ($entry.DisplayName -like 'Patch My PC*' -and $entry.InstallLocation) { $candidates += (Join-Path $entry.InstallLocation $exeName) }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo     $candidates += "$env:ProgramFiles\Patch My PC\Patch My PC Home Updater\$exeName"
>>"%SCRIPT%" echo     $candidates += "${env:ProgramFiles(x86)}\Patch My PC\Patch My PC Home Updater\$exeName"
>>"%SCRIPT%" echo     foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
>>"%SCRIPT%" echo     return $null
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Section "Patch My PC (sweep for direct-download apps)"
>>"%SCRIPT%" echo $patchMyPc = Resolve-PatchMyPC
>>"%SCRIPT%" echo if (-not $patchMyPc) { Add-Note "Patch My PC not installed; skipping the sweep (2-setup-windows.bat installs it)." }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         Write-Host "Running Patch My PC silently: $patchMyPc /s" -ForegroundColor Cyan
>>"%SCRIPT%" echo         $proc = Start-Process -FilePath $patchMyPc -ArgumentList '/s' -Wait -PassThru
>>"%SCRIPT%" echo         if ($proc.ExitCode -eq 0) { Write-Host "Patch My PC finished." -ForegroundColor Green }
>>"%SCRIPT%" echo         else { Add-Failure "Patch My PC exited with code $($proc.ExitCode)" }
>>"%SCRIPT%" echo     } catch { Add-Failure "Patch My PC: $($_.Exception.Message)" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # ---------------------------------------------------------------- summary
>>"%SCRIPT%" echo $elapsed = (Get-Date) - $started
>>"%SCRIPT%" echo Write-Section "Summary ($([int]$elapsed.TotalMinutes) min)"
>>"%SCRIPT%" echo foreach ($note in $notes) { Write-Host "  note: $note" -ForegroundColor Yellow }
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "update-all finished with $($failures.Count) failure(s):" -ForegroundColor Red
>>"%SCRIPT%" echo     foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
>>"%SCRIPT%" echo     try { Stop-Transcript ^| Out-Null } catch {}
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "update-all complete. Everything is up to date." -ForegroundColor Green
>>"%SCRIPT%" echo try { Stop-Transcript ^| Out-Null } catch {}

:: Test hook: write the PowerShell file and stop, so the CMD echo/escape processing above can be
:: exercised (and the result parsed under Windows PowerShell 5.1) without upgrading anything.
if /I "%PCSETUP_GENERATE_ONLY%"=="1" (
    echo Generated %SCRIPT%
    endlocal & exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "UPDATE_EXIT=%errorlevel%"
if %UPDATE_EXIT% neq 0 (
    echo.
    echo update-all failed with exit code %UPDATE_EXIT%.
    echo Generated script: %SCRIPT%
    echo Log: %LOCALAPPDATA%\PCSetup\update-all.log
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %UPDATE_EXIT%
