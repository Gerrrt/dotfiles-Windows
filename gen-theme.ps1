# ============================================================================
#  gen-theme.ps1  -  render theme/palette.toml outward into the terminal layer
#
#  THE DEFECT THIS CLOSES. This repo is "themed in Tokyo Night", and until #228
#  that was a convention maintained by hand — hex literals across eight files in
#  five syntaxes, kept in step by COMMENTS that nothing checked. The comment on
#  powershell/core/10-tools.ps1's fzf block claimed it was "kept byte-for-byte in
#  step with Core's zsh fzf.zsh". It was not: border and scrollbar carried #27a1b9
#  against Core's #29a4bd, and gutter #16161e against #1d202f. Three wrong values,
#  a green CI, and a comment asserting the opposite.
#
#  This is the PowerShell/psmux counterpart of dotfiles-core's scripts/gen-theme.sh,
#  reading the SAME theme/palette.toml (vendored here by theme-sync.ps1). Core owns
#  the numbers; this renders them into the surfaces Core does not know about.
#
#  HOW. There are TWO KINDS of target, because one of them cannot carry a comment.
#
#  Kind 'markers' — the common case. A consumer opts a region in with a marker pair
#  naming a block id, in its own comment syntax, which is `#` for every such target
#  here (PowerShell and psmux.conf both):
#
#      # core:theme:gen fzf-colors
#      ...rendered from theme/palette.toml...
#      # core:theme:end fzf-colors
#
#  Anything OUTSIDE the markers is hand-authored and never touched. Leading
#  indentation on the opening marker is captured and re-applied to every emitted
#  line, which is what lets a block sit inside an @( ) array or an @{ } hashtable.
#
#  Kind 'json-scheme' — windows-terminal/settings.json, added in #230. It carries
#  the repo's largest remaining hand-typed colour block (20 hexes) and CANNOT use a
#  marker pair, for three independent reasons:
#
#    * The file is APP-OWNED AND LIVE. Get-DotfilesLinkPlan symlinks it into all
#      three Windows Terminal flavours' LocalState, so the app rewrites THIS COPY
#      whenever a setting changes in its UI — and its JSON writer strips comments.
#      A `// core:theme:gen` marker would not survive the first toggle.
#    * JSON has no comment syntax at all, and tests/Invoke-Validation.ps1 parses
#      every *.json with ConvertFrom-Json, so a marker would fail the fast gate.
#    * tests/Format-AppJson.ps1 deliberately does NOT re-indent this file, because
#      the app re-serializes it with its own indent on every launch.
#
#  So that kind locates the scheme object BY ITS "name" (Windows Terminal sorts
#  schemes alphabetically, so an array index is not stable) and rewrites the colour
#  VALUES on the lines they already occupy — preserving indentation, key order and
#  trailing commas byte for byte. Deliberately NOT ConvertFrom-Json | ConvertTo-Json:
#  that reformats all 227 lines on every run, which is exactly the churn the
#  no-re-indent carve-out exists to prevent. It also emits UPPERCASE hex, because
#  that is what the app writes — lowercase would make every GUI round-trip a diff.
#
#  Unlike Core's bash version, NO HOISTING IS NEEDED. Core had to lift its fzf
#  palette out of a single-quoted string because a `#` line inside one is an fzf
#  argument, not a comment. Here the same palette is an ARRAY OF STRINGS joined at
#  the end, and a `#` line between elements is a genuine PowerShell comment.
#
#    .\gen-theme.ps1              # rewrite every marked block from theme/palette.toml
#    .\gen-theme.ps1 -Check       # exit 1 (with a diff) if any block is stale - THE GATE
#    .\gen-theme.ps1 -List        # id<TAB>file for every block (coverage, without grep)
#    .\gen-theme.ps1 -Root <dir>  # run against a fixture tree (the test suite uses this)
#
#  THE RESIDUAL SCAN. -Check does one thing Core's does not: after verifying the
#  marked blocks, it asserts that every OTHER hex literal in a registered file is
#  still a value the palette defines. psmux.conf carries seven hexes outside its
#  @tn_* table (pane borders, status style, the @vpn_fg/@pwr_fg seeds) that psmux
#  cannot express as #{@tn_*} lookups, and wrapping each in its own marker pair
#  would be more noise than gate. The scan is what would have caught #16161e and
#  #27a1b9 without carving up the file, and it is what catches those seven the day
#  Core flips `style`.
#
#  Exit: 0 = clean; 1 = drift; 2 = usage, or the generator cannot run. That is the
#  convention tests/Assert-NvimParity.ps1 and tests/Assert-StarshipParity.ps1 already
#  use. Severity is STICKY, 2 > 1 > 0: a structural failure in one target followed by
#  mere drift in another must never report as drift.
# ============================================================================
[CmdletBinding()]
param(
    # Report instead of writing: exit 1 and print a diff if any block is stale.
    # This is what CI runs on every PR.
    [switch]$Check,
    # Print `id<TAB>file` for every registered block and exit.
    [switch]$List,
    # Run against a different tree. Without it the drift DIRECTION is untestable
    # except by mutating tracked files - and the drift direction is the whole point
    # of the gate. Same reason Assert-NvimParity.ps1 and Core's gen-theme.sh --root
    # take one.
    [string]$Root
)

# ── palette parsing ──────────────────────────────────────────────────────────

