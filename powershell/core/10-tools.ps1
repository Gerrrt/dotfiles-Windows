# ============================================================================
#  core/10-tools.ps1  -  prompt, history, completion, fuzzy nav
#  Keeps the host's terminal feel identical to the rest of the fleet.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: Get-InitCache, Clear-InitCache, shell-bench, prof-trace, Invoke-DotfilesSessionizer, Invoke-DotLoadPSFzf, Invoke-Starship-PreCommand
# requires: Get-DotCmdEntry, Get-DotStringSha256, Test-Cmd, Test-InMux, Test-SensitiveHistoryLine, Write-DotErr, Write-DotHost, Write-DotWarn

# --- FAST_START escape hatch --------------------------------------------------
# Skips ALL the heavy prompt/history/completion init in this fragment. The cheap
# fragments (aliases, functions, op, psmux defs) still load, so the shell stays
# usable - you just drop to the stock PowerShell prompt with no starship/zoxide/
# atuin/carapace wiring. `return` here ends only this dot-sourced fragment; the
# loader in profile.ps1 carries on to the next one.
#
# FAST_START is read from the ENVIRONMENT at profile-load time, so it must exist
# *before* pwsh starts - setting it in local.ps1 is too late (local loads last).
#   one lean child shell:   $env:FAST_START='1'; pwsh        # child inherits it
#   always lean on this box: [Environment]::SetEnvironmentVariable('FAST_START','1','User')
if ($env:FAST_START -eq '1') { return }

# --- idempotency sentinels ----------------------------------------------------
# `reload` (. $PROFILE) re-dot-sources this fragment. The four `init` calls below
# each shell out to an external binary and inject prompt/keybind hooks; re-running
# them on every reload wastes time and can stack hooks. Track what's already wired
# in a global so a reload is a no-op for the expensive bits. Using $global: (not
# $script:) means this also holds if the fragment is re-sourced on its own.
if (-not $global:DotfilesInit) { $global:DotfilesInit = @{} }

# --- load tracer (DOTFILES_PROFILE_TRACE=1) -----------------------------------
# One stopwatch, lapped after each heavy step below, so the trace table breaks
# this fragment's cost down by tool instead of reporting one lump. No-op unless
# tracing is on. (Reads $script: state that resolves to this dot-sourced
# fragment's scope; Add-DotfilesTrace is global.)
if ($global:DotfilesTraceOn) { $script:__tsw = [System.Diagnostics.Stopwatch]::StartNew(); $script:__tlast = 0.0 }
function script:__lap {
    param([string]$Name)
    if (-not $global:DotfilesTraceOn) { return }
    $now = $script:__tsw.Elapsed.TotalMilliseconds
    Add-DotfilesTrace "10-tools: $Name" ($now - $script:__tlast)
    $script:__tlast = $now
}

# --- module availability: one scan, not three (P1) ----------------------------
# Get-Module -ListAvailable walks the entire PSModulePath tree; calling it once per
# module (PSReadLine, CompletionPredictor, PSFzf, Terminal-Icons) repeated that walk
# 3-4× every shell start (~30-120ms). Do ONE up-front scan for just the modules this
# fragment gates on, into a case-insensitive name set, then test membership (O(1)) at
# each guard below. A single -Name call with all four keeps it to one traversal.
$script:DotAvailModules = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($m in (Get-Module -ListAvailable -Name PSReadLine, CompletionPredictor, PSFzf, Terminal-Icons -ErrorAction SilentlyContinue)) {
    [void]$script:DotAvailModules.Add($m.Name)
}
__lap 'module-scan'

