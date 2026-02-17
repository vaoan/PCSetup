@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo Adding Windows Security exclusions...

:: XIVLauncher / Dalamud
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%APPDATA%\XIVLauncher'"

:: FINAL FANTASY XIV
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath 'C:\Program Files (x86)\SquareEnix\FINAL FANTASY XIV - A Realm Reborn'"

echo.
echo Done! Windows Security exclusions have been added.
