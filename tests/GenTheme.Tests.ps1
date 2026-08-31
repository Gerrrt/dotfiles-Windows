# ============================================================================
#  tests/GenTheme.Tests.ps1  -  gen-theme.ps1: the palette parser, the line walker,
#  the drift verdict, the residual scan, and an end-to-end run against a HERMETIC
#  FIXTURE tree via -Root.
#
#  The fixture matters. The drift DIRECTION is the entire point of the gate, and it
#  is untestable except by mutating tracked files — so -Root exists for the same
#  reason Assert-NvimParity.ps1 and Core's gen-theme.sh --root take one. The fixture
#  holds one file per SHAPE (a pwsh array, a pwsh hashtable, a psmux.conf table)
#  rather than a copy of all six real consumers.
# ============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:GenTheme = Join-Path $script:RepoRoot 'gen-theme.ps1'
    $env:DOTFILES_GENTHEME_LIBONLY = '1'
    try { . $script:GenTheme }
    finally { Remove-Item Env:DOTFILES_GENTHEME_LIBONLY -ErrorAction SilentlyContinue }

    # A minimal palette in Core's exact flat shape — including the comment hazard the
    # parser has to survive (every colour value STARTS with '#', so a naive
    # comment-strip eats it) and a bare integer that does carry a trailing comment.
    $FixturePalette = @(
        '# theme/palette.toml — a comment line'
        'schema = 1'
        'style         = "storm"'
        '# core:theme:gen palette-colors'
        'color_bg                = "#24283b"'
        'color_bg_dark           = "#1f2335"'
        'color_bg_highlight      = "#292e42"'
        'color_bg_visual         = "#2e3c64"'
        'color_black             = "#1d202f"'
        'color_blue              = "#7aa2f7"'
        'color_blue1             = "#2ac3de"'
        'color_border_highlight  = "#29a4bd"'
        'color_comment           = "#565f89"'
        'color_cyan              = "#7dcfff"'
        'color_dark3             = "#545c7e"'
        'color_fg                = "#c0caf5"'
        'color_fg_dark           = "#a9b1d6"'
        'color_green             = "#9ece6a"'
        'color_magenta           = "#bb9af7"'
        'color_magenta2          = "#ff007c"'
        'color_orange            = "#ff9e64"'
        'color_red               = "#f7768e"'
        'color_red1              = "#db4b4b"'
        'color_terminal_black    = "#414868"'
        'color_yellow            = "#e0af68"'
        '# core:theme:end palette-colors'
        'role_accent = "blue"'
        'role_muted  = "comment"'
        'role_ok     = "green"'
        'role_err    = "red"'
        'role_rule   = "terminal_black"'
        'fallback_accent_sgr  = 111   # a bare integer WITH a trailing comment'
        'fallback_muted_sgr   = 103'
        'fallback_accent_spec = 75'
        'fallback_muted_spec  = 244'
    )
}

Describe 'Get-DotPalette' {
    It 'reads quoted colour values without eating the leading #' {
        # The load-bearing case: `-replace '#.*'` would strip every colour to ''.
        $p = Get-DotPalette -Line $FixturePalette
        $p['color_blue'] | Should -Be '#7aa2f7'
        $p['color_fg']   | Should -Be '#c0caf5'
    }
    It 'strips a trailing comment from a BARE integer value' {
        (Get-DotPalette -Line $FixturePalette)['fallback_accent_sgr'] | Should -Be '111'
    }
    It 'reads the style and the role map' {
        $p = Get-DotPalette -Line $FixturePalette
        $p['style']       | Should -Be 'storm'
        $p['role_accent'] | Should -Be 'blue'
    }
    It 'ignores comment lines and Core own generation markers' {
        $p = Get-DotPalette -Line $FixturePalette
        $p.Keys | Should -Not -Contain '# core:theme:gen palette-colors'
    }
}

