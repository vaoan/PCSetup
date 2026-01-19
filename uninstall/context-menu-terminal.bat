@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo Removing "Open in Terminal as Administrator" from context menu...

reg delete "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenTerminalAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Directory\shell\OpenTerminalAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Drive\shell\OpenTerminalAdmin" /f 2>nul

echo Removing "Open in PowerShell as Administrator" from context menu...

reg delete "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenPowerShellAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Directory\shell\OpenPowerShellAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Drive\shell\OpenPowerShellAdmin" /f 2>nul

echo Removing "Open Git Bash here as Administrator" from context menu...

reg delete "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenGitBashAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Directory\shell\OpenGitBashAdmin" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Drive\shell\OpenGitBashAdmin" /f 2>nul

echo Restoring Windows 11 modern context menu...
reg delete "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" /f 2>nul

echo Restarting Explorer...
powershell -Command "Stop-Process -Name explorer -Force; Start-Process explorer" >nul 2>&1

echo Done!
