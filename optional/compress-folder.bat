@echo off
:: Auto-elevate to Administrator (keeping the dropped folder path)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -ArgumentList '\"%~1\"' -Verb RunAs"
    exit /b
)

:: compress-folder.bat
:: Re-encodes every video directly inside a folder to AV1 (SVT-AV1 on the CPU, at the smallest
:: size that still measures VMAF 95+ against the source; a file that cannot get smaller without
:: visible loss is kept), largest file first, as one background job: close the window
:: and it carries on, run it again to watch, press X in the window to cancel. Three ways to use it:
::   - double-click: the Downloads folder
::   - drop a folder onto this .bat
::   - run it with the folder as the argument:  compress-folder.bat "Z:\some\folder"
:: Subfolders are not searched. All logic lives in download-video.ps1 next to this file
:: (-CompressDownloads / -CompressFolder); each file goes through the same verify-then-swap as a
:: download, so a file that would not get smaller is kept as it is.

setlocal
set "PSModulePath="
title Compress Folder
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-video.ps1" -CompressDownloads
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-video.ps1" -CompressFolder "%~1"
)
endlocal
exit /b %errorlevel%
