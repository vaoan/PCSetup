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

:: Drives to skip (comma-separated, e.g. 'P','Q')
set "SKIP_DRIVES='P','C','I'"

set "SCRIPT=%TEMP%\temp-delete-node-modules.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

>"%SCRIPT%" echo $skip = @(%SKIP_DRIVES%)
>>"%SCRIPT%" echo $excludePaths = @(
>>"%SCRIPT%" echo     "$env:ProgramFiles\Microsoft VS Code",
>>"%SCRIPT%" echo     "${env:ProgramFiles(x86)}\Microsoft VS Code",
>>"%SCRIPT%" echo     "$env:LOCALAPPDATA\Streamlabs OBS",
>>"%SCRIPT%" echo     "$env:ProgramFiles\Slack",
>>"%SCRIPT%" echo     "$env:USERPROFILE\scoop"
>>"%SCRIPT%" echo )
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Deleting all node_modules folders (skipping drives: $($skip -join ', '))..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Write-Host "This may take a while..." -ForegroundColor Yellow
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo $found = 0; $deleted = 0; $freedBytes = [long]0
>>"%SCRIPT%" echo $failed = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo foreach ($drive in (Get-PSDrive -PSProvider FileSystem).Root) {
>>"%SCRIPT%" echo     if ($skip -contains $drive.Substring(0,1)) { Write-Host "Skipping drive $drive" -ForegroundColor Yellow; continue }
>>"%SCRIPT%" echo     if (-not (Test-Path $drive)) { continue }
>>"%SCRIPT%" echo     Write-Host "Scanning drive $drive" -ForegroundColor Cyan
>>"%SCRIPT%" echo     $targets = Get-ChildItem -Path $drive -Directory -Filter 'node_modules' -Recurse -ErrorAction SilentlyContinue ^|
>>"%SCRIPT%" echo         Where-Object { $_.FullName -notmatch '\\node_modules\\.*\\node_modules' } ^|
>>"%SCRIPT%" echo         Where-Object { $p = $_.FullName; -not ($excludePaths ^| Where-Object { $_ -and $p -like "$_*" }) }
>>"%SCRIPT%" echo     foreach ($t in $targets) {
>>"%SCRIPT%" echo         $found++
>>"%SCRIPT%" echo         # Size is measured before deletion so the reclaimed total is real, not estimated.
>>"%SCRIPT%" echo         $size = [long]0
>>"%SCRIPT%" echo         try { $size = (Get-ChildItem -LiteralPath $t.FullName -Recurse -File -ErrorAction SilentlyContinue ^| Measure-Object -Property Length -Sum).Sum } catch { }
>>"%SCRIPT%" echo         if (-not $size) { $size = [long]0 }
>>"%SCRIPT%" echo         Write-Host "Deleting: $($t.FullName)"
>>"%SCRIPT%" echo         try { Remove-Item -LiteralPath $t.FullName -Recurse -Force -ErrorAction Stop } catch { }
>>"%SCRIPT%" echo         # Verify: -ErrorAction SilentlyContinue used to hide locked files entirely, so a
>>"%SCRIPT%" echo         # folder that could not be removed was still reported as a success.
>>"%SCRIPT%" echo         if (Test-Path -LiteralPath $t.FullName) { Write-Host "  FAILED (in use or access denied)" -ForegroundColor Red; $null = $failed.Add($t.FullName) }
>>"%SCRIPT%" echo         else { $deleted++; $freedBytes += $size }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Get-DirSize([string]$path) {
>>"%SCRIPT%" echo     if (-not $path -or -not (Test-Path $path)) { return [long]0 }
>>"%SCRIPT%" echo     $s = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue ^| Measure-Object -Property Length -Sum).Sum
>>"%SCRIPT%" echo     if ($s) { return [long]$s } else { return [long]0 }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # pnpm keeps its packages in a content-addressable store OUTSIDE node_modules (the
>>"%SCRIPT%" echo # node_modules//.pnpm folders are only hardlinks into it), so deleting node_modules
>>"%SCRIPT%" echo # reclaims almost nothing until the store is pruned as well.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo     Write-Host "pnpm not installed; skipping store/cache cleanup." -ForegroundColor Yellow
>>"%SCRIPT%" echo } else {
>>"%SCRIPT%" echo     Write-Host "Pruning pnpm store..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     $storePath = (^& cmd.exe /c "pnpm store path" 2^>$null ^| Select-Object -Last 1)
>>"%SCRIPT%" echo     if ($storePath) { $storePath = $storePath.Trim() }
>>"%SCRIPT%" echo     $storeBefore = Get-DirSize $storePath
>>"%SCRIPT%" echo     Write-Host "  store: $storePath ($([math]::Round($storeBefore / 1GB, 2)) GB)"
>>"%SCRIPT%" echo     # "store prune" only removes packages no longer referenced by any project - it is
>>"%SCRIPT%" echo     # the supported way to reclaim, not a blind delete of the store directory.
>>"%SCRIPT%" echo     ^& cmd.exe /c "pnpm store prune" 2^>^&1 ^| ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
>>"%SCRIPT%" echo     $storeAfter = Get-DirSize $storePath
>>"%SCRIPT%" echo     $storeFreed = $storeBefore - $storeAfter
>>"%SCRIPT%" echo     if ($storeFreed -lt 0) { $storeFreed = [long]0 }
>>"%SCRIPT%" echo     $freedBytes += $storeFreed
>>"%SCRIPT%" echo     Write-Host "  store reclaimed: $([math]::Round($storeFreed / 1GB, 2)) GB" -ForegroundColor Green
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo     Write-Host "Clearing pnpm metadata cache..." -ForegroundColor Cyan
>>"%SCRIPT%" echo     # "pnpm config get cacheDir" prints the string 'undefined' when unset, which is a
>>"%SCRIPT%" echo     # path that happily passes Test-Path checks in relative form - treat it as unset.
>>"%SCRIPT%" echo     $cacheDir = (^& cmd.exe /c "pnpm config get cacheDir" 2^>$null ^| Select-Object -Last 1)
>>"%SCRIPT%" echo     if ($cacheDir) { $cacheDir = $cacheDir.Trim() }
>>"%SCRIPT%" echo     if (-not $cacheDir -or $cacheDir -eq 'undefined' -or -not (Test-Path -LiteralPath $cacheDir)) { $cacheDir = Join-Path $env:LOCALAPPDATA 'pnpm-cache' }
>>"%SCRIPT%" echo     # Usually already empty by this point: "pnpm store prune" reports "Removed all
>>"%SCRIPT%" echo     # cached metadata files" and clears it itself. This stays as a backstop for older
>>"%SCRIPT%" echo     # pnpm versions and for anything prune leaves behind.
>>"%SCRIPT%" echo     $cacheBefore = Get-DirSize $cacheDir
>>"%SCRIPT%" echo     if ($cacheBefore -eq 0) { Write-Host "  pnpm metadata cache already empty ($cacheDir)" -ForegroundColor Yellow }
>>"%SCRIPT%" echo     else {
>>"%SCRIPT%" echo         Write-Host "  cache: $cacheDir ($([math]::Round($cacheBefore / 1MB, 1)) MB)"
>>"%SCRIPT%" echo         try { Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction Stop } catch { }
>>"%SCRIPT%" echo         $cacheAfter = Get-DirSize $cacheDir
>>"%SCRIPT%" echo         if ($cacheAfter -gt 0) { Write-Host "  cache could not be fully cleared" -ForegroundColor Red; $null = $failed.Add($cacheDir) }
>>"%SCRIPT%" echo         $freedBytes += ($cacheBefore - $cacheAfter)
>>"%SCRIPT%" echo         Write-Host "  cache reclaimed: $([math]::Round(($cacheBefore - $cacheAfter) / 1MB, 1)) MB" -ForegroundColor Green
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo Write-Host "Found: $found   Deleted: $deleted   Failed: $($failed.Count)   Reclaimed: $([math]::Round($freedBytes / 1GB, 2)) GB" -ForegroundColor Green
>>"%SCRIPT%" echo if ($failed.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Could not delete:" -ForegroundColor Red
>>"%SCRIPT%" echo     $failed ^| ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
>>"%SCRIPT%" echo     Write-Host "Close any editor/dev server holding these folders and re-run." -ForegroundColor Yellow
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Done!" -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "NM_EXIT=%errorlevel%"
if %NM_EXIT% neq 0 (
    echo.
    echo node_modules cleanup finished with exit code %NM_EXIT%.
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %NM_EXIT%
