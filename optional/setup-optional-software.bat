@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

setlocal

echo === HYTE Nexus + Driver Booster Setup ===

:: Install Chocolatey if not present
where choco >nul 2>&1
if %errorlevel% neq 0 (
    echo Installing Chocolatey...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    set "PATH=%PATH%;%ALLUSERSPROFILE%\chocolatey\bin"
)

echo.
echo Installing Driver Booster...
choco install driverbooster -y --ignore-checksums

echo.
echo Downloading HYTE Nexus installer from the official HYTE link...
set "NEXUS_URL=https://hyte.co/nexus-download"
set "NEXUS_INSTALLER=%TEMP%\HYTE-Nexus-Setup.exe"

if exist "%NEXUS_INSTALLER%" del /f /q "%NEXUS_INSTALLER%" >nul 2>&1
curl.exe -L --progress-bar -o "%NEXUS_INSTALLER%" "%NEXUS_URL%"
if %errorlevel% neq 0 (
    echo ERROR: Failed to download HYTE Nexus installer.
    goto end
)

echo.
echo Launching HYTE Nexus installer...
echo Follow the installer prompts to complete setup.
start /wait "" "%NEXUS_INSTALLER%"
if %errorlevel% neq 0 (
    echo WARNING: HYTE Nexus installer exited with code %errorlevel%.
)

echo.
echo === Setup Complete ===
echo Installed or launched:
echo   - Driver Booster
echo   - HYTE Nexus

:end
echo.
endlocal