# --- Get-DotPalette -----------------------------------------------------------
# Parse Core's deliberately-flat palette.toml into a hashtable. No TOML library, by
# design: Core keeps the file flat precisely so a consumer can read it with one
# anchored regex on a bare box, and a gate that skips itself for a missing dependency
# is the "green because absent" failure this whole change exists to close.
#
# The comment-strip is the load-bearing part. A naive `-replace '#.*'` would EAT THE
# VALUE - every colour in this file starts with `#`. So: take a quoted value verbatim
# up to its closing quote, and only strip a trailing comment from a BARE (integer) one.
function Get-DotPalette {
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line)
    $pal = @{}
    foreach ($l in $Line) {
        if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]*)"') { $pal[$Matches[1]] = $Matches[2]; continue }
        if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^#\s]+)')  { $pal[$Matches[1]] = $Matches[2].Trim() }
    }
    return $pal
}

# --- Test-DotPalette ----------------------------------------------------------
# Validate the parsed table the same way Core's _pal_require does, and return the
# complaints as strings rather than writing them - so the unit tests can assert on
# the verdict without capturing a stream. An empty array means valid.
#
# The keys checked are the ones the emitters below actually dereference. A palette
# missing one of these is a STRUCTURAL failure (exit 2), not drift: there is nothing
# to compare against, so reporting "in sync" would be a lie.
function Test-DotPalette {
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Palette)
    $required = @(
        'color_bg', 'color_bg_dark', 'color_bg_highlight', 'color_bg_visual', 'color_black'
        'color_blue', 'color_blue1', 'color_border_highlight', 'color_comment', 'color_cyan'
        'color_dark3', 'color_fg', 'color_fg_dark', 'color_green', 'color_magenta'
        'color_magenta2', 'color_orange', 'color_red', 'color_terminal_black', 'color_yellow'
        'role_accent', 'role_muted', 'role_ok', 'role_err', 'role_rule'
        'fallback_accent_sgr', 'fallback_muted_sgr', 'fallback_accent_spec', 'fallback_muted_spec'
    )
    $errs = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $required) {
        $v = $Palette[$k]
        if ([string]::IsNullOrWhiteSpace($v)) { $errs.Add("missing key: $k"); continue }
        switch -Regex ($k) {
            '^color_'    { if ($v -cnotmatch '^#[0-9a-f]{6}$') { $errs.Add("$k is not a 6-digit lowercase hex: $v") } }
            '^fallback_' { if ($v -notmatch '^[0-9]{1,3}$')   { $errs.Add("$k is not a 256-colour index: $v") } }
            '^role_'     { if (-not $Palette["color_$v"])     { $errs.Add("$k names an undefined colour: $v") } }
        }
    }
    return $errs.ToArray()
}

# Accessors mirroring Core's pal / pal_role / pal_raw, so an emitter below reads the
# same way its bash twin does.
function Get-PalColor { param([hashtable]$P, [string]$Name) $P["color_$Name"] }
function Get-PalRole  { param([hashtable]$P, [string]$Name) $P["color_$($P["role_$Name"])"] }
function Get-PalRaw   { param([hashtable]$P, [string]$Name) $P[$Name] }

# --- ConvertTo-DotRgb ---------------------------------------------------------
# '#7aa2f7' -> '122;162;247', for the 24-bit SGR sequences in 10-tools.ps1,
# 05-lib.ps1 and psmux-cheat.ps1. Core's _rgb, in PowerShell.
function ConvertTo-DotRgb {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Hex)
    $h = $Hex.TrimStart('#')
    '{0};{1};{2}' -f [Convert]::ToInt32($h.Substring(0, 2), 16),
                     [Convert]::ToInt32($h.Substring(2, 2), 16),
                     [Convert]::ToInt32($h.Substring(4, 2), 16)
}

# ── the registry ─────────────────────────────────────────────────────────────
# One row per block: the single declaration of what exists. -List prints it, the
# preflight checks it both ways against the tree, and the residual scan uses its
# Files column as the set of files it is allowed to police.
#
# A FILE THAT IS ABSENT IS SKIPPED, NOT A FAILURE - that is what lets the test suite
# drive this against a hermetic fixture holding one file per SHAPE rather than a copy
# of the whole repo. In the real tree every file is present, so the "was this block
# deleted?" check below still has full force there.
#
# Kind names which walker reads the row (see the header): 'markers' is a comment-marker
# pair, 'json-scheme' is the structural JSON rewrite keyed on the scheme's own "name".
# It is spelled out on every row rather than defaulted, so the registry stays what its
# comment claims - the single declaration of what exists - now that the rows differ.
$script:ThemeBlocks = @(
    @{ Id = 'fzf-colors';            Kind = 'markers'; File = 'powershell/core/10-tools.ps1' }
    @{ Id = 'psreadline-prediction'; Kind = 'markers'; File = 'powershell/core/10-tools.ps1' }
    @{ Id = 'cmd-separator-colors';  Kind = 'markers'; File = 'powershell/core/10-tools.ps1' }
    @{ Id = 'ansi-sgr-palette';      Kind = 'markers'; File = 'powershell/core/05-lib.ps1' }
    @{ Id = 'accent-tiers';          Kind = 'markers'; File = 'powershell/core/05-lib.ps1' }
    @{ Id = 'psmux-palette';         Kind = 'markers'; File = 'psmux/psmux.conf' }
    @{ Id = 'netinfo-palette';       Kind = 'markers'; File = 'psmux/scripts/psmux-netinfo.ps1' }
    @{ Id = 'power-palette';         Kind = 'markers'; File = 'psmux/scripts/psmux-power.ps1' }
    @{ Id = 'cheat-sgr';             Kind = 'markers'; File = 'psmux/scripts/psmux-cheat.ps1' }
    @{ Id = 'terminal-scheme';       Kind = 'json-scheme'; File = 'windows-terminal/settings.json'
       Scheme = 'Tokyo Night' }
)

