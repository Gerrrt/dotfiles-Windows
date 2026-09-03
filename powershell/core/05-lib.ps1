# ============================================================================
#  core/05-lib.ps1  -  pure, side-effect-free helpers shared across the layers.
#
#  Loads right after 00-aliases (so Test-Cmd exists) and before everything that
#  uses these helpers. NOTHING here shells out, registers a hook, or prints on
#  load — which is also what lets the test suite dot-source this one file in
#  isolation and assert on the functions (see tests/Lib.Tests.ps1).
#
#  Scope note (B7): these are declared as plain `function Name`, not
#  `function global:Name`. The Dotfiles module (powershell/Dotfiles) dot-sources
#  this file and re-exports the curated surface, so the helpers reach the session
#  through the module instead of each one force-installing itself into global
#  scope. Dot-sourcing this file DIRECTLY (the test suite, install.ps1,
#  uninstall.ps1, Install-Packages.ps1) still lands the functions in the caller's
#  scope exactly as before — dot-sourcing is scope-agnostic — so those consumers
#  are unchanged.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: Test-SensitiveHistoryLine, Get-DotConfirmAnswer, Test-DotGum, Read-DotConfirm, Get-DotStringSha256, Get-DotSpinnerFrame, Invoke-DotSpinner, Test-DotEmailish, Get-DotToolNudge, Test-DotNonInteractiveArg, Test-InteractiveShell, Test-InMux, Get-DotfilesLinkPlan, Get-DotfilesRetiredLinkPlan, Get-DotfilesEnvPlan, Get-DotfilesStubContent, Get-DotfilesForwarderContent, Test-StubIntoRepo, Test-StubDirIntoRepo, Test-DotStubParentStale, Test-DotColor, Test-DotUnicode, Get-DotGlyph, Write-DotHost, Write-DotBanner, Get-DotConsoleWidth, Format-DotWrap, Write-DotRule, Write-DotErr, Write-DotOk, Write-DotWarn
# requires: (none)

# --- Test-SensitiveHistoryLine ------------------------------------------------
# Decide whether a command line is sensitive enough to keep OUT of the saved
# PSReadLine history file (it stays usable in-session; it just isn't persisted).
# The PSReadLine analog of Core's HISTORY_IGNORE.
#
# The earlier inline regex matched bare substrings, so it quietly dropped the
# everyday `pwd` command (and anything containing "pass"/"creds"/...), meaning
# common navigation never made it into history. This version is word-boundaried
# and context-aware: secret-bearing KEYWORDS only as whole words, secret-carrying
# FLAGS only when dash-prefixed, and the 1Password live-read verbs as phrases.
# `pwd`, `compass`, "first pass", etc. are no longer false positives.
function Test-SensitiveHistoryLine {
    [OutputType([bool])]
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }

    # 1Password CLI commands that surface live secrets into the terminal.
    if ($Line -match '(?i)\bop\s+(read|item|get|inject|run)\b') { return $true }

    # Secret-bearing keywords. Boundaries are LETTER-only lookarounds, not \b, so
    # digits/underscores/spaces count as separators: this matches GH_TOKEN and
    # OPENAI_API_KEY and "private key", but NOT "compass" or "first pass". Note the
    # deliberate absence of bare `pwd`/`pass` — those are matched as flags below,
    # never as the standalone `pwd` command or the word "pass".
    if ($Line -match '(?i)(?<![a-z])(passwd|password|secret|token|bearer|credentials?|authorization|oauth|jwt|api[\s_-]?key|access[\s_-]?key|secret[\s_-]?key|client[\s_-]?secret|private[\s_-]?key)(?![a-z])') { return $true }

    # Secret-carrying command-line flags: --password / -pwd / --token / -secret …
    # Requires a leading dash so the bare `pwd` command can never match.
    if ($Line -match '(?i)(^|\s)-{1,2}(password|passwd|pwd|pass|token|secret|apikey)\b') { return $true }

    return $false
}

# --- Get-DotConfirmAnswer / Read-DotConfirm -----------------------------------
# A yes/no prompt that doesn't take garbage for an answer. Get-DotConfirmAnswer is
# the PURE classifier (unit-tested): it maps a raw string to 'yes' | 'no' |
# 'invalid', honouring the default for an empty answer. Read-DotConfirm wraps it
# in a Read-Host loop that re-asks on 'invalid' (instead of silently treating a
# typo'd "yse" as no) and degrades to the default on a non-interactive host.
function Get-DotConfirmAnswer {
    [OutputType([string])]
    param([string]$Answer, [bool]$DefaultYes = $true)
    $a = "$Answer".Trim().ToLowerInvariant()
    if ($a -eq '') { return $(if ($DefaultYes) { 'yes' } else { 'no' }) }
    if ($a -in 'y', 'yes') { return 'yes' }
    if ($a -in 'n', 'no')  { return 'no' }
    return 'invalid'
}

# --- Test-DotGum --------------------------------------------------------------
# Should we hand an interactive prompt to gum (charmbracelet/gum) instead of a
# raw Read-Host? gum is in packages/scoopfile.json, so the host has it — this lets
# the few interactive moments (the install overwrite/identity prompts) use gum's
# styled, key-driven widgets while every non-gum path stays exactly as tested.
# True ONLY when ALL of these hold, so scripted/CI/redirected/NO_COLOR runs never
# get an unexpected TUI:
#   • DOTFILES_NO_GUM is unset (the escape hatch — set it to 1 to force plain
#     Read-Host prompts; parity with FAST_START / DOTFILES_CARAPACE),
#   • gum is on PATH,
#   • colour is allowed (NO_COLOR/TERM=dumb opt out), and
#   • stdin is a real interactive console (not redirected / piped / a test host).
# The four inputs are injectable params (env/host defaults read at call time), the
# same pattern as Test-DotColor/Test-DotUnicode, so the decision is unit-tested in
# every branch (tests/Lib.Tests.ps1) without needing gum or a TTY present.
function Test-DotGum {
    [OutputType([bool])]
    param(
        [string]$NoGum       = $env:DOTFILES_NO_GUM,
        # -CommandType Application: gum must be a real executable on PATH. Without
        # it, a user-defined function/alias named `gum` (this repo encourages such
        # wrappers) would flip this true and route prompts into a non-existent TUI.
        [bool]  $HasGum      = [bool](Get-Command gum -CommandType Application -ErrorAction SilentlyContinue),
        [bool]  $Color       = (Test-DotColor),
        [bool]  $Interactive = $(try { -not [Console]::IsInputRedirected } catch { $false })
    )
    if ($NoGum -eq '1') { return $false }
    if (-not $HasGum)      { return $false }
    if (-not $Color)       { return $false }
    if (-not $Interactive) { return $false }
    return $true
}

function Read-DotConfirm {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Prompt, [bool]$DefaultYes = $true)

    # gum confirm: a styled y/n with arrow/enter selection. Exit 0 = affirmative,
    # 1 = negative, anything else (e.g. 130 on Ctrl-C) = treat as "no" — the safe
    # answer for the destructive prompts this guards. Only taken on a genuine
    # interactive console (Test-DotGum); otherwise the Read-Host loop below runs,
    # unchanged, so the mocked-Read-Host tests and non-interactive default still hold.
    if (Test-DotGum) {
        & gum confirm $Prompt --default="$($DefaultYes.ToString().ToLowerInvariant())" 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    for ($i = 0; $i -lt 3; $i++) {
        try { $ans = Read-Host "$Prompt $suffix" }
        catch { return $DefaultYes }   # no interactive host: take the default
        switch (Get-DotConfirmAnswer $ans $DefaultYes) {
            'yes'   { return $true }
            'no'    { return $false }
            default { Write-DotHost '  please answer y or n.' -Color DarkYellow }
        }
    }
    return $DefaultYes   # exhausted retries: fall back to the default
}

