@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Get the drive letter where this script is located
set "drive=%~d0"

echo Deleting all node_modules folders on %drive%\
echo This may take a while...
echo.

for /d /r "%drive%\" %%d in (node_modules) do (
    if exist "%%d" (
        echo Deleting: %%d
        rmdir /s /q "%%d"
    )
)

echo.
echo Done!
pause