# --- PSReadLine: history, prediction, keybinds --------------------------------
# PSReadLine ships with PowerShell 7. Configure it for a zsh-like feel.
#
# Vi edit mode is DELIBERATE — it's the host-side parity with Core's zsh-vi-mode.
# But it has one sharp edge: a multi-line PASTE is only safe in Vi mode when the
# terminal delivers it as a single BRACKETED-PASTE block (ESC[200~ … ESC[201~),
# which PSReadLine inserts literally regardless of edit mode. Without bracketed
# paste the block is replayed keystroke-by-keystroke and Vi interprets `:`/`d`/
# `i`/`a`/`o`/`Esc` as commands — the classic "paste switches modes / reorders
# text / runs vim commands" bug. Bracketed paste needs PSReadLine >= 2.2.0
# (Windows Terminal already sends it), so packages/modules.ps1 pins a recent
# PSReadLine and the version guard below self-diagnoses a stale in-box build.
if ($script:DotAvailModules.Contains('PSReadLine')) {
    Import-Module PSReadLine
    # Self-diagnose a paste-unsafe PSReadLine instead of misbehaving silently. The
    # check is one cheap [version] compare on the already-loaded module, and the
    # warning routes through the repo's Write-DotWarn (honours NO_COLOR/quiet) so a
    # stale box tells the operator exactly what to bump. >= 2.2.0 has bracketed paste.
    $prl = (Get-Module PSReadLine).Version
    if ($prl -and $prl -lt [version]'2.2.0') {
        Write-DotWarn "PSReadLine $prl predates bracketed paste — multi-line paste in Vi mode will run as keystrokes (modes/vim commands)." `
                      'update: Install-Module PSReadLine -MinimumVersion 2.2.0 -Scope CurrentUser -Force (then restart pwsh)'
    }
    Set-PSReadLineOption -EditMode Vi
    Set-PSReadLineOption -HistoryNoDuplicates
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    # CompletionPredictor (managed in packages/modules.ps1) registers itself as a
    # PSReadLine predictor plugin on import — it's the "Plugin" half of the
    # HistoryAndPlugin source set below. Importing it EAGERLY costs ~50-150ms of
    # JIT + subsystem registration on the cold-start path (P2), yet the plugin only
    # earns its keep once you're actually typing at the prompt. So DEFER it to the
    # first idle tick (fires the instant the prompt is drawn, off the render path).
    # A predictor registers PROCESS-globally via SubsystemManager, so an OnIdle import
    # — which runs in the eventing runspace, not the session one — still lands where
    # PSReadLine picks it up (unlike PSFzf's keybindings, which must import into the
    # session runspace and so defer to a keypress instead). Until it loads, the Plugin
    # half is simply empty and history predictions still show; it fills in a few ms
    # after the prompt appears. -MaxTriggerCount 1 makes it one-shot (auto-unsubscribes).
    if ($script:DotAvailModules.Contains('CompletionPredictor')) {
        $null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action {
            try { Import-Module CompletionPredictor -ErrorAction Stop } catch { }
        }
    }
    try {
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        # InlineView by DEFAULT, not ListView. ListView redraws a multi-row dropdown
        # under the cursor on EVERY keystroke — visible churn (the "cursor blinks
        # rapidly / lots happening" feel) and more terminal I/O per key. InlineView
        # shows the SAME predictions as a single inline ghost suggestion: no feature
        # loss, far less render work. Opt back into the dropdown per-machine with
        # DOTFILES_PSRL_LISTVIEW=1 in the User environment (set before the shell starts;
        # local.ps1 loads too late to gate this).
        $prlView = if ($env:DOTFILES_PSRL_LISTVIEW -eq '1') { 'ListView' } else { 'InlineView' }
        Set-PSReadLineOption -PredictionViewStyle $prlView
        # Tint the prediction UI to the Tokyo Night palette the rest of the setup uses
        # instead of PSReadLine's default grey: a muted inline ghost, a blue list row,
        # a dark selection bar. Raw 24-bit SGR (Windows Terminal advertises truecolor);
        # [char]27 = ESC, matching the escapes in core/05-lib.ps1's renderers.
        Set-PSReadLineOption -Colors @{
            # core:theme:gen psreadline-prediction
            InlinePrediction       = "$([char]27)[38;2;86;95;137m"
            ListPrediction         = "$([char]27)[38;2;122;162;247m"
            ListPredictionSelected = "$([char]27)[48;2;46;60;100m"
            # core:theme:end psreadline-prediction
        }
      } catch {
          # predictions unavailable in this host - carry on
        }
    Set-PSReadLineOption -MaximumHistoryCount 200000   # match Core's zsh HISTSIZE/SAVEHIST

    # Never persist obviously sensitive one-liners to the history file. This is
    # the PSReadLine analog of Core's HISTORY_IGNORE (history.zsh): the line is
    # still usable in the session, it just isn't written to disk. Returning
    # 'MemoryOnly' keeps it out of the saved file; 'None' would drop it entirely.
    # The decision lives in Test-SensitiveHistoryLine (core/05-lib.ps1) so it is
    # unit-tested and word-boundaried — the bare `pwd` command is NOT dropped.
    Set-PSReadLineOption -AddToHistoryHandler {
        param([string]$line)
        # preexec analog for the command-block separator (see Invoke-Starship-PreCommand):
        # this handler only fires when a non-empty line is accepted, so a bare Enter never
        # sets the flag — matching Core's preexec-gated "no rule on an empty prompt".
        $global:DotCmdBlockRan = $true
        if (Test-SensitiveHistoryLine $line) { return [Microsoft.PowerShell.AddToHistoryOption]::MemoryOnly }
        return [Microsoft.PowerShell.AddToHistoryOption]::MemoryAndFile
    }

    # Up/Down do prefix-based history search (type `git ` then Up)
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    # Ctrl+arrow word movement; Tab = menu complete
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
    # F2 flips between the inline ghost and the multi-row dropdown on demand — the
    # low-churn InlineView stays the default (see the PredictionViewStyle note above),
    # but the richer ListView is one key away when you want several ranked sources at
    # once. try/catch so an older PSReadLine without the function still loads clean.
    try { Set-PSReadLineKeyHandler -Key F2 -Function SwitchPredictionView } catch { }

    # Ctrl+\ toggles predictions on/off — cross-shell parity with zsh's Ctrl-\
    # autosuggest-toggle (bindings.zsh). PSReadLine has no built-in toggle, so flip
    # PredictionSource between the configured source and None, tracking state in a
    # global so a `reload` doesn't wedge it off. try/catch keeps an older PSReadLine
    # without predictions loading clean.
    try {
        Set-PSReadLineKeyHandler -Chord 'Ctrl+\' -BriefDescription 'Toggle predictions' -ScriptBlock {
            if ($global:DotfilesPredictionsOff) {
                $view = if ($env:DOTFILES_PSRL_LISTVIEW -eq '1') { 'ListView' } else { 'InlineView' }
                Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle $view
                $global:DotfilesPredictionsOff = $false
            } else {
                Set-PSReadLineOption -PredictionSource None
                $global:DotfilesPredictionsOff = $true
            }
        }
    } catch { }
}
__lap 'PSReadLine'

# --- Terminal-Icons (file/dir glyphs for Get-ChildItem output) ----------------
# OFF by default: importing Terminal-Icons costs ~1s every shell, and it only
# themes RAW Get-ChildItem/dir output — your ls/ll/la already render icons via
# `eza --icons`, so you almost never see Terminal-Icons output. Opt in by setting
# the env var (User scope, so it's present at shell start — local.ps1 loads too
# late): [Environment]::SetEnvironmentVariable('DOTFILES_TERMINAL_ICONS','1','User')
# Try/catch: the manifest can exist while the .psm1 it points at is missing.
if ($env:DOTFILES_TERMINAL_ICONS -eq '1' -and $script:DotAvailModules.Contains('Terminal-Icons')) {
    try   { Import-Module Terminal-Icons -ErrorAction Stop }
    catch { Write-DotWarn 'Terminal-Icons failed to load' 'reinstall: Install-Module Terminal-Icons -Scope CurrentUser -Force -AllowClobber' }
}
__lap 'Terminal-Icons'

# --- init-output cache (cold-start speed) -------------------------------------
# starship/zoxide/mise/atuin/carapace each spawn a subprocess just to PRINT their
# shell-integration script, which we then evaluate. Process spawn is the slow part
# on Windows, so cache that text to a file and re-spawn only when the tool's own
# binary is newer than the cache (i.e. after a scoop upgrade). The cache file is
# dot-sourced by the CALLER at global scope (this fragment runs global), so prompt
# hooks / key handlers register exactly as they did with Invoke-Expression.
#   Get-InitCache returns the path to a ready-to-source file (or $null on failure,
#   so each call site can fall back). Bust the whole cache with `init-cache-clear`.
$global:DotfilesInitCacheDir = Join-Path $env:LOCALAPPDATA 'dotfiles\init-cache'
function global:Get-InitCache {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Generate
    )
    $cacheFile = Join-Path $global:DotfilesInitCacheDir "$Name.ps1"

    # The cache key has TWO inputs, so a full hit means BOTH the tool and the recipe
    # are unchanged:
    #   • binary mtime  — a scoop/winget upgrade rewrites the exe and bumps its
    #                     mtime, so a new tool version regenerates (version drift).
    #   • generator hash — a SHA-256 of THIS call's scriptblock text, stored as a
    #                     marker comment on the cache file's first line. Editing the
    #                     flags here (e.g. `zoxide init powershell --cmd cd`) changes
    #                     the hash, so the stale cache self-busts on the next shell
    #                     instead of silently serving the old init until someone
    #                     remembers `init-cache-clear` (B2).
    # genHash is computed up front because the psmux fast-path below also needs it.
    # It's cheap (a SHA over a short string) and touches neither PATH nor the exe.
    $genHash = if (Get-Command Get-DotStringSha256 -ErrorAction SilentlyContinue) {
        Get-DotStringSha256 $Generate.ToString()
    } else { $null }
    $marker = "# initcache-hash: $genHash"
    $hashOk = if ($null -eq $genHash) { $true }
              else { (Get-Content $cacheFile -TotalCount 1 -ErrorAction SilentlyContinue) -eq $marker }

    # --- psmux fast-path: skip the EXPENSIVE half of validation --------------------
    # A psmux split inherits its parent shell's env, so re-resolving the tool exe on
    # PATH (Get-Command — an on-access-AV-scanned stat storm on Windows) and stat-ing
    # it for mtime, on EVERY split, just re-confirms the binary hasn't moved — the
    # ~60ms/tool we're chasing. Skip THAT in a pane. But still honour the cheap
    # generator-hash marker (one first-line read, already done above): editing a
    # tool's init flags here must self-bust the cache even in a split (the B2
    # invariant) — and because DotfilesInitCacheDir lives in LOCALAPPDATA and, with
    # warm/persistent psmux sessions, can outlive many profile edits, trusting it
    # blindly would serve a stale init after a flag change. Pane detection is
    # Test-InMux (core/05-lib.ps1). NOT caught by the fast-path: a tool BINARY upgrade
    # mid-session (only the skipped mtime check sees that) — it self-heals on the next
    # top-level shell / fresh psmux server, or force it now with `init-cache-clear`.
    if ((Test-InMux) -and (Test-Path $cacheFile) -and $hashOk) { return $cacheFile }

    # Reuse the resolution Test-Cmd already did (P3): each caller gates on `Test-Cmd
    # <tool>` right before calling us, so Get-DotCmdEntry returns the cached {Found,
    # Source} record — no second Get-Command PATH scan per tool. (Cache-name-only keys
    # like 'mise-shims', which are never a real command, resolve to Source=$null here
    # just as the old Get-Command did, so the mtime check below is skipped for them.)
    $src = (Get-DotCmdEntry $Name).Source

    $stale = $true
    if ((Test-Path $cacheFile) -and $src -and (Test-Path $src)) {
        $mtimeOk = (Get-Item $cacheFile).LastWriteTimeUtc -ge (Get-Item $src).LastWriteTimeUtc
        # hashOk (generator marker on the first line) was computed above; a full hit
        # needs both it and the mtime. When hashing is unavailable (05-lib didn't
        # load) hashOk defaulted true, so this falls back to mtime only.
        $stale = -not ($mtimeOk -and $hashOk)
    }
    if ($stale) {
        try {
            if (-not (Test-Path $global:DotfilesInitCacheDir)) {
                New-Item -ItemType Directory -Force -Path $global:DotfilesInitCacheDir | Out-Null
            }
            $out = (& $Generate | Out-String)
            if ([string]::IsNullOrWhiteSpace($out)) { return $null }
            # Prepend the marker (a PowerShell comment, so dot-sourcing ignores it).
            $payload = if ($genHash) { $marker + "`n" + $out } else { $out }
            Set-Content -Path $cacheFile -Value $payload -Encoding utf8
        } catch { return $null }
    }
    return $cacheFile
}

# init-cache-clear: drop every cached init script (they regenerate on next start).
# Use after changing a tool's flags here, or if an init ever caches badly.
function global:Clear-InitCache {
    if (Test-Path $global:DotfilesInitCacheDir) {
        Remove-Item (Join-Path $global:DotfilesInitCacheDir '*.ps1') -Force -ErrorAction SilentlyContinue
    }
    Write-DotHost 'init cache cleared (regenerates on next shell start)' -Color Green
}
Set-Alias init-cache-clear Clear-InitCache -Scope Global

# shell-bench: time a cold pwsh start (full profile) N times. Use this to decide
# whether any of the above is worth tuning further — measure, don't guess.
#   shell-bench        # 5 runs
#   shell-bench 10
function global:shell-bench {
    param([int]$Runs = 5)
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) { Write-DotErr 'pwsh not found' 'install it: scoop install pwsh'; return }
    1..$Runs | ForEach-Object {
        (Measure-Command { & $pwshPath -NoLogo -Command exit }).TotalMilliseconds
    } | Measure-Object -Average -Minimum -Maximum |
        Select-Object @{n='Runs';e={$Runs}}, @{n='Min_ms';e={[math]::Round($_.Minimum)}},
                      @{n='Avg_ms';e={[math]::Round($_.Average)}}, @{n='Max_ms';e={[math]::Round($_.Maximum)}}
}

