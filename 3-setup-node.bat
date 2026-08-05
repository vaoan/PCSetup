@echo off
if /I "%PCSETUP_CI%"=="1" goto :after_admin_check
:: Auto-elevate to Administrator
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:after_admin_check

setlocal

:: Windows PowerShell must not inherit PowerShell 7's PSModulePath. If it does, it finds the
:: Core-only Microsoft.PowerShell.Utility/Security first and refuses to load them, so cmdlets
:: start disappearing. Clearing it here (inside setlocal) makes powershell.exe rebuild its own.
set "PSModulePath="

set "SCRIPT=%TEMP%\temp-node-setup.ps1"
if exist "%SCRIPT%" del "%SCRIPT%" >nul

:: Redirection goes FIRST on every line. Written as `echo ... >>"%SCRIPT%"`, a line ending in a
:: standalone digit is read by CMD as a file-handle redirect: `echo $maxAttempts = 3>>"%SCRIPT%"`
:: silently became `$maxAttempts = ` (handle 3 redirected to the file, text sent to the console).
:: $maxAttempts was then $null, `1 -le $null` is false, and the retry loop never ran a single
:: attempt - so no npm package was ever installed while the script reported success.
>"%SCRIPT%" echo [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
>>"%SCRIPT%" echo $failures = New-Object System.Collections.ArrayList
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo function Refresh-SetupEnvironment {
>>"%SCRIPT%" echo     $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
>>"%SCRIPT%" echo     $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
>>"%SCRIPT%" echo     $pathParts = @($machinePath, $userPath) ^| Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
>>"%SCRIPT%" echo     $env:Path = ($pathParts -join ';')
>>"%SCRIPT%" echo     foreach ($scope in 'Machine', 'User') {
>>"%SCRIPT%" echo         foreach ($name in 'NVM_HOME', 'NVM_SYMLINK') {
>>"%SCRIPT%" echo             $value = [Environment]::GetEnvironmentVariable($name, $scope)
>>"%SCRIPT%" echo             if (-not [string]::IsNullOrWhiteSpace($value)) { Set-Item -Path "Env:$name" -Value $value }
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo     # npm puts global .cmd shims in the active Node directory, so it has to be on PATH
>>"%SCRIPT%" echo     # for the post-install verification to see what was just installed.
>>"%SCRIPT%" echo     $npmPrefix = ^& cmd.exe /c "npm.cmd prefix -g" 2^>$null
>>"%SCRIPT%" echo     if ($npmPrefix -and (Test-Path $npmPrefix)) { $env:Path = "$npmPrefix;$env:Path" }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Same shape as Install-ScoopPackage in sources\init-prereqs.ps1: the installed-check
>>"%SCRIPT%" echo # lives inside the function, so every entry in the package table below is guaranteed to
>>"%SCRIPT%" echo # be either already present, freshly installed, or reported as a failure. No call site
>>"%SCRIPT%" echo # can quietly opt a package out.
>>"%SCRIPT%" echo function Install-NpmGlobalPackage([string]$package, [string]$displayName, [string]$command) {
>>"%SCRIPT%" echo     Refresh-SetupEnvironment
>>"%SCRIPT%" echo     if (Get-Command $command -ErrorAction SilentlyContinue) {
>>"%SCRIPT%" echo         Write-Host "$displayName already installed, skipping..." -ForegroundColor Yellow
>>"%SCRIPT%" echo         return $true
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo     $maxAttempts = 3
>>"%SCRIPT%" echo     for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
>>"%SCRIPT%" echo         Write-Host "Installing $displayName (attempt $attempt/$maxAttempts)..." -ForegroundColor Cyan
>>"%SCRIPT%" echo         $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c npm.cmd install -g $package --no-fund --no-audit" -Wait -NoNewWindow -PassThru
>>"%SCRIPT%" echo         Refresh-SetupEnvironment
>>"%SCRIPT%" echo         # Verify the shim exists rather than trusting the exit code: npm can report 0
>>"%SCRIPT%" echo         # after a partial install, and a nonzero code sometimes still leaves a usable CLI.
>>"%SCRIPT%" echo         if (Get-Command $command -ErrorAction SilentlyContinue) {
>>"%SCRIPT%" echo             Write-Host "$displayName installed." -ForegroundColor Green
>>"%SCRIPT%" echo             return $true
>>"%SCRIPT%" echo         }
>>"%SCRIPT%" echo         Write-Host "$displayName attempt $attempt failed with exit code $($proc.ExitCode)." -ForegroundColor Yellow
>>"%SCRIPT%" echo         if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (4 * $attempt) }
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo     Write-Host "$displayName FAILED after $maxAttempts attempts." -ForegroundColor Red
>>"%SCRIPT%" echo     $null = $failures.Add($displayName)
>>"%SCRIPT%" echo     return $false
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host "Starting Node CLI setup..." -ForegroundColor Cyan
>>"%SCRIPT%" echo Refresh-SetupEnvironment
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo foreach ($tool in 'nvm', 'node', 'npm.cmd') {
>>"%SCRIPT%" echo     if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
>>"%SCRIPT%" echo         Write-Host "$tool is not available. Run 0-init-prereqs.bat first." -ForegroundColor Red
>>"%SCRIPT%" echo         exit 1
>>"%SCRIPT%" echo     }
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # Add a CLI by adding one row. Command is what must resolve on PATH afterwards.
>>"%SCRIPT%" echo $npmPackages = @(
>>"%SCRIPT%" echo     @{ Package = '@openai/codex';   Name = 'OpenAI Codex CLI';   Command = 'codex' },
>>"%SCRIPT%" echo     @{ Package = '@github/copilot'; Name = 'GitHub Copilot CLI'; Command = 'copilot.cmd' }
>>"%SCRIPT%" echo )
>>"%SCRIPT%" echo foreach ($entry in $npmPackages) {
>>"%SCRIPT%" echo     Install-NpmGlobalPackage $entry.Package $entry.Name $entry.Command ^| Out-Null
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo # There is deliberately no "gh extension install github/gh-copilot" step. That extension
>>"%SCRIPT%" echo # is archived upstream and is now impossible to install: modern gh has a built-in
>>"%SCRIPT%" echo # "gh copilot" command, so the install aborts with
>>"%SCRIPT%" echo # '"copilot" matches the name of a built-in command or alias'. gh copilot shells out to
>>"%SCRIPT%" echo # the standalone Copilot CLI installed above, so the capability is already covered.
>>"%SCRIPT%" echo if (Get-Command gh -ErrorAction SilentlyContinue) {
>>"%SCRIPT%" echo     Write-Host "gh copilot is built into GitHub CLI; no extension to install." -ForegroundColor Yellow
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo.
>>"%SCRIPT%" echo Write-Host ""
>>"%SCRIPT%" echo if ($failures.Count -gt 0) {
>>"%SCRIPT%" echo     Write-Host "Node CLI setup finished with failures: $($failures -join ', ')" -ForegroundColor Red
>>"%SCRIPT%" echo     exit 1
>>"%SCRIPT%" echo }
>>"%SCRIPT%" echo Write-Host "Node CLI setup complete." -ForegroundColor Green

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "NODE_EXIT=%errorlevel%"
if %NODE_EXIT% neq 0 (
    echo.
    echo Node setup failed with exit code %NODE_EXIT%.
    echo Generated script: %SCRIPT%
) else (
    del "%SCRIPT%" >nul 2>&1
)
endlocal & exit /b %NODE_EXIT%
