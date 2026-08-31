# ============================================================================
#  theme-sync.ps1  -  refresh theme/palette.toml from dotfiles-core
#
#  The THIRD asset this standalone repo mirrors from Core, after nvim/ and
#  starship/starship.toml. Core's theme/palette.toml is the one place a colour is
#  authored in the fleet: dotfiles-core#679 replaced ~90 hand-copied hexes with a
#  single flat table plus scripts/gen-theme.sh, and `make audit` fails on drift.
#  dotfiles-Windows was the last repo still typing the numbers (#228) — and three
#  fzf values had ALREADY drifted (border/scrollbar #27a1b9 vs Core's #29a4bd,
#  gutter #16161e vs #1d202f) under a comment claiming the block was kept
#  byte-for-byte in step. Nothing checked it, so nothing caught it.
#
#  This script vendors the palette; gen-theme.ps1 renders it into the consumers.
#  The split is deliberate and mirrors Core's: syncing is a NETWORK operation that
#  lands one file, generation is an OFFLINE operation over the tree. CI runs the
#  second on every PR and the first on a schedule.
#
#  Usage (from the repo root):
#    .\theme-sync.ps1                                  # shallow-clone the remote, copy the toml
#    .\theme-sync.ps1 -CoreLocal C:\src\dotfiles-core  # copy from an existing clone instead
#    .\theme-sync.ps1 -Branch dev                      # sync from a different Core branch
#    .\theme-sync.ps1 -Ref v5.0.0                      # pin an exact Core commit/tag (reproducible)
#    .\theme-sync.ps1 -Force                           # abandon a recorded pin, track the branch tip
#
#  PINS ARE STICKY, for the same reason starship's are: once a run records
#  `pinned = vX.Y.Z` in theme/.core-ref, a later BARE run honours it rather than
#  silently dragging the file to the branch tip. The scheduled workflow invokes this
#  with no arguments, so without that a deliberate pin would be reverted with nothing
#  in the diff to say so. Use -Force to drop the pin and resume tracking -Branch.
#
#  After it runs: `.\gen-theme.ps1`, review `git diff`, then commit. A palette sync
#  that is not followed by a generate leaves the tree in exactly the state this whole
#  change exists to prevent — which is why gen-theme.ps1 -Check gates every PR.
# ============================================================================
[CmdletBinding()]
param(
    [string]$CoreRemote = 'https://github.com/dotgibson/dotfiles-core.git',
    [string]$Branch     = 'main',
    [string]$CoreLocal,
    # Pin an EXACT Core commit/tag for a reproducible re-vendor. Takes precedence
    # over -Branch; can't be combined with -CoreLocal (which copies a local working
    # tree as-is). Validated/resolved by Get-ThemeSyncRefPlan.
    [string]$Ref,
    # Abandon an existing pin recorded in theme/.core-ref and track the branch tip
    # instead. Without this, a recorded `pinned = vX.Y.Z` is HONOURED (see
    # Get-ThemeSyncPin) so an unattended bot run can't silently un-pin a deliberate
    # decision.
    [switch]$Force
)

