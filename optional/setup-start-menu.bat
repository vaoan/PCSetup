@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

set "BACKUP_FILE=%~dp0start-menu-backup.bin"
set "START_MENU_FILE=%LOCALAPPDATA%\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin"

echo.
echo  Start Menu Backup/Restore Tool
echo  ===============================
echo.
echo  [1] Backup current Start Menu layout
echo  [2] Restore Start Menu layout from backup
echo.
set /p choice="Select option (1 or 2): "

if "%choice%"=="1" goto backup
if "%choice%"=="2" goto restore
echo Invalid option.
goto end

:backup
echo.
echo Backing up Start Menu layout...
if not exist "%START_MENU_FILE%" (
    echo ERROR: Start Menu file not found at:
    echo %START_MENU_FILE%
    goto end
)
copy /Y "%START_MENU_FILE%" "%BACKUP_FILE%" >nul
if %errorlevel% equ 0 (
    echo.
    echo SUCCESS: Start Menu layout backed up to:
    echo %BACKUP_FILE%
) else (
    echo ERROR: Failed to backup Start Menu layout.
)
goto end

:restore
echo.
echo Restoring Start Menu layout...
if not exist "%BACKUP_FILE%" (
    echo ERROR: Backup file not found at:
    echo %BACKUP_FILE%
    echo.
    echo Run this script with option [1] first to create a backup.
    goto end
)

:: Stop Start Menu process
echo Stopping Start Menu...
taskkill /F /IM StartMenuExperienceHost.exe >nul 2>&1
timeout /t 2 /nobreak >nul

:: Copy backup file
copy /Y "%BACKUP_FILE%" "%START_MENU_FILE%" >nul
if %errorlevel% equ 0 (
    echo.
    echo SUCCESS: Start Menu layout restored!
    echo.
    echo Press the Windows key to see your restored Start Menu.
) else (
    echo ERROR: Failed to restore Start Menu layout.
)
goto end

:end
echo.
pause