# ── emitters: one scriptblock per block id ───────────────────────────────────
# NOT a generic renderer over a spec table. The forms differ in quoting, in `=`
# alignment, in PowerShell escape syntax, in one fzf line carrying a `:regular`
# attribute, and in decimal-SGR derivation - a spec language expressive enough for
# all of that is harder to review than the string formatting it would replace. Each
# emitter is a literal picture of its target block, so a reviewer diffs the two side
# by side.
#
# Each returns the block's inner lines WITHOUT the marker's own indentation; the
# writer re-applies that. Relative indentation (an if/else body) is the emitter's job.
$script:ThemeEmitters = @{

    # powershell/core/10-tools.ps1 - the explicit fzf palette.
    #
    # ONE --color PER LINE, matching Core's zsh/35-fzf.zsh line for line. The previous
    # hand-maintained form packed three per line, which is exactly what let three wrong
    # values hide in plain sight: nobody diffs a packed line against an upstream file.
    #
    # `--color=query:<fg>:regular` IS LOAD-BEARING FOR A CROSS-REPO GATE. Core's
    # scripts/parity-check.sh greps `--color=query:` in this file and compares the hex
    # by value against theme/palette.toml. Dropping `:regular`, or splitting the token
    # across lines, breaks that needle even with an identical palette.
    'fzf-colors' = {
        param([hashtable]$p)
        @(
            "'--color=border:$(Get-PalColor $p border_highlight)'"
            "'--color=fg:$(Get-PalColor $p fg)'"
            "'--color=gutter:$(Get-PalColor $p black)'"
            "'--color=header:$(Get-PalColor $p orange)'"
            "'--color=hl:$(Get-PalColor $p blue1)'"
            "'--color=hl+:$(Get-PalColor $p blue1)'"
            "'--color=info:$(Get-PalColor $p dark3)'"
            "'--color=marker:$(Get-PalColor $p magenta2)'"
            "'--color=pointer:$(Get-PalColor $p magenta2)'"
            "'--color=prompt:$(Get-PalColor $p blue1)'"
            "'--color=query:$(Get-PalColor $p fg):regular'"
            "'--color=scrollbar:$(Get-PalColor $p border_highlight)'"
            "'--color=separator:$(Get-PalColor $p orange)'"
            "'--color=spinner:$(Get-PalColor $p magenta2)'"
        )
    }

    # powershell/core/10-tools.ps1 - the PSReadLine prediction UI: a muted inline
    # ghost, an accent list row, and a selection bar on the visual-selection surface.
    # 24-bit SGR because Windows Terminal advertises truecolor; the literal
    # `$([char]27)` is emitted verbatim (single-quoted here so it is not expanded).
    'psreadline-prediction' = {
        param([hashtable]$p)
        $esc = '$([char]27)'
        @(
            'InlinePrediction       = "{0}[38;2;{1}m"' -f $esc, (ConvertTo-DotRgb (Get-PalRole $p muted))
            'ListPrediction         = "{0}[38;2;{1}m"' -f $esc, (ConvertTo-DotRgb (Get-PalRole $p accent))
            'ListPredictionSelected = "{0}[48;2;{1}m"' -f $esc, (ConvertTo-DotRgb (Get-PalColor $p bg_visual))
        )
    }

    # powershell/core/10-tools.ps1 - the command-block separator rule, coloured by
    # exit status. The twin of Core's emit_sep_rule_colors for zsh/00-tools.zsh.
    #
    # The PROSE above this block names the palette roles, not the hexes it used to
    # quote. That is deliberate: a comment repeating a hex is a copy the generator
    # cannot reach, and it drifts silently the first time the palette moves.
    'cmd-separator-colors' = {
        param([hashtable]$p)
        $esc  = '$([char]27)'
        $err  = ConvertTo-DotRgb (Get-PalRole $p err)
        $rule = ConvertTo-DotRgb (Get-PalRole $p rule)
        @(
            '$col  = if ($fail) { "' + $esc + '[38;2;' + $err + 'm" } else { "' + $esc + '[38;2;' + $rule + 'm" }'
        )
    }

    # powershell/core/05-lib.ps1 - Get-DotAnsiSgr's decimal palette, keyed by the
    # ConsoleColor names the renderers already pass. One key per line: a style flip
    # changes the digit COUNT, so any column-aligned layout would churn its whitespace
    # on every palette change and bury the value diff.
    'ansi-sgr-palette' = {
        param([hashtable]$p)
        $map = [ordered]@{
            Red        = 'red';        Green   = 'green';   Yellow = 'yellow'
            Blue       = 'blue';       Magenta = 'magenta'; Cyan   = 'cyan'
            Gray       = 'fg_dark';    White   = 'fg';      Black  = 'black'
            DarkGray   = 'comment';    DarkYellow = 'orange'
        }
        foreach ($k in $map.Keys) {
            "{0,-10} = '{1}'" -f $k, (ConvertTo-DotRgb (Get-PalColor $p $map[$k]))
        }
    }

    # powershell/core/05-lib.ps1 - the pwsh twin of Core's _CORE_ACCENT_SPEC /
    # _CORE_MUTED_SPEC (zsh/05-ui.zsh). Before #228 this repo had NO equivalent at
    # all: `grep -rn 'CORE_ACCENT|AccentSpec' powershell/` returned nothing, which is
    # why PARITY.md's accent half was a genuine gap rather than a drift.
    #
    # Two forms per tier, because colour is rendered two ways: raw SGR escapes and a
    # bare spec a prompt/config consumes. The 256-colour fallbacks are HAND-PICKED in
    # theme/palette.toml and are NOT derivable from the hex - and the two forms
    # deliberately disagree (SGR 111/103 vs spec 75/244). Carry both; never compute one
    # from the other.
    'accent-tiers' = {
        param([hashtable]$p)
        $esc = '$([char]27)'
        @(
            'if ($ColorTerm -in @(''24bit'', ''truecolor'')) {'
            ('    return [pscustomobject]@{{ Accent = "{0}[1;38;2;{1}m"; Muted = "{0}[38;2;{2}m"; AccentSpec = ''{3}''; MutedSpec = ''{4}''; TrueColor = $true }}' -f
                $esc, (ConvertTo-DotRgb (Get-PalRole $p accent)), (ConvertTo-DotRgb (Get-PalRole $p muted)),
                (Get-PalRole $p accent), (Get-PalRole $p muted))
            '}'
            ('return [pscustomobject]@{{ Accent = "{0}[1;38;5;{1}m"; Muted = "{0}[38;5;{2}m"; AccentSpec = {3}; MutedSpec = {4}; TrueColor = $false }}' -f
                $esc, (Get-PalRaw $p fallback_accent_sgr), (Get-PalRaw $p fallback_muted_sgr),
                (Get-PalRaw $p fallback_accent_spec), (Get-PalRaw $p fallback_muted_spec))
        )
    }

    # psmux/psmux.conf - user options the status-bar rules then read as #{@tn_bg}.
    # psmux.conf already had this indirection; only the values were hand-copied. The
    # field widths match Core's emit_tmux_palette exactly, so the two files' palette
    # tables diff cleanly against each other.
    'psmux-palette' = {
        param([hashtable]$p)
        $map = [ordered]@{
            '@tn_bg' = 'bg'; '@tn_bg_dark' = 'bg_dark'; '@tn_bg_hl' = 'bg_highlight'
            '@tn_fg' = 'fg'; '@tn_fg_dim' = 'fg_dark'; '@tn_blue' = 'blue'
            '@tn_cyan' = 'cyan'; '@tn_green' = 'green'; '@tn_magenta' = 'magenta'
            '@tn_red' = 'red'; '@tn_yellow' = 'yellow'; '@tn_orange' = 'orange'
            '@tn_comment' = 'comment'; '@tn_black' = 'terminal_black'
        }
        foreach ($k in $map.Keys) { 'set -g {0,-11} "{1}"' -f $k, (Get-PalColor $p $map[$k]) }
    }

    # psmux/scripts/psmux-netinfo.ps1 - the network pill's own colours. LITERAL HEX IS
    # REQUIRED here, not a stylistic choice: psmux does not expand #{@tn_*} inside a
    # #[...] style, so the pill cannot reference the table above. That is precisely the
    # case a generator is for.
    'netinfo-palette' = {
        param([hashtable]$p)
        @(
            "`$BGHL   = '$(Get-PalColor $p bg_highlight)'"
            "`$BG     = '$(Get-PalColor $p bg)'"
            "`$ORANGE = '$(Get-PalColor $p orange)'"
            "`$GREEN  = '$(Get-PalColor $p green)'"
        )
    }

    # psmux/scripts/psmux-power.ps1 - the battery pill's three thresholds. Same
    # literal-hex constraint as netinfo. tests/Repo.Tests.ps1 asserts these values
    # INDEPENDENTLY and is deliberately NOT generated: if the test read the same
    # palette the script does, it would assert only that the generator is
    # self-consistent, which is not a property worth a test.
    'power-palette' = {
        param([hashtable]$p)
        @(
            "`$GREEN  = '$(Get-PalRole $p ok)'   # ≥60%, and the no-battery AC placeholder"
            "`$YELLOW = '$(Get-PalColor $p yellow)'   # ≥20%"
            "`$RED    = '$(Get-PalRole $p err)'   # <20%"
        )
    }

    # psmux/scripts/psmux-cheat.ps1 - the group/description colours of the cheat-sheet
    # picker, as 24-bit SGR rather than hex. The twin of Core's emit_cheat_sgr.
    'cheat-sgr' = {
        param([hashtable]$p)
        @(
            ('$gc  = "$e[38;2;{0}m"{1}# blue'    -f (ConvertTo-DotRgb (Get-PalRole $p accent)), '   ')
            ('$dim = "$e[38;2;{0}m"{1}# comment' -f (ConvertTo-DotRgb (Get-PalRole $p muted)),  '     ')
        )
    }
}

