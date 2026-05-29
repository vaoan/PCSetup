@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

:: Drives to skip (comma-separated, e.g. 'P','Q')
set "SKIP_DRIVES='P','C','I'"

echo Deleting all node_modules folders on all drives (skipping: %SKIP_DRIVES%)...
echo This may take a while...
echo.

powershell -NoProfile -Command ^
    "$skip = @(%SKIP_DRIVES%);" ^
    "$excludePaths = @('C:\Program Files\Microsoft VS Code', 'C:\Program Files (x86)\Microsoft VS Code', \"$env:LOCALAPPDATA\Streamlabs OBS\", 'C:\Program Files\Slack');" ^
    "$drives = (Get-PSDrive -PSProvider FileSystem).Root;" ^
    "foreach ($drive in $drives) {" ^
    "    if ($skip -contains $drive.Substring(0,1)) { Write-Host \"`nSkipping drive $drive\"; continue };" ^
    "    if (Test-Path $drive) {" ^
    "        Write-Host \"`nScanning drive $drive\";" ^
    "        Get-ChildItem -Path $drive -Directory -Filter 'node_modules' -Recurse -ErrorAction SilentlyContinue | " ^
    "        Where-Object { $_.FullName -notmatch '\\node_modules\\.*\\node_modules' } | " ^
    "        Where-Object { $path = $_.FullName; -not ($excludePaths | Where-Object { $path -like \"$_*\" }) } | " ^
    "        ForEach-Object {" ^
    "            Write-Host \"Deleting: $($_.FullName)\";" ^
    "            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue" ^
    "        }" ^
    "    }" ^
    "}"

echo.
echo Done!