# prof-trace: load the FULL profile in a clean child with tracing on, and show the
# slowest-first breakdown. Instead of relying on the child's console output (which
# can be swallowed by the -Command/-NoExit/host-stream chain — the "prints nothing"
# bug), the child WRITES the table to a temp file and the parent reads it back on
# its own output stream. Robust regardless of how the child's console behaves.
#   • PSMUX_NO_AUTOLAUNCH=1 — psmux can't grab the trace child.
#   • The child writes to $env:DOTFILES_TRACE_OUT (inherited from us), so there's
#     no string-escaping of paths into the command.
#   • If the file comes back empty/missing, that itself tells us the profile didn't
#     populate the trace (vs. an output-plumbing problem) — and we say so.
function global:prof-trace {
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) { Write-DotErr 'pwsh not found' 'install it: scoop install pwsh'; return }
    $out = Join-Path $env:TEMP 'dotfiles-proftrace.txt'
    Remove-Item $out -Force -ErrorAction SilentlyContinue
    $env:DOTFILES_TRACE_OUT = $out
    try {
        & $pwshPath -NoProfile -Command {
            $env:DOTFILES_PROFILE_TRACE = '1'
            $env:PSMUX_NO_AUTOLAUNCH    = '1'
            . $PROFILE
            if ($global:DotfilesTrace -and $global:DotfilesTrace.Count) {
                $global:DotfilesTrace | Sort-Object ms -Descending |
                    Format-Table -AutoSize | Out-String -Width 200 |
                    Set-Content -Path $env:DOTFILES_TRACE_OUT -Encoding utf8
            } else {
                Set-Content -Path $env:DOTFILES_TRACE_OUT -Encoding utf8 `
                    -Value '(trace empty — profile loaded but DotfilesTrace was never populated)'
            }
        }
    } finally {
        Remove-Item Env:DOTFILES_TRACE_OUT -ErrorAction SilentlyContinue
    }
    if (Test-Path $out) {
        Write-DotHost "`nprofile load trace (slowest first):" -Color Cyan
        Get-Content $out
    } else {
        Write-DotWarn 'prof-trace: child wrote no file — the profile likely errored before the trace ran.'
        Write-DotHost  'Fallback (loads the profile the plain way, no -Command indirection):' -Color DarkGray
        Write-DotHost  "  `$env:DOTFILES_PROFILE_TRACE='1'; `$env:PSMUX_NO_AUTOLAUNCH='1'; pwsh -NoLogo" -Color DarkGray
    }
}

# --- OSC 7: announce the cwd to the terminal ---------------------------------
# OSC 7 is the standard "here is my working directory" handshake. Emitting it is
# what lets a terminal open a new tab/split in the SAME directory without having
# to go digging for it, and Windows Terminal, WezTerm, and psmux all consume it.
#
# On the host this is load-bearing for psmux's status bar, not just a nicety.
# psmux resolves #{pane_current_path} in three layers (src/format.rs:1273):
#   1. a PEB walk of the pane's foreground process — and reaching that process
#      first costs a FULL CreateToolhelp32Snapshot over every process on the
#      machine (src/platform.rs:2966), uncached,
#   2. the OSC 7 value,
#   3. the server's own cwd.
# Layer 1 runs FIRST and unconditionally, so #{pane_current_path} pays the
# snapshot on every status repaint no matter what. #{pane_path} (used in
# psmux.conf's status-right) is the pure-OSC-7 variable — layer 2 only — so it
# is nearly free, but it is EMPTY unless the shell announces the path. That is
# what this hook is for. See psmux.conf's header note for the full story.
#
# starship calls Invoke-Starship-PreCommand once per prompt if it exists. Two
# constraints on what this function may do:
#   - It must NOT write to the pipeline. starship's `prompt` calls it inline, so
#     anything returned is concatenated into the prompt STRING. [Console]::Write
#     goes straight to the console handle and sidesteps that.
#   - It must stay cheap: it is on the per-prompt path. A [uri] cast and one
#     write is ~0.05ms; anything heavier belongs somewhere else.
# The FileSystem-provider guard keeps it quiet on Cert:\ / HKLM:\ / Function:\,
# where there is no filesystem path to announce.
function global:Invoke-Starship-PreCommand {
    # ── Command-block separator (port of Core zsh 00-tools.zsh `_cmd_block_*`, P12) ──
    # A thin full-width rule drawn above each prompt that FOLLOWED a command, colored by
    # that command's exit status — the palette's `rule` role on success, `err` on failure —
    # so scrollback reads as scannable blocks. The AddToHistoryHandler above sets
    # $global:DotCmdBlockRan as the preexec signal (a bare Enter never accepts a line, so
    # it draws no rule, exactly like Core's preexec-flag gate). Written via [Console]::Write
    # so it never lands in starship's prompt STRING.
    # NOTE: at this point starship's prompt fn has already read `$?`, so only $LASTEXITCODE
    # is reliable here — the rule tracks native-command exit codes; a failed pure-cmdlet
    # still shows in starship's own [status] segment. $LASTEXITCODE captured FIRST so no
    # later statement perturbs it (mirrors Core's `local ec=$?`).
    $ec = $global:LASTEXITCODE
    if ($global:DotCmdBlockRan) {
        $global:DotCmdBlockRan = $false
        try {
            $w = [Console]::WindowWidth
            if ($w -gt 0) {
                $fail = ($ec -is [int]) -and ($ec -ne 0)
                # core:theme:gen cmd-separator-colors
                $col  = if ($fail) { "$([char]27)[38;2;247;118;142m" } else { "$([char]27)[38;2;65;72;104m" }
                # core:theme:end cmd-separator-colors
                [Console]::Write($col + (([string][char]0x2500) * $w) + "$([char]27)[0m`n")
            }
        } catch { }   # no console (redirected / CI) → skip the rule, never throw
    }

    # ── OSC 7 cwd announce (for psmux's status-right cwd pill) ───────────────────
    if ($PWD.Provider.Name -ne 'FileSystem') { return }
    try {
        # [uri] does the percent-encoding for us (spaces, unicode, #, ...) and
        # yields file:///C:/path or file://server/share for UNC. psmux strips the
        # scheme+host and percent-decodes (crates/vt100-psmux/src/screen.rs).
        $u = ([uri]$PWD.ProviderPath).AbsoluteUri
        [Console]::Write("$([char]27)]7;$u$([char]27)\")
    } catch { }   # never let a prompt hook throw — it would eat the prompt
}

# --- starship prompt (cross-shell - same starship.toml as the fleet) ----------
# Force the repo config to win over any inherited/persistent STARSHIP_CONFIG.
# Only point at it if the file actually exists, so we never aim starship at a
# missing path. init is in its own try so a hiccup can't take down the rest.
if ((Test-Cmd starship) -and -not $global:DotfilesInit.Starship) {
    $starshipCfg = if ($global:DOTFILES) { Join-Path $global:DOTFILES 'starship\starship.toml' } else { $null }
    if ($starshipCfg -and (Test-Path $starshipCfg)) {
        $env:STARSHIP_CONFIG = $starshipCfg
    }
    try {
        # CACHE THE *FULL* INIT, not the bootstrap. `starship init powershell` only
        # prints a ~200-byte stub that itself shells out again —
        #   Invoke-Expression (& starship init powershell --print-full-init | Out-String)
        # so caching that stub still paid an extra starship spawn at PROFILE-LOAD time on
        # every shell (the cache was a no-op for the one tool it mattered most for:
        # ~300-650ms per start). `--print-full-init` emits the actual prompt/keybind code,
        # so the cached file is self-contained and a warm shell does the load-time init
        # with zero starship spawns. (starship.exe still runs once per PROMPT RENDER after
        # that — that's how the prompt works; this only removes the load-time init spawn.)
        # The fallback mirrors the stub's own behaviour so a cache miss never loses the prompt.
        $cf = Get-InitCache -Name starship -Generate { starship init powershell --print-full-init }
        if ($cf) { . $cf } else { Invoke-Expression (& starship init powershell --print-full-init | Out-String) }
        $global:DotfilesInit.Starship = $true
    } catch { Write-DotWarn "starship init failed: $_" }
}
__lap 'starship'

# --- zoxide (smarter cd; `z foo`, `zi` for interactive) -----------------------
if ((Test-Cmd zoxide) -and -not $global:DotfilesInit.Zoxide) {
    $cf = Get-InitCache -Name zoxide -Generate { zoxide init powershell --cmd cd }
    if ($cf) { . $cf } else { Invoke-Expression (& { (zoxide init powershell --cmd cd | Out-String) }) }
    $global:DotfilesInit.Zoxide = $true
}
__lap 'zoxide'

# --- fzf + PSFzf (Ctrl+t files, Ctrl+r history) — LAZY -------------------------
# `Import-Module PSFzf` costs ~260ms (measured) — the single biggest slice of this
# fragment's cost — yet it's dead weight until the moment you press Ctrl+T/Ctrl+R.
# So DEFER it: set the (cheap, child-inherited) env now, bind lightweight stub key
# handlers, and pay the import + install PSFzf's REAL handlers on the FIRST press of
# either chord. The stub scriptblock runs in the SESSION runspace when the key is
# pressed, so the deferred Import-Module lands where the interactive shell sees it —
# an OnIdle event action would import into the eventing runspace instead, so a
# keypress trigger (not an idle one) is the correct deferral here.
#
# Ctrl+R ownership: atuin (loaded below) ignores ATUIN_NOBIND and seizes Ctrl+R on
# init, so the atuin block RE-ASSERTS this lazy Ctrl+R stub afterwards and moves
# atuin's TUI to Ctrl+E to match zsh (Ctrl+E = atuin, Ctrl+R = quick fzf history).
if ((Test-Cmd fzf) -and $script:DotAvailModules.Contains('PSFzf') -and -not $global:DotfilesInit.Fzf) {
    # Layout (hand-authored) + the EXPLICIT tokyonight palette, GENERATED from
    # theme/palette.toml by gen-theme.ps1 so fzf looks identical across the WSL-zsh and
    # Windows-pwsh halves of the fleet. Env is cheap and inherited by child panes, so it
    # stays EAGER — no reason to defer.
    #
    # This block used to be hand-copied under a comment claiming it was "kept
    # byte-for-byte in step with Core's zsh fzf.zsh". It was not: border and scrollbar
    # carried a stale border_highlight, and gutter a bg colour from a different
    # tokyonight style. One --color per line, matching zsh/35-fzf.zsh line for line, is
    # what makes the two readable side by side; the old three-per-line packing is how
    # three wrong values hid in plain sight. Do not hand-edit inside the markers (#228).
    $env:FZF_DEFAULT_OPTS = @(
        '--height=60% --layout=reverse --border=rounded --info=inline'
        # core:theme:gen fzf-colors
        '--color=border:#29a4bd'
        '--color=fg:#c0caf5'
        '--color=gutter:#1d202f'
        '--color=header:#ff9e64'
        '--color=hl:#2ac3de'
        '--color=hl+:#2ac3de'
        '--color=info:#545c7e'
        '--color=marker:#ff007c'
        '--color=pointer:#ff007c'
        '--color=prompt:#2ac3de'
        '--color=query:#c0caf5:regular'
        '--color=scrollbar:#29a4bd'
        '--color=separator:#ff9e64'
        '--color=spinner:#ff007c'
        # core:theme:end fzf-colors
    ) -join ' '
    if (Test-Cmd fd) { $env:FZF_DEFAULT_COMMAND = 'fd --type f --hidden --follow --exclude .git' }

    # One-shot loader: import PSFzf, hand Ctrl+T + Ctrl+R to PSFzf's OWN handlers
    # (Set-PsFzfOption overwrites the stubs below, so every later press skips this),
    # then fire the requested handler for THIS press so the first keystroke isn't
    # swallowed. The Invoke-FzfPsReadlineHandler* names are present from the pinned
    # baseline PSFzf 2.4.0 (packages/modules.ps1) through the current 2.7.10 —
    # verified against both — so the very first press is safe on a fresh box. Setup
    # is wrapped so a broken/removed PSFzf surfaces as a friendly warning instead of
    # a raw error at the prompt (mirrors the starship/atuin/CompletionPredictor guards);
    # the stub stays bound on failure, so a later press simply retries.
    function global:Invoke-DotLoadPSFzf {
        param([ValidateSet('Provider','History')][string]$Action)
        try {
            Import-Module PSFzf -ErrorAction Stop
            Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
        } catch {
            Write-DotWarn "PSFzf lazy init failed: $_" 'reinstall: Install-Module PSFzf -Scope CurrentUser -Force'
            return
        }
        # Handler runs OUTSIDE the try so its own runtime (e.g. an Esc-cancelled fzf)
        # isn't misreported as an init failure.
        switch ($Action) {
            'Provider' { Invoke-FzfPsReadlineHandlerProvider }
            'History'  { Invoke-FzfPsReadlineHandlerHistory }
        }
    }
    # Cheap stubs bound now; the ~260ms import is deferred to first use, off the render path.
    Set-PSReadLineKeyHandler -Chord 'Ctrl+t' -BriefDescription 'PSFzf file picker (lazy load)' -ScriptBlock { Invoke-DotLoadPSFzf -Action Provider }
    Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -BriefDescription 'PSFzf history (lazy load)'      -ScriptBlock { Invoke-DotLoadPSFzf -Action History }
    $global:DotfilesInit.Fzf = $true
}
__lap 'fzf/PSFzf'

# --- mise (runtime/tool version manager; shims + path setup) ------------------
# `mise activate pwsh` installs the per-prompt `mise hook-env` hook that keeps the
# active tool versions / [env] consistent with the nearest .mise.toml / .tool-versions
# as you `cd` around — the Windows equivalent of Core's zsh `mise activate zsh`, and
# the fleet-parity default.
#
# HISTORY: this was briefly switched to `--shims` because the hook cost 0.6-1.2s on
# EVERY prompt — but that turned out to be stacked on-access AV (Malwarebytes + McAfee)
# scanning mise.exe's launch, not mise itself. With the AV exclusions in place,
# `mise hook-env` is ~64ms, so the full hook is back as the default (parity + per-cd env).
#
# Escape hatch for any future slow box (or a machine without the AV fix): set
# DOTFILES_MISE_SHIMS=1 in the User environment BEFORE the shell starts (local.ps1
# loads too late to gate this) to use shims-only mode — a 90-char PATH prepend, no
# prompt hook. Tool versions still resolve via the shims; you just lose mise's per-cd
# env auto-injection (direnv, wired separately, still covers .envrc env).
#
# PSMUX SPLITS ALSO USE SHIMS. Dot-sourcing the full hook-env init is the single most
# expensive step in a pane's cold start — ~195ms of first-run JIT, measured, vs ~12ms
# for the shims init (8.3KB of per-prompt hook code vs a 90-char PATH prepend). A split
# is a fresh pwsh that INHERITS the parent shell's already-resolved env (PATH + the
# [env] mise injected for the starting dir), so shims give correct tool versions with
# no re-activation cost; the only thing traded away is per-cd [env] re-injection WITHIN
# that split (direnv still covers .envrc). Net ~180ms off every split. Pane detection
# is Test-InMux (core/05-lib.ps1). Distinct cache names ('mise' vs 'mise-shims') keep a
# split and a top-level shell from busting each other's cache on the shared mise.ps1.
if ((Test-Cmd mise) -and -not $global:DotfilesInit.Mise) {
    if (($env:DOTFILES_MISE_SHIMS -eq '1') -or (Test-InMux)) {
        $cf = Get-InitCache -Name mise-shims -Generate { mise activate pwsh --shims }
        if ($cf) { . $cf } else { Invoke-Expression (& { (mise activate pwsh --shims | Out-String) }) }
    } else {
        $cf = Get-InitCache -Name mise -Generate { mise activate pwsh }
        if ($cf) { . $cf } else { Invoke-Expression (& { (mise activate pwsh | Out-String) }) }
    }
    $global:DotfilesInit.Mise = $true
}
__lap 'mise'

# --- atuin (shell history sync/search; optional, if installed) ----------------
if ((Test-Cmd atuin) -and -not $global:DotfilesInit.Atuin) {
    $cf = Get-InitCache -Name atuin -Generate { atuin init powershell }
    if ($cf) { . $cf } else { Invoke-Expression (& { (atuin init powershell | Out-String) }) }
    # atuin's pwsh module ignores ATUIN_NOBIND and seizes Ctrl+R + Up/Down on init. For
    # cross-shell parity (PARITY.md: Ctrl+E = atuin TUI, Ctrl+R = quick history, arrows =
    # prefix search), move atuin's interactive search to Ctrl+E and hand the rest back.
    # Invoke-AtuinSearch is the function atuin's init defines for the TUI.
    Set-PSReadLineKeyHandler -Chord 'Ctrl+e' -BriefDescription 'Atuin search' -ScriptBlock { Invoke-AtuinSearch }
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    # Re-assert Ctrl+R AFTER atuin's init seized it. Three cases:
    #   • PSFzf already imported (rare — only if Ctrl+T was pressed mid-load): hand
    #     Ctrl+R straight to PSFzf's real handler.
    #   • PSFzf deferred (the normal path — the lazy block above ran): re-bind the
    #     SAME lazy stub, so atuin's grab is undone and the first Ctrl+R press loads
    #     PSFzf + the fzf history UI.
    #   • PSFzf not installed: hand Ctrl+R to PSReadLine's built-in reverse search so
    #     atuin still ends up on Ctrl+E ONLY (else atuin's init keeps Ctrl+R and the
    #     advertised parity — Ctrl+E atuin, Ctrl+R quick history — silently breaks).
    if (Get-Module PSFzf) {
        Set-PsFzfOption -PSReadlineChordReverseHistory 'Ctrl+r'
    } elseif ($global:DotfilesInit.Fzf) {
        Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -BriefDescription 'PSFzf history (lazy load)' -ScriptBlock { Invoke-DotLoadPSFzf -Action History }
    } else {
        Set-PSReadLineKeyHandler -Key 'Ctrl+r' -Function ReverseSearchHistory
    }
    $global:DotfilesInit.Atuin = $true
}
__lap 'atuin'

# --- carapace (multi-shell completions; optional) -----------------------------
# OFF by default: generating carapace's completion bridge costs ~1.5s on a cold
# shell. pwsh's native completion + CompletionPredictor + atuin cover most needs.
# Opt in (User scope, present at shell start — local.ps1 loads too late):
#   [Environment]::SetEnvironmentVariable('DOTFILES_CARAPACE','1','User')
# When enabled, the init is cached (Get-InitCache) so warm shells skip the spawn.
if ($env:DOTFILES_CARAPACE -eq '1' -and (Test-Cmd carapace) -and -not $global:DotfilesInit.Carapace) {
    $env:CARAPACE_BRIDGES = 'powershell'
    $cf = Get-InitCache -Name carapace -Generate { carapace _carapace powershell }
    if ($cf) { . $cf } else { Invoke-Expression (& { (carapace _carapace powershell | Out-String) }) }
    $global:DotfilesInit.Carapace = $true
}
__lap 'carapace'

# --- Ctrl+G sessionizer + Alt+Z zoxide jump (cross-shell parity, PARITY.md) ----
# Ctrl+G = jump-to-session everywhere (the contract's Option A): pick a project dir
# (zoxide frecency + project roots) and attach-or-create a psmux session for it — the
# bare-prompt host port of zsh's sesh-on-Ctrl+G, mirroring psmux/scripts/psmux-sesh.ps1
# (the in-psmux prefix+f version). This REPLACES navi's old Ctrl+G cheatsheet widget:
# navi now lives in NO shell binding (matching the contract), reachable as the `navi`
# command / the `cheat` helper — which frees Ctrl+G for the sessionizer on both shells.
#
# The key handler types+runs the function as a normal foreground command (RevertLine /
# Insert / AcceptLine), so fzf and the interactive psmux attach behave exactly as they
# would when typed — no nested-readline weirdness. We call `psmux new-session -A`
# directly (the body of the os-layer `mux` verb, inlined) so this core fragment carries
# no dependency on a later-loading os fragment; psmux itself is checked at run time.
if (Test-Cmd fzf) {
    function Invoke-DotfilesSessionizer {
        if (-not (Test-Cmd psmux)) {
            Write-DotErr 'sessionizer: psmux not on PATH' 'install psmux (scoop install psmux)'
            return
        }
        $dirs = [System.Collections.Generic.List[string]]::new()
        if (Test-Cmd zoxide) { zoxide query -l 2>$null | ForEach-Object { if ($_) { $dirs.Add($_) } } }
        foreach ($root in @("$HOME\Projects", "$HOME\dev", "$HOME\work", "$HOME\.config")) {
            if (Test-Path $root) {
                Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { $dirs.Add($_.FullName) }
            }
        }
        if ($dirs.Count -eq 0) { return }
        # fzf runs --preview via its OWN shell, so quote {} for paths with spaces (same
        # rule fif documents). eza is optional on the host (falls back elsewhere), so only
        # add the preview when it's present — Ctrl+G stays usable without it.
        $fzfArgs = @('--prompt', 'session > ')
        if (Test-Cmd eza) { $fzfArgs += @('--preview', 'eza --icons --tree --level=1 --color=always "{}"') }
        $pick = $dirs | Sort-Object -Unique | fzf @fzfArgs
        if (-not $pick) { return }
        $name = (Split-Path $pick -Leaf).ToLower() -replace '[ .]', '_'
        Set-Location -LiteralPath $pick
        psmux new-session -A -s $name   # attach-or-create (the `mux` verb, inlined)
    }
    Set-PSReadLineKeyHandler -Chord 'Ctrl+g' -BriefDescription 'Sessionizer (dir -> psmux session)' -ScriptBlock {
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert('Invoke-DotfilesSessionizer')
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
}
# Alt+Z = zoxide frecency jump (matches zsh's Alt+Z). zoxide's own `zi` already drives
# the fzf picker, so just run it.
if (Test-Cmd zoxide) {
    Set-PSReadLineKeyHandler -Chord 'Alt+z' -BriefDescription 'zoxide interactive jump' -ScriptBlock {
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert('zi')
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
}
__lap 'sessionizer/altz'