# ── emitters: the 'json-scheme' kind ─────────────────────────────────────────
# A DIFFERENT CONTRACT from the table above, and deliberately so. A marker emitter
# returns LINES, because it owns its target's syntax. A json-scheme emitter returns a
# KEY -> HEX map and owns nothing else: the quoting, the four-space indent, the key
# order and the trailing commas are Windows Terminal's, and Set-DotJsonSchemeColor
# below re-emits them verbatim rather than re-deriving them. An emitter that returned
# lines here would have to reproduce the app's serializer, and would be wrong the day
# the app changes it.
#
# This is still a literal picture of its target, not the declarative colour DSL the
# section above argues against - the same [ordered] key map psmux-palette and
# ansi-sgr-palette already use.
$script:ThemeJsonEmitters = @{

    # windows-terminal/settings.json - the "Tokyo Night" scheme's 20 colours.
    #
    # UPPERCASE IS LOAD-BEARING, not a style choice. The app writes uppercase hex, and
    # it owns this file (see the header): emitting lowercase would mean every launch
    # rewrote all 20 values back, turning a settings toggle into a 20-line colour diff -
    # precisely the churn tests/Format-AppJson.ps1's no-re-indent rule exists to avoid.
    # theme/palette.toml stays lowercase; Test-DotPalette enforces that. Upcase HERE.
    #
    # `background` and `selectionBackground` were #1A1B26 and #28344A before #230 -
    # tokyonight NIGHT values, in a palette pinned to storm. #229 hit the same two hexes
    # twice more (ListPredictionSelected, Get-DotAnsiSgr's Black) and adopted Core's
    # value each time; these were the last two left. The terminal's selection now agrees
    # with PSReadLine's prediction bar, and its canvas with psmux's @tn_bg.
    #
    # `name` is deliberately absent from the map, so the writer never touches it - it is
    # also the key the region lookup matches on.
    'terminal-scheme' = {
        param([hashtable]$p)
        $map = [ordered]@{
            background   = 'bg';      black       = 'terminal_black'
            blue         = 'blue';    brightBlack = 'terminal_black'
            brightBlue   = 'blue';    brightCyan  = 'cyan'
            brightGreen  = 'green';   brightPurple = 'magenta'
            brightRed    = 'red';     brightWhite = 'fg'
            brightYellow = 'yellow';  cursorColor = 'fg'
            cyan         = 'cyan';    foreground  = 'fg_dark'
            green        = 'green';   purple      = 'magenta'
            red          = 'red';     selectionBackground = 'bg_visual'
            white        = 'fg';      yellow      = 'yellow'
        }
        $out = [ordered]@{}
        foreach ($k in $map.Keys) { $out[$k] = (Get-PalColor $p $map[$k]).ToUpperInvariant() }
        $out
    }
}

