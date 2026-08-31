# ============================================================================
#  tests/Lib.Tests.ps1  -  behavioral tests for the pure helpers in
#  powershell/core/05-lib.ps1. Dot-sourced in isolation (no side effects).
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    # Load AND exercise the pure helpers under the same StrictMode the Dotfiles
    # module runs them under (it sets StrictMode before dot-sourcing too), so a
    # latent unbound-var / missing-property / bad-index bug fails the suite here
    # instead of silently returning $null in a real session.
    Set-StrictMode -Version Latest
    . (Join-Path $RepoRoot 'powershell/core/05-lib.ps1')
}

Describe 'Test-SensitiveHistoryLine' {
    Context 'must KEEP (not sensitive)' {
        It 'keeps the bare pwd command' { Test-SensitiveHistoryLine 'pwd' | Should -BeFalse }
        It 'keeps cd then pwd'          { Test-SensitiveHistoryLine 'cd C:\src; pwd' | Should -BeFalse }
        It 'keeps a "first pass" commit' { Test-SensitiveHistoryLine 'gcm "first pass at the parser"' | Should -BeFalse }
        It 'keeps words containing pass' { Test-SensitiveHistoryLine 'Compress-Archive .\a .\b' | Should -BeFalse }
        It 'keeps a normal ls'          { Test-SensitiveHistoryLine 'll -a' | Should -BeFalse }
        It 'keeps empty / whitespace'   { Test-SensitiveHistoryLine '   ' | Should -BeFalse }
    }
    Context 'must DROP (sensitive)' {
        It 'drops op read'              { Test-SensitiveHistoryLine 'op read op://Personal/AWS/key' | Should -BeTrue }
        It 'drops op item get'          { Test-SensitiveHistoryLine 'op item get GitHub --otp' | Should -BeTrue }
        It 'drops a PASSWORD= assign'   { Test-SensitiveHistoryLine '$env:PASSWORD="hunter2"' | Should -BeTrue }
        It 'drops a token keyword'      { Test-SensitiveHistoryLine 'export GH_TOKEN=ghp_xxx' | Should -BeTrue }
        It 'drops an api-key keyword'   { Test-SensitiveHistoryLine 'setx OPENAI_API_KEY sk-123' | Should -BeTrue }
        It 'drops a --api-key flag'     { Test-SensitiveHistoryLine 'tool --api-key=sk-1' | Should -BeTrue }
        It 'drops a --api_key flag'     { Test-SensitiveHistoryLine 'tool --api_key sk-1' | Should -BeTrue }
        It 'drops an x-api-key header'  { Test-SensitiveHistoryLine 'curl -H "x-api-key: sk-1"' | Should -BeTrue }
        It 'drops a --password flag'    { Test-SensitiveHistoryLine 'mysql --password=s3cr3t -u root' | Should -BeTrue }
        It 'drops a private-key mention'{ Test-SensitiveHistoryLine 'cat ~/.ssh/id_ed25519 # private key' | Should -BeTrue }
    }
}

Describe 'Test-DotNonInteractiveArg' {
    Context 'interactive launches (must be $false)' {
        It 'no args'            { Test-DotNonInteractiveArg @()            | Should -BeFalse }
        It '-NoLogo (WT profile)' { Test-DotNonInteractiveArg @('-NoLogo')  | Should -BeFalse }
        It '-NoExit'            { Test-DotNonInteractiveArg @('-NoExit')    | Should -BeFalse }
        It '-NoProfile'         { Test-DotNonInteractiveArg @('-NoProfile') | Should -BeFalse }
        It 'a bare positional'  { Test-DotNonInteractiveArg @('script.ps1') | Should -BeFalse }
        It '-non (too short to disambiguate from -NoExit/-NoLogo)' {
            Test-DotNonInteractiveArg @('-non') | Should -BeFalse
        }
    }
    Context 'non-interactive launches (must be $true)' {
        It '-Command'          { Test-DotNonInteractiveArg @('-Command', 'exit') | Should -BeTrue }
        It '-c (prefix of -Command)' { Test-DotNonInteractiveArg @('-c', 'exit')  | Should -BeTrue }
        It '-File'             { Test-DotNonInteractiveArg @('-File', 'x.ps1')   | Should -BeTrue }
        It '-f (prefix of -File)' { Test-DotNonInteractiveArg @('-f', 'x.ps1')   | Should -BeTrue }
        It '-EncodedCommand'   { Test-DotNonInteractiveArg @('-EncodedCommand', 'ZXhpdA==') | Should -BeTrue }
        It '-NonInteractive'   { Test-DotNonInteractiveArg @('-NonInteractive')  | Should -BeTrue }
        It '-noni (shortest unambiguous -NonInteractive)' {
            Test-DotNonInteractiveArg @('-noni') | Should -BeTrue
        }
        It 'finds the flag among other args' {
            Test-DotNonInteractiveArg @('-NoLogo', '-File', 'x.ps1') | Should -BeTrue
        }
    }
}

