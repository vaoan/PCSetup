@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

cd /d "%~dp0"

set "LOCAL_VER="
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

set "NEEDS_UPDATE=1"
if not "%LOCAL_VER%"=="" (
    for /f %%r in ('powershell -NoProfile -Command "if('%REMOTE_VER%' -ne '%LOCAL_VER%'){'1'}else{'0'}"') do set "NEEDS_UPDATE=%%r"
)

if "%NEEDS_UPDATE%"=="1" (
    echo Update available. Downloading latest scripts...
    echo.
    goto :fetch
)

echo Scripts are up to date.
echo.
goto :run_scripts

:fetch
echo Downloading...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest '%REPO_ZIP%' -OutFile '%TEMP%\PCSetup.zip' -UseBasicParsing"
if errorlevel 1 (
    echo ERROR: Download failed. Check your internet connection.
    exit /b 1
)

echo Extracting...
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path '%TEMP%\PCSetup-ext') { Remove-Item '%TEMP%\PCSetup-ext' -Recurse -Force }; Expand-Archive '%TEMP%\PCSetup.zip' -DestinationPath '%TEMP%\PCSetup-ext' -Force"
if errorlevel 1 (
    echo ERROR: Extraction failed.
    exit /b 1
)

echo Copying files...
robocopy "%TEMP%\PCSetup-ext\PCSetup-main" "%~dp0." /E /IS /IT /NFL /NDL /NJH /NJS /NC /NS
if %errorlevel% GEQ 16 (
    echo ERROR: Fatal copy failure.
    exit /b 1
)
if defined REMOTE_VER if not "%REMOTE_VER%"=="0" (
    >"%~dp0.v" echo %REMOTE_VER%
)

rd /s /q "%TEMP%\PCSetup-ext" >nul 2>&1
del /q "%TEMP%\PCSetup.zip" >nul 2>&1
echo Done. Relaunching...
powershell -Command "Start-Process '%~f0' -Verb RunAs"
exit /b

:run_scripts
echo Running all numbered setup scripts in order...
echo.

for /f %%g in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString(\"n\")"') do set "STAGE_DIR=%TEMP%\PCSetup-run-%%g"
echo Staging scripts in: %STAGE_DIR%
mkdir "%STAGE_DIR%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Unable to create staging directory.
    exit /b 1
)

robocopy "%~dp0." "%STAGE_DIR%" *.bat *.config .v /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS >nul
if %errorlevel% GEQ 8 (
    echo ERROR: Failed to stage scripts to temp.
    rd /s /q "%STAGE_DIR%" >nul 2>&1
    exit /b 1
)

:: sources\ has to come along: 0-init-prereqs.bat runs sources\init-prereqs.ps1, so staging
:: only the top-level files made script 0 abort with "Missing prerequisite script" — which is
:: the step that installs Scoop and Java, so every later script failed too.
:: Uses "if errorlevel 8" rather than "%errorlevel% GEQ 8" because this sits inside a
:: parenthesized block, where %errorlevel% would expand before robocopy ever ran.
if exist "%~dp0sources" (
    robocopy "%~dp0sources" "%STAGE_DIR%\sources" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS >nul
    if errorlevel 8 (
        echo ERROR: Failed to stage sources folder to temp.
        rd /s /q "%STAGE_DIR%" >nul 2>&1
        exit /b 1
    )
)

:: The digit filter is load-bearing: '*-*.bat' alone also matches run-all.bat (recursing into
:: itself) and test-local.bat (launching the Docker suite mid-setup). Both sorted to the FRONT,
:: because [int]'run' throws and Sort-Object emits the item anyway instead of dropping it.
:: [char]::IsDigit rather than a '^\d+-' regex — a caret inside a for /f backtick block is
:: eaten by CMD as an escape character before PowerShell ever sees it.
pushd "%STAGE_DIR%"
for /f "usebackq delims=" %%f in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Filter '*-*.bat' | Where-Object { [char]::IsDigit($_.BaseName[0]) } | Sort-Object { [int]($_.BaseName -split '-')[0] } | ForEach-Object { $_.Name }"`) do (
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
popd
rd /s /q "%STAGE_DIR%" >nul 2>&1

echo.
echo ========================================
echo All scripts completed.
echo ========================================
if /I "%PCSETUP_REMOTE_CALL%"=="1" (
    echo Remote call mode detected. Skipping workspace folder open.
    exit /b
)
echo Opening download folder...
explorer.exe "%~dp0"
