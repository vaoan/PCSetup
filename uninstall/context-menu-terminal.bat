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

echo Done!