# --- Get-DotInputResult / Read-DotInput ---------------------------------------
# The text-prompt sibling of Read-DotConfirm: ONE validated free-text prompt with
# a default, optional validator, and secret masking — so every Read-Host in the
# tree shares the same gum/validation/default behaviour instead of each rolling
# its own loop (only the git-email prompt was ever validated). Get-DotInputResult
# is the pure decision (blank => take default; non-blank => validate), unit-tested;
# Read-DotInput does the I/O (gum input when Test-DotGum, else Read-Host).
function Get-DotInputResult {
    [OutputType([string])]   # 'accept' | 'default' | 'retry'
    param([AllowEmptyString()][string]$Answer, [scriptblock]$Validate)
    if ([string]::IsNullOrWhiteSpace($Answer)) { return 'default' }   # blank keeps the default
    if ($Validate) {
        # A validator that THROWS is treated as "invalid" (retry), never allowed to
        # blow up the prompt loop — the caller still gets to re-ask / fall back.
        $ok = $false
        try { $ok = [bool](& $Validate $Answer.Trim()) } catch { $ok = $false }
        if (-not $ok) { return 'retry' }
    }
    return 'accept'
}

function Read-DotInput {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [AllowEmptyString()][string]$Default = '',
        # Shown to the user as the default hint; defaults to $Default. Lets a caller
        # display 'blank to fill in later' while still returning a real fallback.
        [string]$DefaultHint,
        # Optional validator: receives the trimmed answer, returns $true if OK.
        [scriptblock]$Validate,
        [string]$ValidationMessage = '  invalid — please try again.',
        # Mask the typed value (gum input --password / Read-Host -MaskInput) for
        # secrets (tokens/passwords); the answer is returned untrimmed.
        [switch]$Secret,
        [int]$MaxTries = 3
    )
    $hint = if ($PSBoundParameters.ContainsKey('DefaultHint')) { $DefaultHint } else { $Default }

    for ($i = 0; $i -lt $MaxTries; $i++) {
        # Read one raw answer. gum input on a real interactive console (Test-DotGum),
        # otherwise Read-Host — same gate as Read-DotConfirm, so scripted/CI/NO_COLOR
        # runs and the mocked-Read-Host tests stay on the plain path.
        if (Test-DotGum) {
            $gumArgs = @('input', '--prompt', "$Prompt ")
            if ($Secret) { $gumArgs += '--password' }
            if ($hint)   { $gumArgs += @('--placeholder', $hint) }
            $ans = (& gum @gumArgs 2>$null)
            if ($LASTEXITCODE -ne 0) { return $Default }   # ESC / Ctrl-C => default
        } else {
            $suffix = if ($hint) { " [$hint]" } else { '' }
            try {
                $ans = if ($Secret) { Read-Host "$Prompt$suffix" -MaskInput } else { Read-Host "$Prompt$suffix" }
            } catch { return $Default }   # no interactive host: take the default
        }

        switch (Get-DotInputResult -Answer $ans -Validate $Validate) {
            'accept'  { return $(if ($Secret) { $ans } else { $ans.Trim() }) }
            'default' { return $Default }
            'retry'   { Write-DotHost $ValidationMessage -Color DarkYellow }
        }
    }
    return $Default   # exhausted retries: fall back to the default
}

