@echo off
:: Runs every numbered setup script (0-* through 99-*) in order, from this folder.
::
:: This runner ONLY runs scripts. It does not download, update or stage them -
:: bootstrapping a fresh machine is remote-call.ps1's job (irm i.ffxiv.be ^| iex),
:: which materializes the repo into a temp workspace and then calls this file.
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

:: Windows PowerShell must not inherit a PS7 PSModulePath. It then refuses to load the
:: Core-only Microsoft.PowerShell.Utility, taking Where-Object and Sort-Object with it -
:: so the enumeration below returns nothing and NOT ONE script runs, silently, whenever
:: this is launched from WezTerm (whose default shell is pwsh).
::
:: Deliberately NOT `setlocal enabledelayedexpansion`: `call` hands that state to the
:: numbered scripts, and 5-move-profile-folders.bat alone contains 13 literal `!`
:: characters that delayed expansion would eat. Exit codes are captured in the :run_one
:: subroutine instead, where each statement is parsed as it is reached.
setlocal
set "PSModulePath="

cd /d "%~dp0"
set "ROOT=%~dp0"

set "EXITCODE=0"
set "LOCAL_VER="
if exist ".v" for /f "usebackq" %%v in (".v") do set "LOCAL_VER=%%v"

echo ========================================
echo   PCSetup  %LOCAL_VER%
echo ========================================
echo.

set "SCRIPT_LIST=%TEMP%\pcsetup-scripts-%RANDOM%%RANDOM%.txt"
set "FAIL_LIST=%TEMP%\pcsetup-failures-%RANDOM%%RANDOM%.txt"
del "%SCRIPT_LIST%" >nul 2>&1
del "%FAIL_LIST%" >nul 2>&1

:: The digit filter is load-bearing: '*-*.bat' alone also matches run-all.bat (which would
:: then call itself, recursively) and test-local.bat (which launches the Docker suite in the
:: middle of a setup run). Both sort to the FRONT, because [int]'run' throws inside the
:: Sort-Object scriptblock and Sort-Object emits the item anyway rather than dropping it.
:: [char]::IsDigit rather than a '^\d+-' regex - a caret inside a for /f backtick block is
:: eaten by CMD as an escape character before PowerShell ever sees it.
:: -Value (not the pipeline) so the file is still created when nothing matches. Piping an
:: empty result into Set-Content never creates it, which made "no scripts here" look
:: identical to "PowerShell failed" - two problems with very different fixes.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$names = @(Get-ChildItem -LiteralPath '%ROOT%' -Filter '*-*.bat' | Where-Object { [char]::IsDigit($_.BaseName[0]) } | Sort-Object { [int]($_.BaseName -split '-')[0] } | ForEach-Object { $_.Name }); Set-Content -LiteralPath '%SCRIPT_LIST%' -Value $names -Encoding ASCII"
if not exist "%SCRIPT_LIST%" (
    echo ERROR: Could not enumerate the setup scripts - PowerShell did not run.
    exit /b 1
)

set "TOTAL=0"
for /f "usebackq delims=" %%f in ("%SCRIPT_LIST%") do set /a TOTAL+=1

if "%TOTAL%"=="0" (
    echo ERROR: No numbered setup scripts found in:
    echo   %~dp0
    echo.
    echo This runner does not download anything. Bootstrap the repo first:
    echo   irm i.ffxiv.be ^| iex
    del "%SCRIPT_LIST%" >nul 2>&1
    exit /b 1
)

echo Running %TOTAL% setup scripts in order:
for /f "usebackq delims=" %%f in ("%SCRIPT_LIST%") do echo    %%f
echo.

for /f "usebackq delims=" %%f in ("%SCRIPT_LIST%") do call :run_one "%%f"

goto :summary

:run_one
set "SCRIPT=%~1"
echo ========================================
echo Running: %SCRIPT%
echo ========================================
:: Called by absolute path, and the working directory is restored first. A bare
:: `call %SCRIPT%` relies on CMD searching the current directory, which it will not do
:: when NoDefaultCurrentDirectoryInExePath=1 is set - every script then fails with
:: "is not recognized" and the whole run silently accomplishes nothing. Restoring the
:: cwd also covers a script that cd's away without a setlocal to unwind it.
cd /d "%ROOT%"
call "%ROOT%%SCRIPT%"
:: Captured on its own line: %errorlevel% inside the if-block below would otherwise expand
:: when the block is parsed, reporting a stale code (the bug this file used to have).
set "RC=%errorlevel%"
if not "%RC%"=="0" (
    echo.
    echo WARNING: %SCRIPT% exited with code %RC%
    echo.
    >>"%FAIL_LIST%" echo %SCRIPT% - exit %RC%
)
goto :eof

:summary
del "%SCRIPT_LIST%" >nul 2>&1

echo.
echo ========================================
if exist "%FAIL_LIST%" (
    echo   Completed with failures:
    echo ========================================
    type "%FAIL_LIST%"
    del "%FAIL_LIST%" >nul 2>&1
    set "EXITCODE=1"
) else (
    echo   All %TOTAL% scripts completed successfully.
    echo ========================================
)

if /I "%PCSETUP_REMOTE_CALL%"=="1" (
    echo Remote call mode detected. Skipping workspace folder open.
    exit /b %EXITCODE%
)

echo.
echo Opening setup folder...
explorer.exe "%~dp0"
exit /b %EXITCODE%
