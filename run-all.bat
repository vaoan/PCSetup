@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

echo Running all numbered setup scripts in order...
echo.

for %%n in (1 2 3 4 5 6 7 8 9 10) do (
    for /f "tokens=*" %%f in ('dir /b %%n-*.bat 2^>nul') do (
        echo ========================================
        echo Running: %%f
        echo ========================================
        call "%%f"
        if errorlevel 1 (
            echo.
            echo WARNING: %%f exited with error code %errorlevel%
            echo.
        )
    )
)

echo.
echo ========================================
echo All scripts completed.
echo ========================================
