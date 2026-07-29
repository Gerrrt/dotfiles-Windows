# ============================================================================
#  core/00-aliases.ps1  -  cross-fleet aliases (parity with your zsh aliases)
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: Test-Cmd, Get-DotCmdEntry, Export-DotCmdCache, Test-CmdRuns, ls, l, ll, la, lt, llt, cat, catp, grep, http, https, gmd, dns, web, du, pss, watch, hex, loc, df, fm, y, top, htop, tree, ping, cdi, notes, g, gs, gst, gss, gsb, ga, gaa, gap, gc, gcm, gca, gcam, gc!, gcn!, gb, gba, gbd, gbm, gco, gcb, gcom, gsw, gswc, gswm, gd, gds, gdw, glog, gloga, glol, glola, gf, gfa, gl, gpr, gp, gpu, gpf, gpf!, gsta, gstaa, gstp, gstl, gstd, grb, grbi, grbm, grbc, grba, grh, grhh, grs, grss, gr, grv, gm, gma, gdft, jjs, jjl, jjd, lg, .., ..., ...., ~, mkcd, which, reload, dotfiles
# requires: Write-DotHost
# PowerShell has built-in aliases (ls, cat, cp...) that point at cmdlets.
# We remove the ones we want to override, then define functions that shadow
# them with the modern Rust tools. Functions (not Set-Alias) are used where we
# need to pass default flags.

# --- helper: define a function-backed alias only if the tool exists -----------
# MEMOIZED, two tiers. Get-Command does a PATH scan for an external tool; the fleet
# checks the same handful of tools (rg, fzf, eza, psmux…) from MANY fragments, and
# psmux alone is probed at top level from three os/ files. Worse, a MISS is the
# expensive case — to prove a name is absent Get-Command stats every PATHEXT variant
# in every PATH dir, an on-access-AV stat-storm on Windows — and 00-aliases below
# fires ~21 first-time probes for tools that may not be installed.
#
#   • in-memory (session):  Get-DotCmdEntry caches the resolved command per name, so
#     repeated probes across fragments collapse to one lookup each. The entry carries
#     both Found (for Test-Cmd) and Source (the resolved path, reused by Get-InitCache
#     in 10-tools instead of a second Get-Command — see P3).
#   • on-disk (cross-session):  the load-time block below seeds that map from a file
#     written by the previous shell, so a cold start / psmux split skips the stat-storm
#     entirely. The file is keyed by a PATH fingerprint (Get-DotCmdCacheFingerprint),
#     so installing or removing a tool self-busts it; Export-DotCmdCache (called from
#     profile.ps1 after all fragments load) flushes newly-probed names back.
#
# The in-memory map is a session global reset on every `reload` (this fragment re-runs
# top to bottom), then re-seeded from disk — so a tool installed mid-session is picked
# up after `reload` (the install bumps a PATH dir's mtime, changing the fingerprint,
# which discards the stale on-disk entries and forces a live re-probe).
$global:DotfilesCmdCache = @{}

# Resolve a name once, caching the outcome as a small {Found, Source} record. Every
# cached value is a non-null object, so a present key (hit, positive OR negative) is
# truthy and an absent key ($null) is the only miss — no cached-$false ambiguity.
function Get-DotCmdEntry {
    param([string]$Name)
    $hit = $global:DotfilesCmdCache[$Name]
    if ($hit) { return $hit }
    $cmd   = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    $entry = [pscustomobject]@{ Found = [bool]$cmd; Source = $cmd.Source }
    $global:DotfilesCmdCache[$Name] = $entry
    $global:DotfilesCmdCacheDirty   = $true   # a live probe happened; profile.ps1 flushes at load end
    return $entry
}
function Test-Cmd {
    param([string]$Name)
    (Get-DotCmdEntry $Name).Found
}

