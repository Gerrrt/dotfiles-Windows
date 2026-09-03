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

Describe 'Get-DotJsonStructural' {
    It 'blanks a quoted string so its braces are not counted as nesting' {
        # THE REGRESSION THIS GUARDS: settings.json is full of "{574e775e-...}" profile
        # guids. Counting those as nesting ends a region in the wrong place, and the
        # symptom is a silently mis-targeted rewrite rather than an error.
        Get-DotJsonStructural '"guid": "{574e775e-4f2a-5b96-ac1e-a2962a402336}",' | Should -Be '"": "",'
    }
    It 'leaves real structural characters alone' {
        Get-DotJsonStructural '        {' | Should -Be '        {'
    }
    It 'honours a backslash escape so a \" cannot re-open a string' {
        Get-DotJsonStructural '"a\"{": "b"' | Should -Be '"": ""'
    }
}

Describe 'Get-DotJsonSchemeRegion' {
    BeforeAll {
        # Windows Terminal's OWN serializer style: '[' and '{' on the line AFTER the key,
        # four-space indent, keys alphabetical, uppercase hex. Two traps are deliberate —
        # a PROFILE named the same as the target scheme, and a scheme whose NAME contains
        # a brace.
        $Doc = @(
            '{'
            '    "profiles":'
            '    {'
            '        "list":'
            '        ['
            '            {'
            '                "guid": "{574e775e-4f2a-5b96-ac1e-a2962a402336}",'
            '                "name": "Tokyo Night"'
            '            }'
            '        ]'
            '    },'
            '    "schemes":'
            '    ['
            '        {'
            '            "background": "#1f2335",'
            '            "name": "Campbell {legacy}"'
            '        },'
            '        {'
            '            "background": "#000000",'
            '            "name": "Tokyo Night"'
            '        }'
            '    ],'
            '    "themes": []'
            '}'
        )
    }
    It 'finds the scheme by name and brackets its own braces' {
        $r = Get-DotJsonSchemeRegion -Line $Doc -Scheme 'Tokyo Night'
        $Doc[$r.Start].Trim() | Should -Be '{'
        $Doc[$r.End].Trim()   | Should -Be '}'
        ($Doc[$r.Start..$r.End] -join "`n") | Should -Match '"background": "#000000"'
    }
    It 'does not pick a PROFILE that shares the scheme name' {
        # An unscoped search for "name": "Tokyo Night" matches the profile first, and
        # would rewrite colours into profiles.list. This is why the walk is scoped to
        # the schemes array.
        $r = Get-DotJsonSchemeRegion -Line $Doc -Scheme 'Tokyo Night'
        ($Doc[$r.Start..$r.End] -join "`n") | Should -Not -Match 'guid'
    }
    It 'is not derailed by a brace inside an earlier scheme name' {
        # If the string-stripper failed, "Campbell {legacy}" would leave brace depth at 1
        # and the target's region would run to the wrong line.
        $r = Get-DotJsonSchemeRegion -Line $Doc -Scheme 'Tokyo Night'
        ($r.End - $r.Start) | Should -Be 3
    }
    It 'finds a scheme whose own name carries a brace' {
        $r = Get-DotJsonSchemeRegion -Line $Doc -Scheme 'Campbell {legacy}'
        ($Doc[$r.Start..$r.End] -join "`n") | Should -Match '#1f2335'
    }
    It 'returns null for a scheme that is not there' {
        Get-DotJsonSchemeRegion -Line $Doc -Scheme 'Nord' | Should -BeNullOrEmpty
    }
    It 'does not select a scheme whose name differs only in case' {
        # Scheme names are case-sensitive identifiers; targeting must be exact so a
        # 'tokyo night' scheme could never be rewritten in place of 'Tokyo Night'.
        Get-DotJsonSchemeRegion -Line $Doc -Scheme 'tokyo night' | Should -BeNullOrEmpty
    }
    It 'returns null when the document has no schemes array at all' {
        Get-DotJsonSchemeRegion -Line @('{', '    "themes": []', '}') -Scheme 'Tokyo Night' |
            Should -BeNullOrEmpty
    }
    It 'throws on an unterminated schemes array rather than rewriting to EOF' {
        # Same contract as Get-DotThemeRegion: guessing the end destroys the rest of the
        # document.
        { Get-DotJsonSchemeRegion -Line @('{', '    "schemes":', '    [', '        {') -Scheme 'x' } |
            Should -Throw
    }
}

