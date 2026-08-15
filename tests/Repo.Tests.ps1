# ============================================================================
#  tests/Repo.Tests.ps1  -  Pester v5 suite (runs in CI on a Windows runner).
#
#  Structural/regression gates that don't need a live Windows host:
#    • every *.ps1 parses with no syntax errors
#    • package manifests are valid and free of duplicates
#    • the .gitconfig has the expected include for the gitignored local identity
#  Behavioral gates for individual fixes live next to them (e.g. Lib.Tests.ps1).
#
#  Local quick gate (no Pester/Gallery needed): tests/Invoke-Validation.ps1
# ============================================================================

BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Ps1Files = Get-ChildItem -Path $script:RepoRoot -Recurse -Filter *.ps1 -File |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
}

Describe 'PowerShell syntax' {
    It '<RelPath> parses with no errors' -ForEach (
        $script:Ps1Files | ForEach-Object {
            @{ Path = $_.FullName; RelPath = $_.FullName.Substring($script:RepoRoot.Length + 1) }
        }
    ) {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Package manifests' {
    BeforeAll { $RepoRoot = Split-Path -Parent $PSScriptRoot }

    It 'scoopfile.json is valid JSON with apps and buckets' {
        $m = Get-Content (Join-Path $RepoRoot 'packages/scoopfile.json') -Raw | ConvertFrom-Json
        $m.apps    | Should -Not -BeNullOrEmpty
        $m.buckets | Should -Not -BeNullOrEmpty
    }
    It 'scoopfile.json has no duplicate apps' {
        $m = Get-Content (Join-Path $RepoRoot 'packages/scoopfile.json') -Raw | ConvertFrom-Json
        ($m.apps.Name | Group-Object | Where-Object Count -gt 1) | Should -BeNullOrEmpty
    }
    It 'scoopfile.json references only declared buckets' {
        $m = Get-Content (Join-Path $RepoRoot 'packages/scoopfile.json') -Raw | ConvertFrom-Json
        $declared = $m.buckets.Name
        foreach ($app in $m.apps) { $declared | Should -Contain $app.Source }
    }
    It 'winget.json is valid JSON with no duplicate ids' {
        $w = (Get-Content (Join-Path $RepoRoot 'packages/winget.json') -Raw | ConvertFrom-Json).packages
        $w | Should -Not -BeNullOrEmpty
        # Entries may be a bare id string OR an object { id, version, group } (U3) —
        # normalize to ids before the duplicate check.
        $ids = foreach ($e in $w) { if ($e -is [string]) { $e } else { $e.id } }
        ($ids | Group-Object | Where-Object Count -gt 1) | Should -BeNullOrEmpty
    }
    It 'every winget id is a Publisher.Package form (provenance)' {
        $w = (Get-Content (Join-Path $RepoRoot 'packages/winget.json') -Raw | ConvertFrom-Json).packages
        $ids = foreach ($e in $w) { if ($e -is [string]) { $e } else { $e.id } }
        foreach ($id in $ids) { $id | Should -Match '^[^\s.]+(\.[^\s.]+)+$' }
    }
    It 'every scoop app has a plausible id (provenance)' {
        $m = Get-Content (Join-Path $RepoRoot 'packages/scoopfile.json') -Raw | ConvertFrom-Json
        foreach ($app in $m.apps) { $app.Name | Should -Match '^[\w.+-]+$' }
    }
}

Describe 'Managed module pins' {
    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $RepoRoot 'packages/modules.ps1')
    }
    It 'pins a version floor for every managed module' {
        $script:MaintModulePins.Count | Should -BeGreaterThan 0
        foreach ($name in $script:MaintModulePins.Keys) {
            $script:MaintModulePins[$name] | Should -Match '^\d+\.\d+'
        }
    }
    It 'keeps the name list in sync with the pins' {
        @($script:MaintModuleNames).Count | Should -Be $script:MaintModulePins.Count
    }
    It 'pins PSReadLine >= 2.2.0 (bracketed paste; safe multi-line paste under Vi mode)' {
        # Below 2.2.0 PSReadLine has no bracketed-paste support, so a multi-line
        # paste under our EditMode Vi (core/10-tools.ps1) replays as keystrokes and
        # runs as Vi commands. Keep the floor at/above the first release that fixes it.
        [version]$script:MaintModulePins['PSReadLine'] | Should -BeGreaterOrEqual ([version]'2.2.0')
    }
}