# --- Get-DotStringSha256 ------------------------------------------------------
# Lowercase hex SHA-256 of a string, used to integrity-check a downloaded
# bootstrap script against a pinned hash before executing it. Pure, unit-tested.
function Get-DotStringSha256 {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

# --- Get-DotSpinnerFrame / Invoke-DotSpinner ----------------------------------
# A non-blocking progress indicator for steps that are SILENT and slow (a cold
# `winget export`, Save-Module downloads) — without it they look frozen between
# the step header and the result. Get-DotSpinnerFrame is the pure frame picker
# (Braille under Unicode, ASCII spinner otherwise), unit-tested. Invoke-DotSpinner
# runs the work in a background job and animates one in-place line until it
# finishes, returning the job's output. It deliberately does NOT wrap chatty tools
# (scoop/winget app installs) that print their own progress and want the console.
function Get-DotSpinnerFrame {
    [OutputType([string])]
    param([int]$Tick, [bool]$Unicode = (Test-DotUnicode))
    $frames = if ($Unicode) { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' } else { '|', '/', '-', '\' }
    $i = [Math]::Abs($Tick) % $frames.Count
    return $frames[$i]
}

# The full in-place spinner line: "  <frame> <label> (<n>s)". The elapsed-seconds
# suffix appears only once a step has run for a full second, so quick ops don't
# flash "(0s)" — but a long silent op now visibly counts up, so "slow" reads
# differently from "stalled" (U13). Pure (frame + label + elapsed -> string), so
# the formatting and the threshold are unit-tested without animating anything.
function Format-DotSpinnerLine {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [double]$ElapsedSeconds = 0,
        [int]$Tick = 0,
        [bool]$Unicode = (Test-DotUnicode)
    )
    $suffix = if ($ElapsedSeconds -ge 1) { ' ({0:n0}s)' -f [Math]::Floor($ElapsedSeconds) } else { '' }
    return ('  {0} {1}{2}' -f (Get-DotSpinnerFrame -Tick $Tick -Unicode $Unicode), $Label, $suffix)
}

function Invoke-DotSpinner {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$ArgumentList = @()
    )
    # No animation unless stdout is an interactive, colour-capable console: under
    # NO_COLOR/TERM=dumb, redirected output, or CI, run the work INLINE so logs stay
    # clean and a transcript never captures spinner spam. Same result either way.
    $animate = Test-DotColor
    try { if ([Console]::IsOutputRedirected) { $animate = $false } } catch { }
    if (-not $animate) { return (& $Script @ArgumentList) }

    # Prefer Start-ThreadJob (the ThreadJob module ships with pwsh 7): it runs the
    # work on a THREAD in this process instead of spawning a whole child pwsh, so a
    # wrapped step costs a thread, not a process — the same cheaper path the startup
    # update-check (15-update.ps1) already takes. Fall back to Start-Job on any host
    # without it. (B3: don't pay a process spawn for every spinner.)
    $start = if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) { 'Start-ThreadJob' } else { 'Start-Job' }
    $job = & $start -ScriptBlock $Script -ArgumentList $ArgumentList
    $out = $null
    $maxLen = 0   # widest line printed, so the final wipe clears a grown "(12s)" tail
    try {
        $t = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($job.State -eq 'Running') {
            $line = Format-DotSpinnerLine -Label $Label -ElapsedSeconds $sw.Elapsed.TotalSeconds -Tick $t
            if ($line.Length -gt $maxLen) { $maxLen = $line.Length }
            Write-Host ("`r{0}" -f $line) -NoNewline -ForegroundColor Cyan
            Start-Sleep -Milliseconds 120
            $t++
        }
        # Wait-Job before Receive-Job closes a race: a ThreadJob can finish between
        # poll ticks (or before the loop sees 'Running' at all), and reading output
        # off a not-yet-flushed job would drop it. Wait is a no-op once it's done.
        $job | Wait-Job | Out-Null
        $out = Receive-Job $job -ErrorAction SilentlyContinue
    } finally {
        # Runs on normal completion AND on Ctrl-C. Wipe the spinner line, then ALWAYS
        # tear the job down — Stop-Job first so an interrupt can't leave a background
        # thread/process running the half-finished work (U7: clean SIGINT teardown).
        Write-Host ("`r{0}`r" -f (' ' * ([Math]::Max($maxLen, $Label.Length + 6)))) -NoNewline   # wipe the spinner line
        if ($job) {
            try { Stop-Job $job -ErrorAction SilentlyContinue } catch { }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
    return $out
}

# --- Test-DotEmailish ---------------------------------------------------------
# A deliberately loose "does this look like an email?" check for the install-time
# git-identity prompt — enough to catch a fat-fingered "me@" or a name typed into
# the email field, without pretending to be RFC 5322. Pure, so it's unit-tested.
function Test-DotEmailish {
    [OutputType([bool])]
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email)) { return $false }
    return ($Email -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

# --- Get-DotToolNudge ---------------------------------------------------------
# Compose the one-line "core tools missing" startup nudge from a list of missing
# tool names ('' when nothing is missing). Pure — the Test-Cmd probing lives in
# the fragment that calls this (core/57-health-nudge.ps1) — so it's unit-tested.
function Get-DotToolNudge {
    [OutputType([string])]
    param([string[]]$Missing)
    $m = @($Missing | Where-Object { $_ })
    if (-not $m.Count) { return '' }
    $s = if ($m.Count -ne 1) { 's' } else { '' }
    return ("{0} core tool{1} missing ({2}) — run dotfiles-doctor" -f $m.Count, $s, ($m -join ', '))
}

# --- Test-DotNonInteractiveArg / Test-InteractiveShell ------------------------
# Should a profile that's being loaded auto-run INTERACTIVE-ONLY work — the psmux
# auto-attach (os/30-windows.ps1) and the daily background update probe
# (core/15-update.ps1)? The profile is ALSO dot-sourced for `pwsh -Command ...` /
# `pwsh -File ...` (VS Code tasks, git hooks, scheduled scripts) unless they pass
# -NoProfile, and dropping a multiplexer or firing a scoop/winget network check
# there is wrong. Split so the ARGUMENT classification is pure + unit-tested; the
# ambient wrapper just feeds it the live host and process args.
#
# PowerShell accepts any unambiguous PREFIX of a parameter name, so match by
# prefix, not exact spelling. We must NOT treat -NoExit/-NoLogo/-NoProfile as
# non-interactive (all begin 'no' and DO appear on interactive launches — e.g.
# Windows Terminal's `pwsh.exe -NoLogo`), so -NonInteractive only counts once the
# token is long enough to be unambiguous ('noni'+).
function Test-DotNonInteractiveArg {
    [OutputType([bool])]
    param([string[]]$ArgList)
    $nonInteractive = @('command', 'file', 'encodedcommand', 'noninteractive')
    foreach ($a in $ArgList) {
        if ($a -notmatch '^-') { continue }
        $name = $a.TrimStart('-').ToLowerInvariant()
        if (-not $name) { continue }
        foreach ($flag in $nonInteractive) {
            if ($flag.StartsWith($name)) {
                if ($flag -eq 'noninteractive' -and $name.Length -lt 4) { continue }
                return $true
            }
        }
    }
    return $false
}

# Ambient wrapper: a real interactive shell is the ConsoleHost launched without any
# non-interactive flag. ISE / the VS Code editor host / remoting are not ConsoleHost,
# so they're excluded up front. Reads $Host + the process command line — the only two
# ambient bits — and defers the actual decision to the pure helper above.
function Test-InteractiveShell {
    [OutputType([bool])]
    param()
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    return -not (Test-DotNonInteractiveArg ([Environment]::GetCommandLineArgs()))
}

# --- Test-InMux ---------------------------------------------------------------
# Are we running inside a psmux/tmux pane (i.e. the status bar is showing)? psmux
# exports TMUX + PSMUX_SESSION into pane shells (verified against psmux src/pane.rs);
# either marker means "in a pane". THE single source of truth for pane detection —
# shared by the psmux auto-attach guard (os/30-windows.ps1, so it never nests a
# session inside an existing pane) and the pill's auto-arm/status (os/33-psmux-pill.ps1),
# which previously each hand-maintained their own marker list and had already drifted.
function Test-InMux {
    [OutputType([bool])]
    param()
    [bool]($env:TMUX -or $env:PSMUX_SESSION)
}

# --- Get-DotfilesLinkPlan -----------------------------------------------------
# THE single source of truth for every symlink this repo wires: one ordered list
# that install.ps1 creates, uninstall.ps1 removes, and dotfiles-doctor verifies.
# Before this existed the set was hand-maintained in three places, so adding a
# link meant editing all three or silently drifting (uninstall would orphan it,
# doctor would never check it). Pure: every path is derived from injected roots,
# so it's unit-tested and the consumers can't disagree about what "the links" are.
#
# Uses [IO.Path]::Combine (a pure string join), NOT Join-Path: Join-Path resolves
# the drive PROVIDER and throws DriveNotFoundException for a path on a drive that
# doesn't exist on this host — which is exactly what the tests inject (H:, L:, D:).
#
# ParentMustExist flags a link whose parent we must NOT create on demand: a
# Windows Terminal settings dir only exists when THAT build of WT is installed, so
# install.ps1 skips the row rather than materializing an empty tree. WT ships in
# three flavors that each keep settings.json in a different place — the packaged
# Store/winget build (Packages\...WindowsTerminal_8wekyb3d8bbwe\LocalState), the
# unpackaged/scoop build (%LOCALAPPDATA%\Microsoft\Windows Terminal), and the
# Preview package — so all three are planned. Each row links only when ITS build's
# settings dir already exists, so a box links whichever flavor(s) it has (usually
# one, but stable + Preview can coexist) and the rest self-skip.
#
# Kind ('Symlink' | 'Stub') decides HOW a row is wired, and exists because a
# symlink is unreadable from an ssh session on a host running OpenSSH Server.
# sshd inherits Redirection Guard from the Windows service lineage, and that
# mitigation refuses to traverse any reparse point whose target sits under a
# non-admin-owned directory — i.e. this repo. The failure is
# ERROR_UNTRUSTED_MOUNT_POINT, surfaced as "untrusted mount point"; it is
# INHERITED and NON-RELAXABLE (IFEO REDIRECTION_TRUST_ALWAYS_OFF is ignored), so
# it cannot be configured away — see docs/REMOTE-ACCESS.md.
#
# So the configs that matter most over ssh are wired as REAL FILES that point into
# the repo using the config format's own include mechanism. Same single source of
# truth, no reparse point. Everything else stays a symlink: either it has no include
# mechanism (.gitignore_global), or it is only ever used interactively (Windows
# Terminal, GlazeWM, Zebar).
#
# nvim is the row where "the config" is a DIRECTORY, so its reparse point sits on
# the PARENT of the wired path: %LOCALAPPDATA%\nvim was a directory symlink into
# nvim/, and under enforcement the editor could not read its own init.lua — it
# started bare, with netrw and no colorscheme. The stub form wires the FILE
# (%LOCALAPPDATA%\nvim\init.lua) inside a real directory, and that file prepends the
# repo tree to 'runtimepath' and dofile()s it. Do NOT reach for the alternative of
# pointing XDG_CONFIG_HOME at the repo: nvim would honour it, but so would every
# other tool that reads ~/.config.
function Get-DotfilesLinkPlan {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$HomeDir        = $HOME,
        [string]$LocalAppData   = $env:LOCALAPPDATA,
        [string]$RoamingAppData = $env:APPDATA,
        [string]$Documents      = [Environment]::GetFolderPath('MyDocuments')
    )
    $join = { param($a, $b) [System.IO.Path]::Combine($a, $b) }
    if (-not $Documents)      { $Documents      = & $join $HomeDir 'Documents' }
    if (-not $LocalAppData)   { $LocalAppData   = & $join $HomeDir 'AppData\Local' }
    if (-not $RoamingAppData) { $RoamingAppData = & $join $HomeDir 'AppData\Roaming' }
    $repo = { param($p) & $join $RepoRoot $p }
    # LegacyLink: a path an EARLIER shape of this row wired, which uninstall must
    # still recognise as ours. Without it, a row that changes shape orphans whatever
    # the previous install left on disk — the plan no longer names it, so nothing
    # ever cleans it up. For nvim it is also the stub's parent directory, so uninstall
    # uses it for both jobs: retire the old directory symlink, and drop the real
    # directory afterwards if the stub was the only thing in it.
    $row  = {
        param($Name, $Target, $Link, $ParentMustExist = $false, $Kind = 'Symlink', $LegacyLink = $null)
        [pscustomobject]@{ Name = $Name; Target = $Target; Link = $Link; ParentMustExist = $ParentMustExist; Kind = $Kind; LegacyLink = $LegacyLink }
    }
    @(
        # Kind = 'Stub' rows are wired as a REAL FILE that points into the repo via the
        # config format's own include mechanism, NOT as a symlink. See the Kind note in
        # this function's header and Get-DotfilesStubContent below for the why.
        & $row 'PowerShell profile'        (& $repo 'powershell\profile.ps1')        (& $join $Documents    'PowerShell\Microsoft.PowerShell_profile.ps1') $false 'Stub'
        # The wired path is init.lua INSIDE a real %LOCALAPPDATA%\nvim, not the
        # directory itself — see the nvim note in this function's header.
        & $row 'nvim config'               (& $repo 'nvim\init.lua')                 (& $join $LocalAppData 'nvim\init.lua') $false 'Stub' (& $join $LocalAppData 'nvim')
        & $row '.gitconfig'                (& $repo 'git\.gitconfig')                (& $join $HomeDir      '.gitconfig') $false 'Stub'
        # Stays a symlink on purpose: a .gitignore file has no include directive, so
        # there is nothing to stub. The .gitconfig stub instead overrides
        # core.excludesfile to point straight at the repo copy, which is what makes
        # global ignores work over ssh — this row only serves interactive sessions.
        & $row '.gitignore_global'         (& $repo 'git\.gitignore_global')         (& $join $HomeDir      '.gitignore_global')
        # jj and mise are NOT wired here any more — see Get-DotfilesEnvPlan. Both are
        # TOML, which has no include directive, so neither can be stubbed and a symlink
        # is unreadable over ssh (measured: `jj config get ui.default-command` answered
        # "Value not found", and `mise config ls` listed nothing). They are pointed at
        # the repo with JJ_CONFIG / MISE_GLOBAL_CONFIG_FILE instead. The old link paths
        # ride along as LegacyLink so uninstall can still retire what a previous
        # install left behind.
        & $row 'ssh config'                (& $repo 'ssh\config')                    (& $join $HomeDir      '.ssh\config') $false 'Stub'
        # psmux's config format is tmux-compatible, so `source-file` IS its include
        # mechanism — the repo's own psmux.conf already uses it to pull in the reset
        # file. Both are stubbed; the reset stub is what that existing source-file line
        # then resolves to, so the chain needs no change to the config itself.
        & $row 'psmux.conf'                (& $repo 'psmux\psmux.conf')              (& $join $HomeDir      '.config\psmux\psmux.conf') $false 'Stub'
        & $row 'psmux.reset.conf'          (& $repo 'psmux\psmux.reset.conf')        (& $join $HomeDir      '.config\psmux\psmux.reset.conf') $false 'Stub'
        # A DIRECTORY of pwsh popup helpers, and a directory has no include directive
        # either. StubDir is the answer: a real directory of one-line forwarders, one
        # per script, each invoking the repo copy. That leaves psmux.conf's eight bind
        # lines untouched — they keep pointing at ~/.config/psmux/scripts, which is now
        # real. See Write-StubDirItem in install.ps1.
        & $row 'psmux scripts'             (& $repo 'psmux\scripts')                 (& $join $HomeDir      '.config\psmux\scripts') $false 'StubDir'
        & $row 'Windows Terminal settings'             (& $repo 'windows-terminal\settings.json') (& $join $LocalAppData 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') $true
        & $row 'Windows Terminal settings (unpackaged)' (& $repo 'windows-terminal\settings.json') (& $join $LocalAppData 'Microsoft\Windows Terminal\settings.json') $true
        & $row 'Windows Terminal settings (Preview)'    (& $repo 'windows-terminal\settings.json') (& $join $LocalAppData 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json') $true
        # Opt-in desktop layer (GlazeWM + Zebar). The ~/.glzr parents are created on
        # demand, so these are plain rows (no ParentMustExist) — linking a config for
        # an as-yet-uninstalled app is harmless, exactly like the nvim row above.
        & $row 'GlazeWM config'            (& $repo 'desktop\glazewm\config.yaml')   (& $join $HomeDir      '.glzr\glazewm\config.yaml')
        & $row 'Zebar vanilla-clear'       (& $repo 'desktop\zebar\vanilla-clear')   (& $join $HomeDir      '.glzr\zebar\vanilla-clear')
    )
}

# --- Get-DotfilesRetiredLinkPlan ----------------------------------------------
# Paths this repo USED to wire and no longer does. Not part of the link plan — there
# is nothing to create here — but install and uninstall both have to know about them,
# or a box that was set up before the change is left with a symlink nothing owns,
# sitting at the conventional path, that the tool no longer even reads.
#
# jj and mise moved to JJ_CONFIG / MISE_GLOBAL_CONFIG_FILE (Get-DotfilesEnvPlan). A
# leftover link is inert rather than harmful — the env var wins outright — but it is
# exactly the kind of stale artifact that sends someone debugging the wrong file.
# Target is carried so callers can identify OUR link exactly (Test-SymlinkCurrent)
# rather than by a loose path match. A link left over from a checkout at a different
# path is deliberately not recognised: better to leave a stranger's file alone than to
# delete something on a guess.
function Get-DotfilesRetiredLinkPlan {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$HomeDir        = $HOME,
        [string]$RoamingAppData = $env:APPDATA
    )
    $join = { param($a, $b) [System.IO.Path]::Combine($a, $b) }
    if (-not $RoamingAppData) { $RoamingAppData = & $join $HomeDir 'AppData\Roaming' }
    @(
        [pscustomobject]@{
            Name   = 'jj config'
            Target = (& $join $RepoRoot 'jj\config.toml')
            Link   = (& $join $RoamingAppData 'jj\config.toml')
            Reason = 'JJ_CONFIG'
        }
        [pscustomobject]@{
            Name   = 'mise config'
            Target = (& $join $RepoRoot 'mise\config.toml')
            Link   = (& $join $HomeDir '.config\mise\config.toml')
            Reason = 'MISE_GLOBAL_CONFIG_FILE'
        }
    )
}

# --- Get-DotfilesEnvPlan ------------------------------------------------------
# The persistent User-scope environment variables this repo owns, as {Name, Value}.
#
# A third wiring mechanism, alongside Symlink and Stub, and the only one available
# to a config format with NO include directive. jj and mise are both TOML, which
# has none — so there is nothing to stub, and a symlink is unreadable over ssh. Both
# tools do accept a path from the environment, verified on a real host:
#
#   JJ_CONFIG                 a TOML file or a directory of them; when set it
#                             REPLACES the default user-config location entirely
#                             (`jj help -k config`). Without it, `jj config get
#                             ui.default-command` answered "Value not found".
#   MISE_GLOBAL_CONFIG_FILE   the global config path. Without it, `mise config ls`
#                             outside a project listed nothing at all.
#
# User scope, not Process, because the point is to reach every process on the box —
# including an ssh session, which gets the user's environment from the registry, and
# a scheduled task. This is the same mechanism DOTFILES_WIN already relies on.
#
# The cost, stated plainly: nothing exists at ~/.config/mise/config.toml any more, so
# the wiring is invisible to someone poking around the conventional path. That is why
# `dotfiles-doctor` reports these rows explicitly — an env var that silently goes
# missing looks exactly like a tool with no config.
function Get-DotfilesEnvPlan {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $join = { param($a, $b) [System.IO.Path]::Combine($a, $b) }
    @(
        [pscustomobject]@{ Name = 'DOTFILES_WIN';            Value = $RepoRoot }
        [pscustomobject]@{ Name = 'JJ_CONFIG';               Value = (& $join $RepoRoot 'jj\config.toml') }
        [pscustomobject]@{ Name = 'MISE_GLOBAL_CONFIG_FILE'; Value = (& $join $RepoRoot 'mise\config.toml') }
    )
}

# --- Get-DotfilesStubContent --------------------------------------------------
# The body of a Kind='Stub' row: a real file that pulls in the repo copy through
# the config format's own include mechanism, so nothing has to traverse a reparse
# point. Pure — text in, text out — so install.ps1 writes exactly what the tests
# assert. Returns $null for a name with no stub form, which is the signal to the
# caller that the row should be symlinked instead.
#
# Paths are emitted with FORWARD slashes for git (its config parser treats a
# backslash as an escape, so C:\Users would eat the \U) and for Lua (same reason —
# '\U' in a quoted string is an escape, and Neovim accepts forward slashes on
# Windows), and with native backslashes for ssh_config and PowerShell, which both
# take them literally.
function Get-DotfilesStubContent {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target
    )
    $fwd = $Target -replace '\\', '/'
    switch ($Name) {
        'PowerShell profile' {
            @"
# ~`$PROFILE — dotfiles-Windows shim (REAL FILE, deliberately not a symlink).
# A symlinked profile is unreadable over ssh: sshd inherits Redirection Guard from
# the Windows service lineage and refuses to traverse a reparse point into this
# repo. Dot-sourcing a real file has no reparse point. See docs/REMOTE-ACCESS.md.

`$dotfilesProfile = '$Target'
if (Test-Path -LiteralPath `$dotfilesProfile) {
    . `$dotfilesProfile
} else {
    Write-Warning "dotfiles-Windows profile not found at '`$dotfilesProfile' — re-run install.ps1."
}
"@
        }
        '.gitconfig' {
            # excludesfile lives beside .gitconfig in the repo; the included file sets it
            # to ~/.gitignore_global, which IS a symlink, so override it after the include.
            # Order matters: last value wins for a single-valued key.
            $ignore = ($fwd -replace '/\.gitconfig$', '/.gitignore_global')
            @"
# ~/.gitconfig — dotfiles-Windows shim (REAL FILE, deliberately not a symlink).
# See docs/REMOTE-ACCESS.md: a symlink here is unreadable over ssh, and git fails
# with "unable to access ... Invalid argument" rather than anything diagnostic.

[include]
	path = $fwd

# The included file points excludesfile at ~/.gitignore_global, itself a symlink.
# Override it to the repo copy so global ignores survive an ssh session. This must
# stay AFTER the include: last value wins.
[core]
	excludesfile = $ignore
"@
        }
        'nvim config' {
            # $Target is <repo>\nvim\init.lua; the config TREE is its parent, and that
            # is what goes on 'runtimepath'. Derived here rather than passed separately
            # so the plan row keeps Target/Link symmetric, exactly like the .gitconfig
            # case deriving .gitignore_global from its own path.
            $tree = ($fwd -replace '/init\.lua$', '')
            @"
-- ~\AppData\Local\nvim\init.lua — dotfiles-Windows shim (REAL FILE, deliberately
-- not a symlink, in a REAL directory).
--
-- %LOCALAPPDATA%\nvim used to be a directory symlink onto the repo's nvim/ tree. Over
-- ssh that made the editor start bare — netrw, no colorscheme, no plugins — because
-- sshd inherits Redirection Guard from the Windows service lineage and refuses to
-- traverse a reparse point into this repo. Reading a real file has no reparse point.
-- See docs/REMOTE-ACCESS.md.
--
-- Edit the real config at $tree — not this file.

local config = '$tree'
local uv = vim.uv or vim.loop

if not uv.fs_stat(config .. '/init.lua') then
	vim.notify(
		'dotfiles-Windows nvim config not found at ' .. config .. ' — re-run install.ps1.',
		vim.log.levels.WARN
	)
	return
end

-- Prepend so require('gerrrt') resolves in the repo and wins over this shim dir;
-- append after/ so a Core sync that adds one is not silently dropped. Neovim ignores
-- a runtimepath entry that does not exist, so the append is safe today.
vim.opt.runtimepath:prepend(config)
vim.opt.runtimepath:append(config .. '/after')

-- ...but that prepend does not survive on its own. lazy.nvim REPLACES 'runtimepath'
-- wholesale inside lazy.setup() (performance.rtp.reset, on by default), rebuilding it
-- from stdpath('config') — which is THIS directory, not the repo. Every module the
-- config requires after that point becomes unfindable; the first symptom was
-- tokyonight's on_highlights callback dying with "module 'gerrrt.utils.ui-highlights'
-- not found". The config sets no performance.rtp.paths and cannot be edited from here
-- (nvim/ is mirrored from dotfiles-core), so the shim survives the reset itself.
--
-- A searcher, APPENDED. Setting package.path would do nothing: Neovim replaces the
-- stock path searcher with vim._load_package, and vim.loader.enable() then removes
-- that and inserts its cached loaders at positions 2 and 3 — so nothing consults
-- package.path. A searcher at the END is reached on a miss, and those inserts shift
-- it rather than displacing it. Being last, it costs nothing until a lookup has
-- already failed, and it can never shadow a plugin module.
--
-- This is what covers the window DURING lazy.setup(), where an eagerly-loaded spec
-- (tokyonight is lazy = false, priority = 1000) runs before anything downstream of
-- the setup call could put the path back.
local searchers = package.loaders or package.searchers
local luadir = config .. '/lua'
table.insert(searchers, function(name)
	local base = luadir .. '/' .. name:gsub('%.', '/')
	for _, file in ipairs({ base .. '.lua', base .. '/init.lua' }) do
		if uv.fs_stat(file) then
			local chunk, err = loadfile(file)
			if not chunk then
				error(err)
			end
			return chunk
		end
	end
	return "\n\tno file under " .. luadir
end)

-- lazy.nvim keeps its MUTABLE lockfile in stdpath('state') and seeds it once from
-- stdpath('config')/lazy-lock.json. stdpath('config') is THIS directory now, which
-- has no lockfile, so seed from the repo copy here instead — otherwise a fresh box
-- resolves every plugin's default branch rather than starting from the fleet's pins.
-- Best-effort: a failed seed is a slower first run, never a broken startup.
local lockfile = vim.fs.joinpath(vim.fn.stdpath('state'), 'lazy-lock.json')
local seed = config .. '/lazy-lock.json'
if not uv.fs_stat(lockfile) and uv.fs_stat(seed) then
	vim.fn.mkdir(vim.fn.stdpath('state'), 'p')
	uv.fs_copyfile(seed, lockfile)
end

dofile(config .. '/init.lua')

-- And put 'runtimepath' back, because the searcher above only answers require().
-- Runtime FILE lookups go through 'runtimepath' — colors/, ftplugin/, syntax/,
-- treesitter queries, :scriptnames, :checkhealth — and would still miss the repo.
-- Safe after setup: lazy has already built its own rtp, and this only adds to it.
vim.opt.runtimepath:prepend(config)
vim.opt.runtimepath:append(config .. '/after')
"@
        }
        { $_ -in 'psmux.conf', 'psmux.reset.conf' } {
            # psmux's config syntax is tmux-compatible, so source-file is the include
            # directive — the repo's psmux.conf already opens with one. Native
            # backslashes: psmux takes the path literally, like ssh_config.
            #
            # Unlike ssh_config there is no first-wins/last-wins subtlety to respect;
            # a later `set -g` simply overrides an earlier one, so a user's own lines
            # go BELOW the source-file and win, which is the intuitive order.
            @"
# ~/.config/psmux/$Name — dotfiles-Windows shim (REAL FILE, deliberately not a
# symlink). A symlinked config is unreadable over ssh: sshd inherits Redirection
# Guard from the Windows service lineage and refuses to traverse a reparse point
# into this repo. See docs/REMOTE-ACCESS.md.
#
# Add your own lines BELOW the source-file: psmux is last-value-wins, so anything
# here overrides the repo copy rather than being masked by it.

source-file $Target
"@
        }
        'ssh config' {
            @"
# ~/.ssh/config — dotfiles-Windows shim (REAL FILE, deliberately not a symlink).
# This one bites twice: as a symlink it also stalls the ssh CLIENT on the host,
# because ssh.exe reads this file at startup and any shell under the service
# lineage inherits the same enforcement. See docs/REMOTE-ACCESS.md.
#
# Include must come FIRST: ssh_config is first-obtained-value-wins, so anything
# above it would mask the repo's settings rather than extend them.

Include $Target
"@
        }
        default { $null }
    }
}

