@echo off
:: Auto-elevate to Administrator (keeping a dropped file path; no -ArgumentList when there is
:: none, because Start-Process rejects an empty one - see setup-start-menu.bat)
net session >nul 2>&1
if %errorlevel% neq 0 (
    if "%~1"=="" (
        powershell -Command "Start-Process '%~f0' -Verb RunAs"
    ) else (
        powershell -Command "Start-Process '%~f0' -ArgumentList '\"%~1\"' -Verb RunAs"
    )
    exit /b
)

:: unlock-pdf.bat - sets up the Unlock PDF app (a Java window: drop PDFs in, type the password,
:: get copies without it) and opens it. Run it once; afterwards use the "Unlock PDF" shortcut on
:: the Desktop or in Start. The portable app is unlock-pdf\dist\unlock-pdf.jar (any OS, Java 8+).
:: All logic lives in unlock-pdf.ps1.

setlocal
set "PSModulePath="
title Unlock PDF setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0unlock-pdf.ps1" -Path "%~1"
set "RC=%errorlevel%"
endlocal & exit /b %RC%