Describe 'Test-InMux' {
    BeforeAll {
        $script:savedTmux = $env:TMUX
        $script:savedSess = $env:PSMUX_SESSION
    }
    AfterAll {
        if ($null -eq $script:savedTmux) { Remove-Item Env:TMUX -ErrorAction SilentlyContinue } else { $env:TMUX = $script:savedTmux }
        if ($null -eq $script:savedSess) { Remove-Item Env:PSMUX_SESSION -ErrorAction SilentlyContinue } else { $env:PSMUX_SESSION = $script:savedSess }
    }
    BeforeEach {
        Remove-Item Env:TMUX -ErrorAction SilentlyContinue
        Remove-Item Env:PSMUX_SESSION -ErrorAction SilentlyContinue
    }
    It 'is $false outside a pane (no markers)' { Test-InMux | Should -BeFalse }
    It 'is $true when TMUX is set'             { $env:TMUX = 'default,1,0'; Test-InMux | Should -BeTrue }
    It 'is $true when PSMUX_SESSION is set'    { $env:PSMUX_SESSION = 'main'; Test-InMux | Should -BeTrue }
}

Describe 'Test-DotColor' {
    It 'enables colour by default'        { Test-DotColor -NoColor '' -Term 'xterm' | Should -BeTrue }
    It 'disables colour when NO_COLOR set' { Test-DotColor -NoColor '1' -Term 'xterm' | Should -BeFalse }
    It 'disables colour for TERM=dumb'    { Test-DotColor -NoColor '' -Term 'dumb' | Should -BeFalse }
}

Describe 'Test-DotUnicode' {
    It 'is unicode by default'             { Test-DotUnicode -Ascii '' | Should -BeTrue }
    It 'falls back to ASCII when forced'   { Test-DotUnicode -Ascii '1' | Should -BeFalse }
}

Describe 'Test-DotTrueColor' {
    It 'is true for COLORTERM=truecolor / 24bit on a live (non-redirected) console' {
        Test-DotTrueColor -ColorTerm 'truecolor' -Redirected $false | Should -BeTrue
        Test-DotTrueColor -ColorTerm '24bit'     -Redirected $false | Should -BeTrue
    }
    It 'is false when COLORTERM is unset or not a truecolor value' {
        Test-DotTrueColor -ColorTerm ''               -Redirected $false | Should -BeFalse
        Test-DotTrueColor -ColorTerm 'xterm-256color' -Redirected $false | Should -BeFalse
    }
    It 'is false when output is redirected (ANSI must not pollute a captured stream)' {
        Test-DotTrueColor -ColorTerm 'truecolor' -Redirected $true | Should -BeFalse
    }
}

Describe 'Get-DotAnsiSgr' {
    It 'emits a 24-bit foreground SGR for a known accent when truecolor is on' {
        Get-DotAnsiSgr -Color Cyan -TrueColor $true | Should -Be "$([char]27)[38;2;125;207;255m"
    }
    It 'emits a background SGR with -Layer bg' {
        Get-DotAnsiSgr -Color Cyan -Layer bg -TrueColor $true | Should -Be "$([char]27)[48;2;125;207;255m"
    }
    It 'returns empty when truecolor is off (caller falls back to ConsoleColor)' {
        Get-DotAnsiSgr -Color Cyan -TrueColor $false | Should -Be ''
    }
    It 'returns empty for a colour outside the palette' {
        Get-DotAnsiSgr -Color 'Chartreuse' -TrueColor $true | Should -Be ''
    }
}

Describe 'Test-DotGum' {
    It 'is true when gum is present, colour on, interactive, and not opted out' {
        Test-DotGum -NoGum '' -HasGum $true -Color $true -Interactive $true | Should -BeTrue
    }
    It 'is false when DOTFILES_NO_GUM=1 (the escape hatch wins over everything)' {
        Test-DotGum -NoGum '1' -HasGum $true -Color $true -Interactive $true | Should -BeFalse
    }
    It 'is false when gum is not on PATH' {
        Test-DotGum -NoGum '' -HasGum $false -Color $true -Interactive $true | Should -BeFalse
    }
    It 'is false under NO_COLOR / TERM=dumb (colour off)' {
        Test-DotGum -NoGum '' -HasGum $true -Color $false -Interactive $true | Should -BeFalse
    }
    It 'is false when stdin is redirected / non-interactive' {
        Test-DotGum -NoGum '' -HasGum $true -Color $true -Interactive $false | Should -BeFalse
    }
}

Describe 'Get-DotGlyph' {
    It 'returns the unicode glyph by default'   { Get-DotGlyph -Name fail -Unicode $true | Should -Be '✗' }
    It 'returns an ASCII fallback when asked'   { Get-DotGlyph -Name fail -Unicode $false | Should -Be 'x' }
    It 'maps the arrow both ways' {
        Get-DotGlyph arrow -Unicode $true  | Should -Be '→'
        Get-DotGlyph arrow -Unicode $false | Should -Be '->'
    }
    It 'maps the package glyph both ways' {
        Get-DotGlyph pkg -Unicode $true  | Should -Be '⇧'
        Get-DotGlyph pkg -Unicode $false | Should -Be '^'
    }
    It 'rejects an unknown glyph name' { { Get-DotGlyph -Name nope } | Should -Throw }
}

Describe 'Write-DotErr' {
    It 'composes message and hint with -PassThru' {
        $out = Write-DotErr -Message 'boom' -Hint 'do this' -PassThru 6>$null
        $out | Should -Match '✗ boom'
        $out | Should -Match '→ do this'
    }
    It 'omits the hint line when none is given' {
        (Write-DotErr -Message 'only' -PassThru 6>$null) | Should -Be '✗ only'
    }
    It 'uses ASCII glyphs under DOTFILES_ASCII=1' {
        $prev = $env:DOTFILES_ASCII
        try {
            $env:DOTFILES_ASCII = '1'
            (Write-DotErr -Message 'only' -PassThru 6>$null) | Should -Be 'x only'
        } finally { $env:DOTFILES_ASCII = $prev }
    }
}