# --- Get-DotfilesForwarderContent ---------------------------------------------
# The body of ONE file inside a Kind='StubDir' row: a real .ps1 that invokes the repo
# copy and passes its arguments through. The StubDir counterpart to
# Get-DotfilesStubContent, kept separate because it is per-FILE, not per-row.
#
# `&` rather than dot-sourcing: these are standalone popup scripts, not fragments that
# need to define anything in the caller's scope, and `&` keeps $PSScriptRoot pointing
# at the REPO copy — so a script that resolves a sibling still finds it. @args
# forwards parameters verbatim.
#
# The path is single-quoted, with embedded quotes doubled, so a repo path containing
# a quote or a `$` is taken literally instead of being expanded.
function Get-DotfilesForwarderContent {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Target)
    $quoted = "'" + ($Target -replace "'", "''") + "'"
    @"
# dotfiles-Windows forwarder (REAL FILE, deliberately not a symlink).
# A symlinked script is unreadable over ssh — see docs/REMOTE-ACCESS.md.
# Edit the real script at the path below, not this file.
& $quoted @args
"@
}

# --- Test-StubDirIntoRepo -----------------------------------------------------
# The Kind='StubDir' counterpart to Test-StubIntoRepo: true when $Link is a REAL
# directory (not a reparse point) whose forwarders cover every file in $Target and
# reference $Root.
#
# "In sync" is the part that matters and the reason this is not just Test-StubIntoRepo
# in a loop: unlike a symlinked directory, a forwarder directory does NOT track the
# repo on its own. Drift runs BOTH ways and both directions have to fail this, or
# install's idempotent skip hides the very state it should be repairing:
#
#   • a script added upstream has no forwarder until the next install;
#   • a script DELETED upstream leaves a forwarder pointing at nothing, and a psmux
#     bind that opens a popup which immediately errors. Checking only coverage let
#     that one survive forever — the stale forwarder is not missing, so coverage was
#     satisfied, install returned "already wired", and its sweep never ran.
#
# Files the user put here themselves are ignored in the stale direction (they are not
# ours to reconcile), but a file sitting where a forwarder belongs still fails the
# coverage check above, so nothing is silently overwritten either.
function Test-StubDirIntoRepo {
    [OutputType([bool])]
    param([string]$Link, [string]$Target, [string]$Root)
    if (-not $Root) { return $false }
    if (-not (Test-Path -LiteralPath $Link -PathType Container)) { return $false }
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType) { return $false }
    $sources = @(Get-ChildItem -LiteralPath $Target -File -ErrorAction SilentlyContinue)
    if (-not $sources.Count) { return $false }
    foreach ($src in $sources) {
        $forwarder = [System.IO.Path]::Combine($Link, $src.Name)
        if (-not (Test-StubIntoRepo -Link $forwarder -Root $Root)) { return $false }
    }
    $names = @($sources | ForEach-Object Name)
    foreach ($present in @(Get-ChildItem -LiteralPath $Link -File -ErrorAction SilentlyContinue)) {
        if ($names -contains $present.Name) { continue }
        if (Test-StubIntoRepo -Link $present.FullName -Root $Root) { return $false }   # stale: ours, no source
    }
    return $true
}

