@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Drives to skip (comma-separated, e.g. 'P','Q')
set "SKIP_DRIVES='P'"

echo Deleting all node_modules folders on all drives (skipping: %SKIP_DRIVES%)...
echo This may take a while...
echo.

powershell -NoProfile -Command ^
    "$skip = @(%SKIP_DRIVES%);" ^
    "$drives = (Get-PSDrive -PSProvider FileSystem).Root;" ^
    "foreach ($drive in $drives) {" ^
    "    if ($skip -contains $drive.Substring(0,1)) { Write-Host \"`nSkipping drive $drive\"; continue };" ^
    "    if (Test-Path $drive) {" ^
    "        Write-Host \"`nScanning drive $drive\";" ^
    "        Get-ChildItem -Path $drive -Directory -Filter 'node_modules' -Recurse -ErrorAction SilentlyContinue | " ^
    "        Where-Object { $_.FullName -notmatch '\\node_modules\\.*\\node_modules' } | " ^
    "        ForEach-Object {" ^
    "            Write-Host \"Deleting: $($_.FullName)\";" ^
    "            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue" ^
    "        }" ^
    "    }" ^
    "}"

echo.
echo Done!
