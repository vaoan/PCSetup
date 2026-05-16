@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Run the Docker-based setup test in a clean Windows Server Core container
:: Requires: Docker Desktop in Windows containers mode (right-click tray → Switch to Windows containers)

set "BRANCH=main"
if not "%1"=="" set "BRANCH=%1"

echo.
echo ========================================
echo   PCSetup Docker Test
echo   Branch: %BRANCH%
echo ========================================
echo.

docker build --build-arg BRANCH=%BRANCH% -f Dockerfile.test . --progress=plain
if %errorlevel% equ 0 (
    echo.
    echo ========================================
    echo   ALL TESTS PASSED
    echo ========================================
) else (
    echo.
    echo ========================================
    echo   TESTS FAILED (exit code %errorlevel%)
    echo ========================================
    exit /b 1
)
