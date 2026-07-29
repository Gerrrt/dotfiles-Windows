# ============================================================================
#  nvim-sync.ps1  -  refresh nvim/ from dotfiles-core (standalone; NO subtree)
#
#  dotfiles-Windows is a STANDALONE repo. It does not vendor Core as a subtree,
#  because PowerShell can't consume Core's zsh/tmux/bash layers — the only Core
#  asset worth sharing on the host is the Neovim Lua tree. This script is the
#  small, deliberate sync that keeps nvim/ in lockstep with Core, the way the
#  subtree does automatically on the Unix repos.
#
#  Usage (from the repo root):
#    .\nvim-sync.ps1                                  # shallow-clone the remote, copy nvim/
#    .\nvim-sync.ps1 -CoreLocal C:\src\dotfiles-core  # copy from an existing clone instead
#    .\nvim-sync.ps1 -Branch dev                      # sync from a different Core branch
#    .\nvim-sync.ps1 -Ref v1.4.0                       # pin an exact Core commit/tag (reproducible)
#
#  After it runs: review `git diff nvim/`, then commit. lazy-lock.json IS synced
#  (it pins plugin commit SHAs, which are cross-platform — same as the Unix fleet).
# ============================================================================
[CmdletBinding()]
param(
    [string]$CoreRemote = 'https://github.com/dotgibson/dotfiles-core.git',
    [string]$Branch     = 'main',
    [string]$CoreLocal,
    # Pin an EXACT Core commit/tag for a reproducible re-vendor (B1). Takes
    # precedence over -Branch; can't be combined with -CoreLocal (which copies a
    # local working tree as-is). Validated/resolved by Get-NvimSyncRefPlan.
    [string]$Ref
)

# --- Get-NvimSyncRefPlan ------------------------------------------------------
# Pure: decide what to fetch from the remote — a pinned -Ref (commit/tag, the
# reproducible case) or the -Branch tip — and reject the illegal combinations up
# front. Returns { Mode = 'ref'|'branch'; Target; Label }. Unit-tested via the
# DOTFILES_NVIMSYNC_LIBONLY hook below.
function Get-NvimSyncRefPlan {
    [OutputType([pscustomobject])]
    param([string]$Ref, [string]$Branch = 'main', [string]$CoreLocal)
    if ($Ref -and $Ref.StartsWith('-')) {
        throw "invalid -Ref '$Ref': a git ref cannot start with '-'."
    }
    if ($Ref -and $CoreLocal) {
        throw '-Ref re-vendors from the remote and cannot be combined with -CoreLocal. Check out the ref in your local clone and pass -CoreLocal alone, or drop -CoreLocal to fetch the pinned ref.'
    }
    if ($Ref) { return [pscustomobject]@{ Mode = 'ref'; Target = $Ref; Label = "pinned ref $Ref" } }
    return [pscustomobject]@{ Mode = 'branch'; Target = $Branch; Label = "branch $Branch" }
}

# Library-only hook for the test suite: expose the resolver without syncing.
if ($env:DOTFILES_NVIMSYNC_LIBONLY -eq '1') { return }

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Target   = Join-Path $RepoRoot 'nvim'
$plan     = Get-NvimSyncRefPlan -Ref $Ref -Branch $Branch -CoreLocal $CoreLocal