# --- Test-StubIntoRepo --------------------------------------------------------
# The Kind='Stub' counterpart to Test-LinkIntoRepo: true when $Link is a REAL file
# (not a reparse point) that references $Root. Lives here, beside the plan, because
# install.ps1, uninstall.ps1 and dotfiles-doctor all have to agree about what
# "wired" means for a stub — the same reason the plan itself is shared.
#
# Deliberately a content check, not an equality check against
# Get-DotfilesStubContent: the whole point of a stub is that it is a real file the
# user can add their own lines to (a [user] block, an extra ssh Host). Requiring a
# byte-for-byte match would make every local edit read as "not ours" and invite
# uninstall to skip it or install to clobber it.
#
# Compares with forward slashes so C:\repo and C:/repo agree, and uses
# String.Contains rather than -like so a '[' or ']' in the path is not read as a
# wildcard — this gates a delete in uninstall, where a false positive removes a
# file that was never ours.
function Test-StubIntoRepo {
    [OutputType([bool])]
    param([string]$Link, [string]$Root)
    if (-not $Root) { return $false }
    if (-not (Test-Path -LiteralPath $Link)) { return $false }
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    # A symlink is emphatically NOT a stub — that is the state we are migrating away
    # from, and install must be free to replace it.
    if ($item.PSIsContainer -or $item.LinkType) { return $false }
    $content = Get-Content -LiteralPath $Link -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $false }
    return ($content -replace '\\', '/').Contains(($Root -replace '\\', '/'))
}