Describe 'Test-DotPalette' {
    It 'accepts the fixture palette' {
        Test-DotPalette -Palette (Get-DotPalette -Line $FixturePalette) | Should -BeNullOrEmpty
    }
    It 'rejects a missing key' {
        $p = Get-DotPalette -Line $FixturePalette
        $p.Remove('color_blue')
        (Test-DotPalette -Palette $p) -join ';' | Should -Match 'missing key: color_blue'
    }
    It 'rejects an uppercase or short hex' {
        # Core validates lowercase 6-digit; matching that keeps the two generators
        # from disagreeing about what a valid palette is.
        $p = Get-DotPalette -Line $FixturePalette
        $p['color_blue'] = '#7AA2F7'
        (Test-DotPalette -Palette $p) -join ';' | Should -Match 'not a 6-digit lowercase hex'
    }
    It 'rejects a role naming an undefined colour' {
        $p = Get-DotPalette -Line $FixturePalette
        $p['role_accent'] = 'chartreuse'
        (Test-DotPalette -Palette $p) -join ';' | Should -Match 'names an undefined colour'
    }
    It 'rejects a non-numeric 256-colour fallback' {
        $p = Get-DotPalette -Line $FixturePalette
        $p['fallback_accent_sgr'] = 'blue'
        (Test-DotPalette -Palette $p) -join ';' | Should -Match 'not a 256-colour index'
    }
}

Describe 'ConvertTo-DotRgb' {
    It 'converts a hex to the decimal triple the SGR sequences need' {
        ConvertTo-DotRgb '#7aa2f7' | Should -Be '122;162;247'
        ConvertTo-DotRgb '#565f89' | Should -Be '86;95;137'
        ConvertTo-DotRgb '#1d202f' | Should -Be '29;32;47'
    }
    It 'accepts a value with or without the leading #' {
        ConvertTo-DotRgb '7aa2f7' | Should -Be '122;162;247'
    }
}

Describe 'Get-DotThemeRegion' {
    It 'finds a block and captures the opening indentation' {
        $lines = @('before', '    # core:theme:gen demo', '    body', '    # core:theme:end demo', 'after')
        $r = Get-DotThemeRegion -Line $lines -Id 'demo'
        $r.Start  | Should -Be 1
        $r.End    | Should -Be 3
        $r.Indent | Should -Be '    '
        $r.Body   | Should -Be @('    body')
    }
    It 'returns null when the block is absent' {
        Get-DotThemeRegion -Line @('nothing here') -Id 'demo' | Should -BeNullOrEmpty
    }
    It 'throws on an unterminated region rather than rewriting to EOF' {
        # Guessing the end would destroy hand-authored code below the marker.
        { Get-DotThemeRegion -Line @('# core:theme:gen demo', 'body') -Id 'demo' } | Should -Throw
    }
    It 'does not confuse one block id with another' {
        $lines = @('# core:theme:gen alpha', 'a', '# core:theme:end alpha',
                   '# core:theme:gen beta',  'b', '# core:theme:end beta')
        (Get-DotThemeRegion -Line $lines -Id 'beta').Body | Should -Be @('b')
    }
    It 'handles an empty block body' {
        $lines = @('# core:theme:gen demo', '# core:theme:end demo')
        (Get-DotThemeRegion -Line $lines -Id 'demo').Body.Count | Should -Be 0
    }
}

Describe 'Get-DotThemeDrift' {
    It 'reports in sync for identical bodies' {
        (Get-DotThemeDrift -Actual @('a', 'b') -Expected @('a', 'b')).InSync | Should -BeTrue
    }
    It 'reports drift on a changed value' {
        (Get-DotThemeDrift -Actual @('x = 1') -Expected @('x = 2')).InSync | Should -BeFalse
    }
    It 'ignores trailing whitespace rather than calling it a colour change' {
        (Get-DotThemeDrift -Actual @('a   ') -Expected @('a')).InSync | Should -BeTrue
    }
    It 'reports drift when a line is added or removed' {
        (Get-DotThemeDrift -Actual @('a') -Expected @('a', 'b')).InSync | Should -BeFalse
    }
}

Describe 'Get-DotResidualHex' {
    BeforeAll { $Pal = Get-DotPalette -Line $FixturePalette }
    It 'passes a file whose hexes are all palette values' {
        Get-DotResidualHex -Line @('fg=#414868', 'bg=#24283b') -Palette $Pal | Should -BeNullOrEmpty
    }
    It 'flags a hex the palette does not define, with its line number' {
        # THE REGRESSION TEST FOR #228: #16161e and #27a1b9 lived in 10-tools.ps1 for
        # a long time under a comment claiming the block matched Core. This is the
        # check that would have caught them.
        $r = @(Get-DotResidualHex -Line @('ok #24283b', 'bad #16161e') -Palette $Pal)
        $r.Count | Should -Be 1
        $r[0]    | Should -Match '^2: #16161e$'
    }
    It 'is case-insensitive about the literal but still compares by value' {
        Get-DotResidualHex -Line @('#24283B') -Palette $Pal | Should -BeNullOrEmpty
    }
    It 'ignores psmux #{@tn_*} option references' {
        Get-DotResidualHex -Line @('#[fg=#{@tn_blue}]') -Palette $Pal | Should -BeNullOrEmpty
    }
}

