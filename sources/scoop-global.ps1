# Machine-wide ("global") Scoop installs, shared by sources\init-prereqs.ps1 and the PowerShell
# that 2-setup-windows.bat and 6-setup-games.bat generate (`. "<repo>\sources\scoop-global.ps1"`).
#
# Why global: a plain "scoop install" lands in %USERPROFILE%\scoop, so every other Windows account
# on the PC started with nothing and had to install it all again. "scoop install --global" puts
# the app in %ProgramData%\scoop with its shims on the Machine PATH, so every account can run it.
# Each person's data still stays their own for apps that keep it in AppData. Apps that Scoop runs
# in portable mode keep it in the shared persist folder instead, so the ones holding logins
# (Steam, Telegram, Firefox, ShareX) are not installed through Scoop at all - see the scripts.
#
# Check -> act -> verify, and it also moves an existing per-user install over: the per-user
# persist folder is copied first (settings carry over), the global copy is installed and checked,
# and only then is the per-user copy uninstalled. "scoop uninstall" without -p keeps the
# per-user persist folder, so the old data is never deleted here.
#
# Everything here is ASCII on purpose: Windows PowerShell 5.1 reads a BOM-less file as CP1252.

function Get-ScoopGlobalDir {
    if ($env:SCOOP_GLOBAL) { return $env:SCOOP_GLOBAL }
    return (Join-Path $env:ProgramData 'scoop')
}

function Get-ScoopUserDir {
    if ($env:SCOOP) { return $env:SCOOP }
    return (Join-Path $env:USERPROFILE 'scoop')
}

function Get-ScoopAppName([string]$Package) {
    # 'games/steam' -> 'steam'. Bucket-qualified specs are installed as given but live under
    # the bare name.
    return ($Package -split '/')[-1]
}

function Test-ScoopAppAt([string]$Root, [string]$Package) {
    # A failed install has no 'current' junction (and no manifest under it), so it never counts
    # as installed - the same reason the scripts stopped trusting "scoop list".
    $name = Get-ScoopAppName $Package
    return (Test-Path -LiteralPath (Join-Path $Root "apps\$name\current\manifest.json"))
}

function Test-ScoopGlobalApp([string]$Package) { return (Test-ScoopAppAt (Get-ScoopGlobalDir) $Package) }
function Test-ScoopUserApp([string]$Package) { return (Test-ScoopAppAt (Get-ScoopUserDir) $Package) }

function Copy-ScoopPersistToGlobal([string]$Package) {
    $name = Get-ScoopAppName $Package
    $source = Join-Path (Get-ScoopUserDir) "persist\$name"
    $target = Join-Path (Get-ScoopGlobalDir) "persist\$name"
    if (-not (Test-Path -LiteralPath $source)) { return }
    if (Test-Path -LiteralPath $target) { return }
    Write-Host "Copying $name settings from the per-user install..." -ForegroundColor Cyan
    # robocopy, not Copy-Item: nvm's persist folder alone is over 1 GB of Node versions.
    $null = & robocopy.exe $source $target /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { Write-Host "  copy of $name settings reported errors (robocopy $LASTEXITCODE)." -ForegroundColor Yellow }
}

# Installs $Package machine-wide unless it already is, and moves a per-user copy over.
# Returns $true when the global copy is there afterwards. A per-user copy that cannot be removed
# (usually because the app is running) is only a warning: the global shims come first on PATH.
function Install-ScoopGlobalApp {
    param(
        [Parameter(Mandatory)][string]$Package,
        [string]$DisplayName = $Package
    )
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $name = Get-ScoopAppName $Package
        $hadUserCopy = Test-ScoopUserApp $Package
        if (Test-ScoopGlobalApp $Package) {
            Write-Host "$DisplayName already installed for all users, skipping..." -ForegroundColor Yellow
        }
        else {
            if ($hadUserCopy) {
                Write-Host "$DisplayName is installed for this user only; installing it for all users..." -ForegroundColor Cyan
                Copy-ScoopPersistToGlobal $Package
            }
            else {
                Write-Host "Installing $DisplayName for all users via Scoop..." -ForegroundColor Cyan
            }
            # scoop install self-heals a previous failed install (it purges and retries).
            try { & scoop install --global $Package } catch { Write-Host "$DisplayName install error: $($_.Exception.Message)" -ForegroundColor Yellow }
            if (-not (Test-ScoopGlobalApp $Package)) {
                Write-Host "$DisplayName FAILED to install." -ForegroundColor Red
                return $false
            }
            Write-Host "$DisplayName installed for all users." -ForegroundColor Green
        }

        if ($hadUserCopy) {
            Write-Host "Removing the per-user copy of $DisplayName (its settings folder is kept)..." -ForegroundColor Cyan
            try { & scoop uninstall $name } catch { }
            if (Test-ScoopUserApp $Package) {
                Write-Host "  The per-user copy of $DisplayName is still there (is it running?). Close it and re-run to remove it; the all-users copy is used meanwhile." -ForegroundColor Yellow
            }
        }
        return $true
    }
    finally { $ErrorActionPreference = $eap }
}

# For apps that moved off Scoop to a real installer (Steam, Telegram, Firefox, ShareX): once the
# replacement is verified, the old per-user Scoop copy goes. Persist is kept as the backup.
function Remove-ScoopUserApp {
    param(
        [Parameter(Mandatory)][string]$Package,
        [string]$DisplayName = $Package
    )
    if (-not (Test-ScoopUserApp $Package)) { return $true }
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Write-Host "Removing the old Scoop copy of $DisplayName (its data folder is kept)..." -ForegroundColor Cyan
        try { & scoop uninstall (Get-ScoopAppName $Package) } catch { }
        if (Test-ScoopUserApp $Package) {
            Write-Host "  The Scoop copy of $DisplayName is still there (is it running?). Close it and re-run." -ForegroundColor Yellow
            return $false
        }
        return $true
    }
    finally { $ErrorActionPreference = $eap }
}
