# ============================================================================
#  tests/ThemeSync.Tests.ps1  -  theme-sync.ps1 pure ref/pin resolvers
#  (library-only). Covers the reproducible-pin option (-Ref) without cloning.
#  Mirror of StarshipSync.Tests.ps1 / NvimSync.Tests.ps1.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $env:DOTFILES_THEMESYNC_LIBONLY = '1'
    . (Join-Path $RepoRoot 'theme-sync.ps1')
}
AfterAll { Remove-Item Env:DOTFILES_THEMESYNC_LIBONLY -ErrorAction SilentlyContinue }

Describe 'Get-ThemeSyncPin' {
    # Same bug the starship resolver closes: .github/workflows/theme-sync.yml invokes
    # theme-sync.ps1 BARE, so without this a deliberate `pinned = vX.Y.Z` would be
    # silently reverted to the branch tip with nothing in the diff to say so.
    It 'carries a recorded pin forward when no -Ref is given' {
        $p = Get-ThemeSyncPin -RecordedPin 'v5.5.0'
        $p.Ref    | Should -Be 'v5.5.0'
        $p.Source | Should -Be 'recorded'
    }
    It 'lets an explicit -Ref win over the recorded pin' {
        $p = Get-ThemeSyncPin -Ref 'v5.6.0' -RecordedPin 'v5.5.0'
        $p.Ref    | Should -Be 'v5.6.0'
        $p.Source | Should -Be 'explicit'
    }
    It 'abandons the pin when -Force is passed' {
        $p = Get-ThemeSyncPin -RecordedPin 'v5.5.0' -Force
        $p.Ref    | Should -BeNullOrEmpty
        $p.Source | Should -Be 'forced-branch'
    }
    It 'treats the (branch tip) sentinel as NOT a pin' {
        $p = Get-ThemeSyncPin -RecordedPin '(branch tip)'
        $p.Ref    | Should -BeNullOrEmpty
        $p.Source | Should -Be 'branch'
    }
    It 'cannot honour a pin when -CoreLocal copies a working tree' {
        # There is no ref to fetch, so claiming the pin was honoured would be a lie.
        $p = Get-ThemeSyncPin -RecordedPin 'v5.5.0' -CoreLocalUsed
        $p.Ref    | Should -BeNullOrEmpty
        $p.Source | Should -Be 'core-local'
    }
    It 'tracks the branch when nothing is recorded' {
        (Get-ThemeSyncPin).Source | Should -Be 'branch'
    }
}

Describe 'Get-ThemeSyncRefPlan' {
    It 'plans a branch sync by default' {
        $p = Get-ThemeSyncRefPlan -Branch 'main'
        $p.Mode   | Should -Be 'branch'
        $p.Target | Should -Be 'main'
    }
    It 'plans a pinned fetch when -Ref is given' {
        $p = Get-ThemeSyncRefPlan -Ref 'v5.5.0'
        $p.Mode   | Should -Be 'ref'
        $p.Target | Should -Be 'v5.5.0'
    }
    It 'rejects a -Ref that could be read as a git option' {
        # A ref starting with '-' reaches git as a flag, not a revision.
        { Get-ThemeSyncRefPlan -Ref '--upload-pack=evil' } | Should -Throw
    }
    It 'rejects -Ref combined with -CoreLocal' {
        { Get-ThemeSyncRefPlan -Ref 'v5.5.0' -CoreLocal 'C:\src\core' } | Should -Throw
    }
}

Describe 'theme/.core-ref' {
    # Guards the committed marker itself: if someone hand-restamps .core-ref with a
    # non-SHA, CI would hard-fail (exit 2) rather than skip. Catch it locally.
    It 'records a commit that passes the gate its own validator' {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $path = Join-Path $RepoRoot 'theme/.core-ref'
        if (-not (Test-Path $path)) { Set-ItResult -Skipped -Because 'no theme/.core-ref yet'; return }

        $prevNvim = $env:DOTFILES_NVIMPARITY_LIBONLY
        $env:DOTFILES_NVIMPARITY_LIBONLY = '1'
        try { . (Join-Path $PSScriptRoot 'Assert-NvimParity.ps1') }
        finally {
            if ($null -eq $prevNvim) { Remove-Item Env:DOTFILES_NVIMPARITY_LIBONLY -ErrorAction SilentlyContinue }
            else { $env:DOTFILES_NVIMPARITY_LIBONLY = $prevNvim }
        }

        $commit = Get-CoreRefField (Get-Content $path) 'commit'
        $commit | Should -Not -BeNullOrEmpty
        if ($commit -ne 'unknown') { Test-DotGitSha $commit | Should -BeTrue }
    }
}
