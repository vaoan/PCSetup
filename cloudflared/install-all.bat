@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-all.ps1" %*
exit /b %errorlevel%
