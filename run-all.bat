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
set "TIME_LIST=%TEMP%\pcsetup-times-%RANDOM%%RANDOM%.txt"
del "%SCRIPT_LIST%" >nul 2>&1
del "%FAIL_LIST%" >nul 2>&1
del "%TIME_LIST%" >nul 2>&1
set "TOTAL_SECONDS=0"

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
set "T_START=%TIME%"
call "%ROOT%%SCRIPT%"
:: Captured on its own line: %errorlevel% inside the if-block below would otherwise expand
:: when the block is parsed, reporting a stale code (the bug this file used to have).
set "RC=%errorlevel%"
set "T_END=%TIME%"
call :elapsed "%T_START%" "%T_END%"
set /a TOTAL_SECONDS+=ELAPSED_SECONDS
>>"%TIME_LIST%" echo   %ELAPSED%  %SCRIPT%  (exit %RC%)
echo.
echo Finished: %SCRIPT% in %ELAPSED% (exit %RC%)
if not "%RC%"=="0" (
    echo.
    echo WARNING: %SCRIPT% exited with code %RC%
    echo.
    >>"%FAIL_LIST%" echo %SCRIPT% - exit %RC% after %ELAPSED%
)
goto :eof

:elapsed
:: Wall-clock seconds between two %TIME% stamps, as ELAPSED ("4m 07s") and ELAPSED_SECONDS.
:: %TIME% is "H:MM:SS.cc" with a leading space before 10:00, which the : =0 substitution turns
:: into a zero; the decimal separator is "." or "," by locale, so both are delimiters. Each
:: field is read as 1xx-100 so "08" and "09" are not parsed as (invalid) octal by set /a.
:: A run that crosses midnight goes negative and gets a day added back.
set "T_A=%~1"
set "T_B=%~2"
set "T_A=%T_A: =0%"
set "T_B=%T_B: =0%"
for /f "tokens=1-3 delims=:.," %%a in ("%T_A%") do set /a "T_SA=(1%%a-100)*3600+(1%%b-100)*60+(1%%c-100)"
for /f "tokens=1-3 delims=:.," %%a in ("%T_B%") do set /a "T_SB=(1%%a-100)*3600+(1%%b-100)*60+(1%%c-100)"
set /a "ELAPSED_SECONDS=T_SB-T_SA"
if %ELAPSED_SECONDS% lss 0 set /a "ELAPSED_SECONDS+=86400"
set /a "T_M=ELAPSED_SECONDS/60, T_S=ELAPSED_SECONDS%%60"
if %T_S% lss 10 (set "ELAPSED=%T_M%m 0%T_S%s") else (set "ELAPSED=%T_M%m %T_S%s")
goto :eof

:summary
del "%SCRIPT_LIST%" >nul 2>&1

:: Per-script wall-clock times, so the next slow step is found by reading, not by guessing.
set /a "TOTAL_M=TOTAL_SECONDS/60, TOTAL_S=TOTAL_SECONDS%%60"
if %TOTAL_S% lss 10 (set "TOTAL_FMT=%TOTAL_M%m 0%TOTAL_S%s") else (set "TOTAL_FMT=%TOTAL_M%m %TOTAL_S%s")
echo.
echo ========================================
echo   Time per script (total %TOTAL_FMT%):
echo ========================================
if exist "%TIME_LIST%" type "%TIME_LIST%"
del "%TIME_LIST%" >nul 2>&1

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
