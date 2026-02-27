@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "REPO_URL=https://github.com/vaoan/Profiles"
set "DEPTH=1"
set "TOTAL_STEPS=6"
set "STEP=0"

for /f %%E in ('echo prompt $E^| cmd') do set "ESC=%%E"

call :title "FFXIV Profiles Shallow Clone"
call :step "Checking git"
where git >nul 2>&1
if errorlevel 1 (
  call :error "git is not installed or not in PATH."
  goto :end_error
)

call :step "Resolving Documents path"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "[Environment]::GetFolderPath('MyDocuments')"`) do set "DOCS_DIR=%%I"
if not defined DOCS_DIR (
  call :error "Failed to resolve the Documents folder."
  goto :end_error
)

set "DEST_ABS=%DOCS_DIR%\Juegos\FFXIV\Profiles"

call :step "Preparing destination"
if not exist "%DEST_ABS%" (
  mkdir "%DEST_ABS%" >nul 2>&1
  if errorlevel 1 (
    call :error "Failed to create destination: %DEST_ABS%"
    goto :end_error
  )
)

call :info "Documents: %DOCS_DIR%"
call :info "Destination: %DEST_ABS%"

call :step "Entering destination"
pushd "%DEST_ABS%" >nul 2>&1
if errorlevel 1 (
  call :error "Failed to enter destination: %DEST_ABS%"
  goto :end_error
)

call :step "Cleaning destination contents"
for /f "delims=" %%I in ('dir /b /a') do (
  rd /s /q "%%I" >nul 2>&1
  del /f /q "%%I" >nul 2>&1
)

call :step "Cloning repository"
git -c color.ui=always clone --depth %DEPTH% --single-branch "%REPO_URL%" "."
if errorlevel 1 (
  popd >nul 2>&1
  call :error "Clone failed."
  goto :end_error
)

popd >nul 2>&1
call :ok "Clone completed successfully."
goto :end_ok

:title
echo.
call :cecho 96 "============================================================"
call :cecho 96 "  %~1"
call :cecho 96 "============================================================"
echo.
exit /b 0

:step
set /a STEP+=1
set /a PCT=STEP*100/TOTAL_STEPS
set /a FILLED=PCT/10
set "BAR="
for /l %%N in (1,1,10) do (
  if %%N LEQ !FILLED! (set "BAR=!BAR!#") else (set "BAR=!BAR!-")
)
call :cecho 90 "[!BAR!] !PCT!%%  %~1"
exit /b 0

:info
call :cecho 37 "[info] %~1"
exit /b 0

:ok
call :cecho 92 "[ok]   %~1"
exit /b 0

:error
call :cecho 91 "[error] %~1"
exit /b 0

:cecho
echo(!ESC![%~1m%~2!ESC![0m
exit /b 0

:end_error
echo.
pause
exit /b 1

:end_ok
exit /b 0
