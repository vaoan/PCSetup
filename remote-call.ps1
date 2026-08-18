param([string]$Branch = "main")

# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Branch `"$Branch`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

# Server Core images do not always preload the compression assemblies used below.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoZipUrl = "https://github.com/vaoan/PCSetup/archive/refs/heads/$Branch.zip"
$workDir = Join-Path $env:TEMP ("PCSetup-remote-{0}-{1}" -f (Get-Date -Format "yyyyMMddHHmmss"), (Get-Random))
# NOTE: deliberately not "PCSetup-$Branch". GitHub replaces every '/' in a branch
# name with '-' in the archive's top-level folder, so branch fix/foo extracts to
# PCSetup-fix-foo. String-building the name matched zero entries for any branch
# with a slash, the workspace was materialized EMPTY, and the run died much later
# with the thoroughly misleading "run-all.bat was not found in the remote archive"
# - i.e. it looked like a broken download rather than a branch-name bug. The real
# root name is read from the archive itself below.
$repoRootName = $null
$allowedExtensions = @(".bat", ".config", ".v")
# One level of subfolder is materialized too: 0-init-prereqs.bat runs sources\init-prereqs.ps1,
# and a top-level-only workspace made script 0 abort with "Missing prerequisite script".
$allowedSubdirectories = @{ "sources" = @(".ps1", ".reg") }

