@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

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
