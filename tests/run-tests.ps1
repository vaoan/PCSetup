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
        try {
            # Install-Module asks to bootstrap the NuGet provider first, and in a container that
            # prompt has no host to answer it: it died with 'Exception calling "ShouldContinue"...
            # Object reference not set', so every CI run fell through to the manual install.
            # Installing the provider up front leaves Install-Module nothing to ask.
            if (-not (Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [version]'2.8.5.201' })) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
            }
            Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.0.0
        }
        catch {
            Write-Log "Install-Module failed, falling back to manual package install: $($_.Exception.Message)"

            $version = '5.7.1'
            $moduleRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\Pester'
            $modulePath = Join-Path $moduleRoot $version
            $packagePath = Join-Path $env:TEMP "Pester.$version.nupkg"
            $zipPath = Join-Path $env:TEMP "Pester.$version.zip"
            $extractPath = Join-Path $env:TEMP "Pester.$version"

            Remove-Item $packagePath, $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $modulePath -Force | Out-Null

            # Two sources, because on 2026-09-30 the Gallery answered the GitHub runner with "This
            # request is blocked by a Web Application Firewall rule". nuget.org serves the same
            # release from a different CDN, with the module under tools\ instead of the root.
            $sources = @("https://www.powershellgallery.com/api/v2/package/Pester/$version",
                         "https://www.nuget.org/api/v2/package/Pester/$version")
            $downloaded = $false
            foreach ($source in $sources) {
                try {
                    Invoke-WebRequest -Uri $source -OutFile $packagePath -UseBasicParsing
                    $downloaded = $true
                    break
                }
                catch { Write-Log "Download from $source failed: $($_.Exception.Message)" }
            }
            if (-not $downloaded) { throw "Manual Pester install failed: every download source refused." }
            Copy-Item $packagePath $zipPath -Force
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

            $contentRoot = $extractPath
            if (-not (Test-Path (Join-Path $contentRoot 'Pester.psd1'))) { $contentRoot = Join-Path $extractPath 'tools' }
            if (-not (Test-Path (Join-Path $contentRoot 'Pester.psd1'))) {
                throw "Manual Pester install failed: extracted module manifest not found."
            }

            Copy-Item (Join-Path $contentRoot '*') $modulePath -Recurse -Force
        }

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
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'

$result = Invoke-Pester -Configuration $config
if (
    -not $result -or
    $result.FailedCount -gt 0 -or
    ($result.PSObject.Properties.Name -contains 'Result' -and $result.Result -ne 'Passed')
) {
    exit 1
}
