# ============================================================================
#  os/30-windows.ps1  -  native Windows host helpers (scoop / winget / paths)
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: scu, scs, sci, scl, sccl, wgu, wgs, wgi, update-host, path, open, admin, setenv, getenv, modules-localize
# requires: Get-DotModulePrunePlan, Test-Cmd, Test-InMux, Test-InteractiveShell, up, Write-DotErr, Write-DotHost, Write-DotWarn

# --- scoop (your primary CLI package manager on the host) ---------------------
if (Test-Cmd scoop) {
    function scu  { scoop update * @args }            # update all apps
    function scs  { scoop search @args }
    # Named (remaining-args) param so the tab-completer in 50-completions.ps1 can
    # offer the apps this repo manages; behaviour is identical to `scoop install`.
    function sci  { param([Parameter(ValueFromRemainingArguments)][string[]]$App) scoop install @App }
    function scl  { scoop list @args }
    function sccl { scoop cleanup * ; scoop cache rm * }
}

# --- winget (GUI apps + things not in scoop) ----------------------------------
if (Test-Cmd winget) {
    function wgu { winget upgrade --all --include-unknown }
    function wgs { param($q) winget search $q }
    function wgi { param($id) winget install --id $id -e }
}

# --- full host update in one shot ---------------------------------------------
# Delegates to `up` (core/15-update.ps1) which also clears the nudge cache.
# Kept as a muscle-memory alias; `up` is the canonical implementation.
function update-host { up @args }

# --- PATH inspection ----------------------------------------------------------
function path { $env:PATH -split ';' | Where-Object { $_ } }

# --- reveal in Explorer / open ------------------------------------------------
function open { param($Target = '.') Invoke-Item $Target }
Set-Alias explorer-here open

# --- elevate the current shell (sudo-ish) -------------------------------------
# Windows 11 has a native `sudo`; fall back to a Start-Process relaunch.
function admin {
    if (Test-Cmd sudo) { sudo @args; return }
    if ($args.Count -gt 0) {
        # Re-quote any argument that contains whitespace so a relaunched command
        # like `admin code "C:\Program Files\x"` survives the join into -Command
        # instead of being split into separate tokens.
        $cmd = ($args | ForEach-Object {
            if ($_ -match '\s') { '"' + ($_ -replace '"', '`"') + '"' } else { "$_" }
        }) -join ' '
        Start-Process pwsh -Verb RunAs -ArgumentList @('-NoExit', '-Command', $cmd)
    } else {
        Start-Process pwsh -Verb RunAs
    }
}

# --- env var helpers ----------------------------------------------------------
function setenv  { param($Name,$Value) [Environment]::SetEnvironmentVariable($Name,$Value,'User'); Set-Item "env:$Name" $Value }
function getenv  { param($Name) [Environment]::GetEnvironmentVariable($Name,'User') }

