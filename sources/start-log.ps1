# Starts a transcript of the calling setup script into the PCSetup log on the system drive.
#
# Dot-sourced as the FIRST line of every generated setup script and of init-prereqs.ps1, so a
# run leaves a record even though every window closes on its own when it finishes. Before this
# there was nothing to read afterwards: on 2026-11-18 a run stopped halfway through script 2 and
# the only evidence left was the PowerShell event log.
#
#   C:\PCSetup-logs\run-<yyyyMMdd-HHmmss>.log           everything the scripts print (transcript)
#   C:\PCSetup-logs\run-<yyyyMMdd-HHmmss>-commands.log  full stdout/stderr of every native tool
#                                                       run behind the status line (winget, DISM,
#                                                       msiexec, wsl, npm, installers)
#
# run-all.bat / remote-call.ps1 set PCSETUP_LOG so a whole run shares one file; a numbered script
# started on its own gets a file of its own. Logging must never break a setup step, so every
# failure in here is swallowed.
try {
    $pcsetupLogDir = Join-Path $env:SystemDrive 'PCSetup-logs'
    if ([string]::IsNullOrWhiteSpace($env:PCSETUP_LOG)) {
        $caller = $MyInvocation.PSCommandPath
        $leaf = if ($caller) { [IO.Path]::GetFileNameWithoutExtension($caller) } else { 'script' }
        $env:PCSETUP_LOG = Join-Path $pcsetupLogDir ('{0}-{1}.log' -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $env:PCSETUP_LOG) -Force -ErrorAction SilentlyContinue
    $null = Start-Transcript -LiteralPath $env:PCSETUP_LOG -Append -ErrorAction Stop
    $pcsetupIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $pcsetupStep = if ($env:PCSETUP_CURRENT_SCRIPT) { $env:PCSETUP_CURRENT_SCRIPT } else { Split-Path -Leaf $MyInvocation.PSCommandPath }
    Write-Host ('>>> {0} | {1:yyyy-MM-dd HH:mm:ss} | user {2}\{3} | admin {4} | PS {5} | {6}' -f
        $pcsetupStep, (Get-Date), $env:USERDOMAIN, $env:USERNAME, $pcsetupIsAdmin,
        $PSVersionTable.PSVersion, $MyInvocation.PSCommandPath) -ForegroundColor DarkGray
}
catch { }
