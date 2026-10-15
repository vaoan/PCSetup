param([string]$Path)

# Auto-elevate to Administrator (after param(): PowerShell requires param() to be the first statement)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $fwd = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Path) { $fwd += " -Path `"$Path`"" }
    Start-Process PowerShell -ArgumentList $fwd -Verb RunAs
    exit
}

# unlock-pdf.ps1 - Windows setup for the Unlock PDF app (run through unlock-pdf.bat).
#
# The app itself is unlock-pdf\dist\unlock-pdf.jar: a Java window you drop PDFs into, type the
# password once, and get "name (unlocked).pdf" copies. It runs on any OS with Java 8+; this script
# only wires it into Windows:
#   1. builds the jar (unlock-pdf\build.ps1) if it is missing or older than its source;
#   2. creates "Unlock PDF" shortcuts (padlock icon) on the Desktop and in the Start menu, pointing
#      at javaw through Scoop's 'current' junction so a Java update does not break them;
#   3. opens the app NOT elevated (through explorer.exe): Windows blocks drag-and-drop from
#      Explorer into an elevated window (UIPI), so an app started from this elevated script
#      directly would accept no drops at all. A file dropped on the .bat is handed to the app.
#
# Test hook: PCSETUP_UNLOCK_NO_LAUNCH=1 does everything except opening the window.

$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'Unlock PDF setup'

$appDir = Join-Path $PSScriptRoot 'unlock-pdf'
$jar    = Join-Path $appDir 'dist\unlock-pdf.jar'
$failures = New-Object System.Collections.Generic.List[string]

function Write-Ok([string]$t)  { Write-Host "  OK  $t" -ForegroundColor Green }
function Write-Bad([string]$t) { Write-Host "  XX  $t" -ForegroundColor Red }

# --- Java: javaw from Temurin 17 (0-init-prereqs installs it), else whatever is on PATH ----------
$javaw = $null
$jdk17 = (& scoop prefix temurin17-jdk 2>$null | Out-String).Trim()
if ($jdk17 -and (Test-Path -LiteralPath (Join-Path $jdk17 'bin\javaw.exe'))) { $javaw = Join-Path $jdk17 'bin\javaw.exe' }
if (-not $javaw) { $c = Get-Command javaw -ErrorAction SilentlyContinue; if ($c) { $javaw = $c.Source } }
if (-not $javaw) { Write-Bad 'Java is not installed (0-init-prereqs.bat installs Temurin).'; exit 1 }
Write-Ok "Java: $javaw"

# --- 1. Build when needed -------------------------------------------------------------------------
$newestSource = Get-ChildItem -LiteralPath (Join-Path $appDir 'src') -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$stale = (-not (Test-Path -LiteralPath $jar)) -or ($newestSource -and $newestSource.LastWriteTime -gt (Get-Item -LiteralPath $jar).LastWriteTime)
if ($stale) {
    Write-Host '      building unlock-pdf.jar...' -ForegroundColor Gray
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appDir 'build.ps1')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $jar)) { Write-Bad 'build failed'; exit 1 }
}
Write-Ok "app: $jar"

# --- 2. Shortcuts: Desktop (drop target) and Start menu ------------------------------------------
$ws = New-Object -ComObject WScript.Shell
$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Unlock PDF.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Unlock PDF.lnk')
)
foreach ($lnkPath in $targets) {
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = $javaw
    $lnk.Arguments = "-jar `"$jar`""
    $lnk.WorkingDirectory = Split-Path -Parent $jar
    $lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,54"   # the gold padlock
    $lnk.Description = 'Unlock PDF - drop password-protected PDFs, type the password, get copies without it'
    $lnk.Save()
    $check = $ws.CreateShortcut($lnkPath)
    if ((Test-Path -LiteralPath $lnkPath) -and $check.TargetPath -eq $javaw -and $check.Arguments -like "*unlock-pdf.jar*") { Write-Ok "shortcut: $lnkPath" }
    else { $failures.Add("shortcut not written: $lnkPath"); Write-Bad "shortcut not written: $lnkPath" }
}

# --- 3. Open the app, not elevated ---------------------------------------------------------------
if ($env:PCSETUP_UNLOCK_NO_LAUNCH -ne '1') {
    $desktopLnk = $targets[0]
    if ($Path) {
        # explorer.exe cannot pass arguments, so a file dropped on the .bat goes through a one-off
        # shortcut that carries it; it is removed after launch.
        $once = Join-Path $env:TEMP 'Unlock PDF (open file).lnk'
        $l = $ws.CreateShortcut($once)
        $l.TargetPath = $javaw
        $l.Arguments = "-jar `"$jar`" `"$Path`""
        $l.WorkingDirectory = Split-Path -Parent $jar
        $l.Save()
        Start-Process explorer.exe "`"$once`""
        Start-Sleep -Seconds 3
        Remove-Item -LiteralPath $once -Force -ErrorAction SilentlyContinue
    } else {
        Start-Process explorer.exe "`"$desktopLnk`""
    }
    Write-Ok 'Unlock PDF opened'
}

if ($failures.Count -gt 0) { exit 1 }
Write-Host ''
Write-Host '  From now on just open "Unlock PDF" from the Desktop or Start, or drop PDFs on its icon.' -ForegroundColor Cyan
Start-Sleep -Seconds 3
exit 0
