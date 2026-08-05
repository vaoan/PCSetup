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

set "SCRIPT=%TEMP%\temp-steam-icons.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

:: This was previously a single opaque -EncodedCommand base64 blob, which meant the logic could
:: not be reviewed or edited without decoding it by hand. It is generated as readable PowerShell
:: now, exactly like the other setup scripts.
>"%SCRIPT%" echo [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
>>"%SCRIPT%" echo Write-Host "Fixing Steam shortcut icons..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Steam moved to Scoop, so 'C:\Program Files (x86)\Steam' no longer exists on a fresh
>>"%SCRIPT%" echo # machine. The old code hardcoded it and created an empty 'steam\games' folder there
>>"%SCRIPT%" echo # that Steam never reads. Resolve the real install instead.
>>"%SCRIPT%" echo $steamRoot = $null
>>"%SCRIPT%" echo if (Get-Command scoop -ErrorAction SilentlyContinue) {
>>"%SCRIPT%" echo     $p = ^& scoop prefix steam 2^>$null 6^>$null
>>"%SCRIPT%" echo     if ($LASTEXITCODE -eq 0 -and $p -and (Test-Path (Join-Path $p 'steam.exe'))) { $steamRoot = $p }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo if (-not $steamRoot) {
>>"%SCRIPT%" echo     $steamRoot = @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam") ^| Where-Object { Test-Path (Join-Path $_ 'steam.exe') } ^| Select-Object -First 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo if (-not $steamRoot) {
>>"%SCRIPT%" echo     $reg = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
>>"%SCRIPT%" echo     if ($reg -and (Test-Path $reg)) { $steamRoot = $reg }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo if (-not $steamRoot) { Write-Host "Steam is not installed; nothing to fix." -ForegroundColor Yellow; exit 0 }
>>"%SCRIPT%" echo Write-Host "Steam: $steamRoot" -ForegroundColor Cyan
>>"%SCRIPT%" echo $gamesDir = Join-Path $steamRoot 'steam\games'
>>"%SCRIPT%" echo if (-not (Test-Path $gamesDir)) { New-Item -ItemType Directory -Path $gamesDir -Force ^| Out-Null }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $desktop = [Environment]::GetFolderPath('Desktop')
>>"%SCRIPT%" echo $urlFiles = @(Get-ChildItem -Path $desktop -Filter '*.url' -ErrorAction SilentlyContinue ^| Where-Object { (Get-Content $_.FullName -Raw) -match 'steam://rungameid/' })
>>"%SCRIPT%" echo Write-Host "Found $($urlFiles.Count) Steam shortcuts" -ForegroundColor Yellow
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $current = 0; $ok = 0; $downloaded = 0
>>"%SCRIPT%" echo $failed = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo foreach ($file in $urlFiles) {
>>"%SCRIPT%" echo     $current++
>>"%SCRIPT%" echo     $content = Get-Content $file.FullName -Raw
>>"%SCRIPT%" echo     $appId = $null; $iconHash = $null; $iconPath = $null
>>"%SCRIPT%" echo     if ($content -match 'URL=steam://rungameid/(\d+)') { $appId = $Matches[1] }
>>"%SCRIPT%" echo     if ($content -match 'IconFile=.*\\([a-f0-9]{40})\.ico') {
>>"%SCRIPT%" echo         $iconHash = $Matches[1]
>>"%SCRIPT%" echo         if ($content -match 'IconFile=(.+\.ico)') { $iconPath = $Matches[1].Trim() }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo     if (-not $appId) { continue }
>>"%SCRIPT%" echo     Write-Host "[$current/$($urlFiles.Count)] $($file.BaseName) (AppID: $appId)"
>>"%SCRIPT%" echo     if (-not $iconHash) { Write-Host "  No icon hash found, skipping" -ForegroundColor Yellow; continue }
>>"%SCRIPT%" echo     if (Test-Path $iconPath) { Write-Host "  Icon exists" -ForegroundColor Cyan; $ok++; continue }
>>"%SCRIPT%" echo     $iconDir = Split-Path $iconPath -Parent
>>"%SCRIPT%" echo     if ($iconDir -and -not (Test-Path $iconDir)) { New-Item -ItemType Directory -Path $iconDir -Force ^| Out-Null }
>>"%SCRIPT%" echo     $iconUrl = "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/$appId/$iconHash.ico"
>>"%SCRIPT%" echo     try {
>>"%SCRIPT%" echo         Write-Host "  Downloading: $iconHash.ico" -ForegroundColor Gray
>>"%SCRIPT%" echo         Invoke-WebRequest -Uri $iconUrl -OutFile $iconPath -UseBasicParsing -ErrorAction Stop
>>"%SCRIPT%" echo     } catch { Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red; $null = $failed.Add($file.BaseName); continue }
>>"%SCRIPT%" echo     # Verify the file landed instead of counting the attempt as a success.
>>"%SCRIPT%" echo     if (Test-Path $iconPath) { Write-Host "  Downloaded" -ForegroundColor Green; $ok++; $downloaded++ }
>>"%SCRIPT%" echo     else { Write-Host "  Download reported success but no file was written" -ForegroundColor Red; $null = $failed.Add($file.BaseName) }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo Write-Host "Icons OK: $ok of $($urlFiles.Count)  (newly downloaded: $downloaded)" -ForegroundColor Cyan
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo if ($downloaded -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Clearing icon cache..." -ForegroundColor Yellow
>>"%SCRIPT%" echo     Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo     Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache*" -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo     Write-Host "Restarting Explorer..." -ForegroundColor Yellow
>>"%SCRIPT%" echo     Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
>>"%SCRIPT%" echo     Start-Sleep -Seconds ^2
>>"%SCRIPT%" echo     if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
>>"%SCRIPT%" echo } else {
>>"%SCRIPT%" echo     # Restarting Explorer closes the user's windows; only worth it if icons changed.
>>"%SCRIPT%" echo     Write-Host "No icons changed; leaving the icon cache and Explorer alone." -ForegroundColor Yellow
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failed.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Could not fix: $($failed -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Done!" -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "SI_EXIT=%errorlevel%"
if %SI_EXIT% neq 0 (
    echo.
    echo Steam icon fix finished with exit code %SI_EXIT%.
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %SI_EXIT%
