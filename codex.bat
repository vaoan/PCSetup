@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "APP_HOME=%SCRIPT_DIR%\.config"
set "APP_CONFIG_DIR=%APP_HOME%"

if not exist "%APP_HOME%" mkdir "%APP_HOME%"

if not exist "%APP_HOME%\config.toml" (
  if exist "%USERPROFILE%\.app\config.toml" (
    copy /y "%USERPROFILE%\.app\config.toml" "%APP_HOME%\config.toml" >NUL
  ) else (
    > "%APP_HOME%\config.toml" echo model = ^"default^"
    >> "%APP_HOME%\config.toml" echo model_reasoning_effort = ^"medium^"
    >> "%APP_HOME%\config.toml" echo.
    >> "%APP_HOME%\config.toml" echo [mcp_servers.default]
    >> "%APP_HOME%\config.toml" echo url = ^"https://mcp.example.com/mcp^"
  )
)
findstr /c:"[mcp_servers.default]" "%APP_HOME%\config.toml" >NUL
if errorlevel 1 (
  >> "%APP_HOME%\config.toml" echo.
  >> "%APP_HOME%\config.toml" echo [mcp_servers.default]
  >> "%APP_HOME%\config.toml" echo url = ^"https://mcp.example.com/mcp^"
)

set "APP_BIN="
for /f "delims=" %%I in ('where app.cmd 2^>NUL') do set "APP_BIN=%%I" & goto :run
for /f "delims=" %%I in ('where app.exe 2^>NUL') do set "APP_BIN=%%I" & goto :run

echo CLI not found in PATH. Install it or add it to PATH, then rerun.
goto :eof

:run
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -Verb RunAs -FilePath 'cmd.exe' -WorkingDirectory '%SCRIPT_DIR%' -ArgumentList '/k','cd /d %SCRIPT_DIR% && set APP_HOME=%APP_HOME% && set APP_CONFIG_DIR=%APP_CONFIG_DIR% && call \"%APP_BIN%\" --dangerously-bypass-approvals-and-sandbox'"

endlocal