Describe 'Set-DotJsonSchemeColor' {
    BeforeAll {
        $Obj = @(
            '        {'
            '            "background": "#000000",'
            '            "cyan": "#7dcfff",'
            '            "name": "Tokyo Night",'
            '            "red": "#F7768E"'
            '        }'
        )
        $Want = [ordered]@{ background = '#24283B'; cyan = '#7DCFFF'; red = '#F7768E' }
    }
    It 'replaces the hex and preserves indentation and the trailing comma' {
        $r = Set-DotJsonSchemeColor -Line $Obj -Start 0 -End 5 -Color $Want
        $r.Lines[1] | Should -BeExactly '            "background": "#24283B",'
    }
    It 'upcases a value that is already correct but lowercase' {
        # The app writes uppercase. A lowercase value is drift we fix ONCE here, rather
        # than let the app rewrite on every launch.
        $r = Set-DotJsonSchemeColor -Line $Obj -Start 0 -End 5 -Color $Want
        $r.Lines[2] | Should -BeExactly '            "cyan": "#7DCFFF",'
    }
    It 'leaves a key it does not own untouched' {
        (Set-DotJsonSchemeColor -Line $Obj -Start 0 -End 5 -Color $Want).Lines[3] |
            Should -BeExactly '            "name": "Tokyo Night",'
    }
    It 'reports only the keys that actually moved' {
        $r = Set-DotJsonSchemeColor -Line $Obj -Start 0 -End 5 -Color $Want
        @($r.Changed).Count | Should -Be 2
        ($r.Changed.Key | Sort-Object) -join ',' | Should -Be 'background,cyan'
    }
    It 'reports in sync when every value already matches' {
        $r = Set-DotJsonSchemeColor -Line $Obj -Start 0 -End 5 -Color ([ordered]@{ red = '#F7768E' })
        @($r.Changed).Count | Should -Be 0
        @($r.Missing).Count | Should -Be 0
    }
    It 'reports a key the object lacks instead of inserting it' {
        # Inserting means guessing the app's sort order; the caller treats this as
        # structural (exit 2) rather than drift.
        $r = Set-DotJsonSchemeColor -Line $Obj -Start 0 -End 5 -Color ([ordered]@{ purple = '#BB9AF7' })
        $r.Missing | Should -Be @('purple')
    }
    It 'does not touch a matching line OUTSIDE the region' {
        $lines = @('            "blue": "#000000",') + $Obj
        $r = Set-DotJsonSchemeColor -Line $lines -Start 1 -End 6 -Color ([ordered]@{ blue = '#7AA2F7' })
        $r.Lines[0] | Should -BeExactly '            "blue": "#000000",'
        $r.Missing  | Should -Be @('blue')
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
        New-Item -ItemType Directory -Path (Join-Path $Fixture 'windows-terminal') -Force | Out-Null
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

        # The OTHER shape: the app-owned JSON, in Windows Terminal's own serializer style.
        # It carries all twenty keys the emitter owns, because a missing one is a
        # STRUCTURAL failure (exit 2) and would mask the drift this fixture is testing.
        # Three seeds are deliberate: `background` and `blue` are plain wrong, `cyan` is
        # the RIGHT VALUE IN THE WRONG CASE, and every hex the generator does not own is
        # a palette value so the residual scan stays quiet.
        #
        # Two traps, as in the unit tests above: a profile sharing the scheme's name, and
        # a second scheme (with a braced name) that must not move.
        $JsonPath = Join-Path $Fixture 'windows-terminal/settings.json'
        [IO.File]::WriteAllText($JsonPath, (@(
            '{'
            '    "profiles":'
            '    {'
            '        "list":'
            '        ['
            '            {'
            '                "guid": "{574e775e-4f2a-5b96-ac1e-a2962a402336}",'
            '                "name": "Tokyo Night"'
            '            }'
            '        ]'
            '    },'
            '    "schemes":'
            '    ['
            '        {'
            '            "background": "#1F2335",'
            '            "name": "Campbell {legacy}"'
            '        },'
            '        {'
            '            "background": "#000000",'
            '            "black": "#414868",'
            '            "blue": "#000000",'
            '            "brightBlack": "#414868",'
            '            "brightBlue": "#7AA2F7",'
            '            "brightCyan": "#7DCFFF",'
            '            "brightGreen": "#9ECE6A",'
            '            "brightPurple": "#BB9AF7",'
            '            "brightRed": "#F7768E",'
            '            "brightWhite": "#C0CAF5",'
            '            "brightYellow": "#E0AF68",'
            '            "cursorColor": "#C0CAF5",'
            '            "cyan": "#7dcfff",'
            '            "foreground": "#A9B1D6",'
            '            "green": "#9ECE6A",'
            '            "name": "Tokyo Night",'
            '            "purple": "#BB9AF7",'
            '            "red": "#F7768E",'
            '            "selectionBackground": "#2E3C64",'
            '            "white": "#C0CAF5",'
            '            "yellow": "#E0AF68"'
            '        }'
            '    ],'
            '    "themes": []'
            '}'
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
    It 'rewrites the JSON scheme, preserving indentation and the trailing comma' {
        # Byte-for-byte on everything but the six hex digits — the whole point of the
        # line-scoped rewrite over a ConvertTo-Json reserialize.
        $lines = [IO.File]::ReadAllText($JsonPath) -split "`n"
        $lines | Should -Contain '            "background": "#24283B",'
        $lines | Should -Contain '            "blue": "#7AA2F7",'
    }
    It 'emits UPPERCASE hex, so the app does not rewrite it back on next launch' {
        # `cyan` was seeded as the right value in the wrong case (#7dcfff).
        ([IO.File]::ReadAllText($JsonPath) -split "`n") | Should -Contain '            "cyan": "#7DCFFF",'
    }
    It 'leaves the OTHER scheme and the same-named profile alone' {
        $txt = [IO.File]::ReadAllText($JsonPath)
        $txt | Should -Match '"background": "#1F2335"'
        $txt | Should -Match '"guid": "\{574e775e-4f2a-5b96-ac1e-a2962a402336\}"'
    }
    It 'leaves a non-colour key inside the scheme untouched' {
        [IO.File]::ReadAllText($JsonPath) | Should -Match '"name": "Tokyo Night"'
    }
    It 'still parses as JSON — tests/Invoke-Validation.ps1 gates every *.json' {
        { [IO.File]::ReadAllText($JsonPath) | ConvertFrom-Json } | Should -Not -Throw
    }
    It 'is idempotent — a second run changes nothing' {
        $before     = Get-Content -Raw $ConfPath
        $beforeJson = Get-Content -Raw $JsonPath
        $null = & pwsh -NoProfile -File $script:GenTheme -Root $Fixture 2>&1
        Get-Content -Raw $ConfPath | Should -BeExactly $before
        Get-Content -Raw $JsonPath | Should -BeExactly $beforeJson
    }
    It '-Check exits 0 once the tree is generated' {
        $null = & pwsh -NoProfile -File $script:GenTheme -Check -Root $Fixture 2>&1
        $LASTEXITCODE | Should -Be 0
    }
    It 'writes LF, not CRLF' {
        # .gitattributes pins the working tree to LF on every OS and the validator
        # enforces it; Set-Content would have written CRLF here.
        ([IO.File]::ReadAllText($ConfPath)) | Should -Not -Match "`r`n"
        # The JSON target has a second reason: tests/Format-AppJson.ps1 normalizes it to
        # LF with one final newline, and a generator that wrote CRLF would fight the hook.
        ([IO.File]::ReadAllText($JsonPath)) | Should -Not -Match "`r`n"
        ([IO.File]::ReadAllText($JsonPath)) | Should -BeLike "*}`n"
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

Describe 'the JSON target fails STRUCTURALLY, not as drift' {
    # Sticky severity, 2 > 1 > 0. Both cases below leave nothing to compare against, so
    # reporting "drift" (exit 1, "run gen-theme.ps1 to fix it") would send the user to a
    # command that cannot help. The marker kind already treats its equivalents — a
    # deleted marker pair, an unterminated region — the same way.
    BeforeAll {
        function New-JsonOnlyFixture {
            param([string[]]$Scheme)
            $dir = Join-Path ([IO.Path]::GetTempPath()) ('gentheme-json-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $dir 'theme') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $dir 'windows-terminal') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'theme/palette.toml'),
                ($FixturePalette -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $dir 'windows-terminal/settings.json'),
                ((@('{', '    "schemes":', '    [', '        {') + $Scheme + @('        }', '    ]', '}')) -join "`n") + "`n",
                [Text.UTF8Encoding]::new($false))
            return $dir
        }
    }
    It 'exits 2 when no scheme carries the registered name' {
        $dir = New-JsonOnlyFixture -Scheme @('            "name": "Nord"')
        try {
            $null = & pwsh -NoProfile -File $script:GenTheme -Check -Root $dir 2>&1
            $LASTEXITCODE | Should -Be 2
        } finally { Remove-Item -Recurse -Force $dir }
    }
    It 'exits 2 when the scheme is missing a colour key the emitter owns' {
        # How the app dropping a key it considers default would surface — named, rather
        # than silently generating the other nineteen.
        $dir = New-JsonOnlyFixture -Scheme @('            "background": "#24283B",', '            "name": "Tokyo Night"')
        try {
            $out = & pwsh -NoProfile -File $script:GenTheme -Check -Root $dir 2>&1
            $LASTEXITCODE | Should -Be 2
            ($out -join "`n") | Should -Match 'selectionBackground'
        } finally { Remove-Item -Recurse -Force $dir }
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
