@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    if not "%PCSETUP_GENERATE_ONLY%"=="1" (
        powershell -Command "Start-Process '%~f0' -Verb RunAs"
        exit /b
    )
)

:: compress-here.bat - "Compress all videos here"
:: Copy this file into any folder and double-click it: every video directly inside THAT folder
:: is compressed to AV1 at the smallest size that still measures VMAF 95+ against the source
:: (no visible difference; a file that cannot get smaller that way is kept). It is the same
:: background job as compress-folder.bat - one job at a time, close the window and it carries
:: on, run it again to watch, X cancels - so all it does is work out which folder it is in and
:: hand that over. It has to be a .bat, not a shortcut: a .lnk with a blank "Start in" runs in
:: its TARGET's folder (C:\Windows\System32 for cmd.exe, verified through Explorer), never in
:: its own, so a shortcut can never know where it was double-clicked. %~dp0 can.
::
:: download-video.ps1 (Ensure-Shortcuts) drops a ready copy of this file into the Videos and
:: Downloads folders with the path below filled in; copy THAT one around. This template only
:: works from inside the PCSetup\optional folder until the placeholder is replaced.

setlocal
set "DIR=%~dp0"
if "%DIR:~-1%"=="\" set "DIR=%DIR:~0,-1%"
if "%DIR:~-1%"==":" set "DIR=%DIR%\."
set "TOOL=%~dp0compress-folder.bat"
if not exist "%TOOL%" set "TOOL=__PCSETUP_OPTIONAL__\compress-folder.bat"
if not exist "%TOOL%" (
    echo compress-folder.bat was not found next to this file or at:
    echo   %TOOL%
    echo Copy the "Compress all videos here.bat" from your Videos folder instead - that one
    echo carries the path to the PCSetup scripts.
    timeout /t 15 >nul
    exit /b 1
)
title Compress all videos here
call "%TOOL%" "%DIR%"
endlocal
exit /b %errorlevel%
