@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo === Work Apps Setup ===

:: Install Chocolatey if not present
where choco >nul 2>&1
if %errorlevel% neq 0 (
    echo Installing Chocolatey...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    set "PATH=%PATH%;%ALLUSERSPROFILE%\chocolatey\bin"
)

echo.
echo Installing Chocolatey packages...
choco install slack -y --ignore-checksums
choco install awscli -y --ignore-checksums

echo.
echo Installing Winget packages...
winget install LinearOrbit.Linear --silent --accept-package-agreements --accept-source-agreements
winget install Figma.Figma --silent --accept-package-agreements --accept-source-agreements

:: Refresh environment variables
echo.
echo Refreshing environment variables...
refreshenv >nul 2>&1

echo.
echo === Setup Complete ===
echo Installed:
echo   - Slack
echo   - AWS CLI
echo   - Linear
echo   - Figma
