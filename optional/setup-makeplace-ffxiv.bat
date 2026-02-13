@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

SETLOCAL
SET SCRIPT=%TEMP%\temp-makeplace-setup.ps1
if exist "%SCRIPT%" del "%SCRIPT%" >nul

(
echo Set-ExecutionPolicy Bypass -Scope Process -Force
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo.
echo Write-Host ""
echo Write-Host "**********************************************" -ForegroundColor Magenta
echo Write-Host "*                                            *" -ForegroundColor Magenta
echo Write-Host "*   Re:MakePlace Installer                   *" -ForegroundColor Magenta
echo Write-Host "*   FFXIV Housing Layout Tool                *" -ForegroundColor Magenta
echo Write-Host "*                                            *" -ForegroundColor Magenta
echo Write-Host "**********************************************" -ForegroundColor Magenta
echo Write-Host ""
echo.
echo # Set paths
echo $makeplaceDir = [Environment]::GetFolderPath^('MyDocuments'^) + "\ReMakePlace"
echo $desktopPath = [Environment]::GetFolderPath^('Desktop'^)
echo $versionFile = "$makeplaceDir\version.txt"
echo $shortcutPath = "$desktopPath\Re-MakePlace.lnk"
echo.
echo # Get latest release info from GitHub first
echo Write-Host "Checking for latest Re:MakePlace version..." -ForegroundColor Cyan
echo $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/RemakePlace/app/releases/latest"
echo $latestVersion = $releaseInfo.tag_name
echo $releaseName = $releaseInfo.name
echo $asset = $releaseInfo.assets ^| Where-Object { $_.name -like "*.7z" } ^| Select-Object -First 1
echo.
echo if ^(-not $asset^) {
echo     Write-Host "ERROR: Could not find download asset!" -ForegroundColor Red
echo     exit 1
echo }
echo.
echo Write-Host "Latest version: $releaseName" -ForegroundColor Green
echo Write-Host ""
echo.
echo # Check if already installed and get current version
echo $existingExe = $null
echo $installedVersion = $null
echo if ^(Test-Path $makeplaceDir^) {
echo     $existingExe = Get-ChildItem -Path $makeplaceDir -Recurse -Filter "MakePlace.exe" -ErrorAction SilentlyContinue ^| Select-Object -First 1
echo     if ^(Test-Path $versionFile^) {
echo         $installedVersion = Get-Content $versionFile -ErrorAction SilentlyContinue
echo     }
echo }
echo.
echo # Function to create shortcut
echo function Create-Shortcut^($targetExe^) {
echo     Write-Host "Creating desktop shortcut..." -ForegroundColor Cyan
echo     $shell = New-Object -ComObject WScript.Shell
echo     $shortcut = $shell.CreateShortcut^($shortcutPath^)
echo     $shortcut.TargetPath = $targetExe.FullName
echo     $shortcut.WorkingDirectory = $targetExe.DirectoryName
echo     $shortcut.IconLocation = $targetExe.FullName
echo     $shortcut.Description = "FFXIV Housing Layout Tool"
echo     $shortcut.Save^(^)
echo     Write-Host "Desktop shortcut created!" -ForegroundColor Green
echo }
echo.
echo # Check if we need to install/update
echo if ^($existingExe -and $installedVersion^) {
echo     Write-Host "Installed version: $installedVersion" -ForegroundColor Cyan
echo.
echo     if ^($installedVersion -eq $latestVersion -and $existingExe^) {
echo         Write-Host ""
echo         Write-Host "**********************************************" -ForegroundColor Green
echo         Write-Host "*  Already up to date!                       *" -ForegroundColor Green
echo         Write-Host "**********************************************" -ForegroundColor Green
echo         Write-Host ""
echo.
echo         # Ensure shortcut exists
echo         if ^(-not ^(Test-Path $shortcutPath^)^) {
echo             Create-Shortcut $existingExe
echo         }
echo.
echo         explorer.exe $existingExe.DirectoryName
echo         exit
echo     } else {
echo         Write-Host "Update available! Updating..." -ForegroundColor Yellow
echo         Write-Host ""
echo         # Remove old installation
echo         Remove-Item -Path $makeplaceDir -Recurse -Force -ErrorAction SilentlyContinue
echo     }
echo } elseif ^($existingExe^) {
echo     Write-Host "Installed version: Unknown ^(no version file^)" -ForegroundColor Yellow
echo     Write-Host "Re-installing to track version..." -ForegroundColor Yellow
echo     Write-Host ""
echo     Remove-Item -Path $makeplaceDir -Recurse -Force -ErrorAction SilentlyContinue
echo } else {
echo     Write-Host "Re:MakePlace not installed. Installing..." -ForegroundColor Cyan
echo     Write-Host ""
echo }
echo.
echo # Check for 7-Zip
echo Write-Host "Checking for 7-Zip..." -ForegroundColor Cyan
echo $7zPaths = @^(
echo     "$env:ProgramFiles\7-Zip\7z.exe",
echo     "${env:ProgramFiles^(x86^)}\7-Zip\7z.exe"
echo ^)
echo $7zExe = $null
echo foreach ^($path in $7zPaths^) {
echo     if ^(Test-Path $path^) {
echo         $7zExe = $path
echo         Write-Host "7-Zip found: $7zExe" -ForegroundColor Green
echo         break
echo     }
echo }
echo.
echo # Install 7-Zip if not found
echo if ^(-not $7zExe^) {
echo     Write-Host "7-Zip not found. Downloading and installing..." -ForegroundColor Yellow
echo     $7zInstaller = "$env:TEMP\7z-setup.exe"
echo     $7zUrl = "https://www.7-zip.org/a/7z2501-x64.exe"
echo     curl.exe -L --progress-bar -o $7zInstaller $7zUrl
echo     Write-Host "Installing 7-Zip ^(signed installer^)..." -ForegroundColor Cyan
echo     Start-Process -FilePath $7zInstaller -ArgumentList "/S" -Wait
echo     Remove-Item $7zInstaller -Force -ErrorAction SilentlyContinue
echo     $7zExe = "$env:ProgramFiles\7-Zip\7z.exe"
echo     if ^(Test-Path $7zExe^) {
echo         Write-Host "7-Zip installed successfully!" -ForegroundColor Green
echo     } else {
echo         Write-Host "ERROR: 7-Zip installation failed!" -ForegroundColor Red
echo         exit 1
echo     }
echo }
echo.
echo # Download
echo $downloadUrl = $asset.browser_download_url
echo $fileName = $asset.name
echo $fileSize = [math]::Round^($asset.size / 1GB, 2^)
echo.
echo Write-Host ""
echo Write-Host "Downloading $releaseName ^($fileSize GB^)..." -ForegroundColor Cyan
echo Write-Host ""
echo.
echo $downloadPath = "$env:TEMP\$fileName"
echo curl.exe -L --progress-bar -o $downloadPath $downloadUrl
echo.
echo Write-Host ""
echo Write-Host "Download complete! Extracting..." -ForegroundColor Cyan
echo.
echo # Create install directory
echo New-Item -ItemType Directory -Path $makeplaceDir -Force ^| Out-Null
echo.
echo # Extract using 7-Zip
echo $7zArgs = "x `"$downloadPath`" -o`"$makeplaceDir`" -y"
echo Start-Process -FilePath $7zExe -ArgumentList $7zArgs -Wait -NoNewWindow
echo.
echo # Clean up download
echo Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
echo.
echo # Find the exe ^(might be in a subfolder^)
echo $exePath = Get-ChildItem -Path $makeplaceDir -Recurse -Filter "MakePlace.exe" ^| Select-Object -First 1
echo.
echo if ^($exePath^) {
echo     # Save version file
echo     $latestVersion ^| Out-File -FilePath $versionFile -Encoding UTF8 -NoNewline
echo.
echo     # Create desktop shortcut
echo     Create-Shortcut $exePath
echo.
echo     Write-Host ""
echo     Write-Host "**********************************************" -ForegroundColor Green
echo     Write-Host "*  Re:MakePlace installed successfully!      *" -ForegroundColor Green
echo     Write-Host "**********************************************" -ForegroundColor Green
echo     Write-Host ""
echo     Write-Host "Version: $latestVersion" -ForegroundColor Cyan
echo     Write-Host "Location: $^($exePath.DirectoryName^)" -ForegroundColor Cyan
echo     Write-Host ""
echo     explorer.exe $exePath.DirectoryName
echo } else {
echo     Write-Host ""
echo     Write-Host "Extraction complete! Files are in: $makeplaceDir" -ForegroundColor Green
echo     Write-Host "Look for MakePlace.exe to run the application." -ForegroundColor Yellow
echo     explorer.exe $makeplaceDir
echo }
) > "%SCRIPT%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
ENDLOCAL
