@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo Enabling Long Paths support...
reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem" /v "LongPathsEnabled" /t REG_DWORD /d 1 /f

echo Adding "Take Ownership" to context menu...

:: Clean up any existing entries first
reg delete "HKEY_CLASSES_ROOT\*\shell\TakeOwnership" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\*\shell\runas" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Directory\shell\runas" /f 2>nul
reg delete "HKEY_CLASSES_ROOT\Drive\shell\runas" /f 2>nul

:: Files - TakeOwnership with PowerShell elevation
reg add "HKEY_CLASSES_ROOT\*\shell\TakeOwnership" /ve /d "Take Ownership" /f
reg add "HKEY_CLASSES_ROOT\*\shell\TakeOwnership" /v "HasLUAShield" /d "" /f
reg add "HKEY_CLASSES_ROOT\*\shell\TakeOwnership" /v "NoWorkingDirectory" /d "" /f
reg add "HKEY_CLASSES_ROOT\*\shell\TakeOwnership" /v "NeverDefault" /d "" /f
reg add "HKEY_CLASSES_ROOT\*\shell\TakeOwnership\command" /ve /d "powershell -windowstyle hidden -command \"Start-Process cmd -ArgumentList '/c takeown /f \\\"%%1\\\" && icacls \\\"%%1\\\" /grant *S-1-3-4:F /t /c /l' -Verb runAs\"" /f
reg add "HKEY_CLASSES_ROOT\*\shell\TakeOwnership\command" /v "IsolatedCommand" /d "powershell -windowstyle hidden -command \"Start-Process cmd -ArgumentList '/c takeown /f \\\"%%1\\\" && icacls \\\"%%1\\\" /grant *S-1-3-4:F /t /c /l' -Verb runAs\"" /f

:: Directories - TakeOwnership with PowerShell elevation
reg add "HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" /ve /d "Take Ownership" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" /v "HasLUAShield" /d "" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" /v "NoWorkingDirectory" /d "" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" /v "Position" /d "middle" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership" /v "AppliesTo" /d "NOT (System.ItemPathDisplay:=\"C:\\Users\" OR System.ItemPathDisplay:=\"C:\\ProgramData\" OR System.ItemPathDisplay:=\"C:\\Windows\" OR System.ItemPathDisplay:=\"C:\\Windows\\System32\" OR System.ItemPathDisplay:=\"C:\\Program Files\" OR System.ItemPathDisplay:=\"C:\\Program Files (x86)\")" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership\command" /ve /d "powershell -windowstyle hidden -command \"Start-Process cmd -ArgumentList '/c takeown /f \\\"%%1\\\" /r /d y && icacls \\\"%%1\\\" /grant *S-1-3-4:F /t /c /l /q' -Verb runAs\"" /f
reg add "HKEY_CLASSES_ROOT\Directory\shell\TakeOwnership\command" /v "IsolatedCommand" /d "powershell -windowstyle hidden -command \"Start-Process cmd -ArgumentList '/c takeown /f \\\"%%1\\\" /r /d y && icacls \\\"%%1\\\" /grant *S-1-3-4:F /t /c /l /q' -Verb runAs\"" /f

:: Drives - runas (auto-elevates) with trailing backslash on path
reg add "HKEY_CLASSES_ROOT\Drive\shell\runas" /ve /d "Take Ownership" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\runas" /v "HasLUAShield" /d "" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\runas" /v "NoWorkingDirectory" /d "" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\runas" /v "Position" /d "middle" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\runas" /v "AppliesTo" /d "NOT (System.ItemPathDisplay:=\"C:\\\")" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\runas\command" /ve /d "cmd.exe /c takeown /f \"%%1\\\" /r /d y && icacls \"%%1\\\" /grant *S-1-3-4:F /t /c" /f
reg add "HKEY_CLASSES_ROOT\Drive\shell\runas\command" /v "IsolatedCommand" /d "cmd.exe /c takeown /f \"%%1\\\" /r /d y && icacls \"%%1\\\" /grant *S-1-3-4:F /t /c" /f

echo Done!
