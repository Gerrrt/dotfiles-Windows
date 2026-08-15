# ============================================================================
#  tests/Install.Tests.ps1  -  install.ps1 helpers (dot-sourced library-only).
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $env:DOTFILES_INSTALL_LIBONLY = '1'
    . (Join-Path $RepoRoot 'install.ps1')
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:Tmp = New-DotTestTempDir -Prefix 'lnktest'
}
AfterAll {
    if ($script:Tmp -and (Test-Path $script:Tmp)) { Remove-Item $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:DOTFILES_INSTALL_LIBONLY -ErrorAction SilentlyContinue
}

Describe 'Test-SymlinkCurrent' {
    BeforeAll {
        $script:Target = Join-Path $script:Tmp 'target.txt'; 'hi' | Set-Content $script:Target
        $script:Other  = Join-Path $script:Tmp 'other.txt';  'no' | Set-Content $script:Other
        $script:Link   = Join-Path $script:Tmp 'link.txt'
    }
    It 'is false when the link does not exist' {
        Test-SymlinkCurrent -Link $script:Link -Target $script:Target | Should -BeFalse
    }
    It 'is true for a symlink pointing at the target' {
        New-Item -ItemType SymbolicLink -Path $script:Link -Target $script:Target -Force | Out-Null
        Test-SymlinkCurrent -Link $script:Link -Target $script:Target | Should -BeTrue
    }
    It 'is false when the symlink points elsewhere' {
        Test-SymlinkCurrent -Link $script:Link -Target $script:Other | Should -BeFalse
    }
    It 'is false for a real (non-link) file' {
        Test-SymlinkCurrent -Link $script:Target -Target $script:Target | Should -BeFalse
    }
}

Describe 'Test-CopyCurrent' {
    BeforeEach {
        $script:Cc = Join-Path $script:Tmp ('cc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:Cc | Out-Null
    }
    AfterEach { Remove-Item $script:Cc -Recurse -Force -ErrorAction SilentlyContinue }

    It 'is false when the link does not exist' {
        $t = Join-Path $script:Cc 't.txt'; 'hi' | Set-Content $t
        Test-CopyCurrent -Link (Join-Path $script:Cc 'missing.txt') -Target $t | Should -BeFalse
    }
    It 'is true when a file copy matches the target byte-for-byte' {
        $t = Join-Path $script:Cc 't.txt'; 'same content' | Set-Content $t
        $l = Join-Path $script:Cc 'l.txt'; Copy-Item $t $l
        Test-CopyCurrent -Link $l -Target $t | Should -BeTrue
    }
    It 'is false when the file copy differs from the target' {
        $t = Join-Path $script:Cc 't.txt'; 'original' | Set-Content $t
        $l = Join-Path $script:Cc 'l.txt'; 'edited'   | Set-Content $l
        Test-CopyCurrent -Link $l -Target $t | Should -BeFalse
    }
    It 'is false when one side is a file and the other a directory' {
        $t = Join-Path $script:Cc 't.txt'; 'x' | Set-Content $t
        $d = Join-Path $script:Cc 'dir'; New-Item -ItemType Directory -Force -Path $d | Out-Null
        Test-CopyCurrent -Link $d -Target $t | Should -BeFalse
    }
    It 'is true for two directory trees with identical content' {
        $src = Join-Path $script:Cc 'src'; $dst = Join-Path $script:Cc 'dst'
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'sub') | Out-Null
        'a' | Set-Content (Join-Path $src 'a.txt'); 'b' | Set-Content (Join-Path $src 'sub/b.txt')
        Copy-Item $src $dst -Recurse
        Test-CopyCurrent -Link $dst -Target $src | Should -BeTrue
    }
    It 'is false when a nested file differs' {
        $src = Join-Path $script:Cc 'src'; $dst = Join-Path $script:Cc 'dst'
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'sub') | Out-Null
        'a' | Set-Content (Join-Path $src 'a.txt'); 'b' | Set-Content (Join-Path $src 'sub/b.txt')
        Copy-Item $src $dst -Recurse
        'changed' | Set-Content (Join-Path $dst 'sub/b.txt')
        Test-CopyCurrent -Link $dst -Target $src | Should -BeFalse
    }
    It 'is false when the destination tree has an extra file' {
        $src = Join-Path $script:Cc 'src'; $dst = Join-Path $script:Cc 'dst'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        'a' | Set-Content (Join-Path $src 'a.txt')
        Copy-Item $src $dst -Recurse
        'extra' | Set-Content (Join-Path $dst 'extra.txt')
        Test-CopyCurrent -Link $dst -Target $src | Should -BeFalse
    }
    It 'is false when only an EMPTY subdirectory is added (no file changes)' {
        $src = Join-Path $script:Cc 'src'; $dst = Join-Path $script:Cc 'dst'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        'a' | Set-Content (Join-Path $src 'a.txt')
        Copy-Item $src $dst -Recurse
        New-Item -ItemType Directory -Force -Path (Join-Path $dst 'emptydir') | Out-Null
        Test-CopyCurrent -Link $dst -Target $src | Should -BeFalse
    }
}

Describe 'Get-InstallSummaryLines' {
    It 'renders all four tally categories' {
        $lines = Get-InstallSummaryLines -Stats ([ordered]@{ linked = 3; copied = 0; skipped = 2; backedup = 1 })
        # Exact, ordered output — covers the previously-unchecked 'copied' line and
        # the 'skipped' "(already correct)" suffix, not just three loose substrings.
        $lines | Should -Be @(
            'linked   : 3'
            'copied   : 0'
            'skipped  : 2  (already correct)'
            'backed up: 1'
        )
    }
}

