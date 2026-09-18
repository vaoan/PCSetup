@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

setlocal

echo === HYTE Nexus + Driver Booster + Mudfish + IceDrive Setup ===

echo.
echo Installing Driver Booster...
winget install --id IObit.DriverBooster -e --silent --accept-package-agreements --accept-source-agreements
if %errorlevel% neq 0 (
    echo WARNING: Driver Booster winget install failed with code %errorlevel%.
)

echo.
echo Checking ASUS DriverHub...
set "ASUS_DRIVERHUB_EXE=C:\Program Files\ASUS\AsusDriverHub\ASUS DriverHub.exe"
set "ASUS_DRIVERHUB_INSTALLER=C:\Program Files\ASUS\AsusDriverHubInstaller\ASUS-DriverHub-Installer.exe"
if exist "%ASUS_DRIVERHUB_EXE%" (
    echo ASUS DriverHub already installed.
) else if exist "%ASUS_DRIVERHUB_INSTALLER%" (
    echo Launching local ASUS DriverHub installer...
    start /wait "" "%ASUS_DRIVERHUB_INSTALLER%"
    if %errorlevel% neq 0 (
        echo WARNING: ASUS DriverHub installer exited with code %errorlevel%.
    )
) else (
    echo ASUS DriverHub does not expose a universal package installer.
    echo Opening official ASUS guidance for motherboard-specific installation...
    start "" "https://www.asus.com/global/support/faq/1053934/"
)

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
echo === Mudfish Cloud VPN ===
call :install_mudfish

echo.
echo === IceDrive ===
call :install_icedrive

echo.
echo === Setup Complete ===
echo Installed or launched:
echo   - Driver Booster
echo   - ASUS DriverHub
echo   - HYTE Nexus
echo   - Mudfish Cloud VPN
echo   - IceDrive

:end
echo.
endlocal
goto :eof

:: Moved here from 2-setup-windows.bat: the installer stops on a driver-installation question
:: that no silent switch answers, so it cannot be part of the unattended run. The download link
:: is resolved from mudfish.net/download (the filename carries the version), then the installer
:: runs interactively - answer its prompt and it finishes on its own.
:: A subroutine, not a parenthesised block: inside ( ) every %VAR% expands when the block is
:: parsed, so the URL, the installer path and %errorlevel% set in it would all read empty.
:install_mudfish
set "MUDFISH_EXE="
if exist "%ProgramFiles(x86)%\Mudfish Cloud VPN\mudfish.exe" set "MUDFISH_EXE=%ProgramFiles(x86)%\Mudfish Cloud VPN\mudfish.exe"
if exist "%ProgramFiles%\Mudfish Cloud VPN\mudfish.exe" set "MUDFISH_EXE=%ProgramFiles%\Mudfish Cloud VPN\mudfish.exe"
if exist "%LOCALAPPDATA%\Mudfish Cloud VPN\mudfish.exe" set "MUDFISH_EXE=%LOCALAPPDATA%\Mudfish Cloud VPN\mudfish.exe"
if defined MUDFISH_EXE (
    echo Mudfish already installed at "%MUDFISH_EXE%".
    goto :eof
)
set "MUDFISH_INSTALLER=%TEMP%\MudfishSetup.exe"
if exist "%MUDFISH_INSTALLER%" del /f /q "%MUDFISH_INSTALLER%" >nul 2>&1
set "MUDFISH_URL="
echo Resolving the Mudfish download link...
for /f "usebackq delims=" %%u in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = (Invoke-WebRequest -Uri 'https://mudfish.net/download' -UseBasicParsing).Content; $m = [regex]::Match($p, '/download\?filename=mudfish-[0-9.]+-x86_64-win2k-setup\.exe'); if ($m.Success) { 'https://mudfish.net/releases/' + ($m.Value -replace '.*filename=', '') }"`) do set "MUDFISH_URL=%%u"
if not defined MUDFISH_URL (
    echo WARNING: Mudfish Windows installer link not found on mudfish.net/download - skipping.
    goto :eof
)
echo Downloading %MUDFISH_URL%
curl.exe -L --progress-bar -o "%MUDFISH_INSTALLER%" "%MUDFISH_URL%"
if not exist "%MUDFISH_INSTALLER%" (
    echo WARNING: Mudfish download failed - skipping.
    goto :eof
)
echo Launching the Mudfish installer - it asks about its network driver; answer it and it completes on its own.
start /wait "" "%MUDFISH_INSTALLER%"
set "MUDFISH_RC=%errorlevel%"
if not "%MUDFISH_RC%"=="0" echo WARNING: Mudfish installer exited with code %MUDFISH_RC%.
goto :eof

:: IceDrive for the one case 2-setup-windows.bat skips: a Dokan driver already present, where the
:: installer stops on a "Confirm File Replace" dialog for dokan2.sys even with /S. Runs interactively.
:install_icedrive
set "ICEDRIVE_EXE="
if exist "%ProgramFiles%\Icedrive\Icedrive.exe" set "ICEDRIVE_EXE=%ProgramFiles%\Icedrive\Icedrive.exe"
if exist "%ProgramFiles(x86)%\Icedrive\Icedrive.exe" set "ICEDRIVE_EXE=%ProgramFiles(x86)%\Icedrive\Icedrive.exe"
if exist "%LOCALAPPDATA%\Programs\Icedrive\Icedrive.exe" set "ICEDRIVE_EXE=%LOCALAPPDATA%\Programs\Icedrive\Icedrive.exe"
if defined ICEDRIVE_EXE (
    echo IceDrive already installed at "%ICEDRIVE_EXE%".
    goto :eof
)
set "ICEDRIVE_INSTALLER=%TEMP%\IcedriveSetup.exe"
if exist "%ICEDRIVE_INSTALLER%" del /f /q "%ICEDRIVE_INSTALLER%" >nul 2>&1
set "ICEDRIVE_URL="
echo Resolving the IceDrive download link...
for /f "usebackq delims=" %%u in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = (Invoke-WebRequest -Uri 'https://icedrive.net/apps/desktop-laptop' -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)').Content; $m = [regex]::Match($p, 'https://cdn\.icedrive\.net/static/apps/win/IcedriveSetup-v[0-9.]+\.exe'); if ($m.Success) { $m.Value } else { $r = [regex]::Match($p, 'value=.(win/IcedriveSetup-v[0-9.]+\.exe)'); if ($r.Success) { 'https://cdn.icedrive.net/static/apps/' + $r.Groups[1].Value } }"`) do set "ICEDRIVE_URL=%%u"
if not defined ICEDRIVE_URL set "ICEDRIVE_URL=https://cdn.icedrive.net/static/apps/win/IcedriveSetup-v3.62.exe"
echo Downloading %ICEDRIVE_URL%
curl.exe -L --progress-bar -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -e "https://icedrive.net/apps/desktop-laptop" -o "%ICEDRIVE_INSTALLER%" "%ICEDRIVE_URL%"
if not exist "%ICEDRIVE_INSTALLER%" (
    echo WARNING: IceDrive download failed - skipping.
    goto :eof
)
echo Launching the IceDrive installer - answer its Dokan driver question and it completes on its own.
start /wait "" "%ICEDRIVE_INSTALLER%"
set "ICEDRIVE_RC=%errorlevel%"
if not "%ICEDRIVE_RC%"=="0" echo WARNING: IceDrive installer exited with code %ICEDRIVE_RC%.
goto :eof