# --- Test-DotStubParentStale --------------------------------------------------
# Must a stub's PARENT DIRECTORY be retired before the stub can be written into it?
#
# This exists because the nvim row wires a file inside a directory that USED to be
# the linked thing: %LOCALAPPDATA%\nvim was a directory symlink onto <repo>\nvim.
# Write a stub blindly into that and every path operation resolves THROUGH the link:
# the "existing file" backed up is the repo's own init.lua, and the stub lands inside
# the Core-mirrored tree. Silent, and it corrupts the one directory in this repo that
# must stay byte-for-byte upstream. So the parent is checked first, always.
#
# Two shapes qualify, matching the two ways install.ps1 has ever wired a directory
# row (Link-Item falls back to a recursive Copy-Item when Test-CanSymlink is false):
#   • a reparse point — the symlink case;
#   • a real directory holding entries that belong to the TARGET's tree — the copy
#     case, where a stale lua\ beside the stub would sit on 'runtimepath' behind the
#     repo, shadowed but visible in :scriptnames.
#
# Pure: the caller does the directory reads and this decides what they mean.
# $TargetSiblings is what lives beside the stub's target in the repo, EXCLUDING the
# target's own leaf — otherwise a correctly-wired stub (a lone init.lua) would look
# stale to itself and be retired on every run.
function Test-DotStubParentStale {
    [OutputType([bool])]
    param(
        [bool]$IsReparsePoint,
        [string[]]$ParentEntries  = @(),
        [string[]]$TargetSiblings = @()
    )
    if ($IsReparsePoint) { return $true }
    foreach ($entry in $ParentEntries) {
        foreach ($sibling in $TargetSiblings) {
            if ($entry -and $sibling -and $entry -ieq $sibling) { return $true }
        }
    }
    return $false
}