Describe 'repo hygiene' {
    BeforeAll { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    It 'ships an .editorconfig' {
        Test-Path (Join-Path $RepoRoot '.editorconfig') | Should -BeTrue
    }
    It 'install.ps1 excludes the .git tree from Unblock-File' {
        $i = Get-Content (Join-Path $RepoRoot 'install.ps1') -Raw
        $i | Should -Match "notlike '\*\\\.git\\\*'"
    }
    It 'Maintenance.ps1 has no garbled nested-hash comment' {
        $m = Get-Content (Join-Path $RepoRoot 'maint/Maintenance.ps1') -Raw
        $m | Should -Not -Match '#\s+#\s+#'
    }
    It '<RelPath> ends with a final newline (editorconfig)' -ForEach (
        $script:Ps1Files | ForEach-Object {
            @{ Path = $_.FullName; RelPath = $_.FullName.Substring($script:RepoRoot.Length + 1) }
        }
    ) {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length) { $bytes[-1] | Should -Be 0x0A }
    }
}

Describe 'README layout box tracks the actual fragments (B15)' {
    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $readme = Get-Content (Join-Path $RepoRoot 'README.md') -Raw
        # Grab the fenced code block under "## Layout" (allow an optional language/
        # info string after the opening fence, e.g. ```text).
        $m = [regex]::Match($readme, '(?ms)^## Layout\s*\r?\n```[^\r\n]*\r?\n(.*?)\r?\n```')
        $script:LayoutBlock = if ($m.Success) { $m.Groups[1].Value } else { '' }
        # Fragment tokens in the box (NN-name), e.g. 05-lib, 31-wsl-bridge, 57-health-nudge.
        $script:DocFrags = [regex]::Matches($script:LayoutBlock, '\b\d{2}-[a-z][a-z-]*') |
            ForEach-Object { $_.Value } | Sort-Object -Unique
        # Actual fragments on disk (core + os), basename without .ps1.
        $script:DiskFrags = Get-ChildItem `
            (Join-Path $RepoRoot 'powershell/core'), (Join-Path $RepoRoot 'powershell/os') -Filter *.ps1 |
            ForEach-Object { $_.BaseName } | Sort-Object -Unique
    }
    It 'finds the Layout code block' {
        $script:LayoutBlock | Should -Not -BeNullOrEmpty
    }
    It 'lists exactly the on-disk core/os fragments (no missing, no stale)' {
        # Equal sets: a new fragment must be added to the box, a removed one dropped.
        ($script:DocFrags -join ', ') | Should -Be ($script:DiskFrags -join ', ') `
            -Because 'the README Layout box drifted from powershell/core + powershell/os (update it)'
    }
}

