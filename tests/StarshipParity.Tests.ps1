# ============================================================================
#  tests/StarshipParity.Tests.ps1  -  Assert-StarshipParity.ps1 pure helpers.
#  The clone/diff orchestration is CI-only (it needs the network); these cover the
#  verdict logic and the untrusted-input guards it inherits from the nvim gate.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $env:DOTFILES_STARSHIPPARITY_LIBONLY = '1'
    . (Join-Path $RepoRoot 'tests/Assert-StarshipParity.ps1')
}
AfterAll { Remove-Item Env:DOTFILES_STARSHIPPARITY_LIBONLY -ErrorAction SilentlyContinue }

Describe 'Get-StarshipParityDiff' {
    It 'is in sync when both hashes match' {
        (Get-StarshipParityDiff -LocalHash 'ABC123' -CoreHash 'ABC123').InSync | Should -BeTrue
    }
    It 'is NOT in sync when the hashes differ' {
        (Get-StarshipParityDiff -LocalHash 'ABC123' -CoreHash 'DEF456').InSync | Should -BeFalse
    }
    It 'is not in sync when either hash is missing' {
        (Get-StarshipParityDiff -LocalHash ''       -CoreHash 'ABC123').InSync | Should -BeFalse
        (Get-StarshipParityDiff -LocalHash 'ABC123' -CoreHash ''      ).InSync | Should -BeFalse
        (Get-StarshipParityDiff -LocalHash ''       -CoreHash ''      ).InSync | Should -BeFalse
    }
    It 'reports both hashes so a drift failure is diagnosable' {
        $d = Get-StarshipParityDiff -LocalHash 'AAA' -CoreHash 'BBB'
        $d.LocalHash | Should -Be 'AAA'
        $d.CoreHash  | Should -Be 'BBB'
    }
}

Describe 'shared untrusted-input guards (reused from the nvim gate)' {
    # These are imported, not redefined — the point of the reuse is that there is
    # exactly ONE copy of the checks that stop a PR-edited .core-ref from steering
    # CI's outbound clone. If that import ever breaks, these fail loudly.
    It 'imports the shared helpers rather than redefining them' {
        Get-Command Get-CoreRefField   -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-DotGitSha     -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Resolve-CoreRemote -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'rejects a commit that is not a git SHA' {
        Test-DotGitSha '--upload-pack=evil' | Should -BeFalse
        Test-DotGitSha 'not-a-sha'          | Should -BeFalse
        Test-DotGitSha '23822156e0a81cc2ef36fbc1a1202afc88500351' | Should -BeTrue
    }
    It 'falls back to the canonical remote for a non-allowlisted source' {
        $allowed  = @('https://github.com/dotgibson/dotfiles-core.git')
        $fallback = 'https://github.com/dotgibson/dotfiles-core.git'
        Resolve-CoreRemote -Source 'https://evil.example/x.git' -Allowed $allowed -Fallback $fallback |
            Should -Be $fallback
    }
    It 'parses a pinned field out of .core-ref lines' {
        $lines = @('source = https://x', 'pinned = v4.9.0', 'commit = abc1234')
        Get-CoreRefField $lines 'pinned' | Should -Be 'v4.9.0'
        Get-CoreRefField $lines 'nope'   | Should -BeNullOrEmpty
    }
}

Describe 'starship/.core-ref' {
    It 'records a commit that passes the gate its own validator' {
        # Guards the committed marker itself: if someone hand-restamps .core-ref with
        # a non-SHA, CI would hard-fail (exit 2) rather than skip. Catch it locally.
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $path = Join-Path $RepoRoot 'starship/.core-ref'
        if (-not (Test-Path $path)) { Set-ItResult -Skipped -Because 'no starship/.core-ref yet'; return }
        $commit = Get-CoreRefField (Get-Content $path) 'commit'
        $commit | Should -Not -BeNullOrEmpty
        if ($commit -ne 'unknown') { Test-DotGitSha $commit | Should -BeTrue }
    }
}
