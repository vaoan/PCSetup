$ErrorActionPreference = 'Stop'

Describe "container base scripts" {
    It "run-all exists" {
        Test-Path (Join-Path $PSScriptRoot "..\run-all.bat") | Should -BeTrue
    }

    It "remote-call exists" {
        Test-Path (Join-Path $PSScriptRoot "..\remote-call.ps1") | Should -BeTrue
    }

    It "delete-node-modules script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\1-delete-node-modules.bat") | Should -BeTrue
    }

    It "windows setup script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\2-setup-windows.bat") | Should -BeTrue
    }

    It "node setup script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\3-setup-node.bat") | Should -BeTrue
    }
}

Describe "container installed toolchain" {
    It "Chocolatey installed" {
        (choco --version 2>&1 | Out-String) | Should -Match '\d+\.\d+'
    }

    It "Git installed" {
        (git --version 2>&1 | Out-String) | Should -Match 'git version'
    }

    It "Python installed" {
        (python --version 2>&1 | Out-String) | Should -Match 'Python \d+\.\d+'
    }

    It "GitHub CLI installed" {
        $output = (gh --version 2>&1 | Out-String)
        ($output -match 'gh version' -or $output -match 'cli/releases/tag') | Should -BeTrue
    }

    It "nvm installed" {
        $onPath = (Get-Command nvm -ErrorAction SilentlyContinue) -ne $null
        $atPath = Test-Path "$env:APPDATA\nvm\nvm.exe"
        ($onPath -or $atPath) | Should -BeTrue
    }

    It "Node.js installed" {
        (node --version 2>&1 | Out-String) | Should -Match 'v\d+'
    }

    It "npm installed" {
        (npm --version 2>&1 | Out-String) | Should -Match '\d+\.\d+'
    }
}

Describe "container test harness" {
    It "repo test runner bootstraps Pester 5" {
        $script = Get-Content (Join-Path $PSScriptRoot 'run-tests.ps1') -Raw
        $script | Should -Match 'Install-Module Pester'
        $script | Should -Match 'Import-Module'
        $script | Should -Match 'New-PesterConfiguration'
    }

    It "container mode does not require cloudflared recovery tests" {
        $dockerfile = Get-Content (Join-Path $PSScriptRoot '..\Dockerfile.test') -Raw
        $dockerfile | Should -Match 'https://i\.ffxivbe\.org/'
        $dockerfile | Should -Match 'container\.tests\.ps1'
        $dockerfile | Should -Not -Match 'test-clean-install\.ps1'
        $dockerfile | Should -Not -Match 'verify-console\.ps1'
    }

    It "install worker is configured as a custom domain" {
        $wrangler = Get-Content (Join-Path $PSScriptRoot '..\cloudflared\install-worker\wrangler.toml') -Raw
        $wrangler | Should -Match 'workers_dev = true'
        $wrangler | Should -Match 'pattern = "i\.ffxivbe\.org"'
        $wrangler | Should -Match 'custom_domain = true'
    }
}
