@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: ============================================
:: CONFIGURATION - Change these as needed
:: ============================================
set "TARGET_DRIVE=Z:"
set "TARGET_BASE=%TARGET_DRIVE%\Users\%USERNAME%"
:: Set to 1 to move existing files, 0 to just change registry
set "MOVE_FILES=1"
:: ============================================

echo.
echo =============================================
echo   Move Downloads Folder Script
echo =============================================
echo.
echo Target location: %TARGET_BASE%\Downloads
echo Move existing files: %MOVE_FILES%
echo.

:: Create target folder
echo Creating target folder...
if not exist "%TARGET_BASE%\Downloads" mkdir "%TARGET_BASE%\Downloads"

:: Move files if enabled
if "%MOVE_FILES%"=="1" (
    echo.
    echo Moving existing files to new location...
    echo This may take a while depending on file sizes...
    echo.

    robocopy "%USERPROFILE%\Downloads" "%TARGET_BASE%\Downloads" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul

    echo Files moved.
)

echo.
echo Updating registry...

:: Update User Shell Folders
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{374DE290-123F-4565-9164-39C4925E467B}" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Downloads" /f

echo.
echo =============================================
echo   Downloads folder relocated successfully!
echo =============================================
echo.
echo New location: %TARGET_BASE%\Downloads
echo.
echo Restarting Explorer to apply changes...
taskkill /f /im explorer.exe >nul 2>&1
timeout /t 2 /nobreak >nul
start explorer.exe
echo.
echo Done!
echo.