# --- defensive output: NO_COLOR + non-Unicode terminals -----------------------
# Two universal escape hatches so the colored, glyph-decorated output degrades on
# hosts that can't render it instead of spraying ANSI codes or mojibake:
#   • NO_COLOR (https://no-color.org) — any non-empty value strips colour. We also
#     treat TERM=dumb as no-colour (CI logs, redirected output).
#   • DOTFILES_ASCII=1 — swap the Unicode glyphs (✓ ✗ → •) for ASCII so a legacy
#     codepage console (437/1252) shows readable markers, not boxes.
# Both are PURE given their parameters (defaults read the environment at call
# time), so the decision logic is unit-tested in tests/Lib.Tests.ps1.
function Test-DotColor {
    [OutputType([bool])]
    param([string]$NoColor = $env:NO_COLOR, [string]$Term = $env:TERM)
    if (-not [string]::IsNullOrEmpty($NoColor)) { return $false }
    if ($Term -eq 'dumb') { return $false }
    return $true
}

function Test-DotUnicode {
    [OutputType([bool])]
    param([string]$Ascii = $env:DOTFILES_ASCII)
    return ($Ascii -ne '1')
}

# --- Test-DotTrueColor / Get-DotAnsiSgr (U6) ----------------------------------
# 16-colour ConsoleColor can't hit the Tokyo Night accents the rest of the setup
# uses. When the terminal advertises 24-bit colour (COLORTERM=truecolor|24bit) AND
# stdout is a live console (not redirected), the renderers emit raw 24-bit ANSI for
# accents; everywhere else they fall back to ConsoleColor. The redirection guard
# (same one Invoke-DotSpinner uses) keeps ANSI escapes out of captured/transcript/CI
# streams. Test-DotTrueColor is pure given its params, so it's unit-tested.
function Test-DotTrueColor {
    [OutputType([bool])]
    param([string]$ColorTerm = $env:COLORTERM, [Nullable[bool]]$Redirected = $null)
    if ($ColorTerm -notin @('truecolor', '24bit')) { return $false }
    if ($null -eq $Redirected) { try { $Redirected = [Console]::IsOutputRedirected } catch { $Redirected = $false } }
    return (-not $Redirected)
}

# The 24-bit SGR escape for a Tokyo Night accent, keyed by the SAME ConsoleColor
# names the renderers already pass — so a truecolor terminal gets the exact palette
# and every other surface falls back. Returns '' when truecolor is off or the name
# isn't in the palette, which is the caller's signal to use ConsoleColor instead.
# Pure given -TrueColor, so it's unit-tested.
function Get-DotAnsiSgr {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Color,
        [ValidateSet('fg', 'bg')][string]$Layer = 'fg',
        [bool]$TrueColor = (Test-DotTrueColor)
    )
    if (-not $TrueColor) { return '' }
    # GENERATED from theme/palette.toml by gen-theme.ps1 — do not hand-edit. One key
    # per line because a style flip changes the digit COUNT, and any column-aligned
    # layout would then churn its whitespace on every palette change and bury the
    # value diff under it.
    $palette = @{
        # core:theme:gen ansi-sgr-palette
        Red        = '247;118;142'
        Green      = '158;206;106'
        Yellow     = '224;175;104'
        Blue       = '122;162;247'
        Magenta    = '187;154;247'
        Cyan       = '125;207;255'
        Gray       = '169;177;214'
        White      = '192;202;245'
        Black      = '29;32;47'
        DarkGray   = '86;95;137'
        DarkYellow = '255;158;100'
        # core:theme:end ansi-sgr-palette
    }
    $rgb = $palette[$Color]
    if (-not $rgb) { return '' }
    $code = if ($Layer -eq 'bg') { '48' } else { '38' }
    return ("$([char]27)[$code;2;${rgb}m")
}

# --- Get-DotAccentSpec --------------------------------------------------------
# The pwsh twin of Core's _CORE_ACCENT_SPEC / _CORE_MUTED_SPEC (zsh/05-ui.zsh): the
# ONE place $COLORTERM is interpreted for the branded accent + muted grey. Before
# #228 this host had no equivalent at all — `grep -rnE 'CORE_ACCENT|AccentSpec'
# powershell/` returned nothing — which is why PARITY.md's accent half was a genuine
# GAP rather than a drift.
#
# Two forms per tier, because colour is rendered two ways here exactly as in Core:
# raw SGR escapes (Accent/Muted, for direct console writes) and a bare spec
# (AccentSpec/MutedSpec) a prompt or config consumes. Truecolor when the terminal
# advertises 24-bit, else a 256-colour approximation — the same "degrade, don't
# assume" rule Test-DotTrueColor applies.
#
# The 256-colour fallbacks are HAND-PICKED in theme/palette.toml and are NOT
# derivable from the hex: they are eyeballed cube approximations, and the two forms
# deliberately disagree (SGR 111/103 vs spec 75/244). The generator carries both
# verbatim and computes neither from the other.
#
# Deliberately NOT folded into Get-DotAnsiSgr: that one is keyed by ConsoleColor name
# and answers "what escape paints this colour", and it returns '' rather than
# degrading when truecolor is off. This answers "what is the accent on THIS terminal"
# and always returns something usable. Pure given -ColorTerm, so it is unit-tested.
function Get-DotAccentSpec {
    [OutputType([pscustomobject])]
    param([string]$ColorTerm = $env:COLORTERM)
    # core:theme:gen accent-tiers
    if ($ColorTerm -in @('24bit', 'truecolor')) {
        return [pscustomobject]@{ Accent = "$([char]27)[1;38;2;122;162;247m"; Muted = "$([char]27)[38;2;86;95;137m"; AccentSpec = '#7aa2f7'; MutedSpec = '#565f89'; TrueColor = $true }
    }
    return [pscustomobject]@{ Accent = "$([char]27)[1;38;5;111m"; Muted = "$([char]27)[38;5;103m"; AccentSpec = 75; MutedSpec = 244; TrueColor = $false }
    # core:theme:end accent-tiers
}

# Status/decoration glyphs, resolved once here so every renderer agrees and the
# ASCII fallback is in exactly one place.
function Get-DotGlyph {
    param(
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'fail', 'arrow', 'bullet', 'pkg')][string]$Name,
        [bool]$Unicode = (Test-DotUnicode)
    )
    $uni = @{ ok = '✓'; warn = '!'; fail = '✗'; arrow = '→'; bullet = '•'; pkg = '⇧' }
    $asc = @{ ok = 'OK'; warn = '!'; fail = 'x'; arrow = '->'; bullet = '-'; pkg = '^' }
    if ($Unicode) { $uni[$Name] } else { $asc[$Name] }
}

# Colour-aware Write-Host: honours NO_COLOR by dropping the -ForegroundColor so
# every helper can stay a one-liner instead of branching on colour at each call.
function Write-DotHost {
    param(
        [Parameter(Position = 0)][string]$Text = '',
        [string]$Color,
        [switch]$NoNewline
    )
    if (-not $Color -or -not (Test-DotColor)) {
        Write-Host $Text -NoNewline:$NoNewline
        return
    }
    # Truecolor terminals get the exact Tokyo Night accent via raw 24-bit ANSI;
    # everyone else (and any redirected/CI stream) falls back to the 16-colour
    # console. Get-DotAnsiSgr returns '' unless truecolor is live, so this is a
    # transparent upgrade — no call site changes.
    $sgr = Get-DotAnsiSgr -Color $Color
    if ($sgr) {
        Write-Host ($sgr + $Text + "$([char]27)[0m") -NoNewline:$NoNewline
    } else {
        Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
    }
}