Describe 'psmux config' {
    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:Conf = Get-Content (Join-Path $RepoRoot 'psmux/psmux.conf') -Raw
        # Just the `set -g status-*` lines — asserting against the whole file would
        # happily match the pills' own explanatory comment blocks (which is exactly how
        # the previous version of these tests kept passing after the segment it checked
        # had been retired into a comment).
        $script:StatusLeft  = ([regex]::Match($script:Conf, '(?m)^set -g status-left "(.*)"$')).Groups[1].Value
        $script:StatusRight = ([regex]::Match($script:Conf, '(?m)^set -g status-right "(.*)"$')).Groups[1].Value
    }
    It 'renders the VPN/IP pill from the @vpn_pill user option in status-left' {
        # The lag-safe transport: an in-process option lookup, never a #() spawn.
        $script:StatusLeft | Should -Match '#\{@vpn_pill\}'
        $script:StatusLeft | Should -Match '#\[nobold,fg=#\{@vpn_fg\}\]'
    }
    It 'renders the power pill right-most in status-right (macOS battery parity)' {
        $script:StatusRight | Should -Match '#\{@pwr_pill\}'
        $script:StatusRight | Should -Match 'fg=#\{@pwr_fg\}'
        # Right-most: nothing but whitespace may follow it.
        $script:StatusRight | Should -Match '#\{@pwr_pill\}\s*$'
        # ...and it must come after the clock, not before it.
        $script:StatusRight.IndexOf('#{@pwr_pill}') | Should -BeGreaterThan $script:StatusRight.IndexOf('%H:%M')
    }
    It 'defaults <Opt> with -o so a config reload cannot clobber a live poke' -ForEach @(
        @{ Opt = '@pwr_pill' }
        @{ Opt = '@pwr_fg' }
        @{ Opt = '@vpn_fg' }
    ) {
        # `set -og` is only-if-unset. A plain `set -g` overwrites whatever the refresher last
        # poked, on every prefix + r, and the segment then lies until the next tick (up to a
        # full refresh interval).
        #
        # This applies to the COLOUR options as much as the text: these pills encode their
        # state in the colour, so a clobbered @pwr_fg paints a 15% battery healthy-green and a
        # clobbered @vpn_fg paints a live tunnel in the no-tunnel colour. @vpn_pill is the one
        # option with no default at all — see psmux.conf.
        $script:Conf | Should -Match "(?m)^set -og\s+$([regex]::Escape($Opt))\b"
        $script:Conf | Should -Not -Match "(?m)^set -g\s+$([regex]::Escape($Opt))\b"
    }
    It 'spaces its bar gaps with #{p<n>:}, which psmux will not collapse' {
        # psmux parses option values as split_whitespace() + join(" "), so ANY run of real
        # spaces in these two values silently becomes one -- the twelve-space cwd->clock gap
        # rendered as a single space for as long as it existed. #{p<n>:} pads an empty body at
        # RENDER time, after the parser, and is the same idiom Core's tmux.conf uses.
        foreach ($seg in @($script:StatusLeft, $script:StatusRight)) {
            $seg | Should -Not -Match '  ' -Because 'a multi-space gap collapses to one; use #{p<n>:}'
        }
        # ...and the gaps are actually there (a guard that only forbids is a guard that
        # passes when someone deletes the spacing altogether).
        $script:StatusLeft  | Should -Match '#\{p\d+:\}'
        $script:StatusRight | Should -Match '#\{p\d+:\}'
    }
    It 'keeps the prefix/copy/idle indicator branches the same width' {
        # The invariant that stops holding the prefix key from sliding the IP pill sideways.
        # These branches are the gap between #S and the pill, so they must render identically
        # wide: 2 blanks + a 1-cell glyph + 2 blanks, against 5 blanks when idle.
        # Anchored on #{p<n>:} in every branch: status-left opens with a SECOND
        # #{?client_prefix,...} — the colour selector — and an unanchored pattern matches that
        # one instead and silently compares palette names.
        $m = [regex]::Match($script:StatusLeft,
            '#\{\?client_prefix,(?<pfx>[^,]*#\{p\d+:\}[^,]*),#\{\?pane_in_mode,(?<copy>[^,]*#\{p\d+:\}[^,]*),(?<idle>[^,]*#\{p\d+:\}[^,]*)\}\}')
        $m.Success | Should -BeTrue -Because 'the three-branch indicator should still be in status-left'
        # Width = the #{p<n>:} pads plus one cell per remaining rune. The indicator glyphs are
        # astral (U+F0820 / U+F018F) so they are TWO UTF-16 chars each but measured one cell
        # on a real terminal — count runes, not chars.
        $width = {
            param($s)
            $pad = ([regex]::Matches($s, '#\{p(\d+):\}') | ForEach-Object { [int]$_.Groups[1].Value } |
                Measure-Object -Sum).Sum
            $rest = [regex]::Replace($s, '#\{p\d+:\}', '')
            [int]$pad + @($rest.EnumerateRunes()).Count
        }
        $pfx  = & $width $m.Groups['pfx'].Value
        $copy = & $width $m.Groups['copy'].Value
        $idle = & $width $m.Groups['idle'].Value
        $pfx  | Should -Be $idle -Because "prefix branch is $pfx cells, idle is $idle"
        $copy | Should -Be $idle -Because "copy-mode branch is $copy cells, idle is $idle"
    }
    It 'never spawns a process on the render path' {
        # The hard rule from the config header: psmux expands these SYNCHRONOUSLY on
        # every state push, so a #() here is keystroke lag.
        $script:StatusLeft  | Should -Not -Match '#\('
        $script:StatusRight | Should -Not -Match '#\('
    }
}