# ── the line walker ──────────────────────────────────────────────────────────

# --- Get-DotThemeRegion -------------------------------------------------------
# Locate a marker pair by id and return { Start; End; Indent; Body } as 0-based line
# indices of the MARKERS themselves (Body is what sits between them). $null when the
# opening marker is absent - which the caller treats as "this block was deleted",
# distinct from "the file is missing".
#
# Throws on an unterminated region rather than guessing: silently rewriting to the end
# of the file would destroy hand-authored code below.
function Get-DotThemeRegion {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line, [Parameter(Mandatory)][string]$Id)
    $open = -1; $indent = ''
    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Line[$i] -match "^(\s*)#\s*core:theme:gen\s+$([regex]::Escape($Id))\s*$") {
            $open = $i; $indent = $Matches[1]; break
        }
    }
    if ($open -lt 0) { return $null }
    for ($j = $open + 1; $j -lt $Line.Count; $j++) {
        if ($Line[$j] -match "^\s*#\s*core:theme:end\s+$([regex]::Escape($Id))\s*$") {
            return [pscustomobject]@{
                Start  = $open
                End    = $j
                Indent = $indent
                Body   = @(if ($j -gt $open + 1) { $Line[($open + 1)..($j - 1)] })
            }
        }
    }
    throw "unterminated 'core:theme:gen $Id' region"
}

# --- Get-DotThemeDrift --------------------------------------------------------
# Pure verdict: does the block's current body already equal what the emitter would
# render? Compared line by line after trimming trailing whitespace, so a stray
# end-of-line space is not reported as a colour change. Unit-tested without any IO.
function Get-DotThemeDrift {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Expected
    )
    $a = @($Actual  | ForEach-Object { $_.TrimEnd() })
    $e = @($Expected | ForEach-Object { $_.TrimEnd() })
    [pscustomobject]@{
        Actual   = $a
        Expected = $e
        InSync   = (($a -join "`n") -eq ($e -join "`n"))
    }
}

# ── the JSON walker ──────────────────────────────────────────────────────────
# The 'json-scheme' counterpart of the three functions above: locate a region, decide
# the drift, rewrite the values. Same purity discipline - no IO, verdicts returned
# rather than written - so the test suite can drive them without a fixture tree.

