@echo off
setlocal

:: Toggle Claude Code tmux session
:: Usage: toggle-claude-session.bat [session-name]
:: Default: claude

set SESSION=%1
if "%SESSION%"=="" set SESSION=claude

set TASK_NAME=%SESSION%-session

:: Check if task exists
schtasks /query /tn "%TASK_NAME%" >nul 2>&1
if %errorlevel% neq 0 (
    echo Task '%TASK_NAME%' not found.
    echo Run install-claude-session.ps1 first.
    pause
    exit /b 1
)

:: Check if tmux session exists
C:\msys64\usr\bin\bash.exe -lc "tmux has-session -t %SESSION% 2>/dev/null"
if %errorlevel%==0 (
    echo Stopping %SESSION% session...
    C:\msys64\usr\bin\bash.exe -lc "tmux kill-session -t %SESSION% 2>/dev/null"
    echo %SESSION% session stopped.
) else (
    echo Starting %SESSION% session...
    schtasks /run /tn "%TASK_NAME%"
    timeout /t 2 /nobreak >nul
    echo %SESSION% session starting...
    echo.
    echo To attach, run: tmux attach -t %SESSION%
)

pause
