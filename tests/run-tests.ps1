param(
    [string]$Path = (Join-Path $PSScriptRoot 'setup.tests.ps1')
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    Write-Host "[run-tests] $Message"
}

function Ensure-Pester5 {
    $loaded = Get-Module Pester -ListAvailable | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $loaded) {
        Write-Log "Installing Pester 5 for the current user..."
        Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.0.0
        $loaded = Get-Module Pester -ListAvailable | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
    }

    if (-not $loaded) {
        throw "Pester 5 could not be installed."
    }

    Import-Module $loaded.Path -Force
    return $loaded.Version
}

$version = Ensure-Pester5
Write-Log "Using Pester $version"

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Output.Verbosity = 'Detailed'

$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) {
    exit 1
}
