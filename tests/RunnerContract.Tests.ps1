# ============================================================================
#  tests/RunnerContract.Tests.ps1  -  "passes locally" == "passes CI".
#
#  The gated run (coverage bar, exact test-file match, test-case floor) used to
#  live only inline in .github/workflows/ci.yml, while the documented local command
#  was a bare `Invoke-Pester -Path tests`. Two different assertions, and the
#  difference only surfaced when CI failed. tests/Invoke-Tests.ps1 is now the single
#  entry point; these tests keep it that way.
# ============================================================================

BeforeAll {
    $env:DOTFILES_INVOKETESTS_LIBONLY = '1'
    . (Join-Path $PSScriptRoot 'Invoke-Tests.ps1')
}
AfterAll { Remove-Item Env:DOTFILES_INVOKETESTS_LIBONLY -ErrorAction SilentlyContinue }

Describe 'CI delegates to the shared runner' {
    It 'invokes tests/Invoke-Tests.ps1 rather than re-implementing the gate' {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $ci = Get-Content (Join-Path $RepoRoot '.github/workflows/ci.yml') -Raw
        $ci | Should -Match 'tests/Invoke-Tests\.ps1'
    }
    It 'does not carry its own inline coverage gate any more' {
        # These were the tell-tales of the duplicated logic. If they reappear in
        # ci.yml, the two paths have started to drift again.
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $ci = Get-Content (Join-Path $RepoRoot '.github/workflows/ci.yml') -Raw
        $ci | Should -Not -Match 'Get-CoverageGateResult'
        $ci | Should -Not -Match 'CodeCoverage\.CoveragePercentTarget'
        $ci | Should -Not -Match 'New-PesterConfiguration'
    }
}

Describe 'the documented local command is the gated one' {
    It 'README points at the runner, not a bare Invoke-Pester' {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $readme = Get-Content (Join-Path $RepoRoot 'README.md') -Raw
        $readme | Should -Match 'tests/Invoke-Tests\.ps1'
        # A bare `Invoke-Pester -Path tests` skips the coverage bar and the floor,
        # so documenting it as "the full suite" was the original overclaim.
        $readme | Should -Not -Match 'Invoke-Pester -Path tests` is the full suite'
    }
    It 'the dev-deps installer points at the runner too' {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $dev = Get-Content (Join-Path $RepoRoot 'tests/Install-DevDeps.ps1') -Raw
        $dev | Should -Match 'tests/Invoke-Tests\.ps1'
    }
}

Describe 'coverage surface' {
    It 'every path the gate measures actually exists' {
        # A renamed helper file would silently drop out of the coverage measurement
        # and the percentage would go UP, hiding the loss.
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        foreach ($p in $script:CoveragePaths) {
            $full = Join-Path $RepoRoot ($p -replace '^\./', '')
            Test-Path -LiteralPath $full | Should -BeTrue -Because "coverage path '$p' does not exist"
        }
    }
    It 'measures more than one file' {
        $script:CoveragePaths.Count | Should -BeGreaterThan 1
    }
}
