$ErrorActionPreference = "Stop"
$ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { (Get-Location).Path } else { $PSScriptRoot }
$ScriptPath = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { Join-Path $ScriptRoot "run-all.ps1" } else { $PSCommandPath }

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$ScriptPath`""
    )
    exit
}

Set-Location -Path $ScriptRoot

$localVer = ""
if (Test-Path ".v") {
    $localVer = (Get-Content ".v" -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
}

Write-Host "========================================"
Write-Host "  PCSetup  $localVer"
Write-Host "========================================"
Write-Host ""

$repoZip = "https://github.com/vaoan/PCSetup/archive/refs/heads/main.zip"
$versionUrl = "https://raw.githubusercontent.com/vaoan/PCSetup/main/.v"

function Invoke-FetchAndRelaunch {
    param(
        [string]$ExpectedVersion = ""
    )
    Write-Host "Downloading..."
    $zipPath = Join-Path $env:TEMP "PCSetup.zip"
    $extractPath = Join-Path $env:TEMP "PCSetup-ext"

    Invoke-WebRequest -Uri $repoZip -OutFile $zipPath -UseBasicParsing

    Write-Host "Extracting..."
    if (Test-Path $extractPath) {
        Remove-Item $extractPath -Recurse -Force
    }
    Expand-Archive $zipPath -DestinationPath $extractPath -Force

    Write-Host "Copying files..."
    $sourcePath = Join-Path $extractPath "PCSetup-main"
    $copyProc = Start-Process -FilePath "robocopy.exe" -ArgumentList @(
        $sourcePath, $ScriptRoot, "/E", "/IS", "/IT", "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS"
    ) -Wait -PassThru -NoNewWindow
    if ($copyProc.ExitCode -ge 16) {
        throw "Fatal copy failure (robocopy exit code $($copyProc.ExitCode))."
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $ExpectedVersion -ne "0") {
        Set-Content -Path (Join-Path $ScriptRoot ".v") -Value $ExpectedVersion -Encoding UTF8
    }

    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    Write-Host "Done. Relaunching..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$ScriptPath`""
    )
    exit
}

$missingScripts = -not (Get-ChildItem -Path $ScriptRoot -Filter "1-*.bat" -ErrorAction SilentlyContinue) -or
                  -not (Get-ChildItem -Path $ScriptRoot -Filter "2-*.bat" -ErrorAction SilentlyContinue)

if ($missingScripts) {
    Write-Host "No setup scripts found. Downloading from GitHub..."
    Write-Host ""
    Invoke-FetchAndRelaunch
}

Write-Host "Checking for updates..."
$remoteVer = "0"
try {
    $remoteVer = (Invoke-WebRequest -Uri $versionUrl -UseBasicParsing -TimeoutSec 5).Content.Trim()
} catch {
    $remoteVer = "0"
}

if ($remoteVer -eq "0") {
    Write-Host "Could not reach GitHub. Running local scripts."
    Write-Host ""
} else {
    $needsUpdate = ($localVer -eq "") -or ($remoteVer -ne $localVer)
    if ($needsUpdate) {
        Write-Host "Update available. Downloading latest scripts..."
        Write-Host ""
        Invoke-FetchAndRelaunch -ExpectedVersion $remoteVer
    }
    Write-Host "Scripts are up to date."
    Write-Host ""
}

Write-Host "Running all numbered setup scripts in order..."
Write-Host ""

$stageDir = Join-Path $env:TEMP ("PCSetup-run-{0}-{1}" -f (Get-Random), (Get-Random))
Write-Host "Staging scripts in: $stageDir"
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

$copyStageProc = Start-Process -FilePath "robocopy.exe" -ArgumentList @(
    $ScriptRoot, $stageDir, "*.bat", "*.config", ".v", "/R:1", "/W:1", "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS"
) -Wait -PassThru -NoNewWindow
if ($copyStageProc.ExitCode -ge 8) {
    throw "Failed to stage scripts to temp (robocopy exit code $($copyStageProc.ExitCode))."
}

Push-Location $stageDir
try {
    foreach ($n in 1..10) {
        $pattern = "{0}-*.bat" -f $n
        $files = Get-ChildItem -Path $stageDir -Filter $pattern -File -ErrorAction SilentlyContinue | Sort-Object Name
        foreach ($file in $files) {
            Write-Host "========================================"
            Write-Host "Running: $($file.Name)"
            Write-Host "========================================"

            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($file.FullName)`"" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                Write-Host ""
                Write-Host "WARNING: $($file.Name) exited with error code $($proc.ExitCode)"
                Write-Host ""
            }
        }
    }
} finally {
    Pop-Location
    Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================"
Write-Host "All scripts completed."
Write-Host "========================================"
