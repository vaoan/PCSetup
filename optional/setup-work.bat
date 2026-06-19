@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo === Work Apps Setup ===

echo.
echo Installing Scoop packages...
where scoop >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Scoop is missing. Run ..\0-init-prereqs.bat first.
    exit /b 1
)
scoop install slack
scoop install aws

echo.
echo Installing Winget packages...
winget install LinearOrbit.Linear --silent --accept-package-agreements --accept-source-agreements
winget install Figma.Figma --silent --accept-package-agreements --accept-source-agreements
winget install Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
winget install Codeium.Windsurf --silent --accept-package-agreements --accept-source-agreements

:: Refresh environment variables
echo.
echo Refreshing environment variables...
set "PATH=%PATH%;%USERPROFILE%\scoop\shims;%ProgramData%\scoop\shims"

echo.
echo === Setup Complete ===
echo Installed:
echo   - Slack
echo   - AWS CLI
echo   - Linear
echo   - Figma
echo   - Docker Desktop
echo   - Windsurf