# --- Get-DotJsonStructural ----------------------------------------------------
# Blank out every quoted string so the bracket/brace walk below counts NESTING only.
# Load-bearing: this file's profile guids are "{574e775e-4f2a-...}" and its wsl profile
# carries "--distribution-id {4d88cd54-...}". Counting those as nesting would end a
# region in the wrong place, and the failure would be a silently mis-targeted rewrite
# rather than an error. Escapes are honoured so a \" inside a value cannot re-open one.
function Get-DotJsonStructural {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [regex]::Replace($Text, '"(\\.|[^"\\])*"', '""')
}

# --- Get-DotJsonSchemeRegion --------------------------------------------------
# Locate a colour scheme by its own "name" and return { Start; End } as 0-based line
# indices of its opening { and closing }. $null when no scheme carries that name.
#
# KEYED ON THE NAME, NOT AN INDEX, because Windows Terminal re-sorts the schemes array
# alphabetically on every rewrite - a position that is right today is a different scheme
# the moment someone adds one.
#
# SCOPED TO THE schemes ARRAY, which is the other half of the same point: every entry in
# profiles.list has a "name" too, so an unscoped search for "name": "Tokyo Night" would
# happily rewrite a PROFILE that happened to share the scheme's name.
#
# Throws on an unterminated array rather than guessing, exactly as Get-DotThemeRegion
# does: the alternative is truncating the rest of the document.
function Get-DotJsonSchemeRegion {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line,
        [Parameter(Mandatory)][string]$Scheme
    )
    $key = -1
    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Line[$i] -match '^\s*"schemes"\s*:') { $key = $i; break }
    }
    if ($key -lt 0) { return $null }

    # The app writes the '[' on the line AFTER the key; tolerate it on the same line.
    $depth = 0; $arrStart = -1; $arrEnd = -1
    for ($i = $key; $i -le $Line.Count - 1; $i++) {
        $s = Get-DotJsonStructural $Line[$i]
        if ($i -eq $key) { $s = $s.Substring($s.IndexOf(':') + 1) }
        foreach ($c in $s.ToCharArray()) {
            if ($c -eq '[') { if ($arrStart -lt 0) { $arrStart = $i }; $depth++ }
            elseif ($c -eq ']') { $depth--; if ($arrStart -ge 0 -and $depth -le 0) { $arrEnd = $i; break } }
        }
        if ($arrEnd -ge 0) { break }
    }
    if ($arrStart -lt 0 -or $arrEnd -lt 0) { throw 'unterminated "schemes" array' }

    # Objects at depth 1 inside it. Brace-counted rather than "the next }", so a nested
    # object inside a scheme could not end the region early.
    $nameRe = '^\s*"name"\s*:\s*"' + [regex]::Escape($Scheme) + '"\s*,?\s*$'
    $bd = 0; $objStart = -1; $isMatch = $false
    for ($i = $arrStart; $i -le $arrEnd; $i++) {
        $s = Get-DotJsonStructural $Line[$i]
        if ($i -eq $arrStart) { $s = $s.Substring($s.IndexOf('[') + 1) }
        if ($bd -ge 1 -and $Line[$i] -match $nameRe) { $isMatch = $true }
        foreach ($c in $s.ToCharArray()) {
            if ($c -eq '{') {
                if ($bd -eq 0) { $objStart = $i; $isMatch = ($Line[$i] -match $nameRe) }
                $bd++
            } elseif ($c -eq '}') {
                $bd--
                if ($bd -le 0) {
                    if ($isMatch -and $objStart -ge 0) { return [pscustomobject]@{ Start = $objStart; End = $i } }
                    $bd = 0; $objStart = -1; $isMatch = $false
                }
            }
        }
    }
    return $null
}

# --- Set-DotJsonSchemeColor ---------------------------------------------------
# Rewrite the colour VALUES inside [Start..End] from $Color (key -> hex), and report
# what moved. Returns { Lines; Changed; Missing }; in sync means both Changed and
# Missing are empty. Pure - $Line is not mutated.
#
# LINE-SCOPED, NOT A RESERIALIZE. Groups 1/3/5 - the indentation, the ": " and the
# trailing comma - are re-emitted verbatim, so the only bytes that move are the six
# hex digits. ConvertFrom-Json | ConvertTo-Json would reformat all 227 lines on every
# run (the app's writer puts '[' on its own line and indents four; ConvertTo-Json does
# neither), which is the churn tests/Format-AppJson.ps1's no-re-indent rule exists to
# prevent. It would also drop the file's key order, which is the app's, not ours.
#
# The comparison is -ceq, CASE-SENSITIVE on purpose: the app writes uppercase and the
# palette is lowercase, so "already correct but lowercase" is drift we want to fix once
# rather than let the app fix on every launch.
#
# A key present in $Color but absent from the object is reported in Missing, never
# inserted. Guessing where it belongs means guessing the app's sort order; the caller
# treats it as structural instead.
function Set-DotJsonSchemeColor {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line,
        [Parameter(Mandatory)][int]$Start,
        [Parameter(Mandatory)][int]$End,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Color
    )
    $out = [string[]]::new($Line.Count)
    if ($Line.Count) { [Array]::Copy($Line, $out, $Line.Count) }
    $changed = [System.Collections.Generic.List[pscustomobject]]::new()
    $seen = @{}
    for ($i = $Start; $i -le $End -and $i -lt $Line.Count; $i++) {
        if ($Line[$i] -match '^(\s*)"([A-Za-z0-9_]+)"(\s*:\s*)"(#[0-9a-fA-F]{6})"(\s*,?\s*)$') {
            $indent = $Matches[1]; $k = $Matches[2]; $sep = $Matches[3]
            $have = $Matches[4]; $tail = $Matches[5]
            if (-not $Color.Contains($k)) { continue }
            $seen[$k] = $true
            $want = [string]$Color[$k]
            if ($have -ceq $want) { continue }
            $changed.Add([pscustomobject]@{ Key = $k; Actual = $have; Expected = $want })
            $out[$i] = '{0}"{1}"{2}"{3}"{4}' -f $indent, $k, $sep, $want, $tail
        }
    }
    $missing = @(foreach ($k in $Color.Keys) { if (-not $seen[$k]) { $k } })
    return [pscustomobject]@{ Lines = $out; Changed = $changed.ToArray(); Missing = $missing }
}