# --- Write-DotBanner ----------------------------------------------------------
# The one section header every report uses: an inverse " Title " chip (with an
# optional dimmer subtitle on the same line) when colour is on, degrading to a
# plain "== Title ==" / "== Title :: subtitle ==" under NO_COLOR/TERM=dumb. Pulls
# dotfiles-doctor and dothelp onto a single visual language instead of each
# re-implementing the Test-DotColor branch.
function Write-DotBanner {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Subtitle,
        [string]$Background = 'Cyan',
        [string]$Foreground = 'Black',
        [string]$SubtitleColor = 'Cyan'
    )
    if (Test-DotColor) {
        # The chip is all-or-nothing: truecolor only when BOTH its bg and fg are in
        # the palette, else the whole chip uses the 16-colour inverse (you can't
        # cleanly mix a truecolor bg with a ConsoleColor fg — the ANSI reset would
        # clobber it). The subtitle is independent and falls back on its own.
        $reset = "$([char]27)[0m"
        $bg = Get-DotAnsiSgr -Color $Background -Layer bg
        $fg = Get-DotAnsiSgr -Color $Foreground -Layer fg
        if ($bg -and $fg) {
            Write-Host ($bg + $fg + " $Text " + $reset) -NoNewline:([bool]$Subtitle)
        } else {
            Write-Host " $Text " -ForegroundColor $Foreground -BackgroundColor $Background -NoNewline:([bool]$Subtitle)
        }
        if ($Subtitle) {
            $sfg = Get-DotAnsiSgr -Color $SubtitleColor
            if ($sfg) { Write-Host ($sfg + "  $Subtitle" + $reset) }   # SGR first, so the spacing is coloured like the text
            else { Write-Host "  $Subtitle" -ForegroundColor $SubtitleColor }
        }
    } elseif ($Subtitle) {
        Write-Host "== $Text :: $Subtitle =="
    } else {
        Write-Host "== $Text =="
    }
}

# --- Get-DotConsoleWidth ------------------------------------------------------
# The usable console width, or $Fallback (80) when there's no real console handle
# (redirected output, a transcript, CI). Guarded so it never throws on a host
# without a window. Lets the rule/wrap helpers below size to the actual terminal
# instead of a hardcoded column count (U5/U12).
function Get-DotConsoleWidth {
    [OutputType([int])]
    param([int]$Fallback = 80)
    try { $w = [Console]::WindowWidth; if ($w -gt 0) { return $w } } catch { }
    return $Fallback
}

# --- Format-DotWrap -----------------------------------------------------------
# Word-wrap $Text to $Width columns, prefixing every line (including continuations)
# with $Indent, and return the lines. A word longer than the available width is
# emitted whole rather than hard-split (paths stay clickable). Pure, so it's
# unit-tested; used to keep long hint lines from overflowing a narrow terminal (U12).
function Format-DotWrap {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$Width = 80,
        [string]$Indent = ''
    )
    $avail = [Math]::Max(1, $Width - $Indent.Length)
    $words = @($Text -split '\s+' | Where-Object { $_ -ne '' })
    if (-not $words.Count) { return @() }
    $lines = [System.Collections.Generic.List[string]]::new()
    $cur = ''
    foreach ($w in $words) {
        if (-not $cur)                                       { $cur = $w }
        elseif (($cur.Length + 1 + $w.Length) -le $avail)    { $cur += ' ' + $w }
        else                                                 { $lines.Add($Indent + $cur); $cur = $w }
    }
    if ($cur) { $lines.Add($Indent + $cur) }
    return $lines.ToArray()
}

# --- Write-DotRule ------------------------------------------------------------
# A titled horizontal rule ("-- Summary ─────…"), Unicode by default and ASCII
# under DOTFILES_ASCII, colour-aware via Write-DotHost. One place for the box-rule
# glyph so install/uninstall/maint summaries line up. With no explicit -Width it
# now fills the actual console (U5) instead of a fixed 56 columns; an explicit
# -Width still wins (so the existing callers/tests are unaffected).
function Write-DotRule {
    param([string]$Title, [int]$Width = 0, [string]$Color = 'Cyan')
    $ch = if (Test-DotUnicode) { '─' } else { '-' }
    if ($Width -le 0) {
        $prefix = if ($Title) { ("-- $Title ").Length } else { 0 }
        $Width = [Math]::Max(8, (Get-DotConsoleWidth) - $prefix)
    }
    $line = if ($Title) { "-- $Title " + ($ch * $Width) } else { ($ch * $Width) }
    Write-DotHost $line -Color $Color
}

# --- Write-DotErr -------------------------------------------------------------
# One consistent error layout for the interactive helpers: a red "✗ <message>"
# and, when supplied, a dimmed "→ <hint>" telling the user how to fix it (usually
# the exact install command). Replaces the bare, hint-less `Write-Error 'needs x'`
# scattered across the helpers. Glyphs/colour degrade via the helpers above.
# -PassThru returns the composed text (for tests).
function Write-DotErr {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Hint,
        [switch]$PassThru
    )
    $x = Get-DotGlyph fail
    $arrow = Get-DotGlyph arrow
    Write-DotHost "  $x " -Color Red -NoNewline
    Write-DotHost $Message -Color Red
    if ($Hint) {
        Write-DotHost "    $arrow " -Color DarkGray -NoNewline
        Write-DotHost $Hint -Color DarkGray
    }
    if ($PassThru) {
        $out = "$x $Message"
        if ($Hint) { $out += "`n$arrow $Hint" }
        return $out
    }
}

# --- Write-DotOk --------------------------------------------------------------
# The success sibling of Write-DotErr/Write-DotWarn: a green "✓ <message>" with an
# optional dimmed "→ <hint>". Replaces the bare `Write-Host '✓ ...' -Foreground
# Green` scattered across the helpers, which ignored NO_COLOR and printed a raw
# glyph under DOTFILES_ASCII. Glyph/colour degrade via the helpers above.
# -PassThru returns the composed text (for tests).
function Write-DotOk {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Hint,
        [switch]$PassThru
    )
    $ok = Get-DotGlyph ok
    $arrow = Get-DotGlyph arrow
    Write-DotHost "  $ok " -Color Green -NoNewline
    Write-DotHost $Message -Color Green
    if ($Hint) {
        Write-DotHost "    $arrow " -Color DarkGray -NoNewline
        Write-DotHost $Hint -Color DarkGray
    }
    if ($PassThru) {
        $out = "$ok $Message"
        if ($Hint) { $out += "`n$arrow $Hint" }
        return $out
    }
}

# --- Write-DotWarn ------------------------------------------------------------
# The non-fatal sibling of Write-DotErr: a yellow "! <message>" with an optional
# dimmed "→ <hint>". Used in place of bare Write-Warning at the user-facing entry
# points (install.ps1, the package installer) so warnings share one layout and
# honour NO_COLOR / DOTFILES_ASCII. -PassThru returns the composed text.
function Write-DotWarn {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Hint,
        [switch]$PassThru
    )
    $bang = Get-DotGlyph warn
    $arrow = Get-DotGlyph arrow
    Write-DotHost "  $bang " -Color Yellow -NoNewline
    Write-DotHost $Message -Color Yellow
    if ($Hint) {
        Write-DotHost "    $arrow " -Color DarkGray -NoNewline
        Write-DotHost $Hint -Color DarkGray
    }
    if ($PassThru) {
        $out = "$bang $Message"
        if ($Hint) { $out += "`n$arrow $Hint" }
        return $out
    }
}