# --- cross-session command-resolution cache (P6) ------------------------------
# A cheap signature of "which commands could resolve on PATH". It changes when the
# PATH string changes OR when any existing PATH directory's contents change —
# installing/removing a shim bumps that directory's LastWriteTime on NTFS — so a
# scoop/winget install or uninstall self-busts the cache. A mere version UPGRADE
# (same shim path) does not, which is correct: Test-Cmd only cares that a name
# resolves, and Get-InitCache re-stats the actual binary's mtime itself. Directory
# metadata reads are NOT executable launches, so they dodge the on-access-AV storm
# this whole cache exists to avoid. No dependency on 05-lib helpers — this fragment
# loads before 05-lib, so the SHA is computed inline.
function script:Get-DotCmdCacheFingerprint {
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add([string]$env:PATHEXT)
    foreach ($dir in ($env:PATH -split ';')) {
        if (-not $dir) { continue }
        # GetLastWriteTimeUtc returns a sentinel (not a throw) for a missing dir, so a
        # PATH entry that doesn't exist contributes a stable constant. try/catch guards
        # only genuinely malformed paths.
        try { $parts.Add("$dir|$([System.IO.Directory]::GetLastWriteTimeUtc($dir).Ticks)") }
        catch { $parts.Add("$dir|x") }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($parts -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

# Seed $global:DotfilesCmdCache from the on-disk file IF its fingerprint still matches.
# The path is resolved null-safely: a host with no LOCALAPPDATA leaves the file $null,
# which DISABLES the on-disk tier entirely (Export-DotCmdCache no-ops too) rather than
# letting `Join-Path $null …` throw and abort profile load. Otherwise best-effort — an
# unreadable/partial file just leaves the map empty (the fingerprint check won't match)
# and every probe falls back to a live Get-Command. Line 1 is the fingerprint marker.
$global:DotfilesCmdCacheFp    = script:Get-DotCmdCacheFingerprint
$global:DotfilesCmdCacheDirty = $false
$global:DotfilesCmdCacheFile  = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'dotfiles\cmd-cache.txt' } else { $null }
try {
    if ($global:DotfilesCmdCacheFile -and (Test-Path $global:DotfilesCmdCacheFile)) {
        $lines = Get-Content $global:DotfilesCmdCacheFile -ErrorAction Stop
        if ($lines -and $lines[0] -eq "# fp: $global:DotfilesCmdCacheFp") {
            foreach ($ln in ($lines | Select-Object -Skip 1)) {
                if (-not $ln) { continue }
                $f, $name, $src = $ln -split "`t", 3
                if (-not $name) { continue }
                $global:DotfilesCmdCache[$name] = [pscustomobject]@{
                    Found  = ($f -eq '1')
                    Source = if ($src) { $src } else { $null }
                }
            }
        }
    }
} catch { }

# Flush newly-probed names back to disk under the current fingerprint. Called from
# profile.ps1 AFTER every fragment has loaded (so 10-tools' probes are captured too),
# which runs in the session runspace where these globals live — an OnIdle handler runs
# in the eventing runspace and couldn't see them. No-op when nothing new was probed
# (a full on-disk hit), so warm shells and psmux splits never rewrite the file.
function Export-DotCmdCache {
    # Skip when nothing new was probed (full on-disk hit) or the on-disk tier is
    # disabled ($global:DotfilesCmdCacheFile is $null — no LOCALAPPDATA on this host).
    if (-not $global:DotfilesCmdCacheDirty -or -not $global:DotfilesCmdCacheFile) { return }
    try {
        $dir = Split-Path -Parent $global:DotfilesCmdCacheFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $out = [System.Collections.Generic.List[string]]::new()
        $out.Add("# fp: $global:DotfilesCmdCacheFp")
        foreach ($k in $global:DotfilesCmdCache.Keys) {
            $e = $global:DotfilesCmdCache[$k]
            $out.Add(("{0}`t{1}`t{2}" -f $(if ($e.Found) { '1' } else { '0' }), $k, $e.Source))
        }
        Set-Content -Path $global:DotfilesCmdCacheFile -Value $out -Encoding utf8
        $global:DotfilesCmdCacheDirty = $false
    } catch { }
}

# --- helper: does a command RESOLVE *and* actually launch? ---------------------
# Test-Cmd only proves a NAME resolves (Get-Command). A dead/dangling shim — e.g.
# a leftover Chocolatey shim whose target was removed, or a scoop shim pointing at
# an uninstalled app — still resolves fine, then errors with "Program X failed to
# run" / "cannot find file" the instant you invoke it. Test-CmdRuns probes one step
# further: it actually launches the tool (a cheap version flag) and reports whether
# it started. Exit code is deliberately ignored — some tools return non-zero for an
# unknown flag yet are perfectly runnable; we only care that the process LAUNCHED,
# so the only failure signal is a thrown native-launch error. Used by fif/fbr and
# dotfiles-doctor so a broken shim surfaces as an actionable hint, not a raw error.
function Test-CmdRuns {
    param([string]$Name, [string[]]$ProbeArgs = @('--version'))
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { return $false }
    # Local Continue so a non-zero exit can't throw under pwsh 7.4+'s
    # $PSNativeCommandUseErrorActionPreference — only a real launch failure should.
    $ErrorActionPreference = 'Continue'
    try { & $Name @ProbeArgs *> $null; return $true }
    catch { return $false }
}

# --- ls -> eza (fall back to lsd, then Get-ChildItem) -------------------------
Remove-Item Alias:ls -ErrorAction SilentlyContinue
if (Test-Cmd eza) {
    function ls  { eza --icons --group-directories-first @args }
    function l   { eza --icons --group-directories-first -1 @args }
    function ll  { eza --icons --group-directories-first -lh --git @args }
    function la  { eza --icons --group-directories-first -lha --git @args }
    function lt  { eza --icons --tree --level=2 @args }
    function llt { eza --icons --tree --level=3 -lh @args }
} elseif (Test-Cmd lsd) {
    function ls  { lsd --group-directories-first @args }
    function ll  { lsd -lh --group-directories-first @args }
    function la  { lsd -lha --group-directories-first @args }
    function lt  { lsd --tree --depth 2 @args }
} else {
    function ll  { Get-ChildItem @args | Format-Table -AutoSize }
    function la  { Get-ChildItem -Force @args | Format-Table -AutoSize }
}

# --- cat -> bat ---------------------------------------------------------------
if (Test-Cmd bat) {
    Remove-Item Alias:cat -ErrorAction SilentlyContinue
    function cat { bat --paging=never @args }
    function catp { bat @args }                         # paged view
    $env:BAT_THEME = 'ansi'   # follow the terminal palette (Tokyo Night)
    # NOTE: MANPAGER is intentionally NOT set here — `sh` doesn't exist on the
    # native Windows host. Wire it inside WSL/git-bash contexts instead.
}

# --- find / grep --------------------------------------------------------------
if (Test-Cmd rg) { function grep { rg --smart-case @args } }
# fd is already named `fd` on Windows (no fd-find rename like Debian)

# --- 2026 modern stack additions (all guarded; classics untouched) ------------
# Parity with Core's aliases.zsh. Each is a distinct verb so it never shadows the
# classic tool in scripts.
if (Test-Cmd xh)    { function http  { xh @args }; function https { xh --https @args } }  # Rust HTTPie — poke APIs/web targets
# render markdown; `gmd` avoids shadowing the built-in `md`/mkdir. Only page when a
# pager exists — glow's default pager is `less`, absent on a stock Windows box, which
# otherwise makes `glow --pager` abort with `exec: "less" not found`.
if (Test-Cmd glow)  { function gmd { if ($env:PAGER -or (Test-CmdRuns less)) { glow --pager @args } else { glow @args } } }
if (Test-Cmd doggo) { function dns   { doggo @args } }                                     # modern dig (DNS recon)
# gron / sd / jq / yq / jnv are their own commands (no alias — never shadow sed/jq usage in
# scripts). jnv is the interactive JSON explorer — run `jnv file.json` or pipe into it (the
# "explore" verb to jq's "transform" and gron's "grep").
# terminal web browser — parity with Core's `web` verb. w3m has no scoop manifest, but lynx
# does (packaged in scoopfile.json); prefer whatever text browser is present, same resolution
# order as Core's 00-tools.zsh. Baked as a literal per branch (a captured $var would be out of
# scope by call time). GUI-first host, so — unlike Core's headless path — we never export
# $BROWSER; `web` stays an opt-in verb and is skipped entirely when no text browser is installed.
if     (Test-Cmd w3m)    { function web { w3m @args } }
elseif (Test-Cmd lynx)   { function web { lynx @args } }
elseif (Test-Cmd links)  { function web { links @args } }
elseif (Test-Cmd elinks) { function web { elinks @args } }

# --- 2026 batch 2: system inspection & utilities (all guarded) ----------------
# dust: visual disk-usage tree (du replacement).
if (Test-Cmd dust)  { function du    { dust @args } }

# procs: colorized, searchable process viewer (ps replacement).
# PowerShell's `ps` alias points at Get-Process; we use `pss` (process-search) to
# avoid shadowing it — `pss nvim`, `pss --tree` etc.
if (Test-Cmd procs) { function pss   { procs @args } }

# viddy: modern `watch` — Windows has no native watch. `watch -n 2 'git status'`.
if (Test-Cmd viddy) { function watch { viddy @args } }

# hexyl: colored hex viewer. `hex binary-file`.
if (Test-Cmd hexyl) { function hex   { hexyl @args } }

# tokei: lines-of-code counter by language. `loc` for muscle memory.
if (Test-Cmd tokei) { function loc   { tokei @args } }

# --- 2026 batch 3: parity with the rest of Core's aliases.zsh (all guarded) ----
# duf: modern, mountpoint-aware disk-free (df replacement). `df` isn't a native
# Windows command, so this adds the verb rather than shadowing one.
if (Test-Cmd duf)  { function df    { duf @args } }

# yazi: TUI file manager. Same two verbs Core exposes (`fm`/`y`).
if (Test-Cmd yazi) { function fm    { yazi @args }; function y { yazi @args } }

# btop: process/resource monitor (top/htop replacement). Neither `top` nor `htop`
# is a native Windows command, so these are additive verbs.
if (Test-Cmd btop) { function top   { btop @args }; function htop { btop @args } }

# eza --tree: `tree` (Core aliases it too). Shadows cmd.exe's `tree` with the icon
# tree when eza is present; a bare box keeps the classic `tree`.
if (Test-Cmd eza)  { function tree  { eza --tree --icons=auto @args } }

# gping: ping with a live latency graph. Core does `ping`→gping when installed;
# mirror it (the classic `ping.exe` returns on a bare box). gping ships via scoop.
if (Test-Cmd gping) { function ping { gping @args } }

# zoxide interactive jump verb. `cd` is already zoxide (init --cmd cd, 10-tools);
# `cdi` is the fzf picker, matching Core's `cdi`→`zi`. `zi` is defined by zoxide's
# init (loaded in 10-tools) and resolved at call time, so the load order is fine.
if (Test-Cmd zoxide) { function cdi { zi @args } }

# notes: jump to the notes dir and open it in the editor (Core's `notes` alias).
# NOTES_DIR mirrors Core's default of ~/Notes; override it in local.ps1.
function notes { $d = if ($env:NOTES_DIR) { $env:NOTES_DIR } else { Join-Path $HOME 'Notes' }; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }; Set-Location $d; if (Test-Cmd nvim) { nvim . } }

# --- git shorthands (full parity with Core's zsh/git.zsh) ---------------------
# The complete OMZ-style set from Core's git.zsh, so the ~55 `g*` verbs carry
# across the WSL-zsh and Windows-pwsh halves of the fleet. `gl` PULLS (Core's omz
# convention), `glog` is the graph log, and `gpf` is the SAFE force
# (--force-with-lease), matching Core exactly.
#
# PowerShell ships built-in ALIASES that OUTRANK same-named functions
# (about_Command_Precedence: Alias > Function), so `function gc {…}` on its own is
# shadowed by the stock `gc`→Get-Content alias — the same reason `ls`/`cat` above
# are Remove-Item'd before their functions. Remove the built-in aliases that
# collide with a git shorthand so the functions below actually win. -Force clears
# ReadOnly ones; SilentlyContinue no-ops where an edition doesn't define one.
#   gc→Get-Content  gcm→Get-Command  gp→Get-ItemProperty
#   gl→Get-Location  gm→Get-Member   gcb→Get-Clipboard
foreach ($a in 'gc', 'gcm', 'gp', 'gl', 'gm', 'gcb') {
    Remove-Item "Alias:$a" -Force -ErrorAction SilentlyContinue
}

# Resolve the repo's trunk (main/master/trunk/…) like Core's git_main_branch(), so
# gcom/gswm/grbm target the real default branch instead of assuming "main". script:
# scoped (private to this fragment), mirroring 10-tools' `function script:__lap`.
function script:Get-DotGitMainBranch {
    foreach ($ref in @(
            'refs/heads/main', 'refs/heads/trunk', 'refs/heads/mainline', 'refs/heads/default', 'refs/heads/stable', 'refs/heads/master',
            'refs/remotes/origin/main', 'refs/remotes/origin/trunk', 'refs/remotes/origin/mainline', 'refs/remotes/origin/default', 'refs/remotes/origin/stable', 'refs/remotes/origin/master',
            'refs/remotes/upstream/main', 'refs/remotes/upstream/master')) {
        git show-ref --quiet --verify $ref 2>$null
        if ($LASTEXITCODE -eq 0) { return ($ref -replace '.*/', '') }
    }
    'master'
}

# git itself + status / inspection
function g    { git @args }
function gs   { git status -sb @args }            # Windows-kept extra; == gsb
function gst  { git status @args }
function gss  { git status --short @args }
function gsb  { git status --short --branch @args }
# staging
function ga   { git add @args }
function gaa  { git add --all @args }
function gap  { git add --patch @args }
# commit
function gc   { git commit --verbose @args }
function gcm  { git commit --message @args }
function gca  { git commit --verbose --all @args }
function gcam { git commit --all --message @args }
function gc!  { git commit --verbose --amend @args }
function gcn! { git commit --verbose --no-edit --amend @args }
# branch
function gb   { git branch @args }
function gba  { git branch --all @args }
function gbd  { git branch --delete @args }        # NB: gbD (force) can't coexist — pwsh is case-insensitive; use `gbd -D`
function gbm  { git branch --move @args }
# checkout / switch
function gco  { git checkout @args }
function gcb  { git checkout -b @args }
function gcom { git checkout (Get-DotGitMainBranch) @args }
function gsw  { git switch @args }
function gswc { git switch --create @args }
function gswm { git switch (Get-DotGitMainBranch) @args }
# diff
function gd   { git diff @args }
function gds  { git diff --staged @args }
function gdw  { git diff --word-diff @args }
# log
function glog  { git log --oneline --decorate --graph @args }
function gloga { git log --oneline --decorate --graph --all @args }
function glol  { git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' @args }
function glola { git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --all @args }
# fetch / pull / push
function gf   { git fetch @args }
function gfa  { git fetch --all --prune --tags @args }
function gl   { git pull @args }
function gpr  { git pull --rebase @args }
function gp   { git push @args }
function gpu  { git push --set-upstream origin (git branch --show-current) @args }
function gpf  { git push --force-with-lease @args }   # safe force (upgrade vs OMZ)
function gpf! { git push --force @args }               # raw force, explicit
# stash
function gsta  { git stash push @args }
function gstaa { git stash push --include-untracked @args }
function gstp  { git stash pop @args }
function gstl  { git stash list @args }
function gstd  { git stash drop @args }
# rebase
function grb   { git rebase @args }
function grbi  { git rebase --interactive @args }
function grbm  { git rebase (Get-DotGitMainBranch) @args }
function grbc  { git rebase --continue @args }
function grba  { git rebase --abort @args }
# reset / restore
function grh   { git reset @args }
function grhh  { git reset --hard @args }
function grs   { git restore @args }
function grss  { git restore --staged @args }
# remote / merge
function gr    { git remote @args }
function grv   { git remote --verbose @args }
function gm    { git merge @args }
function gma   { git merge --abort @args }
# lazygit launcher
if (Test-Cmd lazygit) { function lg { lazygit @args } }

# gdft: difftastic structural diff via git's difftool (Core's `gdft`). Guarded so
# it only exists when difftastic is installed (git/.gitconfig defines the tool).
if (Test-Cmd difft) { function gdft { git difftool --tool=difftastic @args } }

# jujutsu (jj) — opt-in, colocated git companion (never shadows git). Core's
# jjs/jjl/jjd. Guarded on jj, so they simply don't exist on a box without it.
if (Test-Cmd jj) {
    function jjs { jj status @args }
    function jjl { jj log @args }
    function jjd { jj diff @args }
}

# --- navigation ---------------------------------------------------------------
function ..    { Set-Location .. }
function ...   { Set-Location ..\.. }
function ....  { Set-Location ..\..\.. }
function ~     { Set-Location $HOME }
function mkcd  { param($p) New-Item -ItemType Directory -Force -Path $p | Out-Null; Set-Location $p }

# --- misc quality-of-life -----------------------------------------------------
function which {
    param($n)
    $cmd = Get-Command $n -ErrorAction SilentlyContinue
    if (-not $cmd) { return }
    # External apps/scripts have a .Source path; our own functions/aliases don't,
    # so fall back to the resolved name + kind (zsh `which` resolves those too).
    if ($cmd.Source) { return $cmd.Source }
    switch ($cmd.CommandType) {
        'Alias'    { "$n -> $($cmd.Definition)" }
        'Function' { "$n is a function" }
        default    { "$n ($($cmd.CommandType))" }
    }
}
function reload { . $PROFILE; Write-DotHost 'profile reloaded' -Color Green }
function dotfiles { Set-Location $global:DOTFILES }

# --- Neovim ----------------------------------------------------------------
# Guarded like every other tool wiring above: only claim `vim` if nvim exists,
# so a fresh box (pre-bootstrap) keeps any real vim on PATH.
if (Test-Cmd nvim) { Set-Alias vim nvim }
