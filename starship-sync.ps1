# ============================================================================
#  starship-sync.ps1  -  refresh starship/starship.toml from dotfiles-core
#
#  dotfiles-Windows is a STANDALONE repo (no core/ subtree). starship is the rare
#  Core asset the host CAN share verbatim: starship.toml is cross-shell by design,
#  and Core now carries `powershell_indicator` in [shell] so the single canonical
#  file renders under both zsh and PowerShell. This is the small, deliberate sync
#  that keeps starship/starship.toml in lockstep with Core — the sibling of
#  nvim-sync.ps1 (whose pattern this mirrors exactly).
#
#  Usage (from the repo root):
#    .\starship-sync.ps1                                  # shallow-clone the remote, copy the toml
#    .\starship-sync.ps1 -CoreLocal C:\src\dotfiles-core  # copy from an existing clone instead
#    .\starship-sync.ps1 -Branch dev                      # sync from a different Core branch
#    .\starship-sync.ps1 -Ref v2.1.0                       # pin an exact Core commit/tag (reproducible)
#    .\starship-sync.ps1 -Force                           # abandon a recorded pin, track the branch tip
#
#  PINS ARE STICKY. Once a run records `pinned = vX.Y.Z` in starship/.core-ref, a
#  later bare run honours it rather than silently dragging the file to the branch
#  tip — the scheduled workflow invokes this script with no arguments, so without
#  that a deliberate pin would be reverted with nothing in the diff to say so.
#  Use -Force to deliberately drop the pin and resume tracking -Branch.
#
#  After it runs: review `git diff starship/`, then commit.
# ============================================================================
[CmdletBinding()]
param(
    [string]$CoreRemote = 'https://github.com/dotgibson/dotfiles-core.git',
    [string]$Branch     = 'main',
    [string]$CoreLocal,
    # Pin an EXACT Core commit/tag for a reproducible re-vendor. Takes precedence
    # over -Branch; can't be combined with -CoreLocal (which copies a local working
    # tree as-is). Validated/resolved by Get-StarshipSyncRefPlan.
    [string]$Ref,
    # Abandon an existing pin recorded in starship/.core-ref and track the branch
    # tip instead. Without this, a recorded `pinned = vX.Y.Z` is HONOURED (see
    # Get-StarshipSyncPin) so an unattended bot run can't silently un-pin a
    # deliberate decision.
    [switch]$Force
)

