# ============================================================================
#  tests/ThemeParity.Tests.ps1  -  Assert-ThemeParity.ps1 verdict logic
#
#  The clone/diff orchestration is CI-only (it needs the network); these cover the
#  verdict logic and the untrusted-input guards it inherits from the nvim gate.
#  Mirror of StarshipParity.Tests.ps1.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $env:DOTFILES_THEMEPARITY_LIBONLY = '1'
    . (Join-Path $RepoRoot 'tests/Assert-ThemeParity.ps1')
}
AfterAll { Remove-Item Env:DOTFILES_THEMEPARITY_LIBONLY -ErrorAction SilentlyContinue }

Describe 'Get-ThemeParityDiff' {
    It 'is in sync when both hashes match' {
        (Get-ThemeParityDiff -LocalHash 'ABC123' -CoreHash 'ABC123').InSync | Should -BeTrue
    }
    It 'is NOT in sync when the hashes differ' {
        (Get-ThemeParityDiff -LocalHash 'ABC123' -CoreHash 'DEF456').InSync | Should -BeFalse
    }
    It 'is NOT in sync when either hash is missing' {
        # A missing hash means the comparison never happened. Reporting "in sync" there
        # is the "green because absent" failure the gate exists to prevent.
        (Get-ThemeParityDiff -LocalHash ''       -CoreHash 'DEF456').InSync | Should -BeFalse
        (Get-ThemeParityDiff -LocalHash 'ABC123' -CoreHash '').InSync       | Should -BeFalse
    }
    It 'reports both hashes back for the failure message' {
        $d = Get-ThemeParityDiff -LocalHash 'AAA' -CoreHash 'BBB'
        $d.LocalHash | Should -Be 'AAA'
        $d.CoreHash  | Should -Be 'BBB'
    }
}

Describe 'shared untrusted-input guards' {
    # These come from Assert-NvimParity.ps1 by design — one copy, because they are the
    # trust boundary that stops a PR-edited .core-ref from steering CI's outbound clone.
    # Asserting them here proves the import actually happened rather than silently
    # leaving this gate unguarded.
    It 'exposes the nvim gate helpers rather than re-implementing them' {
        Get-Command Get-CoreRefField  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-DotGitSha    -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Resolve-CoreRemote -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'rejects a .core-ref commit that is not a git SHA' {
        Test-DotGitSha 'a85622e9ec439d478614d7432f2641060b3430af' | Should -BeTrue
        Test-DotGitSha '--upload-pack=evil'                       | Should -BeFalse
        Test-DotGitSha 'unknown'                                  | Should -BeFalse
    }
}

Describe 'theme/palette.toml' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:PalettePath = Join-Path $script:RepoRoot 'theme/palette.toml'
    }
    It 'is vendored, not absent' {
        # gen-theme.ps1 exits 2 without it, so an accidental delete would break the
        # whole terminal layer's generation rather than merely skipping a check.
        Test-Path $script:PalettePath | Should -BeTrue
    }
    It 'still parses and validates with the generator own parser' {
        $prev = $env:DOTFILES_GENTHEME_LIBONLY
        $env:DOTFILES_GENTHEME_LIBONLY = '1'
        try { . (Join-Path $script:RepoRoot 'gen-theme.ps1') }
        finally {
            if ($null -eq $prev) { Remove-Item Env:DOTFILES_GENTHEME_LIBONLY -ErrorAction SilentlyContinue }
            else { $env:DOTFILES_GENTHEME_LIBONLY = $prev }
        }
        $pal = Get-DotPalette -Line (Get-Content -LiteralPath $script:PalettePath)
        (Test-DotPalette -Palette $pal) | Should -BeNullOrEmpty
    }
}
