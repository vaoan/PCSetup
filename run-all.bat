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

for /f "tokens=*" %%f in ('dir /b /on [0-9]-*.bat [0-9][0-9]-*.bat 2^>nul') do (
    echo ========================================
    echo Running: %%f
    echo ========================================
    call "%%f"
    if %errorlevel% neq 0 (
        echo.
        echo WARNING: %%f exited with error code %errorlevel%
        echo.
    )
)

echo.
echo ========================================
echo All scripts completed.
echo ========================================
pause
