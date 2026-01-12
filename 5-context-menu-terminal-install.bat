@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

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

echo Done!