$tempClone = $null
try {
    # --- resolve the source nvim tree ----------------------------------------
    if ($CoreLocal) {
        $srcNvim = Join-Path $CoreLocal 'nvim'
        if (-not (Test-Path $srcNvim)) { throw "no nvim/ under -CoreLocal path: $CoreLocal" }
        Write-Host "Using local Core clone: $srcNvim" -ForegroundColor Cyan
    } else {
        $tempClone = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-core-" + [guid]::NewGuid().ToString('N'))
        if ($plan.Mode -eq 'ref') {
            # Fetch an EXACT commit/tag shallowly: a --branch clone can't name an
            # arbitrary commit, so init + fetch the ref + detach onto it. GitHub
            # allows fetching a reachable SHA directly.
            Write-Host "Fetching $CoreRemote @ $($plan.Target) (pinned)..." -ForegroundColor Cyan
            git init -q $tempClone
            if ($LASTEXITCODE -ne 0) { throw "git init failed (exit $LASTEXITCODE)" }
            git -C $tempClone remote add origin $CoreRemote
            git -C $tempClone fetch --depth 1 origin $plan.Target
            if ($LASTEXITCODE -ne 0) { throw "git fetch '$($plan.Target)' failed (exit $LASTEXITCODE) - is that ref pushed to the remote?" }
            git -C $tempClone checkout -q --detach FETCH_HEAD
            if ($LASTEXITCODE -ne 0) { throw "git checkout FETCH_HEAD failed (exit $LASTEXITCODE)" }
        } else {
            Write-Host "Shallow-cloning $CoreRemote ($($plan.Target))..." -ForegroundColor Cyan
            git clone --depth 1 --branch $plan.Target $CoreRemote $tempClone
            if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)" }
        }
        $srcNvim = Join-Path $tempClone 'nvim'
        if (-not (Test-Path $srcNvim)) { throw "cloned Core has no nvim/ tree" }
    }

    # --- mirror source -> target ----------------------------------------------
    # robocopy /MIR makes the target match the source (so deletions in Core
    # propagate). lazy-lock.json IS mirrored on purpose: it pins each plugin to a
    # commit SHA, and those SHAs are CROSS-PLATFORM — excluding it would leave
    # Windows nvim floating on plugin HEAD while every Unix repo (and Core's weekly
    # nvim-lock freshness bot) stays pinned. Syncing it keeps Windows in lockstep
    # with the fleet's pinned plugin set. robocopy exit codes 0-7 are success;
    # >=8 is a real error.
    Write-Host 'Syncing nvim/ ...' -ForegroundColor Cyan
    robocopy $srcNvim $Target /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy reported errors (exit $LASTEXITCODE)" }

    # --- record vendoring provenance -> nvim/.core-ref ------------------------
    # nvim/ is the ONLY asset vendored from Core, and the sync was previously
    # amnesiac: nothing recorded WHICH Core commit the tree came from, so you
    # couldn't tell a current tree from a months-stale one or reproduce a past
    # state. Stamp the source commit/date into a tracked marker the moment we copy;
    # dotfiles-doctor surfaces it (B1). Best-effort: a non-git -CoreLocal yields
    # 'unknown', which is still a truthful record.
    $srcRepo  = if ($CoreLocal) { $CoreLocal }  else { $tempClone }
    $srcLabel = if ($CoreLocal) { $CoreLocal }  else { $CoreRemote }
    $sha  = (& git -C $srcRepo rev-parse HEAD 2>$null)
    # `git describe` needs the tags AND the history back to the nearest one. The
    # clone/fetch above is shallow (--depth 1), where describe sees only a tag sitting
    # ON the tip — so a branch-tip sync between releases finds nothing and the
    # 'vX.Y.Z-N-g...' nearest-ancestor form is unreachable. For our throwaway temp
    # clone, best-effort deepen + fetch tags so describe resolves the nearest release
    # tag, matching how dotfiles-core's sync-core.sh computes core_tag from a full clone.
    # (-CoreLocal is the user's OWN clone — don't mutate it; rely on its existing tags.)
    if (-not $CoreLocal) {
        git -C $srcRepo fetch --tags --unshallow --quiet 2>$null
        # --unshallow errors on an already-complete repo; fall back to a plain tag fetch.
        if ($LASTEXITCODE -ne 0) { git -C $srcRepo fetch --tags --quiet 2>$null }
    }
    # Nearest Core release tag describing the vendored commit (e.g. 'v2.0.0', or
    # 'v2.0.0-3-gabc1234' a few commits past it). Lets fleet-drift label the Windows
    # row by release name like the Unix repos' core.lock 'core_tag', instead of a bare
    # SHA. Best-effort: empty when Core carries no tags yet, or for a non-git -CoreLocal
    # — in which case the line is omitted (the SHA stays the source of truth).
    $tag  = (& git -C $srcRepo describe --tags HEAD 2>$null)
    $when = (& git -C $srcRepo show -s --format=%cs HEAD 2>$null)
    $refFile = Join-Path $Target '.core-ref'
    $now = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    @(
        '# dotfiles-Windows :: nvim vendor provenance (written by nvim-sync.ps1)'
        '# The Core commit this nvim/ tree was vendored from. dotfiles-doctor reads it.'
        "source = $srcLabel"
        "branch = $Branch"
        "pinned = $(if ($Ref) { $Ref } else { '(branch tip)' })"
        "commit = $(if ($sha)  { $sha }  else { 'unknown' })"
        if ($tag) { "tag    = $tag" }
        "date   = $(if ($when) { $when } else { 'unknown' })"
        "synced = $now"
    ) | Set-Content -Path $refFile -Encoding UTF8
    $shortSha = if ($sha) { $sha.Substring(0, [Math]::Min(7, $sha.Length)) } else { 'unknown' }
    Write-Host "  recorded provenance -> nvim/.core-ref (core@$shortSha)" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'nvim/ synced from Core. Review and commit:' -ForegroundColor Green
    Write-Host "  git -C `"$RepoRoot`" diff --stat nvim/" -ForegroundColor DarkGray
    Write-Host "  git -C `"$RepoRoot`" add nvim/ ; git -C `"$RepoRoot`" commit -m 'sync nvim from core'" -ForegroundColor DarkGray
}
finally {
    if ($tempClone -and (Test-Path $tempClone)) {
        Remove-Item $tempClone -Recurse -Force -ErrorAction SilentlyContinue
    }
}
