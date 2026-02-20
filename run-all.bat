@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

:: Check if numbered scripts exist; if not, download from GitHub
set "REPO_ZIP=https://github.com/vaoan/PCSetup/archive/refs/heads/main.zip"
set "MISSING_SCRIPTS=1"
for %%f in (1-*.bat 2-*.bat) do set "MISSING_SCRIPTS=0"

if "%MISSING_SCRIPTS%"=="0" goto :run_scripts

echo No setup scripts found. Downloading from GitHub...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$z='%TEMP%\PCSetup.zip';$e='%TEMP%\PCSetup-ext';$d='%~dp0';Write-Host 'Downloading...';Invoke-WebRequest '%REPO_ZIP%' -OutFile $z -UseBasicParsing;Write-Host 'Extracting...';Expand-Archive $z $e -Force;Write-Host 'Copying files...';Copy-Item \"$e\PCSetup-main\*\" $d -Recurse -Force -Exclude 'run-all.bat';Remove-Item $z,$e -Recurse -Force;Write-Host 'Done.'"
if errorlevel 1 (
    echo ERROR: Failed to download. Check your internet connection.
    pause
    exit /b 1
)
echo Files downloaded successfully.
echo.

:run_scripts
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
