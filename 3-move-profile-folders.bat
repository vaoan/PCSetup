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
echo   Windows Profile Folders Relocation Script
echo =============================================
echo.
echo Target location: %TARGET_BASE%
echo Move existing files: %MOVE_FILES%
echo.

:: Create target folders
echo Creating target folders...
if not exist "%TARGET_BASE%\Desktop" mkdir "%TARGET_BASE%\Desktop"
if not exist "%TARGET_BASE%\Documents" mkdir "%TARGET_BASE%\Documents"
if not exist "%TARGET_BASE%\Music" mkdir "%TARGET_BASE%\Music"
if not exist "%TARGET_BASE%\Pictures" mkdir "%TARGET_BASE%\Pictures"
if not exist "%TARGET_BASE%\Videos" mkdir "%TARGET_BASE%\Videos"
if not exist "%TARGET_BASE%\3D Objects" mkdir "%TARGET_BASE%\3D Objects"
if not exist "%TARGET_BASE%\Favorites" mkdir "%TARGET_BASE%\Favorites"
if not exist "%TARGET_BASE%\Contacts" mkdir "%TARGET_BASE%\Contacts"
if not exist "%TARGET_BASE%\Links" mkdir "%TARGET_BASE%\Links"
if not exist "%TARGET_BASE%\Saved Games" mkdir "%TARGET_BASE%\Saved Games"
if not exist "%TARGET_BASE%\Searches" mkdir "%TARGET_BASE%\Searches"

:: Move files if enabled
if "%MOVE_FILES%"=="1" (
    echo.
    echo Moving existing files to new location...
    echo This may take a while depending on file sizes...
    echo.

    robocopy "%USERPROFILE%\Desktop" "%TARGET_BASE%\Desktop" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\Documents" "%TARGET_BASE%\Documents" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\Music" "%TARGET_BASE%\Music" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\Pictures" "%TARGET_BASE%\Pictures" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\Videos" "%TARGET_BASE%\Videos" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\3D Objects" "%TARGET_BASE%\3D Objects" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\Favorites" "%TARGET_BASE%\Favorites" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\Contacts" "%TARGET_BASE%\Contacts" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\Links" "%TARGET_BASE%\Links" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\Saved Games" "%TARGET_BASE%\Saved Games" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul
    robocopy "%USERPROFILE%\Searches" "%TARGET_BASE%\Searches" /E /MOVE /R:1 /W:1 /NP /NFL /NDL 2>nul

    echo Files moved.
)

echo.
echo Updating registry...

:: Update User Shell Folders (main registry key)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "Desktop" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Desktop" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "Personal" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Documents" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{F42EE2D3-909F-4907-8871-4C22FC0BF756}" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Documents" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Music" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Music" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Pictures" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Pictures" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Video" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Videos" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{31C0DD25-9439-4F12-BF41-7FF4EDA38722}" /t REG_EXPAND_SZ /d "%TARGET_BASE%\3D Objects" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "Favorites" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Favorites" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{56784854-C6CB-462B-8169-88E350ACB882}" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Contacts" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968}" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Links" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Saved Games" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{7D1D3A04-DEBB-4115-95CF-2F29DA2920DA}" /t REG_EXPAND_SZ /d "%TARGET_BASE%\Searches" /f

:: Update Shell Folders (legacy, but some apps still use it)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "Desktop" /t REG_SZ /d "%TARGET_BASE%\Desktop" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "Personal" /t REG_SZ /d "%TARGET_BASE%\Documents" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "My Music" /t REG_SZ /d "%TARGET_BASE%\Music" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "My Pictures" /t REG_SZ /d "%TARGET_BASE%\Pictures" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "My Video" /t REG_SZ /d "%TARGET_BASE%\Videos" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "Favorites" /t REG_SZ /d "%TARGET_BASE%\Favorites" /f

echo.
echo =============================================
echo   Profile folders relocated successfully!
echo =============================================
echo.
echo New locations:
echo   Desktop:     %TARGET_BASE%\Desktop
echo   Documents:   %TARGET_BASE%\Documents
echo   Music:       %TARGET_BASE%\Music
echo   Pictures:    %TARGET_BASE%\Pictures
echo   Videos:      %TARGET_BASE%\Videos
echo   3D Objects:  %TARGET_BASE%\3D Objects
echo   Favorites:   %TARGET_BASE%\Favorites
echo   Contacts:    %TARGET_BASE%\Contacts
echo   Links:       %TARGET_BASE%\Links
echo   Saved Games: %TARGET_BASE%\Saved Games
echo   Searches:    %TARGET_BASE%\Searches
echo.
echo Restarting Explorer to apply changes...
taskkill /f /im explorer.exe >nul 2>&1
timeout /t 2 /nobreak >nul
start explorer.exe
echo.
echo Done! If some apps still show old paths, restart them or log out/in.
echo.