Describe 'Write-DotWarn' {
    It 'composes a warning with the bang glyph and hint' {
        $out = Write-DotWarn -Message 'heads up' -Hint 'try this' -PassThru 6>$null
        $out | Should -Match '! heads up'
        $out | Should -Match '→ try this'
    }
    It 'omits the hint line when none is given' {
        (Write-DotWarn -Message 'bare' -PassThru 6>$null) | Should -Be '! bare'
    }
}

Describe 'Get-DotConfirmAnswer' {
    It 'treats an empty answer as the default (yes)' { Get-DotConfirmAnswer '' $true  | Should -Be 'yes' }
    It 'treats an empty answer as the default (no)'  { Get-DotConfirmAnswer '' $false | Should -Be 'no' }
    It 'accepts y / yes (any case/space)'            { Get-DotConfirmAnswer '  YES ' | Should -Be 'yes' }
    It 'accepts n / no'                              { Get-DotConfirmAnswer 'n' | Should -Be 'no' }
    It 'flags a typo as invalid (not a silent no)'   { Get-DotConfirmAnswer 'yse' | Should -Be 'invalid' }
}

Describe 'Get-DotToolNudge' {
    It 'is empty when nothing is missing' {
        Get-DotToolNudge @()        | Should -BeNullOrEmpty
        Get-DotToolNudge @($null)   | Should -BeNullOrEmpty
    }
    It 'uses the singular for one missing tool and names it' {
        Get-DotToolNudge @('eza') | Should -Be '1 core tool missing (eza) — run dotfiles-doctor'
    }
    It 'uses the plural and lists all missing tools' {
        Get-DotToolNudge @('starship', 'zoxide', 'fzf') |
            Should -Be '3 core tools missing (starship, zoxide, fzf) — run dotfiles-doctor'
    }
}

