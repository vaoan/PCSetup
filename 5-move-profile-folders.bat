@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
setlocal EnableExtensions EnableDelayedExpansion

:: ============================================
:: CONFIGURATION
:: Loaded from profile-folders.config (next to this script)
:: ============================================
set "TARGET_DRIVE=Z:"
set "TARGET_PROFILE_FOLDER=%USERNAME%"
:: Set to 1 to move existing files, 0 to just change registry
set "MOVE_FILES=1"

set "CONFIG_FILE=%~dp0profile-folders.config"
if exist "%CONFIG_FILE%" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%CONFIG_FILE%") do (
        set "CFG_KEY=%%~A"
        set "CFG_VALUE=%%~B"
        if /I "!CFG_KEY!"=="TARGET_DRIVE" set "TARGET_DRIVE=!CFG_VALUE!"
        if /I "!CFG_KEY!"=="TARGET_PROFILE_FOLDER" set "TARGET_PROFILE_FOLDER=!CFG_VALUE!"
        if /I "!CFG_KEY!"=="MOVE_FILES" set "MOVE_FILES=!CFG_VALUE!"
    )
)

if "%TARGET_DRIVE%"=="" set "TARGET_DRIVE=Z:"
if "%TARGET_PROFILE_FOLDER%"=="" set "TARGET_PROFILE_FOLDER=%USERNAME%"
if /I "%TARGET_PROFILE_FOLDER%"=="AUTO" set "TARGET_PROFILE_FOLDER=%USERNAME%"
if "%MOVE_FILES%"=="" set "MOVE_FILES=1"
if not "%TARGET_DRIVE:~-1%"==":" set "TARGET_DRIVE=%TARGET_DRIVE%:"
set "TARGET_BASE=%TARGET_DRIVE%\Users\%TARGET_PROFILE_FOLDER%"
:: ============================================

echo.
echo =============================================
echo   Windows Profile Folders Relocation Script
echo =============================================
echo.
echo Config file: %CONFIG_FILE%
echo Target drive: %TARGET_DRIVE%
echo Target profile folder: %TARGET_PROFILE_FOLDER%
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

:: Detect current source folders from registry (with %USERPROFILE% fallback)
call :GetShellPath "Desktop" "%USERPROFILE%\Desktop" SRC_DESKTOP
call :GetShellPath "Personal" "%USERPROFILE%\Documents" SRC_DOCUMENTS
call :GetShellPath "My Music" "%USERPROFILE%\Music" SRC_MUSIC
call :GetShellPath "My Pictures" "%USERPROFILE%\Pictures" SRC_PICTURES
call :GetShellPath "My Video" "%USERPROFILE%\Videos" SRC_VIDEOS
call :GetShellPath "{31C0DD25-9439-4F12-BF41-7FF4EDA38722}" "%USERPROFILE%\3D Objects" SRC_3DOBJECTS
call :GetShellPath "Favorites" "%USERPROFILE%\Favorites" SRC_FAVORITES
call :GetShellPath "{56784854-C6CB-462B-8169-88E350ACB882}" "%USERPROFILE%\Contacts" SRC_CONTACTS
call :GetShellPath "{BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968}" "%USERPROFILE%\Links" SRC_LINKS
call :GetShellPath "{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}" "%USERPROFILE%\Saved Games" SRC_SAVEDGAMES
call :GetShellPath "{7D1D3A04-DEBB-4115-95CF-2F29DA2920DA}" "%USERPROFILE%\Searches" SRC_SEARCHES

:: Move files if enabled
if "%MOVE_FILES%"=="1" (
    echo.
    echo Moving existing files to new location...
    echo This may take a while depending on file sizes...
    echo.

    call :MoveKnownFolder "!SRC_DESKTOP!" "%TARGET_BASE%\Desktop" "Desktop"
    call :MoveKnownFolder "!SRC_DOCUMENTS!" "%TARGET_BASE%\Documents" "Documents"
    call :MoveKnownFolder "!SRC_MUSIC!" "%TARGET_BASE%\Music" "Music"
    call :MoveKnownFolder "!SRC_PICTURES!" "%TARGET_BASE%\Pictures" "Pictures"
    call :MoveKnownFolder "!SRC_VIDEOS!" "%TARGET_BASE%\Videos" "Videos"
    call :MoveKnownFolder "!SRC_3DOBJECTS!" "%TARGET_BASE%\3D Objects" "3D Objects"
    call :MoveKnownFolder "!SRC_FAVORITES!" "%TARGET_BASE%\Favorites" "Favorites"
    call :MoveKnownFolder "!SRC_CONTACTS!" "%TARGET_BASE%\Contacts" "Contacts"
    call :MoveKnownFolder "!SRC_LINKS!" "%TARGET_BASE%\Links" "Links"
    call :MoveKnownFolder "!SRC_SAVEDGAMES!" "%TARGET_BASE%\Saved Games" "Saved Games"
    call :MoveKnownFolder "!SRC_SEARCHES!" "%TARGET_BASE%\Searches" "Searches"

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
goto :eof

:GetShellPath
setlocal EnableDelayedExpansion
set "valueName=%~1"
set "fallbackPath=%~2"
set "resolvedPath="
for /f "tokens=1,2,*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "%valueName%" 2^>nul ^| findstr /I /R "REG_"') do (
    set "resolvedPath=%%C"
)
if not defined resolvedPath set "resolvedPath=%fallbackPath%"
call set "resolvedPath=%%resolvedPath%%"
if not defined resolvedPath set "resolvedPath=%fallbackPath%"
endlocal & set "%~3=%resolvedPath%"
exit /b 0

:MoveKnownFolder
setlocal
set "src=%~1"
set "dst=%~2"
set "label=%~3"
if /I "%src%"=="%dst%" (
    echo   Skipping %label%: source already matches target.
    endlocal & exit /b 0
)
if not exist "%src%" (
    echo   Skipping %label%: source path not found - "%src%"
    endlocal & exit /b 0
)
if not exist "%dst%" mkdir "%dst%" >nul 2>&1
robocopy "%src%" "%dst%" /E /MOVE /R:1 /W:1 /NP /NFL /NDL >nul 2>nul
endlocal & exit /b 0