# --- modules-localize: move PowerShell modules OFF OneDrive (one-time) ---------
# Importing modules from a OneDrive-synced Documents\PowerShell\Modules folder
# adds seconds to every shell start. profile.ps1 already prepends a local modules
# dir to $env:PSModulePath; this copies your existing CurrentUser modules there so
# imports resolve from local disk. Run it ONCE, ideally from `pwsh -NoProfile` so
# no module DLLs are locked. Idempotent — safe to re-run.
#
# -Prune (B11): after copying, reconcile the local dir against the MANAGED module
# set (packages/modules.ps1) — every maint roll-forward leaves the old version
# beside the new one, so the dir accumulates. Prune keeps the highest version of
# each managed module and removes the stale ones. Conservative: it never touches a
# module you aren't managing. Safe to run on its own (copy is skipped if there's
# no OneDrive source to pull from).
function modules-localize {
    param([switch]$Prune)
    $src = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
    $dst = Join-Path $env:LOCALAPPDATA 'PowerShell\Modules'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null

    # --- copy pass (only when there's an OneDrive source to pull from) ---------
    if (Test-Path $src) {
        if ($src -notlike '*OneDrive*') {
            Write-DotHost "your modules path isn't under OneDrive ($src) — no move needed." -Color DarkYellow
        }
        Write-DotHost "copying modules to local disk" -Color Cyan
        Write-DotHost "  from $src" -Color DarkGray
        Write-DotHost "  to   $dst" -Color DarkGray
        # /E copy (not /MOVE): leaves the OneDrive copies in place so a module loaded
        # in THIS session can't block the operation. The prepend makes the local copy
        # win regardless; delete the OneDrive Modules folder by hand later if you like.
        robocopy $src $dst /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-DotErr "robocopy failed (exit $LASTEXITCODE)" 'check that the source/destination paths are writable, then retry'; return }
        Write-DotHost "done — open a NEW shell. Modules now load from $dst (off OneDrive)." -Color Green
        Write-DotHost "verify with: (Get-Module -ListAvailable PSReadLine).Path" -Color DarkGray
    } elseif (-not $Prune) {
        Write-Host "no user modules at $src (nothing to move)"; return
    }

    # --- prune pass (opt-in): drop stale versions of MANAGED modules -----------
    if ($Prune) {
        $managed = @()
        $pins = if ($global:DOTFILES) { Join-Path $global:DOTFILES 'packages\modules.ps1' } else { $null }
        if ($pins -and (Test-Path $pins)) { . $pins; $managed = @($script:MaintModuleNames) }
        if (-not $managed) { $managed = @($MaintModuleNames) }   # scope fallback
        if (-not $managed) {
            Write-DotWarn 'no managed module list — skipping prune.' 'ensure $DOTFILES/packages/modules.ps1 is present'
            return
        }
        # Discover the Name/Version dirs under the local store (Modules/<Name>/<Version>).
        $installed = foreach ($md in Get-ChildItem $dst -Directory -ErrorAction SilentlyContinue) {
            foreach ($vd in Get-ChildItem $md.FullName -Directory -ErrorAction SilentlyContinue) {
                [pscustomobject]@{ Name = $md.Name; Version = $vd.Name; Path = $vd.FullName }
            }
        }
        $plan = @(Get-DotModulePrunePlan -Installed $installed -ManagedNames $managed)
        if (-not $plan.Count) {
            Write-DotHost "prune: managed modules already at a single version — nothing stale." -Color DarkGray
            return
        }
        # Remove each stale dir, then VERIFY it's actually gone — a version that's
        # loaded in another shell can have a locked DLL, and -ErrorAction
        # SilentlyContinue would otherwise let us falsely report it pruned.
        $removed = 0; $stuck = 0
        foreach ($p in $plan) {
            Remove-Item -LiteralPath $p.Path -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $p.Path) {
                Write-DotWarn "could not remove $($p.Name) $($p.Version) (in use?)" 'close shells using it (or run from pwsh -NoProfile), then re-run -Prune'
                $stuck++
            } else {
                Write-DotHost "  pruned $($p.Name) $($p.Version)" -Color DarkGray
                $removed++
            }
        }
        if ($removed) { Write-DotHost "prune: removed $removed stale version(s) of managed modules." -Color Green }
        if ($stuck)   { Write-DotWarn "$stuck stale version(s) could not be removed (likely locked by a running shell)." }
    }
}

# --- Start psmux session (top-level interactive shell only) -------------------
# Pane detection is Test-InMux (core/05-lib.ps1) — the single source of truth,
# shared with os/33-psmux-pill.ps1. If a shell that IS in a pane weren't
# recognised we'd auto-launch a NESTED session, so the marker set (TMUX +
# PSMUX_SESSION, verified against psmux src/pane.rs) lives in exactly one place.
$InMux = Test-InMux

# Only auto-launch for a *top-level interactive* shell. The profile is ALSO
# loaded for `pwsh -Command ...` / `pwsh -File ...` (VS Code tasks, git hooks,
# scheduled scripts, other tooling) unless they pass -NoProfile — and attaching
# a multiplexer there would hang or hijack the scripted call. Test-InteractiveShell
# (core/05-lib.ps1) inspects the actual process command line and host; it's shared
# with core/15-update.ps1's daily-check guard so the "is this a real interactive
# session?" rule lives in ONE place instead of drifting between two copies.
#
# Escape hatch: set PSMUX_NO_AUTOLAUNCH=1 to suppress the auto-attach and stay in
# a bare pwsh shell (parity with FAST_START / DOTFILES_UPDATE_CHECK). Read from the
# ENVIRONMENT, so it must be set before pwsh starts — for a one-off lean shell:
#   $env:PSMUX_NO_AUTOLAUNCH='1'; pwsh        # child inherits it
# or permanently on this box:
#   [Environment]::SetEnvironmentVariable('PSMUX_NO_AUTOLAUNCH','1','User')
# This is the off-switch to reach for if psmux ever misbehaves on launch and you
# need a prompt without it (you can still run `mux` by hand afterward).
#
# Also skip over ssh ($env:SSH_CONNECTION set — Windows OpenSSH sets it): arriving
# over ssh you're normally already inside a multiplexer on the client, so auto-
# attaching here just nests a mux you'd close anyway. Run `mux` by hand if you do
# want a server-side session. Fleet-wide policy, mirrored in dotfiles-Debian's
# os/debian.zsh tmux auto-attach.
if ((Test-Cmd psmux) -and -not $InMux -and -not $env:PSMUX_AUTOLAUNCHED -and
    $env:PSMUX_NO_AUTOLAUNCH -ne '1' -and -not $env:SSH_CONNECTION -and
    (Test-InteractiveShell)) {
    $env:PSMUX_AUTOLAUNCHED = '1'
    psmux new-session -A -s Gerrrt
}