Describe 'Get-DotStringSha256' {
    It 'matches the known SHA-256 of "abc"' {
        Get-DotStringSha256 'abc' | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
    It 'hashes the empty string to the well-known digest' {
        Get-DotStringSha256 '' | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    }
    It 'is lowercase hex of length 64' {
        Get-DotStringSha256 'dotfiles' | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe 'Get-DotSpinnerFrame' {
    It 'cycles through the unicode frames' {
        Get-DotSpinnerFrame -Tick 0  -Unicode $true | Should -Be '⠋'
        Get-DotSpinnerFrame -Tick 10 -Unicode $true | Should -Be '⠋'   # wraps (10 frames)
    }
    It 'uses an ASCII spinner when not unicode' {
        Get-DotSpinnerFrame -Tick 0 -Unicode $false | Should -Be '|'
        Get-DotSpinnerFrame -Tick 1 -Unicode $false | Should -Be '/'
    }
    It 'handles a negative tick without erroring' {
        { Get-DotSpinnerFrame -Tick -3 -Unicode $true } | Should -Not -Throw
    }
}

Describe 'Format-DotSpinnerLine' {
    It 'shows frame + label with no elapsed suffix under one second' {
        Format-DotSpinnerLine -Label 'working' -ElapsedSeconds 0.4 -Tick 0 -Unicode $false |
            Should -Be '  | working'
    }
    It 'appends whole elapsed seconds once a step has run for >= 1s' {
        Format-DotSpinnerLine -Label 'working' -ElapsedSeconds 1.0  -Tick 0 -Unicode $false | Should -Be '  | working (1s)'
        Format-DotSpinnerLine -Label 'working' -ElapsedSeconds 12.9 -Tick 0 -Unicode $false | Should -Be '  | working (12s)'
    }
    It 'reflects the spinner frame for the given tick' {
        Format-DotSpinnerLine -Label 'x' -ElapsedSeconds 0 -Tick 1 -Unicode $false | Should -Be '  / x'
    }
}

Describe 'Invoke-DotSpinner' {
    It 'runs the script inline and returns its output when not animating (NO_COLOR)' {
        $prev = $env:NO_COLOR
        try { $env:NO_COLOR = '1'; Invoke-DotSpinner -Label 'x' -Script { 21 * 2 } | Should -Be 42 }
        finally { $env:NO_COLOR = $prev }
    }
    It 'passes ArgumentList through inline' {
        $prev = $env:NO_COLOR
        try { $env:NO_COLOR = '1'; Invoke-DotSpinner -Label 'x' -ArgumentList @(3, 4) -Script { param($a, $b) $a + $b } | Should -Be 7 }
        finally { $env:NO_COLOR = $prev }
    }
}

Describe 'Test-DotEmailish' {
    It 'accepts a plausible address'      { Test-DotEmailish 'me@example.com' | Should -BeTrue }
    It 'accepts a sub-domain address'     { Test-DotEmailish 'a.b@mail.corp.io' | Should -BeTrue }
    It 'rejects a bare local part'        { Test-DotEmailish 'me@' | Should -BeFalse }
    It 'rejects a missing domain dot'     { Test-DotEmailish 'me@host' | Should -BeFalse }
    It 'rejects a name with no @'         { Test-DotEmailish 'Jane Doe' | Should -BeFalse }
    It 'rejects whitespace/empty'         { Test-DotEmailish '   ' | Should -BeFalse }
}

Describe 'Write-DotBanner' {
    It 'renders a plain == Title == under NO_COLOR' {
        $prev = $env:NO_COLOR
        try { $env:NO_COLOR = '1'; (Write-DotBanner 'Doctor' 6>&1 | Out-String).Trim() | Should -Be '== Doctor ==' }
        finally { $env:NO_COLOR = $prev }
    }
    It 'includes the subtitle under NO_COLOR' {
        $prev = $env:NO_COLOR
        try { $env:NO_COLOR = '1'; (Write-DotBanner 'A' -Subtitle 'B' 6>&1 | Out-String).Trim() | Should -Be '== A :: B ==' }
        finally { $env:NO_COLOR = $prev }
    }
    It 'keeps the title and subtitle text in the coloured output' {
        # Colour-on wraps the chip in ANSI/SGR, but the title and subtitle text
        # must survive regardless of palette (truecolor vs 16-colour fallback).
        $out = Write-DotBanner 'Doctor' -Subtitle 'preview' 6>&1 | Out-String
        $out | Should -Match 'Doctor'
        $out | Should -Match 'preview'
    }
}

Describe 'Write-DotRule' {
    It 'prefixes the title and draws a rule' {
        (Write-DotRule -Title 'Summary' -Width 5 6>&1 | Out-String) | Should -Match '-- Summary'
    }
    It 'uses ASCII dashes under DOTFILES_ASCII=1' {
        $prev = $env:DOTFILES_ASCII
        try { $env:DOTFILES_ASCII = '1'; (Write-DotRule -Width 4 6>&1 | Out-String).Trim() | Should -Be '----' }
        finally { $env:DOTFILES_ASCII = $prev }
    }
    It 'auto-sizes to the console when no width is given' {
        # No explicit -Width: the rule still leads with the title and fills past it
        # (Width floors at 8), so the line is longer than the bare "-- Summary " prefix.
        $out = (Write-DotRule -Title 'Summary' 6>&1 | Out-String).Trim()
        $out | Should -Match '^-- Summary '
        $out.Length | Should -BeGreaterThan '-- Summary '.Length
    }
}

Describe 'Get-DotConsoleWidth' {
    It 'returns the fallback when no real console is present' {
        # Under the test host there is usually no window; either way it must be a
        # positive int, and the fallback is honoured when the console width is 0.
        Get-DotConsoleWidth -Fallback 80 | Should -BeGreaterThan 0
    }
}

Describe 'Format-DotWrap' {
    It 'returns empty for empty/whitespace text' {
        Format-DotWrap -Text ''     -Width 40 | Should -BeNullOrEmpty
        Format-DotWrap -Text '   '  -Width 40 | Should -BeNullOrEmpty
    }
    It 'keeps a short string on one indented line' {
        # @() guards the single-element-array -> scalar unwrap so [0] indexes the
        # line, not its first character (the consumer wraps with @() for the same reason).
        $r = @(Format-DotWrap -Text 'scoop install fzf' -Width 40 -Indent '  ')
        $r.Count | Should -Be 1
        $r[0] | Should -Be '  scoop install fzf'
    }
    It 'wraps long text onto multiple lines within the width' {
        $r = Format-DotWrap -Text 'the quick brown fox jumps over the lazy dog again and again' -Width 20
        @($r).Count | Should -BeGreaterThan 1
        ($r | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 20
    }
    It 'emits an over-long word whole rather than hard-splitting it' {
        $r = Format-DotWrap -Text 'C:\some\really\long\path\that\exceeds\the\width' -Width 10
        @($r).Count | Should -Be 1
    }
}

Describe 'Read-DotConfirm' {
    # Force the plain Read-Host path so these tests are deterministic even when the
    # dev box has gum installed and an interactive console (Test-DotGum would
    # otherwise route to `gum confirm` and bypass the mocked Read-Host).
    BeforeAll { $script:prevNoGum = $env:DOTFILES_NO_GUM; $env:DOTFILES_NO_GUM = '1' }
    AfterAll  { $env:DOTFILES_NO_GUM = $script:prevNoGum }

    It 'returns true when the user answers yes' {
        Mock Read-Host { 'y' }
        Read-DotConfirm 'go?' | Should -BeTrue
    }
    It 'returns false when the user answers no' {
        Mock Read-Host { 'n' }
        Read-DotConfirm 'go?' | Should -BeFalse
    }
    It 're-asks on an invalid answer, then honours the next valid one' {
        $script:calls = 0
        Mock Read-Host { $script:calls++; if ($script:calls -eq 1) { 'huh' } else { 'n' } }
        Read-DotConfirm 'go?' | Should -BeFalse
        Should -Invoke Read-Host -Times 2
    }
    It 'takes the default when there is no interactive host (Read-Host throws)' {
        Mock Read-Host { throw 'no host' }
        Read-DotConfirm 'go?' -DefaultYes $true | Should -BeTrue
        Read-DotConfirm 'go?' -DefaultYes $false | Should -BeFalse
    }
}

Describe 'Get-DotInputResult' {
    It 'takes the default on a blank or whitespace answer' {
        Get-DotInputResult -Answer ''    | Should -Be 'default'
        Get-DotInputResult -Answer '   ' | Should -Be 'default'
    }
    It 'accepts a non-blank answer when there is no validator' {
        Get-DotInputResult -Answer 'Alice' | Should -Be 'accept'
    }
    It 'accepts when the validator passes and retries when it fails' {
        $v = { param($x) $x -like '*@*' }
        Get-DotInputResult -Answer 'a@b.com' -Validate $v | Should -Be 'accept'
        Get-DotInputResult -Answer 'nope'    -Validate $v | Should -Be 'retry'
    }
    It 'treats a throwing validator as invalid (retry), not a crash' {
        Get-DotInputResult -Answer 'x' -Validate { throw 'boom' } | Should -Be 'retry'
    }
}

Describe 'Read-DotInput' {
    # Force the plain Read-Host path (same reason as Read-DotConfirm above).
    BeforeAll { $script:prevNoGum = $env:DOTFILES_NO_GUM; $env:DOTFILES_NO_GUM = '1' }
    AfterAll  { $env:DOTFILES_NO_GUM = $script:prevNoGum }

    It 'returns the entered value, trimmed' {
        Mock Read-Host { '  Alice  ' }
        Read-DotInput -Prompt 'name' | Should -Be 'Alice'
    }
    It 'returns the default on a blank answer' {
        Mock Read-Host { '' }
        Read-DotInput -Prompt 'name' -Default 'YOUR NAME' | Should -Be 'YOUR NAME'
    }
    It 're-asks on an invalid answer, then honours the next valid one' {
        $script:c = 0
        Mock Read-Host { $script:c++; if ($script:c -eq 1) { 'bad' } else { 'a@b.com' } }
        Read-DotInput -Prompt 'email' -Validate { param($v) Test-DotEmailish $v } | Should -Be 'a@b.com'
        Should -Invoke Read-Host -Times 2
    }
    It 'falls back to the default after exhausting retries on invalid input' {
        Mock Read-Host { 'still-bad' }
        Read-DotInput -Prompt 'email' -Default 'you@example.com' -Validate { param($v) Test-DotEmailish $v } |
            Should -Be 'you@example.com'
        Should -Invoke Read-Host -Times 3
    }
    It 'takes the default when there is no interactive host (Read-Host throws)' {
        Mock Read-Host { throw 'no host' }
        Read-DotInput -Prompt 'name' -Default 'D' | Should -Be 'D'
    }
    It 'returns a secret value untrimmed' {
        Mock Read-Host { 'tok en ' }
        Read-DotInput -Prompt 'token' -Secret | Should -Be 'tok en '
    }
}

Describe 'Get-DotfilesLinkPlan' {
    It 'derives every link from the injected roots' {
        $plan = Get-DotfilesLinkPlan -RepoRoot 'R:\repo' -HomeDir 'H:\me' -LocalAppData 'L:\app' -Documents 'D:\docs'
        $links = $plan.Link
        $links | Should -Contain 'H:\me\.gitconfig'
        $links | Should -Contain 'L:\app\nvim\init.lua'
        $links | Should -Contain 'D:\docs\PowerShell\Microsoft.PowerShell_profile.ps1'
    }
    It 'derives every target from the repo root' {
        $plan = Get-DotfilesLinkPlan -RepoRoot 'R:\repo' -HomeDir 'H:' -LocalAppData 'L:' -Documents 'D:'
        ($plan.Target -join ';') | Should -Match ([regex]::Escape('R:\repo\git\.gitconfig'))
        ($plan.Target -join ';') | Should -Match ([regex]::Escape('R:\repo\windows-terminal\settings.json'))
    }
    It 'covers the full family of configs (parity with the installer)' {
        $links = (Get-DotfilesLinkPlan -RepoRoot 'R:' -HomeDir 'H:' -LocalAppData 'L:' -Documents 'D:').Link -join ';'
        foreach ($needle in 'profile.ps1', 'nvim', '.gitconfig', '.gitignore_global', 'ssh\config',
                            'psmux.conf', 'psmux.reset.conf', 'psmux\scripts', 'settings.json',
                            '.config\mise\config.toml') {
            $links | Should -Match ([regex]::Escape($needle))
        }
    }
    It 'links mise config to the XDG-style path mise reads on Windows' {
        # mise reads ~/.config/mise/config.toml on Windows (NOT %APPDATA%), so the
        # link must land there or the node pin silently never applies.
        $plan = Get-DotfilesLinkPlan -RepoRoot 'R:\repo' -HomeDir 'H:\me' -LocalAppData 'L:' -Documents 'D:'
        $mise = $plan | Where-Object Name -eq 'mise config'
        $mise                  | Should -Not -BeNullOrEmpty
        $mise.Link             | Should -Be 'H:\me\.config\mise\config.toml'
        $mise.Target           | Should -Be 'R:\repo\mise\config.toml'
        $mise.ParentMustExist  | Should -BeFalse
    }
    It 'flags only the Windows Terminal settings variants as ParentMustExist' {
        # WT keeps settings.json in a per-build location (packaged Store, unpackaged/
        # scoop, Preview); each row self-skips unless THAT build's parent exists, so
        # all three — and nothing else — carry ParentMustExist.
        $plan = Get-DotfilesLinkPlan -RepoRoot 'R:' -HomeDir 'H:' -LocalAppData 'L:' -Documents 'D:'
        @($plan | Where-Object ParentMustExist).Name | Should -Be @(
            'Windows Terminal settings'
            'Windows Terminal settings (unpackaged)'
            'Windows Terminal settings (Preview)'
        )
        # every ParentMustExist row is a Windows Terminal settings row (no others crept in)
        foreach ($n in @($plan | Where-Object ParentMustExist).Name) {
            $n | Should -BeLike 'Windows Terminal settings*'
        }
    }
    It 'stubs exactly the four configs that have to survive an ssh session' {
        # A symlink is unreadable from an ssh session (Redirection Guard, inherited by
        # sshd from the Windows service lineage - docs/REMOTE-ACCESS.md), so these four
        # are wired as real files that include the repo copy. If this list grows, the
        # matching arm in Get-DotfilesStubContent must grow with it, or install.ps1
        # falls back to a symlink and the ssh breakage comes straight back.
        $plan = Get-DotfilesLinkPlan -RepoRoot 'R:' -HomeDir 'H:' -LocalAppData 'L:' -Documents 'D:'
        @($plan | Where-Object Kind -eq 'Stub').Name | Should -Be @(
            'PowerShell profile'
            'nvim config'
            '.gitconfig'
            'ssh config'
        )
    }
    It 'gives every other row Kind=Symlink (no row is left without a Kind)' {
        $plan = Get-DotfilesLinkPlan -RepoRoot 'R:' -HomeDir 'H:' -LocalAppData 'L:' -Documents 'D:'
        foreach ($row in $plan) { $row.Kind | Should -BeIn @('Stub', 'Symlink') }
        @($plan | Where-Object Kind -eq 'Symlink').Count | Should -Be ($plan.Count - 4)
    }
    It 'wires nvim as init.lua INSIDE the config dir, not the dir itself' {
        # The reparse point that broke nvim over ssh was on %LOCALAPPDATA%\nvim, the
        # config DIRECTORY. Wiring the file inside it is what makes a stub possible at
        # all: the directory becomes real, and only init.lua points into the repo.
        $plan = Get-DotfilesLinkPlan -RepoRoot 'R:\repo' -HomeDir 'H:' -LocalAppData 'L:\app' -Documents 'D:'
        $nvim = $plan | Where-Object Name -eq 'nvim config'
        $nvim.Kind       | Should -Be 'Stub'
        $nvim.Link       | Should -Be 'L:\app\nvim\init.lua'
        $nvim.Target     | Should -Be 'R:\repo\nvim\init.lua'
        # The old shape, so uninstall can still retire it and install can retire it
        # before writing the stub into what would otherwise be the repo.
        $nvim.LegacyLink | Should -Be 'L:\app\nvim'
    }
    It 'gives LegacyLink only to the row whose shape actually changed' {
        # LegacyLink gates the one destructive move install.ps1 can make to a stub's
        # parent (Clear-StubParent). A row that acquires it by accident would hand that
        # power to a directory nobody intended - $HOME, for ~/.gitconfig.
        $plan = Get-DotfilesLinkPlan -RepoRoot 'R:' -HomeDir 'H:' -LocalAppData 'L:' -Documents 'D:'
        @($plan | Where-Object LegacyLink).Name | Should -Be @('nvim config')
    }
    It 'keeps .gitignore_global a symlink - a gitignore has no include directive' {
        # Deliberate: global ignores survive ssh because the .gitconfig stub overrides
        # core.excludesfile to the repo copy, NOT because this row is stubbed.
        $plan = Get-DotfilesLinkPlan -RepoRoot 'R:' -HomeDir 'H:' -LocalAppData 'L:' -Documents 'D:'
        ($plan | Where-Object Name -eq '.gitignore_global').Kind | Should -Be 'Symlink'
    }
}

Describe 'Get-DotfilesStubContent' {
    It 'returns nothing for a row with no stub form, so the caller symlinks it' {
        Get-DotfilesStubContent -Name 'psmux.conf'   -Target 'R:\repo\psmux\psmux.conf'      | Should -BeNullOrEmpty
        Get-DotfilesStubContent -Name 'jj config'    -Target 'R:\repo\jj\config.toml'        | Should -BeNullOrEmpty
    }
    It 'dot-sources the repo profile rather than linking to it' {
        $c = Get-DotfilesStubContent -Name 'PowerShell profile' -Target 'R:\repo\powershell\profile.ps1'
        $c | Should -Match ([regex]::Escape('R:\repo\powershell\profile.ps1'))
        # dot-source, not '&': the profile defines functions that must land in the
        # caller's scope, exactly as the symlinked profile used to.
        $c | Should -Match ([regex]::Escape('. $dotfilesProfile'))
    }
    It 'writes the git include path with forward slashes' {
        # git treats a backslash in a config value as an escape, so C:\Users would eat
        # the \U and the include would silently never load.
        $c = Get-DotfilesStubContent -Name '.gitconfig' -Target 'C:\repo\git\.gitconfig'
        $c | Should -Match ([regex]::Escape('path = C:/repo/git/.gitconfig'))
        $c | Should -Not -Match ([regex]::Escape('C:\repo'))
    }
    It 'overrides core.excludesfile AFTER the include, or the symlinked one wins' {
        $c = Get-DotfilesStubContent -Name '.gitconfig' -Target 'C:\repo\git\.gitconfig'
        $c | Should -Match ([regex]::Escape('excludesfile = C:/repo/git/.gitignore_global'))
        $c.IndexOf('[core]') | Should -BeGreaterThan $c.IndexOf('[include]') -Because 'last value wins for a single-valued key'
    }
    It 'puts the repo tree on runtimepath and sources the repo init.lua' {
        $c = Get-DotfilesStubContent -Name 'nvim config' -Target 'C:\repo\nvim\init.lua'
        # PREPEND, so require('gerrrt') resolves in the repo and not in the shim dir.
        $c | Should -Match ([regex]::Escape("runtimepath:prepend(config)"))
        $c | Should -Match ([regex]::Escape("local config = 'C:/repo/nvim'"))
        $c | Should -Match ([regex]::Escape("dofile(config .. '/init.lua')"))
    }
    It 'writes the Lua path with forward slashes' {
        # '\U' is an escape in a Lua quoted string, exactly as in a git config value,
        # so C:\Users would be eaten the same way.
        $c = Get-DotfilesStubContent -Name 'nvim config' -Target 'C:\Users\me\repo\nvim\init.lua'
        $c | Should -Match ([regex]::Escape("local config = 'C:/Users/me/repo/nvim'"))
        $c | Should -Not -Match ([regex]::Escape("'C:\Users"))
    }
    It 'appends after/ so a Core sync that adds one is not silently dropped' {
        $c = Get-DotfilesStubContent -Name 'nvim config' -Target 'C:\repo\nvim\init.lua'
        $c | Should -Match ([regex]::Escape("runtimepath:append(config .. '/after')"))
    }
    It 'survives lazy.nvim wiping runtimepath, via an APPENDED searcher' {
        # lazy.setup() replaces 'runtimepath' wholesale from stdpath('config')
        # (performance.rtp.reset, on by default), which is the shim dir - so the
        # prepend alone is gone before an eagerly-loaded spec runs its config.
        # The searcher must be appended with no index: Neovim's vim.loader inserts
        # its cached loaders AT 2 and 3, so a searcher placed there would be shifted
        # around, and package.path is never consulted at all.
        $c = Get-DotfilesStubContent -Name 'nvim config' -Target 'C:\repo\nvim\init.lua'
        $c | Should -Match ([regex]::Escape('package.loaders or package.searchers'))
        $c | Should -Match ([regex]::Escape('table.insert(searchers, function(name)'))
        $c | Should -Not -Match ([regex]::Escape('table.insert(searchers, 2,'))
        # package.path is a dead end here, so it must never be ASSIGNED to. (The shim
        # names it in a comment explaining why - match the assignment, not the word.)
        $c | Should -Not -Match 'package\.path\s*(=|\.\.)'
    }
    It 'restores runtimepath after the config runs, for runtime FILE lookups' {
        # A searcher only answers require(). colors/, ftplugin/, syntax/, treesitter
        # queries and :checkhealth all go through 'runtimepath'.
        $c = Get-DotfilesStubContent -Name 'nvim config' -Target 'C:\repo\nvim\init.lua'
        $prepends = ([regex]::Matches($c, [regex]::Escape('runtimepath:prepend(config)'))).Count
        $prepends | Should -Be 2 -Because 'once before the config runs, once after lazy has reset it'
        $c.LastIndexOf('runtimepath:prepend(config)') | Should -BeGreaterThan $c.IndexOf('dofile(')
    }
    It 'seeds lazy''s lockfile from the repo, since stdpath(config) is now the shim dir' {
        # Core's lazy.lua seeds from stdpath('config')/lazy-lock.json, which under a
        # stub holds no lockfile - a fresh box would resolve every plugin's default
        # branch instead of starting from the fleet's pins.
        $c = Get-DotfilesStubContent -Name 'nvim config' -Target 'C:\repo\nvim\init.lua'
        $c | Should -Match ([regex]::Escape("local seed = config .. '/lazy-lock.json'"))
        $c | Should -Match ([regex]::Escape("vim.fn.stdpath('state')"))
    }
    It 'warns and stops rather than erroring when the repo config is gone' {
        $c = Get-DotfilesStubContent -Name 'nvim config' -Target 'C:\repo\nvim\init.lua'
        $c | Should -Match 're-run install\.ps1'
        # The guard must come BEFORE the dofile, or a missing repo is a stack trace on
        # every startup instead of one warning.
        $c.IndexOf('vim.notify') | Should -BeLessThan $c.IndexOf('dofile(')
    }
    It 'puts ssh Include first - ssh_config is first-obtained-value-wins' {
        $c = Get-DotfilesStubContent -Name 'ssh config' -Target 'C:\repo\ssh\config'
        $c | Should -Match ([regex]::Escape('Include C:\repo\ssh\config'))
        $first = @($c -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s*#' })[0]
        $first | Should -Match '^Include '
    }
}

Describe 'Test-DotStubParentStale' {
    It 'retires a reparse-point parent - the shape that broke nvim over ssh' {
        Test-DotStubParentStale -IsReparsePoint $true | Should -BeTrue
    }
    It 'ignores the entries of a reparse-point parent entirely' {
        # The caller must not enumerate a linked parent (it would list the repo's own
        # children), so a $true here has to stand on its own.
        Test-DotStubParentStale -IsReparsePoint $true -ParentEntries @() -TargetSiblings @() | Should -BeTrue
    }
    It 'retires a real parent holding the target tree - the copy-mode leftover' {
        # Link-Item falls back to a recursive Copy-Item without Developer Mode, so
        # %LOCALAPPDATA%\nvim can be a real directory full of a stale config copy.
        Test-DotStubParentStale -IsReparsePoint $false `
            -ParentEntries @('init.lua', 'lua', 'lazy-lock.json') `
            -TargetSiblings @('lua', 'lazy-lock.json') | Should -BeTrue
    }
    It 'leaves a correctly wired parent alone (the stub is the only occupant)' {
        # TargetSiblings excludes the target's own leaf precisely so this holds -
        # otherwise a healthy stub would look stale to itself and be retired every run.
        Test-DotStubParentStale -IsReparsePoint $false `
            -ParentEntries @('init.lua') -TargetSiblings @('lua', 'lazy-lock.json') | Should -BeFalse
    }
    It 'leaves an unrelated parent alone even when it is full' {
        Test-DotStubParentStale -IsReparsePoint $false `
            -ParentEntries @('Documents', 'Downloads', '.ssh') -TargetSiblings @('lua') | Should -BeFalse
    }
    It 'matches case-insensitively, like NTFS' {
        Test-DotStubParentStale -IsReparsePoint $false `
            -ParentEntries @('LUA') -TargetSiblings @('lua') | Should -BeTrue
    }
    It 'is false with nothing to compare' {
        Test-DotStubParentStale -IsReparsePoint $false | Should -BeFalse
    }
}

Describe 'Test-StubIntoRepo' {
    BeforeAll {
        $script:StubRoot = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Force -Path $script:StubRoot | Out-Null
    }
    It 'is true for a real file that references the repo' {
        $f = Join-Path $TestDrive 'stub.gitconfig'
        "[include]`n`tpath = $($script:StubRoot -replace '\\','/')/git/.gitconfig" | Set-Content -LiteralPath $f
        Test-StubIntoRepo -Link $f -Root $script:StubRoot | Should -BeTrue
    }
    It 'is false for a file of the user''s own that never mentions the repo' {
        $f = Join-Path $TestDrive 'mine.gitconfig'
        "[user]`n`tname = Someone" | Set-Content -LiteralPath $f
        Test-StubIntoRepo -Link $f -Root $script:StubRoot | Should -BeFalse
    }
    It 'is false for a symlink - that is the state we are migrating away from' {
        $target = Join-Path $script:StubRoot 'real.txt'
        'x' | Set-Content -LiteralPath $target
        $link = Join-Path $TestDrive 'as-symlink.txt'
        New-Item -ItemType SymbolicLink -Path $link -Target $target -Force | Out-Null
        Test-StubIntoRepo -Link $link -Root $script:StubRoot | Should -BeFalse
    }
    It 'is false for a missing path, an empty file, and a blank root' {
        Test-StubIntoRepo -Link (Join-Path $TestDrive 'nope.txt') -Root $script:StubRoot | Should -BeFalse
        $empty = Join-Path $TestDrive 'empty.txt'
        Set-Content -LiteralPath $empty -Value ''
        Test-StubIntoRepo -Link $empty -Root $script:StubRoot | Should -BeFalse
        $f = Join-Path $TestDrive 'stub2.txt'
        "path = $script:StubRoot" | Set-Content -LiteralPath $f
        Test-StubIntoRepo -Link $f -Root '' | Should -BeFalse
    }
    It 'matches regardless of slash direction' {
        $f = Join-Path $TestDrive 'slashy.txt'
        "path = $($script:StubRoot -replace '\\','/')/git/.gitconfig" | Set-Content -LiteralPath $f
        Test-StubIntoRepo -Link $f -Root $script:StubRoot | Should -BeTrue
    }
    It 'treats a bracketed path literally, not as a wildcard' {
        # This predicate gates a delete in uninstall.ps1, so a '[' read as a character
        # class would be a false positive on a file that was never ours.
        $odd = Join-Path $TestDrive 'repo[1]'
        New-Item -ItemType Directory -Force -Path $odd | Out-Null
        $f = Join-Path $TestDrive 'odd.txt'
        "path = $odd/git/.gitconfig" | Set-Content -LiteralPath $f
        Test-StubIntoRepo -Link $f -Root $odd | Should -BeTrue
        Test-StubIntoRepo -Link $f -Root (Join-Path $TestDrive 'repo1') | Should -BeFalse
    }
}

Describe 'Write-DotOk' {
    It 'composes a success line with the ok glyph and hint' {
        $out = Write-DotOk -Message 'all set' -Hint 'next: reload' -PassThru 6>$null
        $out | Should -Match '✓ all set'
        $out | Should -Match '→ next: reload'
    }
    It 'omits the hint line when none is given' {
        (Write-DotOk -Message 'done' -PassThru 6>$null) | Should -Be '✓ done'
    }
    It 'uses an ASCII glyph under DOTFILES_ASCII=1' {
        $prev = $env:DOTFILES_ASCII
        try {
            $env:DOTFILES_ASCII = '1'
            (Write-DotOk -Message 'done' -PassThru 6>$null) | Should -Be 'OK done'
        } finally { $env:DOTFILES_ASCII = $prev }
    }
}
