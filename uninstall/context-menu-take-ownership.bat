@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo Removing "Take Ownership" from context menu...

reg delete "HKEY_CLASSES_ROOT\*\shell\TakeOwnership" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Drive\shell\runas" /f 2>nul

echo Done!