Describe 'psmux power pill (Core tmux parity)' {
    # The dev box is a desktop, so without -SimulateState every branch below would ship
    # unexecuted — the one state that needs no logic would be the only one ever seen.
    # Thresholds and glyphs are copied from dotfiles-core's tmux/scripts/tmux-battery.sh so
    # the two TERMINAL bars agree; if either side moves, these break. (Zebar/sketchybar use a
    # different scale on purpose — those two are matched to each other, desktop-to-desktop.)
    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:PwrScript = Join-Path $RepoRoot 'psmux/scripts/psmux-power.ps1'
        $script:PLUG   = [char]::ConvertFromUtf32(0xF06A5)   # nf-md-power_plug
        $script:CHG    = [char]::ConvertFromUtf32(0xF0084)   # charging bolt
        $script:GREEN  = '#9ece6a'
        $script:YELLOW = '#e0af68'
        $script:RED    = '#f7768e'
    }
    It 'shows a lone green plug on a desktop (no battery)' {
        # The one deliberate divergence from Core, which draws nothing at all here.
        $r = & $script:PwrScript -SimulateState NoBattery
        $r.Text | Should -BeExactly $script:PLUG
        $r.Fg   | Should -BeExactly $script:GREEN
    }
    It 'swaps the level glyph for a charging bolt on AC, keeping the level colour' {
        # Core changes the GLYPH when charging, never the colour — a charging laptop at 15%
        # is still red. Getting this wrong would silently hide a nearly-flat battery.
        $r = & $script:PwrScript -SimulateState AC -SimulatePercent 15
        $r.Text | Should -BeExactly "$script:CHG 15%"
        $r.Fg   | Should -BeExactly $script:RED
    }
    It 'colours by charge level on battery: <Pct>% -> <Colour>' -ForEach @(
        @{ Pct = 95; Colour = '#9ece6a' }
        @{ Pct = 60; Colour = '#9ece6a' }   # boundary: >=60 is green
        @{ Pct = 59; Colour = '#e0af68' }   # boundary: 59 tips into yellow
        @{ Pct = 20; Colour = '#e0af68' }   # boundary: >=20 is still yellow
        @{ Pct = 19; Colour = '#f7768e' }   # boundary: <20 is red
        @{ Pct = 0;  Colour = '#f7768e' }
    ) {
        $r = & $script:PwrScript -SimulateState Battery -SimulatePercent $Pct
        $r.Fg   | Should -BeExactly $Colour
        $r.Text | Should -BeLike "*$Pct%"
        $r.Text | Should -Not -BeLike "*$script:CHG*"   # no bolt off AC
    }
    It 'steps the level glyph at Core''s thresholds: <Pct>% -> U+<Cp>' -ForEach @(
        @{ Pct = 95; Cp = '0xF0081' }   # battery high
        @{ Pct = 60; Cp = '0xF0081' }
        @{ Pct = 59; Cp = '0xF007E' }   # battery medium
        @{ Pct = 20; Cp = '0xF007E' }
        @{ Pct = 19; Cp = '0xF007B' }   # battery low
    ) {
        $r = & $script:PwrScript -SimulateState Battery -SimulatePercent $Pct
        $r.Text | Should -BeLike "*$([char]::ConvertFromUtf32([int]$Cp))*"
    }
    It 'does not touch the live bar when simulating' {
        # A test that poked the running session would rewrite the user's status bar.
        $r = & $script:PwrScript -SimulateState Battery -SimulatePercent 50
        $r | Should -BeOfType [pscustomobject]
        (Get-Content -LiteralPath $script:PwrScript -Raw) |
            Should -Match 'if \(\$SimulateState\) \{[\s\S]*?return Resolve-PowerPill'
    }
}