# --- Get-ThemeSyncRefPlan -----------------------------------------------------
# Pure: decide what to fetch from the remote — a pinned -Ref (commit/tag, the
# reproducible case) or the -Branch tip — and reject the illegal combinations up
# front. Returns { Mode = 'ref'|'branch'; Target; Label }. Unit-tested via the
# DOTFILES_THEMESYNC_LIBONLY hook below. (Mirrors starship-sync.ps1's resolver.)
function Get-ThemeSyncRefPlan {
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

# --- Get-ThemeSyncPin ---------------------------------------------------------
# Pure: decide whether an EXISTING pin recorded in theme/.core-ref should be carried
# forward. Precedence: an explicit -Ref always wins; -Force deliberately abandons the
# pin; -CoreLocal copies a working tree as-is (there is no ref to fetch, so a recorded
# pin cannot be honoured and claiming otherwise would be a lie); otherwise a recorded
# pin is honoured. '(branch tip)' is the sentinel the writer below uses for "not
# pinned", so it is not a pin.
function Get-ThemeSyncPin {
    [OutputType([pscustomobject])]
    param([string]$Ref, [string]$RecordedPin, [switch]$Force, [switch]$CoreLocalUsed)
    if ($Ref)           { return [pscustomobject]@{ Ref = $Ref; Source = 'explicit' } }
    if ($Force)         { return [pscustomobject]@{ Ref = $null; Source = 'forced-branch' } }
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
#
# Duplicated verbatim from nvim-sync.ps1 / starship-sync.ps1 — the three scripts are
# deliberate twins, and this helper is inert formatting. The SECURITY-critical helpers
# are SHARED rather than copied; see tests/Assert-ThemeParity.ps1 for that half of the
# split and the reasoning behind it.
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
# `tag` line then omitted) when nothing matches.
#
# --match 'v[0-9]*.[0-9]*.[0-9]*' IS LOAD-BEARING, not tidiness (#202). Every Core
# release ALSO carries a moving major alias (`v4`), re-pointed on each cut by Core's
# scripts/tag-release.sh with `git tag -fa`, AFTER the specific tag. Both are annotated
# and both sit on the release commit, so `git describe` breaks the tie by TAGGER TIME
# and prefers the alias — a provenance field naming a target that moves out from under
# it. The two-dot shape excludes the alias by construction.
#
# try/catch, not `2>$null` alone: today $PSNativeCommandUseErrorActionPreference is
# $false, so a failing git yields $null instead of throwing under this script's
# ErrorActionPreference='Stop'. The contract is "best-effort, never fatal".
# (Kept identical in nvim-sync.ps1 / starship-sync.ps1.)
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
if ($env:DOTFILES_THEMESYNC_LIBONLY -eq '1') { return }

$ErrorActionPreference = 'Stop'
$RepoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetDir = Join-Path $RepoRoot 'theme'
$Target    = Join-Path $TargetDir 'palette.toml'

# Carry a recorded pin forward unless told otherwise (see Get-ThemeSyncPin).
$recordedPin = $null
$existingRef = Join-Path $TargetDir '.core-ref'
if (Test-Path $existingRef) {
    $recordedPin = ((Get-Content $existingRef | Where-Object { $_ -match '^\s*pinned\s*=' } | Select-Object -First 1) `
        -replace '^\s*pinned\s*=\s*', '').Trim()
}
$pin = Get-ThemeSyncPin -Ref $Ref -RecordedPin $recordedPin -Force:$Force -CoreLocalUsed:([bool]$CoreLocal)
if ($pin.Source -eq 'recorded') {
    Write-Host "Honouring the pin recorded in theme/.core-ref: $($pin.Ref)" -ForegroundColor Yellow
    Write-Host '  (pass -Force to abandon it and track the branch tip instead)' -ForegroundColor DarkGray
} elseif ($pin.Source -eq 'forced-branch' -and $recordedPin -and $recordedPin -ne '(branch tip)') {
    Write-Host "-Force: abandoning the recorded pin $recordedPin and tracking $Branch." -ForegroundColor Yellow
}
$Ref  = $pin.Ref
$plan = Get-ThemeSyncRefPlan -Ref $Ref -Branch $Branch -CoreLocal $CoreLocal

$tempClone = $null
try {
    # --- resolve the source palette.toml --------------------------------------
    if ($CoreLocal) {
        $srcToml = Join-Path $CoreLocal 'theme/palette.toml'
        if (-not (Test-Path $srcToml)) {
            throw "no theme/palette.toml under -CoreLocal path: $CoreLocal (a Core checkout from before dotfiles-core#793 does not carry one - pull it, or drop -CoreLocal to fetch the remote)."
        }
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
        $srcToml = Join-Path $tempClone 'theme/palette.toml'
        if (-not (Test-Path $srcToml)) { throw "cloned Core has no theme/palette.toml" }
    }

    # --- copy source -> target ------------------------------------------------
    # One file, taken VERBATIM. Core's own header calls the palette a generation-time
    # INPUT whose outputs ship; here it is both — the input gen-theme.ps1 reads, and a
    # vendored artefact tests/Assert-ThemeParity.ps1 hashes against Core. Editing it
    # here would fork the fleet's colour, so the gate treats any local change as drift.
    Write-Host 'Syncing theme/palette.toml ...' -ForegroundColor Cyan
    if (-not (Test-Path $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir | Out-Null }
    Copy-Item -Path $srcToml -Destination $Target -Force

    # --- record vendoring provenance -> theme/.core-ref -----------------------
    # Stamp WHICH Core commit this palette came from, the moment we copy — the same
    # marker nvim/.core-ref and starship/.core-ref carry, so dotfiles-doctor can tell
    # a current file from a stale one. Best-effort: a non-git -CoreLocal yields
    # 'unknown', still a truthful record.
    $srcRepo  = if ($CoreLocal) { $CoreLocal }  else { $tempClone }
    $srcLabel = if ($CoreLocal) { $CoreLocal }  else { $CoreRemote }
    $sha  = (& git -C $srcRepo rev-parse HEAD 2>$null)
    # `git describe` needs the tags AND history back to the nearest one, but the
    # clone/fetch above is shallow — so deepen the throwaway temp clone best-effort
    # first. (-CoreLocal is the user's OWN clone — don't mutate it; rely on its tags.)
    if (-not $CoreLocal) {
        git -C $srcRepo fetch --tags --unshallow --quiet 2>$null
        # --unshallow errors on an already-complete repo; fall back to a tag fetch.
        if ($LASTEXITCODE -ne 0) { git -C $srcRepo fetch --tags --quiet 2>$null }
    }
    # Describe HEAD rather than $sha, and don't reorder this with the `git show` below
    # it: that show resets $LASTEXITCODE, and .github/workflows/theme-sync.yml runs this
    # script under `shell: pwsh`, whose epilogue is `exit $LASTEXITCODE`.
    $tag  = Get-CoreDescribeTag -RepoPath $srcRepo -Rev 'HEAD'
    $when = (& git -C $srcRepo show -s --format=%cs HEAD 2>$null)
    $refFile = Join-Path $TargetDir '.core-ref'
    $now = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    @(
        '# dotfiles-Windows :: theme vendor provenance (written by theme-sync.ps1)'
        '# The Core commit this palette.toml was vendored from. dotfiles-doctor reads it.'
        "source = $srcLabel"
        "branch = $Branch"
        "pinned = $(if ($Ref) { $Ref } else { '(branch tip)' })"
        "commit = $(if ($sha)  { $sha }  else { 'unknown' })"
        if ($tag) { "tag    = $tag" }
        "date   = $(if ($when) { $when } else { 'unknown' })"
        "synced = $now"
    ) | Write-CoreRefFile -Path $refFile
    $shortSha = if ($sha) { $sha.Substring(0, [Math]::Min(7, $sha.Length)) } else { 'unknown' }
    Write-Host "  recorded provenance -> theme/.core-ref (core@$shortSha)" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'palette.toml synced from Core. Now REGENERATE, then review and commit:' -ForegroundColor Green
    Write-Host "  pwsh -NoProfile -File `"$RepoRoot\gen-theme.ps1`"" -ForegroundColor DarkGray
    Write-Host "  git -C `"$RepoRoot`" diff" -ForegroundColor DarkGray
    Write-Host "  git -C `"$RepoRoot`" commit -am 'sync theme from core'" -ForegroundColor DarkGray
}
finally {
    if ($tempClone -and (Test-Path $tempClone)) {
        Remove-Item $tempClone -Recurse -Force -ErrorAction SilentlyContinue
    }
}
