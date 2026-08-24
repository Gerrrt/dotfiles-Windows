# ============================================================================
#  tests/NvimSync.Tests.ps1  -  nvim-sync.ps1 pure ref resolver (library-only).
#  Covers B1's reproducible-pin option (-Ref) without cloning anything.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $env:DOTFILES_NVIMSYNC_LIBONLY = '1'
    . (Join-Path $RepoRoot 'nvim-sync.ps1')
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
}
AfterAll { Remove-Item Env:DOTFILES_NVIMSYNC_LIBONLY -ErrorAction SilentlyContinue }

Describe 'Get-NvimSyncRefPlan' {
    It 'syncs the branch tip when no ref is given' {
        $p = Get-NvimSyncRefPlan -Branch 'main'
        $p.Mode   | Should -Be 'branch'
        $p.Target | Should -Be 'main'
    }
    It 'pins an exact ref, which wins over -Branch' {
        $p = Get-NvimSyncRefPlan -Ref 'v1.4.0' -Branch 'main'
        $p.Mode   | Should -Be 'ref'
        $p.Target | Should -Be 'v1.4.0'
    }
    It 'rejects a ref that starts with a dash (option injection)' {
        { Get-NvimSyncRefPlan -Ref '--upload-pack=evil' } | Should -Throw
    }
    It 'rejects -Ref combined with -CoreLocal' {
        { Get-NvimSyncRefPlan -Ref 'abc1234' -CoreLocal 'C:\src\dotfiles-core' } | Should -Throw
    }
}

Describe 'Get-CoreDescribeTag' {
    # The bug (#202): nvim/.core-ref recorded `tag = v4-19-g10ad221`. `v4` is a MOVING
    # major alias that Core's tag-release.sh force-repoints on every cut, so the recorded
    # string silently changed meaning — re-running the same describe today yields
    # v4.15.1-19-g10ad221. `commit` was always right; only `tag` lied. These cases live
    # here (not below the LIBONLY hook) precisely because the old inline describe call was
    # unreachable from Pester, which is why a wrong value shipped unnoticed.
    It 'names the SPECIFIC release, not the moving major alias' {
        if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git is not on PATH'; return
        }
        $fx = New-DotCoreTagFixture -Release 'v9.9.9' -Alias 'v9' -Past 2
        try { Get-CoreDescribeTag -RepoPath $fx | Should -Match '^v9\.9\.9-2-g[0-9a-f]{7,}$' }
        finally { Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'covers a case a bare `describe --tags` gets WRONG' {
        # Guards the FIXTURE, not the code: if this ever stops returning the alias, the
        # fixture has stopped reproducing #202 and the assertion above proves nothing.
        if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git is not on PATH'; return
        }
        $fx = New-DotCoreTagFixture -Release 'v9.9.9' -Alias 'v9' -Past 2
        try { (& git -C $fx describe --tags HEAD 2>$null) | Should -Match '^v9-2-g' }
        finally { Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns the bare release when the vendored commit IS the release' {
        if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git is not on PATH'; return
        }
        $fx = New-DotCoreTagFixture -Release 'v9.9.9' -Alias 'v9' -Past 0
        try { Get-CoreDescribeTag -RepoPath $fx | Should -Be 'v9.9.9' }
        finally { Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns EMPTY when only the moving alias exists (absent beats wrong)' {
        # The deliberate trade Core states in sync-core.sh: the `tag` line is then omitted
        # and `commit` stays authoritative, rather than stamping a marker that moves out
        # from under us.
        if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git is not on PATH'; return
        }
        $fx = New-DotCoreTagFixture -Alias 'v9' -Past 2 -AliasOnly
        try { Get-CoreDescribeTag -RepoPath $fx | Should -BeNullOrEmpty }
        finally { Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns empty (does not throw) for a path that is not a git repo' {
        # The -CoreLocal-on-a-plain-directory case: best-effort, never fatal.
        $d = New-DotTestTempDir -Prefix 'notgit'
        try { Get-CoreDescribeTag -RepoPath $d | Should -BeNullOrEmpty }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