# --- Get-DotResidualHex -------------------------------------------------------
# Every hex literal in $Line that the palette does not define. The blocks above are
# generated and therefore always correct; this is what polices the hexes AROUND them
# - psmux.conf's pane-border/status styles, the @vpn_fg and @pwr_fg seeds, and any
# hex a future edit drops into a registered file.
#
# This is the check that would have caught #16161e and #27a1b9 years earlier, and it
# costs one regex rather than seven more marker pairs.
function Get-DotResidualHex {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line,
        [Parameter(Mandatory)][hashtable]$Palette
    )
    $known = @{}
    foreach ($k in $Palette.Keys) { if ($k -like 'color_*') { $known[$Palette[$k].ToLowerInvariant()] = $true } }
    $bad = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Line.Count; $i++) {
        foreach ($m in [regex]::Matches($Line[$i], '#[0-9a-fA-F]{6}\b')) {
            if (-not $known[$m.Value.ToLowerInvariant()]) { $bad.Add("$($i + 1): $($m.Value)") }
        }
    }
    return $bad.ToArray()
}

# --- Read/Write-DotThemeFile --------------------------------------------------
# Round-trip a target preserving its BYTES, not just its text. Two properties matter
# and neither is the default:
#
#   * BOM. powershell/core/05-lib.ps1 is UTF-8 WITH a BOM and psmux/psmux.conf is
#     without. Set-Content would impose one policy on both and show up as a whole-file
#     binary diff that hides the four lines that actually changed.
#   * LF. .gitattributes pins the working tree to LF on every OS and the validator
#     enforces it; Set-Content writes CRLF on Windows. Write the bytes we mean, the
#     same reason theme-sync.ps1 carries Write-CoreRefFile.
function Read-DotThemeFile {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    [pscustomobject]@{
        Lines   = [string[]]($text -split "`r?`n")
        Bom     = $bom
        Newline = $(if ($text -match "`r`n") { "`r`n" } else { "`n" })
    }
}
function Write-DotThemeFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][pscustomobject]$File, [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, ($Lines -join $File.Newline), [System.Text.UTF8Encoding]::new($File.Bom))
}

# Library-only hook: let the test suite import the pure helpers without generating.
if ($env:DOTFILES_GENTHEME_LIBONLY -eq '1') { return }

# ── main ─────────────────────────────────────────────────────────────────────
$RepoRoot = if ($Root) { (Resolve-Path -LiteralPath $Root).Path } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ($List) {
    foreach ($b in $script:ThemeBlocks) { "$($b.Id)`t$($b.File)" }
    exit 0
}

$palettePath = Join-Path $RepoRoot 'theme/palette.toml'
if (-not (Test-Path -LiteralPath $palettePath)) {
    Write-Error "gen-theme: no theme/palette.toml under $RepoRoot - run theme-sync.ps1 first."
    exit 2
}
$palette = Get-DotPalette -Line (Get-Content -LiteralPath $palettePath)
$palErrs = Test-DotPalette -Palette $palette
if ($palErrs.Count) {
    foreach ($e in $palErrs) { Write-Host "gen-theme: theme/palette.toml: $e" -ForegroundColor Red }
    exit 2
}

# Sticky severity, 2 > 1 > 0 (see the header).
$rc = 0
function Set-Rc { param([int]$Level) if ($Level -gt $script:rc) { $script:rc = $Level } }

$style = if ($palette['style']) { $palette['style'] } else { 'unknown' }
Write-Host "gen-theme: theme/palette.toml (style=$style)" -ForegroundColor Cyan

