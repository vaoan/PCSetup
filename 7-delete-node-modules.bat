@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo Deleting all node_modules folders on all drives...
echo This may take a while...
echo.

for /f "tokens=*" %%x in ('powershell -NoProfile -Command "(Get-PSDrive -PSProvider FileSystem).Root"') do (
    if exist "%%x" (
        echo.
        echo Scanning drive %%x
        for /d /r "%%x" %%d in (node_modules) do (
            if exist "%%d" (
                echo Deleting: %%d
                rmdir /s /q "%%d"
            )
        )
    )
)

echo.
echo Done!
