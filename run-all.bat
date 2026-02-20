@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

set "LOCAL_VER=0"
if exist ".v" for /f "usebackq" %%v in (".v") do set "LOCAL_VER=%%v"

echo ========================================
echo   PCSetup  %LOCAL_VER%
echo ========================================
echo.

set "REPO_ZIP=https://github.com/vaoan/PCSetup/archive/refs/heads/main.zip"
set "VERSION_URL=https://raw.githubusercontent.com/vaoan/PCSetup/main/.v"

:: Check if numbered scripts exist
set "MISSING_SCRIPTS=1"
for %%f in (1-*.bat 2-*.bat) do set "MISSING_SCRIPTS=0"

if "%MISSING_SCRIPTS%"=="1" (
    echo No setup scripts found. Downloading from GitHub...
    echo.
    goto :fetch
)

:: Scripts exist — check remote version
echo Checking for updates...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{(Invoke-WebRequest '%VERSION_URL%' -UseBasicParsing -TimeoutSec 5).Content.Trim() | Set-Content '%TEMP%\pcsetup-ver.txt' -Encoding UTF8}catch{Set-Content '%TEMP%\pcsetup-ver.txt' '0'}"

set "REMOTE_VER=0"
for /f "usebackq" %%v in ("%TEMP%\pcsetup-ver.txt") do set "REMOTE_VER=%%v"
del "%TEMP%\pcsetup-ver.txt" >nul 2>&1

if "%REMOTE_VER%"=="0" (
    echo Could not reach GitHub. Running local scripts.
    echo.
    goto :run_scripts
)

:: Use PowerShell for comparison — timestamps overflow CMD's 32-bit GTR
set "NEEDS_UPDATE=0"
for /f %%r in ('powershell -NoProfile -Command "if('%REMOTE_VER%' -gt '%LOCAL_VER%'){'1'}else{'0'}"') do set "NEEDS_UPDATE=%%r"

if "%NEEDS_UPDATE%"=="1" (
    echo Update available. Downloading latest scripts...
    echo.
    goto :fetch
)

echo Scripts are up to date.
echo.
goto :run_scripts

:fetch
powershell -NoProfile -ExecutionPolicy Bypass -Command "$z='%TEMP%\PCSetup.zip';$e='%TEMP%\PCSetup-ext';$d='%~dp0';Write-Host 'Downloading...';Invoke-WebRequest '%REPO_ZIP%' -OutFile $z -UseBasicParsing;Write-Host 'Extracting...';Expand-Archive $z $e -Force;Write-Host 'Copying files...';Copy-Item \"$e\PCSetup-main\*\" $d -Recurse -Force -Exclude 'run-all.bat';Remove-Item $z,$e -Recurse -Force;Write-Host 'Done.'"
if errorlevel 1 (
    echo ERROR: Failed to download. Check your internet connection.
    pause
    exit /b 1
)
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
