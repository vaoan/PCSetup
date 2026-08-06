$ErrorActionPreference = 'Stop'

Describe "container base scripts" {
    It "init prereqs script exists" {
        Test-Path (Join-Path $PSScriptRoot "..\0-init-prereqs.bat") | Should -BeTrue
    }

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
    It "Scoop installed" {
        (scoop --version 2>&1 | Out-String) | Should -Match '\S+'
    }

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
        $dockerfile | Should -Match 'https://i\.ffxiv\.be/'
        $dockerfile | Should -Match 'container\.tests\.ps1'
        $dockerfile | Should -Not -Match 'test-clean-install\.ps1'
        $dockerfile | Should -Not -Match 'verify-console\.ps1'
    }

    It "install worker is configured as a custom domain" {
        $wrangler = Get-Content (Join-Path $PSScriptRoot '..\cloudflared\install-worker\wrangler.toml') -Raw
        $wrangler | Should -Match 'pattern = "i\.ffxiv\.be"'
        $wrangler | Should -Match 'custom_domain = true'
    }
}

# These are the point of the container build: they only pass if the numbered scripts actually
# ran. Before this, remote-call.ps1 returned after its CI bootstrap and no script ran at all,
# so the suite asserted against a machine that had merely had Chocolatey pointed at it.
Describe "numbered scripts actually ran" {
    It "4-fix-execution-policy set CurrentUser to RemoteSigned" {
        (Get-ExecutionPolicy -Scope CurrentUser) | Should -Be 'RemoteSigned'
    }

    It "9-context-menu-take-ownership enabled long paths" {
        $fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        (Get-ItemProperty -Path $fsKey -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled |
            Should -Be 1
    }

    It "3-setup-node installed the OpenAI Codex CLI" {
        (Get-Command codex -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "3-setup-node installed the GitHub Copilot CLI" {
        (Get-Command copilot -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

Describe "container-incompatible scripts opt out explicitly" {
    # Server Core has no winget, no Defender and no consumer Appx packages. Those scripts skip
    # their own bodies on PCSETUP_CI=1 rather than failing the run - but the guard has to stay
    # present, or the container build starts failing for reasons that say nothing about the code.
    # BeforeDiscovery + -ForEach, NOT `foreach ($name in ...) { It "$name" { ... } }`. Pester
    # generates the It blocks during discovery but runs their bodies later, in the run phase,
    # where a discovery-phase loop variable no longer exists. Written the loop way, all six tests
    # were generated with the correct names and then failed identically with
    # "Could not find a part of the path 'C:\workspace\'" - $name was empty inside the body, so
    # "..\$name" collapsed to the repo root. Same discovery-vs-run trap as the -Skip: note on
    # recovery.tests.ps1.
    BeforeDiscovery {
        $skipScripts = @(
            '2-setup-windows.bat'
            '5-move-profile-folders.bat'
            '6-setup-games.bat'
            '10-setup-exclusions.bat'
            '11-setup-win11debloat.bat'
            '99-remove-windows-ai.bat'
        )
    }

    It "<_> skips its body under PCSETUP_CI" -ForEach $skipScripts {
        $body = Get-Content (Join-Path $PSScriptRoot "..\$_") -Raw
        $body | Should -Match 'if "%PCSETUP_CI%"=="1" \('
        $body | Should -Match 'SKIP: CI mode'
    }
}
