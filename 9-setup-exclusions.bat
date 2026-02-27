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
echo Setting Google Chrome as default browser/PDF/email handler...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$ErrorActionPreference='Stop';" ^
 "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072;" ^
 "if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null };" ^
 "if (-not (Get-Module -ListAvailable -Name PS-SFTA)) { Install-Module PS-SFTA -Scope CurrentUser -Force -AllowClobber };" ^
 "Import-Module PS-SFTA -Force;" ^
 "Set-PTA ChromeHTML http;" ^
 "Set-PTA ChromeHTML https;" ^
 "Set-PTA ChromeHTML mailto;" ^
 "Set-FTA ChromeHTML .htm;" ^
 "Set-FTA ChromeHTML .html;" ^
 "Set-FTA ChromePDF .pdf"
if %errorlevel% neq 0 (
    echo WARNING: Could not fully apply Chrome default-app associations.
    echo You can set them manually in Settings ^> Apps ^> Default apps ^> Google Chrome.
)

echo.
echo Done! Windows Security exclusions have been added.
echo Note: A restart is required for Smart App Control changes to take effect.
