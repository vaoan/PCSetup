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
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%APPDATA%\XIVLauncher\addon'"
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%APPDATA%\XIVLauncher\runtime'"

:: FINAL FANTASY XIV
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath 'C:\Program Files (x86)\SquareEnix\FINAL FANTASY XIV - A Realm Reborn'"

:: Disable Smart App Control (blocks Dalamud/Reloaded.Hooks DLLs with "can't confirm publisher")
:: 0 = Off, 1 = Evaluation, 2 = On
powershell -NoProfile -Command "reg add 'HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy' /v 'VerifiedAndReputablePolicyState' /t REG_DWORD /d 0 /f"

echo.
echo Done! Windows Security exclusions have been added.
echo Note: A restart is required for Smart App Control changes to take effect.