# --- Get-StarshipSyncRefPlan --------------------------------------------------
# Pure: decide what to fetch from the remote — a pinned -Ref (commit/tag, the
# reproducible case) or the -Branch tip — and reject the illegal combinations up
# front. Returns { Mode = 'ref'|'branch'; Target; Label }. Unit-tested via the
# DOTFILES_STARSHIPSYNC_LIBONLY hook below. (Mirrors nvim-sync.ps1's resolver.)
function Get-StarshipSyncRefPlan {
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

# --- Get-StarshipSyncPin ------------------------------------------------------
# Pure: decide whether an EXISTING pin recorded in starship/.core-ref should be
# carried forward.
#
# The bug this closes: starship/.core-ref recorded `pinned = v4.9.0` (set by a
# deliberate `-Ref v4.9.0` run), but .github/workflows/starship-sync.yml invokes
# this script BARE — no -Ref. The next scheduled run would therefore have synced
# the branch tip and rewritten `pinned = (branch tip)`, silently discarding the
# decision with nothing in the diff to say a pin had been dropped.
#
# Precedence: an explicit -Ref always wins; -Force deliberately abandons the pin;
# otherwise a recorded pin is honoured. '(branch tip)' is the sentinel the writer
# below uses for "not pinned", so it is not a pin.
function Get-StarshipSyncPin {
    [OutputType([pscustomobject])]
    param([string]$Ref, [string]$RecordedPin, [switch]$Force, [switch]$CoreLocalUsed)
    if ($Ref)           { return [pscustomobject]@{ Ref = $Ref; Source = 'explicit' } }
    if ($Force)         { return [pscustomobject]@{ Ref = $null; Source = 'forced-branch' } }
    # -CoreLocal copies a working tree as-is; there is no ref to fetch, so a
    # recorded pin cannot be honoured and claiming otherwise would be a lie.
    if ($CoreLocalUsed) { return [pscustomobject]@{ Ref = $null; Source = 'core-local' } }
    if ($RecordedPin -and $RecordedPin -ne '(branch tip)') {
        return [pscustomobject]@{ Ref = $RecordedPin; Source = 'recorded' }
    }
    return [pscustomobject]@{ Ref = $null; Source = 'branch' }
}

# --- Write-CoreRefFile --------------------------------------------------------
# Write .core-ref with explicit LF and no BOM. `Set-Content -Encoding UTF8` writes
# CRLF on Windows, so every sync left the working tree with CRLF that .gitattributes
# then silently normalized on commit — and .core-ref is not in the validator's
# checked extensions, so nothing ever flagged it. Write the bytes we actually mean.
function Write-CoreRefFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(ValueFromPipeline)][string[]]$Line
    )
    begin { $acc = [System.Collections.Generic.List[string]]::new() }
    process { foreach ($l in $Line) { $acc.Add($l) } }
    end {
        [System.IO.File]::WriteAllText($Path, (($acc -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
}

# --- Get-CoreDescribeTag ------------------------------------------------------
# Nearest Core RELEASE tag describing $Rev in $RepoPath — 'v2.0.0' when the vendored
# commit IS a release, 'v2.0.0-3-gabc1234' a few commits past one. Empty (and the
# `tag` line then omitted) when nothing matches: Core carries no release tag yet, the
# clone is still shallow past the nearest one, or -CoreLocal isn't a git repo at all.
#
# --match 'v[0-9]*.[0-9]*.[0-9]*' IS LOAD-BEARING, not tidiness (#202; ports the same
# fix from dotfiles-core#515 / sync-core.sh). Every Core release ALSO carries a moving
# major alias (`v4`), re-pointed on each cut by Core's scripts/tag-release.sh with
# `git tag -fa`, AFTER the specific tag. Both are annotated and both sit on the release
# commit, so `git describe` breaks the tie by TAGGER TIME and prefers the alias. That
# is how nvim/.core-ref came to record `tag = v4-19-g10ad221`: a provenance field
# naming a target that moves out from under it, so the same recorded string means a
# DIFFERENT commit after the next release. The two-dot shape excludes the alias by
# construction. (It also immunizes a -CoreLocal run against a locally STALE alias —
# a plain `git fetch` never force-updates an existing tag.)
#
# Don't "simplify" by dropping --tags: that restricts describe to annotated tags, and
# the alias is annotated too, so it would fix nothing.
#
# When ONLY an alias exists, describe finds nothing and the caller omits the line — an
# ABSENT tag is strictly better than a wrong one, and `commit` (the full SHA the parity
# gate and dotfiles-doctor actually read) stays the source of truth either way.
#
# The single-quoted glob reaches git VERBATIM: PowerShell does not expand wildcards in
# native-command arguments (that is a POSIX shell behaviour); the quotes only stop its
# own parser from reading `[`, `]` and `*`.
#
# try/catch, not `2>$null` alone: today $PSNativeCommandUseErrorActionPreference is
# $false, so a failing git yields $null instead of throwing under this script's
# ErrorActionPreference='Stop'. If a future pwsh flips that default, the redirect on its
# own would stop protecting the contract and a tag-less Core would abort the whole sync.
# The contract is "best-effort, never fatal" — state it rather than inherit it.
# (Kept identical in nvim-sync.ps1 — the two scripts are deliberate twins.)
function Get-CoreDescribeTag {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$Rev = 'HEAD'
    )
    try { $t = (& git -C $RepoPath describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' $Rev 2>$null) }
    catch { return '' }
    if ($t) { "$t".Trim() } else { '' }
}

# Library-only hook for the test suite: expose the helpers without syncing.
if ($env:DOTFILES_STARSHIPSYNC_LIBONLY -eq '1') { return }

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetDir = Join-Path $RepoRoot 'starship'
$Target    = Join-Path $TargetDir 'starship.toml'

# Carry a recorded pin forward unless told otherwise (see Get-StarshipSyncPin).
$recordedPin = $null
$existingRef = Join-Path $TargetDir '.core-ref'
if (Test-Path $existingRef) {
    $recordedPin = ((Get-Content $existingRef | Where-Object { $_ -match '^\s*pinned\s*=' } | Select-Object -First 1) `
        -replace '^\s*pinned\s*=\s*', '').Trim()
}
$pin = Get-StarshipSyncPin -Ref $Ref -RecordedPin $recordedPin -Force:$Force -CoreLocalUsed:([bool]$CoreLocal)
if ($pin.Source -eq 'recorded') {
    Write-Host "Honouring the pin recorded in starship/.core-ref: $($pin.Ref)" -ForegroundColor Yellow
    Write-Host '  (pass -Force to abandon it and track the branch tip instead)' -ForegroundColor DarkGray
} elseif ($pin.Source -eq 'forced-branch' -and $recordedPin -and $recordedPin -ne '(branch tip)') {
    Write-Host "-Force: abandoning the recorded pin $recordedPin and tracking $Branch." -ForegroundColor Yellow
}
$Ref  = $pin.Ref
$plan = Get-StarshipSyncRefPlan -Ref $Ref -Branch $Branch -CoreLocal $CoreLocal

$tempClone = $null
try {
    # --- resolve the source starship.toml ------------------------------------
    if ($CoreLocal) {
        $srcToml = Join-Path $CoreLocal 'starship/starship.toml'
        if (-not (Test-Path $srcToml)) { throw "no starship/starship.toml under -CoreLocal path: $CoreLocal" }
        Write-Host "Using local Core clone: $srcToml" -ForegroundColor Cyan
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
        $srcToml = Join-Path $tempClone 'starship/starship.toml'
        if (-not (Test-Path $srcToml)) { throw "cloned Core has no starship/starship.toml" }
    }

    # --- copy source -> target ------------------------------------------------
    # A single file (unlike nvim's tree), so a plain copy — no robocopy /MIR. This
    # is the canonical, cross-shell starship.toml; we take it verbatim so the host
    # prompt matches the fleet.
    Write-Host 'Syncing starship/starship.toml ...' -ForegroundColor Cyan
    if (-not (Test-Path $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir | Out-Null }
    Copy-Item -Path $srcToml -Destination $Target -Force

    # --- record vendoring provenance -> starship/.core-ref --------------------
    # Stamp WHICH Core commit this toml came from, the moment we copy — same B1
    # marker nvim/.core-ref carries, so dotfiles-doctor / fleet-drift can tell a
    # current file from a stale one. Best-effort: a non-git -CoreLocal yields
    # 'unknown', still a truthful record.
    $srcRepo  = if ($CoreLocal) { $CoreLocal }  else { $tempClone }
    $srcLabel = if ($CoreLocal) { $CoreLocal }  else { $CoreRemote }
    $sha  = (& git -C $srcRepo rev-parse HEAD 2>$null)
    # `git describe` needs the tags AND history back to the nearest one, but the
    # clone/fetch above is shallow — so deepen the throwaway temp clone best-effort
    # first. Without this the nearest-ancestor 'vX.Y.Z-N-g...' form is unreachable
    # and starship/.core-ref ends up with no `tag` line at all, unlike nvim's.
    # (-CoreLocal is the user's OWN clone — don't mutate it; rely on its tags.)
    #
    # This deepen got MORE load-bearing with #202, not less: on a shallow clone the only
    # tag describe can see is one sitting ON the tip, and on a release commit the newest
    # such tag is the moving `vN` alias — which the shape filter now (correctly) rejects.
    # Without the tags-and-history fetch below, the field would simply go empty most runs.
    if (-not $CoreLocal) {
        git -C $srcRepo fetch --tags --unshallow --quiet 2>$null
        # --unshallow errors on an already-complete repo; fall back to a tag fetch.
        if ($LASTEXITCODE -ne 0) { git -C $srcRepo fetch --tags --quiet 2>$null }
    }
    # Same release-tag stamp as nvim/.core-ref's, same shape filter, same reasons (#202)
    # — see Get-CoreDescribeTag above. Describe HEAD rather than $sha, and don't reorder
    # this with the `git show` below it (that show resets $LASTEXITCODE, which the
    # `shell: pwsh` workflow epilogue exits with).
    $tag  = Get-CoreDescribeTag -RepoPath $srcRepo -Rev 'HEAD'
    $when = (& git -C $srcRepo show -s --format=%cs HEAD 2>$null)
    $refFile = Join-Path $TargetDir '.core-ref'
    $now = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    @(
        '# dotfiles-Windows :: starship vendor provenance (written by starship-sync.ps1)'
        '# The Core commit this starship.toml was vendored from. dotfiles-doctor reads it.'
        "source = $srcLabel"
        "branch = $Branch"
        "pinned = $(if ($Ref) { $Ref } else { '(branch tip)' })"
        "commit = $(if ($sha)  { $sha }  else { 'unknown' })"
        if ($tag) { "tag    = $tag" }
        "date   = $(if ($when) { $when } else { 'unknown' })"
        "synced = $now"
    ) | Write-CoreRefFile -Path $refFile
    $shortSha = if ($sha) { $sha.Substring(0, [Math]::Min(7, $sha.Length)) } else { 'unknown' }
    Write-Host "  recorded provenance -> starship/.core-ref (core@$shortSha)" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'starship.toml synced from Core. Review and commit:' -ForegroundColor Green
    Write-Host "  git -C `"$RepoRoot`" diff starship/" -ForegroundColor DarkGray
    Write-Host "  git -C `"$RepoRoot`" add starship/ ; git -C `"$RepoRoot`" commit -m 'sync starship from core'" -ForegroundColor DarkGray
}
finally {
    if ($tempClone -and (Test-Path $tempClone)) {
        Remove-Item $tempClone -Recurse -Force -ErrorAction SilentlyContinue
    }
}
