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
if errorlevel 1 (
    exit /b 1
)

echo Removing OneDrive leftovers...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $oneDriveExe=$env:LocalAppData + '\Microsoft\OneDrive\OneDrive.exe'; if(Test-Path $oneDriveExe){ Start-Process -FilePath $oneDriveExe -ArgumentList '/shutdown' -Wait -ErrorAction SilentlyContinue; Start-Process -FilePath $oneDriveExe -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue }; $setupPaths=@($env:SystemRoot + '\System32\OneDriveSetup.exe', $env:SystemRoot + '\SysWOW64\OneDriveSetup.exe') | Select-Object -Unique; foreach($setup in $setupPaths){ if(Test-Path $setup){ Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue } }; Start-Sleep -Seconds 2; Get-Process OneDrive,OneDriveStandaloneUpdater,FileCoAuth -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Get-AppxPackage -AllUsers Microsoft.OneDrive -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue; $policyPath='HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; if(-not (Test-Path $policyPath)){ New-Item -Path $policyPath -Force | Out-Null }; New-ItemProperty -Path $policyPath -Name 'DisableFileSyncNGSC' -PropertyType DWord -Value 1 -Force | Out-Null; $runPaths=@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'); foreach($runPath in $runPaths){ Remove-ItemProperty -Path $runPath -Name 'OneDrive' -ErrorAction SilentlyContinue }; Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OneDrive*' } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue; $namespacePaths=@('Registry::HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}','Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'); foreach($nsPath in $namespacePaths){ if(Test-Path $nsPath){ New-ItemProperty -Path $nsPath -Name 'System.IsPinnedToNameSpaceTree' -PropertyType DWord -Value 0 -Force | Out-Null } }; Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' -Recurse -Force -ErrorAction SilentlyContinue; $folders=@($env:UserProfile + '\OneDrive', $env:LocalAppData + '\Microsoft\OneDrive', $env:ProgramData + '\Microsoft OneDrive', $env:SystemDrive + '\OneDriveTemp'); foreach($folder in $folders){ if(Test-Path $folder){ Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue } }; Start-Sleep -Seconds 1; Start-Process explorer.exe; Write-Host 'OneDrive removal step finished.'"
if errorlevel 1 (
    exit /b 1
)
endlocal
