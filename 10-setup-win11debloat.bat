@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

setlocal
echo Running Win11Debloat (RunDefaults + Remove safe apps + Silent)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((irm 'https://debloat.raphi.re/'))) -RunDefaults -RemoveApps -Apps \"Microsoft.OneDrive,Microsoft.YourPhone,Microsoft.WindowsCamera,Microsoft.Windows.Photos,Microsoft.ZuneMusic,Microsoft.RemoteDesktop,Microsoft.Whiteboard\" -Silent"
endlocal
