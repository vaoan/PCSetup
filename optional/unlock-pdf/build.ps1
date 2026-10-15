# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Builds dist\unlock-pdf.jar: the Unlock PDF app plus Apache PDFBox in one self-contained jar that
# runs on any OS with Java 8+ (java -jar unlock-pdf.jar). Normally run by ..\unlock-pdf.bat.
#
#   1. JDK: prefers Temurin 17 (--release 8), falls back to any javac on PATH.
#   2. Libraries: downloaded from Maven Central into a cache, each checked against the .sha1
#      Maven publishes next to it - a captive portal or truncated download never reaches the jar.
#   3. Compile for Java 8, then write the jar directly (manifest first, our classes, then the
#      libraries' classes; signature files and module-info dropped, first copy of a duplicate wins).
#   4. Verify: the new jar must start and run --cli before it replaces dist\unlock-pdf.jar.

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$here    = $PSScriptRoot
$srcDir  = Join-Path $here 'src'
$distJar = Join-Path $here 'dist\unlock-pdf.jar'
$cache   = Join-Path $env:LOCALAPPDATA 'PCSetup\unlock-pdf-lib'
$work    = Join-Path $env:TEMP ("unlock-pdf-build-" + [Guid]::NewGuid().ToString('N'))

# Pinned, and matching what PDFBox 3.0.8 itself is built against (pdfbox-parent pom).
$libs = @(
    @{ Group = 'org/apache/pdfbox'; Artifact = 'pdfbox';          Version = '3.0.8' },
    @{ Group = 'org/apache/pdfbox'; Artifact = 'pdfbox-io';       Version = '3.0.8' },
    @{ Group = 'org/apache/pdfbox'; Artifact = 'fontbox';         Version = '3.0.8' },
    @{ Group = 'commons-logging';   Artifact = 'commons-logging'; Version = '1.4.0' }
)

function Fail([string]$m) { Write-Host "[build] ERROR: $m" -ForegroundColor Red; exit 1 }
function Log([string]$m)  { Write-Host "[build] $m" }

# --- 1. JDK ----------------------------------------------------------------------------------
$jdkBin = $null
foreach ($candidate in @(((& scoop prefix temurin17-jdk 2>$null | Out-String).Trim()), $env:JAVA_HOME)) {
    if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'bin\javac.exe'))) { $jdkBin = Join-Path $candidate 'bin'; break }
}
if (-not $jdkBin) {
    $javac = Get-Command javac -ErrorAction SilentlyContinue
    if ($javac) { $jdkBin = Split-Path -Parent $javac.Source }
}
if (-not $jdkBin) { Fail 'no JDK found (javac). 0-init-prereqs.bat installs Temurin 17.' }
$javacExe = Join-Path $jdkBin 'javac.exe'
$javaExe  = Join-Path $jdkBin 'java.exe'
$verLine  = (& $javacExe -version 2>&1 | Out-String).Trim()
Log "JDK: $javacExe ($verLine)"
# javac 9+ has --release; javac 8 needs -source/-target.
$targetArgs = if ($verLine -match 'javac 1\.8') { @('-source', '8', '-target', '8') } else { @('--release', '8') }

# --- 2. Libraries ------------------------------------------------------------------------------
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$jars = @()
foreach ($l in $libs) {
    $name = "$($l.Artifact)-$($l.Version).jar"
    $file = Join-Path $cache $name
    $base = "https://repo1.maven.org/maven2/$($l.Group)/$($l.Artifact)/$($l.Version)/$name"
    $expected = ((& curl.exe -sSL --fail --retry 3 "$base.sha1" | Out-String).Trim() -split '\s+')[0].ToLower()
    if ($expected -notmatch '^[0-9a-f]{40}$') { Fail "no valid SHA-1 published for $name (got '$expected')" }
    $ok = (Test-Path -LiteralPath $file) -and ((Get-FileHash -LiteralPath $file -Algorithm SHA1).Hash.ToLower() -eq $expected)
    if (-not $ok) {
        Log "downloading $name"
        & curl.exe -sSL --fail --retry 3 -o $file $base
        if ($LASTEXITCODE -ne 0) { Fail "download failed: $base" }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA1).Hash.ToLower()
        if ($actual -ne $expected) { Remove-Item -LiteralPath $file -Force; Fail "SHA-1 mismatch for $name (expected $expected, got $actual)" }
    }
    Log "OK $name (sha1 verified)"
    $jars += $file
}