Describe 'psmux user-option pokes' {
    # REGRESSION GUARD for a bug that was completely silent: in PowerShell a bare @name
    # in argument position is the SPLATTING operator, so `psmux set -g @vpn_pill $text`
    # drops the option name from the command line entirely. psmux then receives a single
    # positional and discards the whole command — exit 0, nothing on stderr, option never
    # set. The VPN pill was invisible for months with every other layer working. Nothing
    # at runtime will ever tell you; only this static check will.
    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:PokeLines = Get-ChildItem -Path $RepoRoot -Recurse -Filter *.ps1 -File |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            ForEach-Object {
                $rel = $_.FullName.Substring($RepoRoot.Length + 1)
                $n = 0
                foreach ($line in (Get-Content -LiteralPath $_.FullName)) {
                    $n++
                    # `psmux set ...` / `psmux set-option ...`, ignoring commented-out lines
                    # (the comment guard is the -notlike below; this file and its neighbours
                    # quote plenty of example pokes in prose that must not be scanned).
                    if ($line -match 'psmux\s+set(-option)?\s' -and $line.TrimStart() -notlike '#*') {
                        [pscustomobject]@{ Where = "${rel}:${n}"; Text = $line.Trim() }
                    }
                }
            }
    }
    It 'finds the poke lines it is meant to guard' {
        # A rename that hides every call site would make the assertions below vacuous.
        $script:PokeLines | Should -Not -BeNullOrEmpty
    }
    It 'quotes every @option name (a bare @name is splatted away by PowerShell)' {
        $bad = $script:PokeLines | Where-Object { $_.Text -match "psmux\s+set(-option)?\s[^|]*(?<!['`"])@\w+" }
        ($bad | ForEach-Object { $_.Where + '  ->  ' + $_.Text }) -join "`n" | Should -BeNullOrEmpty `
            -Because "a bare @name splats away and psmux silently discards the set; write 'psmux set -g ''@name'' `$value'"
    }
}

Describe 'git config' {
    BeforeAll { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    It 'includes the gitignored local identity file' {
        $gc = Get-Content (Join-Path $RepoRoot 'git/.gitconfig') -Raw
        $gc | Should -Match 'path\s*=\s*~/\.gitconfig\.local'
    }
    It 'gitignores the local identity and profile override' {
        $gi = Get-Content (Join-Path $RepoRoot '.gitignore') -Raw
        $gi | Should -Match '\.gitconfig\.local'
        $gi | Should -Match 'powershell/local\.ps1'
    }
}

Describe 'dev-dependency pins match CI' {
    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $env:DOTFILES_DEVDEPS_LIBONLY = '1'
        . (Join-Path $RepoRoot 'tests/Install-DevDeps.ps1')
        $script:Ci = Get-Content (Join-Path $RepoRoot '.github/workflows/ci.yml') -Raw
    }
    AfterAll { Remove-Item Env:DOTFILES_DEVDEPS_LIBONLY -ErrorAction SilentlyContinue }
    It 'pins Pester to the CI PESTER_VERSION (no drift)' {
        $v = (Get-DevDepVersions).Pester
        $script:Ci | Should -Match ([regex]::Escape("PESTER_VERSION: `"$v`""))
    }
    It 'pins PSScriptAnalyzer to the CI PSSA_VERSION (no drift)' {
        $v = (Get-DevDepVersions).PSScriptAnalyzer
        $script:Ci | Should -Match ([regex]::Escape("PSSA_VERSION: `"$v`""))
    }
}

Describe 'coverage gate is baseline-driven (B5)' {
    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $RepoRoot 'tests/CoverageGate.ps1')
        $script:Ci = Get-Content (Join-Path $RepoRoot '.github/workflows/ci.yml') -Raw
        # The gate moved out of ci.yml into tests/Invoke-Tests.ps1 so the local and
        # CI runs are the SAME command; assert against the runner, and separately
        # that CI still delegates to it (tests/RunnerContract.Tests.ps1).
        $script:Runner = Get-Content (Join-Path $RepoRoot 'tests/Invoke-Tests.ps1') -Raw
        $script:Baseline = Read-CoverageBaseline (Get-Content (Join-Path $RepoRoot 'tests/coverage-baseline.json') -Raw)
    }
    It 'ships a parseable, checked-in baseline (coverage bar + test-case floor)' {
        $script:Baseline.MinTotalTests | Should -BeGreaterThan 0
        $script:Baseline.CoveragePercentTarget | Should -BeGreaterThan 0
    }
    It 'the runner reads the baseline through the pure gate (not hand-edited literals)' {
        $script:Runner | Should -Match 'Read-CoverageBaseline'
        $script:Runner | Should -Match 'Get-CoverageGateResult'
        # The old magic-number floors must not creep back in - in EITHER place.
        $script:Runner | Should -Not -Match '\$minTotal\s*='
        $script:Runner | Should -Not -Match '\$minFiles\s*='
        $script:Ci     | Should -Not -Match '\$minTotal\s*='
        $script:Ci     | Should -Not -Match '\$minFiles\s*='
    }
    It 'the runner auto-derives the test-file count from the glob (not a stored number)' {
        $script:Runner | Should -Match 'ExpectedFileCount'
        $script:Runner | Should -Match '-Recurse -File -Filter \*\.Tests\.ps1'
    }
}
