@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo Enabling classic context menu (always show full menu)...
reg add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve

echo.
echo Adding "Open in Terminal as Administrator" to context menu...

:: CMD - Directory Background
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenTerminalAdmin" /ve /d "Open in Terminal as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenTerminalAdmin" /v "Icon" /d "cmd.exe" /f
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenTerminalAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process cmd -ArgumentList '/k cd /d \"\"%%V\"\"' -Verb RunAs\"" /f

:: CMD - Directory
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenTerminalAdmin" /ve /d "Open in Terminal as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenTerminalAdmin" /v "Icon" /d "cmd.exe" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenTerminalAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process cmd -ArgumentList '/k cd /d \"\"%%V\"\"' -Verb RunAs\"" /f

:: CMD - Drive
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenTerminalAdmin" /ve /d "Open in Terminal as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenTerminalAdmin" /v "Icon" /d "cmd.exe" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenTerminalAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process cmd -ArgumentList '/k cd /d \"\"%%V\"\"' -Verb RunAs\"" /f

echo Adding "Open in PowerShell as Administrator" to context menu...

:: PowerShell - Directory Background
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenPowerShellAdmin" /ve /d "Open in PowerShell as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenPowerShellAdmin" /v "Icon" /d "powershell.exe" /f
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenPowerShellAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process powershell -ArgumentList '-NoExit -Command cd ''\"\"%%V\"\"''' -Verb RunAs\"" /f

:: PowerShell - Directory
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenPowerShellAdmin" /ve /d "Open in PowerShell as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenPowerShellAdmin" /v "Icon" /d "powershell.exe" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenPowerShellAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process powershell -ArgumentList '-NoExit -Command cd ''\"\"%%V\"\"''' -Verb RunAs\"" /f

:: PowerShell - Drive
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenPowerShellAdmin" /ve /d "Open in PowerShell as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenPowerShellAdmin" /v "Icon" /d "powershell.exe" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenPowerShellAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process powershell -ArgumentList '-NoExit -Command cd ''\"\"%%V\"\"''' -Verb RunAs\"" /f

echo Removing default "Git Bash Here" context menu entry...
reg delete "HKEY_CLASSES_ROOT\Directory\Background\shell\git_shell" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Directory\shell\git_shell" /f 2>nul

echo Adding "Open Git Bash here as Administrator" to context menu...

:: Git Bash - Directory Background
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenGitBashAdmin" /ve /d "Open Git Bash here as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenGitBashAdmin" /v "Icon" /d "C:\\Program Files\\Git\\git-bash.exe" /f
reg add "HKEY_CLASSES_ROOT\Directory\Background\shell\OpenGitBashAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process 'C:\\Program Files\\Git\\git-bash.exe' -ArgumentList '--cd=\"\"%%V\"\"' -Verb RunAs\"" /f

:: Git Bash - Directory
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenGitBashAdmin" /ve /d "Open Git Bash here as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenGitBashAdmin" /v "Icon" /d "C:\\Program Files\\Git\\git-bash.exe" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\OpenGitBashAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process 'C:\\Program Files\\Git\\git-bash.exe' -ArgumentList '--cd=\"\"%%V\"\"' -Verb RunAs\"" /f

:: Git Bash - Drive
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenGitBashAdmin" /ve /d "Open Git Bash here as Administrator" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenGitBashAdmin" /v "Icon" /d "C:\\Program Files\\Git\\git-bash.exe" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\OpenGitBashAdmin\command" /ve /d "powershell -WindowStyle Hidden -Command \"Start-Process 'C:\\Program Files\\Git\\git-bash.exe' -ArgumentList '--cd=\"\"%%V\"\"' -Verb RunAs\"" /f

echo Restarting Explorer...
powershell -Command "Stop-Process -Name explorer -Force; Start-Process explorer" >nul 2>&1

echo Done!
