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

:: Windows Defender is not installed in Server Core, so Add-MpPreference/Get-MpPreference do
:: not exist and every exclusion below would fail.
if "%PCSETUP_CI%"=="1" (
    echo SKIP: CI mode - skipping Defender exclusions
    exit /b 0
)

:: Add-MpPreference/Get-MpPreference (Defender), Get-PackageProvider and Install-Module all live
:: in modules. Inheriting PowerShell 7's PSModulePath makes Windows PowerShell refuse to load
:: them, so every exclusion here would silently do nothing.
set "PSModulePath="

set "SCRIPT=%TEMP%\temp-exclusions.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
>>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo function Add-Failure([string]$name) { if (-not $failures.Contains($name)) { $null = $failures.Add($name) } }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Adding Windows Security exclusions..." -ForegroundColor Cyan
>>"%SCRIPT%" echo if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo     Write-Host "Defender cmdlets unavailable (Defender module failed to load or is disabled)." -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Paths are resolved, not hardcoded: XIVLauncher and the game can live in several
>>"%SCRIPT%" echo # places, and Defender silently accepts an exclusion for a path that does not exist.
>>"%SCRIPT%" echo $exclusions = @(
>>"%SCRIPT%" echo     "$env:APPDATA\XIVLauncher",
>>"%SCRIPT%" echo     "$env:APPDATA\XIVLauncher\addon",
>>"%SCRIPT%" echo     "$env:APPDATA\XIVLauncher\runtime",
>>"%SCRIPT%" echo     "$env:LOCALAPPDATA\XIVLauncher",
>>"%SCRIPT%" echo     "${env:ProgramFiles(x86)}\SquareEnix\FINAL FANTASY XIV - A Realm Reborn",
>>"%SCRIPT%" echo     "$env:ProgramFiles\WezTerm"
>>"%SCRIPT%" echo )
>>"%SCRIPT%" echo # Whatever Scoop actually installed lands under one root; exclude the real one.
>>"%SCRIPT%" echo if (Get-Command scoop -ErrorAction SilentlyContinue) {
>>"%SCRIPT%" echo     foreach ($app in 'steam', 'wezterm') {
>>"%SCRIPT%" echo         $prefix = ^& scoop prefix $app 2^>$null 6^>$null
>>"%SCRIPT%" echo         if ($LASTEXITCODE -eq 0 -and $prefix -and (Test-Path $prefix)) { $exclusions += $prefix }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $existing = @((Get-MpPreference).ExclusionPath)
>>"%SCRIPT%" echo foreach ($path in ($exclusions ^| Select-Object -Unique)) {
>>"%SCRIPT%" echo     if ($existing -contains $path) { Write-Host "Already excluded: $path" -ForegroundColor Yellow; continue }
>>"%SCRIPT%" echo     Write-Host "Excluding: $path" -ForegroundColor Cyan
>>"%SCRIPT%" echo     try { Add-MpPreference -ExclusionPath $path -ErrorAction Stop } catch { Write-Host "  error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Re-read from Defender rather than trusting Add-MpPreference to have worked.
>>"%SCRIPT%" echo $now = @((Get-MpPreference).ExclusionPath)
>>"%SCRIPT%" echo foreach ($path in ($exclusions ^| Select-Object -Unique)) {
>>"%SCRIPT%" echo     if ($now -notcontains $path) { Write-Host "FAILED to exclude: $path" -ForegroundColor Red; Add-Failure "exclusion: $path" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "$($now.Count) exclusion paths registered with Defender." -ForegroundColor Green
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Smart App Control blocks Dalamud/Reloaded.Hooks DLLs with "can't confirm publisher".
>>"%SCRIPT%" echo # 0 = Off, 1 = Evaluation, 2 = On. Once SAC is On, Windows only allows Off via a
>>"%SCRIPT%" echo # clean install - the registry write succeeds but is reverted, so verify and say so.
>>"%SCRIPT%" echo $sacKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
>>"%SCRIPT%" echo $sacBefore = (Get-ItemProperty $sacKey -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
>>"%SCRIPT%" echo if ($null -eq $sacBefore) { Write-Host "Smart App Control not present on this system; skipping." -ForegroundColor Yellow }
>>"%SCRIPT%" echo elseif ($sacBefore -eq 0) { Write-Host "Smart App Control already off." -ForegroundColor Yellow }
>>"%SCRIPT%" echo else {
>>"%SCRIPT%" echo     Write-Host "Turning Smart App Control off (was state $sacBefore)..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     try { Set-ItemProperty -Path $sacKey -Name VerifiedAndReputablePolicyState -Value 0 -Type DWord -Force -ErrorAction Stop } catch { Write-Host "  error: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     $sacAfter = (Get-ItemProperty $sacKey -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
>>"%SCRIPT%" echo     if ($sacAfter -eq 0) { Write-Host "Smart App Control off (restart required to take effect)." -ForegroundColor Green }
>>"%SCRIPT%" echo     else { Write-Host "Smart App Control is still state $sacAfter. Windows only allows On -> Off via a clean install." -ForegroundColor Red; Add-Failure 'Smart App Control disable' }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Setting Google Chrome as default browser/PDF/email handler..." -ForegroundColor Cyan
>>"%SCRIPT%" echo function Get-HttpDefaultProgId {
>>"%SCRIPT%" echo     return (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -Name ProgId -ErrorAction SilentlyContinue).ProgId
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo if ((Get-HttpDefaultProgId) -eq 'ChromeHTML') { Write-Host "Chrome is already the default handler, skipping." -ForegroundColor Yellow }
>>"%SCRIPT%" echo elseif (-not (Get-Command chrome -ErrorAction SilentlyContinue) -and -not (Test-Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") -and -not (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")) {
>>"%SCRIPT%" echo     Write-Host "Chrome is not installed; skipping default-app associations." -ForegroundColor Yellow
>>"%SCRIPT%" echo } else {
>>"%SCRIPT%" echo     # PS-SFTA is a GitHub repo containing SFTA.ps1, NOT a PowerShell Gallery module.
>>"%SCRIPT%" echo     # "Install-Module PS-SFTA" always failed with "No match was found ... module name
>>"%SCRIPT%" echo     # 'PS-SFTA'", so this step had never once worked. Dot-source the real script instead.
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         $sftaUrl = 'https://raw.githubusercontent.com/DanysysTeam/PS-SFTA/master/SFTA.ps1'
>>"%SCRIPT%" echo         $sftaPath = Join-Path $env:TEMP 'SFTA.ps1'
>>"%SCRIPT%" echo         Invoke-WebRequest -Uri $sftaUrl -OutFile $sftaPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
>>"%SCRIPT%" echo         . $sftaPath
>>"%SCRIPT%" echo         if (-not (Get-Command Set-PTA -ErrorAction SilentlyContinue)) { throw "SFTA.ps1 did not define Set-PTA." }
>>"%SCRIPT%" echo         Set-PTA ChromeHTML http
>>"%SCRIPT%" echo         Set-PTA ChromeHTML https
>>"%SCRIPT%" echo         Set-PTA ChromeHTML mailto
>>"%SCRIPT%" echo         Set-FTA ChromeHTML .htm
>>"%SCRIPT%" echo         Set-FTA ChromeHTML .html
>>"%SCRIPT%" echo         Set-FTA ChromePDF .pdf
>>"%SCRIPT%" echo     } catch { Write-Host "  SFTA: $($_.Exception.Message)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     # Deliberately a warning, not a failure. Windows 11 hash-protects the UserChoice
>>"%SCRIPT%" echo     # keys and blocks third-party writes ("Write Reg Protocol UserChoice FAILED") both
>>"%SCRIPT%" echo     # elevated and de-elevated, so no script can set this. Counting it as a failure
>>"%SCRIPT%" echo     # would make this script permanently exit 1 and mask real failures.
>>"%SCRIPT%" echo     if ((Get-HttpDefaultProgId) -eq 'ChromeHTML') { Write-Host "Chrome set as default for http/https/mailto/.htm/.html/.pdf." -ForegroundColor Green }
>>"%SCRIPT%" echo     else {
>>"%SCRIPT%" echo         Write-Host "NOTE: Windows blocked the default-app change (currently '$(Get-HttpDefaultProgId)')." -ForegroundColor Yellow
>>"%SCRIPT%" echo         Write-Host "      Set it by hand: Settings > Apps > Default apps > Google Chrome > Set default." -ForegroundColor Yellow
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Exclusions setup finished with failures: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Done! Restart is required for Smart App Control changes to take effect." -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "EX_EXIT=%errorlevel%"
if %EX_EXIT% neq 0 (
    echo.
    echo Exclusions setup finished with exit code %EX_EXIT%.
    echo Generated script: %SCRIPT%
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %EX_EXIT%
