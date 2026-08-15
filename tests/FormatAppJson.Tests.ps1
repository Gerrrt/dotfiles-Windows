# ============================================================================
#  tests/FormatAppJson.Tests.ps1  -  Format-AppJson.ps1 pure normalizer (library-only).
#  Covers the drift Windows Terminal reintroduces every time it rewrites its own
#  settings.json through the symlink: trailing WS, missing final newline, CRLF.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $env:DOTFILES_FORMATAPPJSON_LIBONLY = '1'
    . (Join-Path $RepoRoot 'tests/Format-AppJson.ps1')
}
AfterAll { Remove-Item Env:DOTFILES_FORMATAPPJSON_LIBONLY -ErrorAction SilentlyContinue }

Describe 'Get-NormalizedAppJson' {
    It 'adds a missing final newline' {
        Get-NormalizedAppJson -Text '{}' | Should -Be "{}`n"
    }
    It 'strips trailing spaces and tabs' {
        Get-NormalizedAppJson -Text "{`n  `"a`": 1,   `n`t`n}`n" |
            Should -Be "{`n  `"a`": 1,`n`n}`n"
    }
    It 'converts CRLF to LF' {
        Get-NormalizedAppJson -Text "{`r`n}`r`n" | Should -Be "{`n}`n"
    }
    It 'converts a lone CR to LF, leaving no stranded carriage return' {
        $out = Get-NormalizedAppJson -Text "{`r}`r"
        $out | Should -Be "{`n}`n"
        $out | Should -Not -Match "`r"
    }
    It 'collapses a run of blank lines at EOF to exactly one newline' {
        Get-NormalizedAppJson -Text "{}`n`n`n`n" | Should -Be "{}`n"
    }
    It 'is idempotent' {
        $once  = Get-NormalizedAppJson -Text "{`n  `"a`": 1   `n}"
        $twice = Get-NormalizedAppJson -Text $once
        $twice | Should -Be $once
    }
    It 'leaves an already-clean file byte-identical' {
        $clean = "{`n  `"a`": 1`n}`n"
        Get-NormalizedAppJson -Text $clean | Should -Be $clean
    }
    It 'preserves indentation — the app owns it, so we must not re-indent' {
        # 4-space indent is what Windows Terminal writes; normalizing it to 2
        # would dirty the whole file on every launch. See the .editorconfig
        # carve-out for windows-terminal/settings.json.
        $four = "{`n    `"a`": 1`n}`n"
        Get-NormalizedAppJson -Text $four | Should -Be $four
    }
    It 'returns empty string for empty input' {
        Get-NormalizedAppJson -Text '' | Should -Be ''
    }
}

Describe 'windows-terminal/settings.json' {
    It 'is committed in normalized form' {
        # The regression guard: if this fails, someone committed an app rewrite
        # without the pre-commit hook. Fix: pwsh -File tests/Format-AppJson.ps1
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $path = Join-Path $RepoRoot 'windows-terminal/settings.json'
        $raw = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($path))
        Get-NormalizedAppJson -Text $raw | Should -Be $raw
    }
    It 'carries no hardcoded user profile path' {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $path = Join-Path $RepoRoot 'windows-terminal/settings.json'
        (Get-Content $path -Raw) | Should -Not -Match 'C:\\\\Users\\\\'
    }
}