try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    Write-Host "Downloading remote setup archive into memory..." -ForegroundColor Cyan
    $zipBytes = [System.Net.WebClient]::new().DownloadData($repoZipUrl)
    if (-not $zipBytes -or $zipBytes.Length -eq 0) {
        throw "Downloaded archive is empty."
    }

    $memStream = New-Object System.IO.MemoryStream(,$zipBytes)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($memStream, [System.IO.Compression.ZipArchiveMode]::Read)
        try {
            # Resolve the archive's actual top-level folder rather than assuming it.
            $repoRootName = $zip.Entries |
                Where-Object { $_.FullName -match '^[^/]+/' } |
                ForEach-Object { ($_.FullName -split '/')[0] } |
                Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($repoRootName)) {
                throw "Could not determine the archive root folder in $repoZipUrl (branch '$Branch')."
            }
            Write-Host "Archive root: $repoRootName" -ForegroundColor Cyan

            foreach ($entry in $zip.Entries) {
                if ([string]::IsNullOrWhiteSpace($entry.FullName)) { continue }
                if ($entry.FullName -notlike "$repoRootName/*") { continue }
                if ($entry.FullName.EndsWith("/")) { continue }

                $relativePath = ($entry.FullName.Substring($repoRootName.Length + 1)) -replace "/", "\"
                if ($relativePath -like "*..*") { continue }

                $segments = $relativePath.Split("\")
                $extension = [System.IO.Path]::GetExtension($relativePath)
                if ($segments.Count -eq 1) {
                    if ($allowedExtensions -notcontains $extension) { continue }
                }
                elseif ($segments.Count -eq 2 -and $allowedSubdirectories.ContainsKey($segments[0])) {
                    if ($allowedSubdirectories[$segments[0]] -notcontains $extension) { continue }
                }
                else { continue }

                $destinationPath = Join-Path $workDir $relativePath
                $destinationDir = Split-Path $destinationPath -Parent
                if (-not (Test-Path $destinationDir)) {
                    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
                }

                $entryStream = $entry.Open()
                try {
                    $fileStream = [System.IO.File]::Open($destinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $entryStream.CopyTo($fileStream)
                    }
                    finally {
                        $fileStream.Dispose()
                    }
                }
                finally {
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        $memStream.Dispose()
    }

    # Fail where the problem actually is. An empty workspace used to sail on and
    # only blow up much later at the run-all.bat check, which reads as a broken
    # download and sends you looking at the network rather than at the filter above.
    $materialized = @(Get-ChildItem -Path $workDir -File -Recurse)
    if ($materialized.Count -eq 0) {
        throw "No files were materialized from $repoZipUrl (archive root '$repoRootName'). The archive downloaded but nothing matched the allowlist."
    }
    Write-Host ("Materialized {0} files from the archive." -f $materialized.Count) -ForegroundColor Cyan

    $manifestPath = Join-Path $workDir "remote-call.manifest.json"
    $manifest = [ordered]@{
        source = $repoZipUrl
        downloaded_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        workspace = $workDir
        execution_mode = "temp-materialized-from-memory"
        files = @(Get-ChildItem -Path $workDir -File -Recurse | ForEach-Object { $_.FullName.Substring($workDir.Length + 1) } | Sort-Object)
    } | ConvertTo-Json -Depth 4
    Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8

    $env:PCSETUP_REMOTE_CALL = "1"
    if ($env:PCSETUP_CI -eq '1') {
        Write-Host "CI mode detected. Installing container-safe toolchain prerequisites..." -ForegroundColor Cyan

        function Refresh-ProcessPath {
            $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $pathParts = @($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $env:Path = ($pathParts -join ';')
        }

        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            Write-Host "Installing Chocolatey..." -ForegroundColor Cyan
            $chocoInstallScript = (Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing -TimeoutSec 180).Content
            Invoke-Expression $chocoInstallScript
            Refresh-ProcessPath
        }

        Write-Host "Installing CI packages..." -ForegroundColor Cyan
        & choco install git python gh nvm -y --no-progress
        if ($LASTEXITCODE -ne 0) {
            throw "Chocolatey package install failed with exit code $LASTEXITCODE."
        }
        Refresh-ProcessPath

        $nvmCandidates = @(
            (Get-Command nvm -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
            (Join-Path $env:APPDATA 'nvm\nvm.exe'),
            'C:\ProgramData\nvm\nvm.exe'
        ) | Where-Object { $_ } | Select-Object -Unique

        $nvmExe = $nvmCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $nvmExe) {
            throw "nvm was not installed successfully."
        }

        $nvmHome = [Environment]::GetEnvironmentVariable('NVM_HOME', 'Machine')
        $nvmSymlink = [Environment]::GetEnvironmentVariable('NVM_SYMLINK', 'Machine')
        if ([string]::IsNullOrWhiteSpace($nvmHome)) {
            $nvmHome = Split-Path $nvmExe -Parent
        }
        if ([string]::IsNullOrWhiteSpace($nvmSymlink)) {
            $nvmSymlink = 'C:\nvm4w\nodejs'
        }

        $env:NVM_HOME = $nvmHome
        $env:NVM_SYMLINK = $nvmSymlink

        if (-not (Test-Path $env:NVM_HOME)) {
            New-Item -ItemType Directory -Path $env:NVM_HOME -Force | Out-Null
        }

        $nvmSymlinkParent = Split-Path $env:NVM_SYMLINK -Parent
        if (-not [string]::IsNullOrWhiteSpace($nvmSymlinkParent) -and -not (Test-Path $nvmSymlinkParent)) {
            New-Item -ItemType Directory -Path $nvmSymlinkParent -Force | Out-Null
        }
        if ((Test-Path $env:NVM_SYMLINK) -and (Get-Item $env:NVM_SYMLINK).PSIsContainer) {
            Remove-Item $env:NVM_SYMLINK -Recurse -Force
        }

        $nvmSettingsPath = Join-Path $env:NVM_HOME 'settings.txt'
        if (-not (Test-Path $nvmSettingsPath)) {
            @(
                "root: $env:NVM_HOME"
                "path: $env:NVM_SYMLINK"
                "arch: 64"
                "proxy: none"
            ) | Set-Content -Path $nvmSettingsPath -Encoding ASCII
        }

        $pathSegments = @(
            $env:NVM_HOME,
            $env:NVM_SYMLINK,
            [Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User')
        ) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ -split ';' } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
        $env:Path = $pathSegments -join ';'

        $nodeVersion = '22.19.0'
        Push-Location $env:NVM_HOME
        try {
            $nvmInstallSucceeded = $false
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                & $nvmExe install $nodeVersion
                if ($LASTEXITCODE -eq 0) {
                    $nvmInstallSucceeded = $true
                    break
                }

                if ($attempt -lt 3) {
                    Start-Sleep -Seconds (5 * $attempt)
                }
            }

            if (-not $nvmInstallSucceeded) {
                throw "nvm install $nodeVersion failed after 3 attempts. Last exit code: $LASTEXITCODE."
            }
            & $nvmExe use $nodeVersion
            if ($LASTEXITCODE -ne 0) {
                $versionDir = Join-Path $env:NVM_HOME ("v{0}" -f $nodeVersion)
                $nodeExePath = Join-Path $versionDir 'node.exe'
                $npmCmdPath = Join-Path $versionDir 'npm.cmd'
                if (-not (Test-Path $nodeExePath) -or -not (Test-Path $npmCmdPath)) {
                    throw "nvm use $nodeVersion failed with exit code $LASTEXITCODE."
                }

                $env:Path = (@($versionDir, $env:Path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
            }
        }
        finally {
            Pop-Location
        }
        Refresh-ProcessPath

        foreach ($commandName in 'choco', 'git', 'python', 'gh', 'nvm', 'node', 'npm') {
            if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
                throw "Required CI command '$commandName' was not available after bootstrap."
            }
        }
    }

    # CI used to `return` here, so the container installed a handful of packages and never ran a
    # single numbered script - the "full install" test asserted against a machine that had only
    # been bootstrapped. The bootstrap above is a prerequisite for the run, not a substitute for
    # it, so both paths now fall through to the runner. Scripts that cannot work in Server Core
    # (2, 5, 6, 10, 11, 99) skip their own bodies on PCSETUP_CI=1.
    $runAllPath = Join-Path $workDir "run-all.bat"
    if (-not (Test-Path $runAllPath)) {
        throw "run-all.bat was not found in the remote archive."
    }

    Write-Host "Executing remote runner from temp workspace: $workDir" -ForegroundColor Cyan
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$runAllPath`"" -WorkingDirectory $workDir -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "Remote runner failed with exit code $($proc.ExitCode)."
    }
}
finally {
    Remove-Item Env:PCSETUP_REMOTE_CALL -ErrorAction SilentlyContinue
    if (Test-Path $workDir) {
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