Describe 'gen-theme.ps1 end-to-end (hermetic fixture)' {
    BeforeAll {
        $Fixture = Join-Path ([IO.Path]::GetTempPath()) ('gentheme-fx-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $Fixture 'theme') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Fixture 'psmux') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $Fixture 'theme/palette.toml'),
            ($FixturePalette -join "`n") + "`n", [Text.UTF8Encoding]::new($false))

        # One real consumer shape: psmux.conf's @tn_* table. Seeded WRONG on purpose,
        # so the assertions below prove the generator corrects rather than merely agrees.
        $ConfPath = Join-Path $Fixture 'psmux/psmux.conf'
        [IO.File]::WriteAllText($ConfPath, (@(
            '# hand-authored above'
            '# core:theme:gen psmux-palette'
            'set -g @tn_bg      "#000000"'
            '# core:theme:end psmux-palette'
            '# hand-authored below'
        ) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    }
    AfterAll { if (Test-Path $Fixture) { Remove-Item -Recurse -Force $Fixture } }

    It '-Check exits 1 on a stale block' {
        $null = & pwsh -NoProfile -File $script:GenTheme -Check -Root $Fixture 2>&1
        $LASTEXITCODE | Should -Be 1
    }
    It 'rewrites the block from the palette' {
        $null = & pwsh -NoProfile -File $script:GenTheme -Root $Fixture 2>&1
        $LASTEXITCODE | Should -Be 0
        $txt = Get-Content -Raw $ConfPath
        $txt | Should -Match 'set -g @tn_bg      "#24283b"'
        $txt | Should -Match 'set -g @tn_black   "#414868"'
    }
    It 'leaves hand-authored lines outside the markers untouched' {
        $txt = Get-Content -Raw $ConfPath
        $txt | Should -Match '# hand-authored above'
        $txt | Should -Match '# hand-authored below'
    }
    It 'is idempotent — a second run changes nothing' {
        $before = Get-Content -Raw $ConfPath
        $null = & pwsh -NoProfile -File $script:GenTheme -Root $Fixture 2>&1
        Get-Content -Raw $ConfPath | Should -BeExactly $before
    }
    It '-Check exits 0 once the tree is generated' {
        $null = & pwsh -NoProfile -File $script:GenTheme -Check -Root $Fixture 2>&1
        $LASTEXITCODE | Should -Be 0
    }
    It 'writes LF, not CRLF' {
        # .gitattributes pins the working tree to LF on every OS and the validator
        # enforces it; Set-Content would have written CRLF here.
        ([IO.File]::ReadAllText($ConfPath)) | Should -Not -Match "`r`n"
    }
    It 'exits 2 when the palette is missing entirely' {
        # Structural failure, NOT drift: there is nothing to compare against, so
        # reporting "in sync" would be a lie. Sticky severity, 2 > 1 > 0.
        $bare = Join-Path ([IO.Path]::GetTempPath()) ('gentheme-bare-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bare -Force | Out-Null
        try {
            $null = & pwsh -NoProfile -File $script:GenTheme -Check -Root $bare 2>&1
            $LASTEXITCODE | Should -Be 2
        } finally { Remove-Item -Recurse -Force $bare }
    }
}

Describe 'the registry covers every marker in the tree' {
    # Both directions, as Core's preflight does: a block id declared with no marker in
    # the file is caught by the generator itself (exit 2); this catches the inverse —
    # a marker pair someone added without registering an emitter, which would sit in
    # the tree looking generated while nothing ever rendered it.
    It 'has a registered block for every core:theme:gen marker in the repo' {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $gen = Join-Path $RepoRoot 'gen-theme.ps1'
        $declared = @(@(& pwsh -NoProfile -File $gen -List) |
            ForEach-Object { ($_ -split "`t")[0] } | Sort-Object -Unique)

        $found = Get-ChildItem -Path $RepoRoot -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Extension -in @('.ps1', '.conf') } |
            Select-String -Pattern '^\s*#\s*core:theme:gen\s+(\S+)\s*$' |
            ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique

        foreach ($id in $found) { $declared | Should -Contain $id }
    }
}