# --- 3. Compile and package --------------------------------------------------------------------
try {
    $classes = Join-Path $work 'classes'
    New-Item -ItemType Directory -Path $classes -Force | Out-Null
    $sources = @(Get-ChildItem -LiteralPath $srcDir -Recurse -Filter *.java | ForEach-Object FullName)
    if ($sources.Count -eq 0) { Fail "no sources under $srcDir" }
    $cp = $jars -join ';'
    & $javacExe @targetArgs -encoding UTF-8 -Xlint:-options -cp $cp -d $classes @sources
    if ($LASTEXITCODE -ne 0) { Fail 'javac failed' }
    Log "compiled $($sources.Count) source file(s) for Java 8"

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path (Split-Path -Parent $distJar) -Force | Out-Null
    $tmpJar = "$distJar.tmp"
    if (Test-Path -LiteralPath $tmpJar) { Remove-Item -LiteralPath $tmpJar -Force }
    $zip = [IO.Compression.ZipFile]::Open($tmpJar, 'Create')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        $mf = $zip.CreateEntry('META-INF/MANIFEST.MF')
        $w = New-Object IO.StreamWriter($mf.Open(), (New-Object Text.UTF8Encoding $false))
        $w.Write("Manifest-Version: 1.0`r`nMain-Class: pcsetup.unlockpdf.UnlockPdf`r`nCreated-By: PCSetup optional/unlock-pdf/build.ps1`r`n`r`n")
        $w.Dispose()
        [void]$seen.Add('META-INF/MANIFEST.MF')

        foreach ($f in Get-ChildItem -LiteralPath $classes -Recurse -File) {
            $rel = $f.FullName.Substring($classes.Length + 1) -replace '\\', '/'
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel)
            [void]$seen.Add($rel)
        }
        foreach ($jar in $jars) {
            $src = [IO.Compression.ZipFile]::OpenRead($jar)
            try {
                foreach ($e in $src.Entries) {
                    $n = $e.FullName
                    if ($n.EndsWith('/')) { continue }
                    if ($n -match '^META-INF/[^/]+\.(SF|RSA|DSA|EC)$' -or $n -match '(^|/)module-info\.class$' -or $n -ieq 'META-INF/MANIFEST.MF') { continue }
                    if (-not $seen.Add($n)) { continue }
                    $dst = $zip.CreateEntry($n)
                    $in = $e.Open(); $out = $dst.Open()
                    try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
                }
            } finally { $src.Dispose() }
        }
    } finally { $zip.Dispose() }

    # --- 4. Verify the jar before it replaces the old one ----------------------------------------
    $testDir = Join-Path $work 'test'
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    $probe = Join-Path $testDir 'probe.pdf'
    # The jar must start, load PDFBox from inside itself, and report a non-PDF as ERROR rather than
    # crash (a missing class from a bad merge would crash here). Real PDFs are covered by the tests.
    Set-Content -LiteralPath $probe -Value 'not a pdf' -Encoding ASCII
    $out = & $javaExe -jar $tmpJar --cli $probe 2>&1 | Out-String
    if ($out -notmatch '^ERROR\t') { Fail "the new jar did not run correctly: $out" }
    Move-Item -LiteralPath $tmpJar -Destination $distJar -Force
    Log ("OK built {0} ({1:N1} MB)" -f $distJar, ((Get-Item -LiteralPath $distJar).Length / 1MB))
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