# Group by file so each target is read and written exactly once, even though
# 10-tools.ps1 and 05-lib.ps1 each carry more than one block.
foreach ($group in ($script:ThemeBlocks | Group-Object File)) {
    $rel  = $group.Name
    $path = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $path)) {
        # Absent is SKIPPED, not a failure - see the registry note.
        Write-Host "  skip $rel (absent)" -ForegroundColor DarkGray
        continue
    }
    $file  = Read-DotThemeFile -Path $path
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange($file.Lines)
    $touched = $false

    foreach ($block in $group.Group) {
        # ---- kind 'json-scheme' ------------------------------------------------
        # Same shape as the marker arm below - locate, diff, rewrite - but over a JSON
        # object found by name rather than a comment-delimited line range. It reuses the
        # file already read above and the same $touched flag, so a target of either kind
        # is still read and written exactly once.
        if ($block.Kind -eq 'json-scheme') {
            $emit = $script:ThemeJsonEmitters[$block.Id]
            if (-not $emit) { Write-Host "  gen-theme: no JSON emitter for block id '$($block.Id)'" -ForegroundColor Red; Set-Rc 2; continue }
            try { $region = Get-DotJsonSchemeRegion -Line $lines.ToArray() -Scheme $block.Scheme }
            catch { Write-Host "  $rel : $($_.Exception.Message)" -ForegroundColor Red; Set-Rc 2; continue }
            if (-not $region) {
                # The scheme was renamed or deleted - the JSON twin of "the marker pair is
                # gone from a file that still exists".
                Write-Host "  $rel : no colour scheme named '$($block.Scheme)'" -ForegroundColor Red
                Set-Rc 2; continue
            }
            $patch = Set-DotJsonSchemeColor -Line $lines.ToArray() -Start $region.Start -End $region.End -Color (& $emit $palette)
            if ($patch.Missing.Count) {
                # STRUCTURAL, not drift: a key the generator owns is not there to compare
                # against, and inserting it would mean guessing the app's sort order.
                Write-Host "  $rel : scheme '$($block.Scheme)' has no $($patch.Missing -join ', ') key" -ForegroundColor Red
                Set-Rc 2; continue
            }
            if (-not $patch.Changed.Count) { continue }

            if ($Check) {
                # Per CHANGED KEY, not the whole 20-line object: one moved hex should
                # print one pair, or the diff buries the value it is reporting.
                Write-Host "  DRIFT $rel [$($block.Id)]" -ForegroundColor Red
                foreach ($c in $patch.Changed) {
                    Write-Host "    - `"$($c.Key)`": `"$($c.Actual)`""   -ForegroundColor DarkRed
                    Write-Host "    + `"$($c.Key)`": `"$($c.Expected)`"" -ForegroundColor DarkGreen
                }
                Set-Rc 1
            } else {
                $lines.Clear(); $lines.AddRange([string[]]$patch.Lines)
                Write-Host "  wrote $rel [$($block.Id)]" -ForegroundColor Green
                $touched = $true
            }
            continue
        }

        # ---- kind 'markers' ----------------------------------------------------
        $emit = $script:ThemeEmitters[$block.Id]
        if (-not $emit) { Write-Host "  gen-theme: no emitter for block id '$($block.Id)'" -ForegroundColor Red; Set-Rc 2; continue }
        try { $region = Get-DotThemeRegion -Line $lines.ToArray() -Id $block.Id }
        catch { Write-Host "  $rel : $($_.Exception.Message)" -ForegroundColor Red; Set-Rc 2; continue }
        if (-not $region) {
            # The marker pair was removed from a file that still exists - exactly how a
            # consumer would silently stop being covered.
            Write-Host "  $rel : block '$($block.Id)' has no 'core:theme:gen' marker" -ForegroundColor Red
            Set-Rc 2; continue
        }

        $rendered = @(& $emit $palette | ForEach-Object { if ([string]::IsNullOrEmpty($_)) { '' } else { "$($region.Indent)$_" } })
        $drift    = Get-DotThemeDrift -Actual $region.Body -Expected $rendered
        if ($drift.InSync) { continue }

        if ($Check) {
            Write-Host "  DRIFT $rel [$($block.Id)]" -ForegroundColor Red
            foreach ($l in $drift.Actual)   { Write-Host "    - $l" -ForegroundColor DarkRed }
            foreach ($l in $drift.Expected) { Write-Host "    + $l" -ForegroundColor DarkGreen }
            Set-Rc 1
        } else {
            $lines.RemoveRange($region.Start + 1, $region.End - $region.Start - 1)
            $lines.InsertRange($region.Start + 1, [string[]]$rendered)
            Write-Host "  wrote $rel [$($block.Id)]" -ForegroundColor Green
            $touched = $true
        }
    }

    if ($touched) { Write-DotThemeFile -Path $path -File $file -Lines $lines.ToArray() }

    # The residual scan runs over the file as it now stands - after generation in write
    # mode, as-committed in -Check mode - so it only ever complains about hand-authored
    # hexes the generator does not own.
    $residual = Get-DotResidualHex -Line $lines.ToArray() -Palette $palette
    if ($residual.Count) {
        Write-Host "  UNKNOWN HEX in $rel - not a value theme/palette.toml defines:" -ForegroundColor Red
        foreach ($r in $residual) { Write-Host "    $r" -ForegroundColor Yellow }
        Set-Rc 1
    }
}

if ($Check) {
    if ($rc -eq 0) { Write-Host 'gen-theme: OK - every block matches theme/palette.toml.' -ForegroundColor Green }
    elseif ($rc -eq 1) {
        Write-Host ''
        Write-Host 'gen-theme: DRIFT. Run: pwsh -NoProfile -File ./gen-theme.ps1' -ForegroundColor Red
        Write-Host '  (do not hand-edit a generated block - the next run will overwrite it)' -ForegroundColor DarkGray
        Write-Host "  (picking a colour in Windows Terminal's Settings pane counts as a hand-edit:" -ForegroundColor DarkGray
        Write-Host '   change it in Core, then theme-sync.ps1 and gen-theme.ps1)' -ForegroundColor DarkGray
    }
} elseif ($rc -eq 0) {
    Write-Host 'gen-theme: done. Review `git diff`, then commit.' -ForegroundColor Green
}
exit $rc
