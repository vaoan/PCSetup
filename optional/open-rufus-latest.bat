@echo off
setlocal

set "RUFUS_DIR=%LOCALAPPDATA%\PCSetupCache\Rufus"
set "RUFUS_EXE=%RUFUS_DIR%\rufus.exe"
set "RUFUS_TMP=%RUFUS_DIR%\rufus-download.exe"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference = 'Stop';" ^
  "$ProgressPreference = 'SilentlyContinue';" ^
  "$release = Invoke-RestMethod 'https://api.github.com/repos/pbatard/rufus/releases/latest';" ^
  "$asset = $release.assets | Where-Object { $_.name -match '^rufus-[0-9].*\.exe$' -and $_.name -notmatch 'portable' } | Select-Object -First 1;" ^
  "if (-not $asset) { throw 'Could not find the latest Rufus EXE asset.' };" ^
  "New-Item -ItemType Directory -Force -Path '%RUFUS_DIR%' | Out-Null;" ^
  "if (Test-Path '%RUFUS_TMP%') { Remove-Item '%RUFUS_TMP%' -Force -ErrorAction SilentlyContinue };" ^
  "Invoke-WebRequest -Uri $asset.browser_download_url -OutFile '%RUFUS_TMP%';" ^
  "try { Move-Item '%RUFUS_TMP%' '%RUFUS_EXE%' -Force } catch { Remove-Item '%RUFUS_TMP%' -Force -ErrorAction SilentlyContinue };" ^
  "if (-not (Test-Path '%RUFUS_EXE%')) { throw 'Cached Rufus executable is not available.' };" ^
  "Start-Process -FilePath '%RUFUS_EXE%';" ^
  "Write-Host ('Opened ' + $asset.name + ' from %RUFUS_EXE%')"

if errorlevel 1 (
    echo Failed to download or launch the latest Rufus.
    exit /b 1
)

endlocal