Describe 'Get-DotLogsToPrune' {
    BeforeAll {
        # 13 fake logs with increasing timestamps; newest should be kept.
        $script:Logs = 1..13 | ForEach-Object {
            [pscustomobject]@{ Name = "install-$_.log"; FullName = "C:\logs\install-$_.log"; LastWriteTime = (Get-Date).AddMinutes($_) }
        }
    }
    It 'returns nothing when at or under the keep count' {
        Get-DotLogsToPrune ($script:Logs | Select-Object -First 5) -Keep 10 | Should -BeNullOrEmpty
    }
    It 'prunes everything except the newest Keep' {
        $pruned = Get-DotLogsToPrune $script:Logs -Keep 10
        @($pruned).Count | Should -Be 3
        # the three OLDEST (smallest minute offsets) are the ones pruned
        ($pruned.Name | Sort-Object) | Should -Be @('install-1.log', 'install-2.log', 'install-3.log')
    }
    It 'handles an empty/null input' {
        Get-DotLogsToPrune @()   -Keep 10 | Should -BeNullOrEmpty
        Get-DotLogsToPrune $null -Keep 10 | Should -BeNullOrEmpty
    }
}

Describe 'Get-DotRedactedTranscript' {
    It 'redacts a line carrying a secret and keeps ordinary lines' {
        $out = Get-DotRedactedTranscript @('cd C:\src', 'export GH_TOKEN=ghp_secret', 'll -a')
        ($out -join "`n") | Should -Match 'cd C:\\src'
        ($out -join "`n") | Should -Match 'll -a'
        ($out -join "`n") | Should -Match '<redacted'
        ($out -join "`n") | Should -Not -Match 'ghp_secret'
    }
    It 'returns empty for empty input' {
        Get-DotRedactedTranscript @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-InstallUsage' {
    It 'documents every public switch' {
        $u = (Get-InstallUsage) -join "`n"
        foreach ($flag in '-SkipPackages', '-DryRun', '-NonInteractive', '-Yes', '-Help') {
            $u | Should -Match ([regex]::Escape($flag))
        }
    }
}

Describe 'Test-CanSymlink' {
    # The capability matrix. The bug this guards: Developer Mode alone used to
    # return $true on Windows PowerShell 5.1, whose New-Item does NOT pass
    # SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE — so every link threw AFTER
    # Link-Item had already moved the user's real config to a .bak.
    It 'is true for an administrator regardless of edition or Developer Mode' {
        Test-CanSymlink -Edition 'Desktop' -IsAdminOverride $true -DevModeOverride 0 | Should -BeTrue
        Test-CanSymlink -Edition 'Core'    -IsAdminOverride $true -DevModeOverride 0 | Should -BeTrue
    }
    It 'is true for Developer Mode on pwsh 7 (Core) without admin' {
        Test-CanSymlink -Edition 'Core' -IsAdminOverride $false -DevModeOverride 1 | Should -BeTrue
    }
    It 'is FALSE for Developer Mode on Windows PowerShell 5.1 without admin' {
        Test-CanSymlink -Edition 'Desktop' -IsAdminOverride $false -DevModeOverride 1 | Should -BeFalse
    }
    It 'is false with neither admin nor Developer Mode' {
        Test-CanSymlink -Edition 'Core'    -IsAdminOverride $false -DevModeOverride 0 | Should -BeFalse
        Test-CanSymlink -Edition 'Desktop' -IsAdminOverride $false -DevModeOverride 0 | Should -BeFalse
    }
}

Describe 'dangling symlink handling' {
    It 'Test-Path SEES a dangling symlink, so the backup gate is not fooled' {
        # Pins the platform behaviour Link-Item's backup gate relies on. Contrary to
        # the POSIX intuition (where -e follows the link and a broken one is false),
        # Windows Test-Path reports the reparse point itself, so a dead link is
        # backed up and replaced like any other file. If a future PowerShell ever
        # changes this, the backup gate silently stops firing — hence the guard.
        $gone = Join-Path $script:Tmp 'vanished.txt'; 'bye' | Set-Content $gone
        $dangling = Join-Path $script:Tmp 'dangling.txt'
        New-Item -ItemType SymbolicLink -Path $dangling -Target $gone -Force | Out-Null
        Remove-Item -LiteralPath $gone -Force

        Test-Path -LiteralPath $dangling | Should -BeTrue
        Test-SymlinkCurrent -Link $dangling -Target (Join-Path $script:Tmp 'target.txt') | Should -BeFalse
        Remove-Item -LiteralPath $dangling -Force -ErrorAction SilentlyContinue
    }
}

Describe 'install.ps1 step counter' {
    It 'declares a StepTotal matching the number of Write-Step calls' {
        # Guards the "[6/5]" off-by-one: StepTotal was 5 while Write-Step was called
        # six times, so the final section rendered as [6/5] — the last thing a user
        # sees before the summary. AST-derived so adding a step can't silently drift.
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $path = Join-Path $RepoRoot 'install.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)

        $calls = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Write-Step'
        }, $true)

        $assign = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$script:StepTotal'
        }, $true)

        $assign.Count | Should -Be 1 -Because 'StepTotal should be declared exactly once'
        [int]$assign[0].Right.Extent.Text | Should -Be $calls.Count
    }
}
