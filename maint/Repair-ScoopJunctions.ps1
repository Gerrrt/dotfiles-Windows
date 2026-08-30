# ============================================================================
#  maint/Repair-ScoopJunctions.ps1  -  keep scoop traversable from ssh sessions.
# ============================================================================
#  Under ProcessRedirectionTrustPolicy (Redirection Guard) an ssh/service-lineage
#  process refuses to follow a junction that was CREATED by a non-admin. NTFS
#  stamps the trust level at creation from the creator's token, so ownership is
#  irrelevant — `icacls /setowner` on the link or its target does nothing. The one
#  lever is to re-create the junction from an elevated process. See
#  docs/REMOTE-ACCESS.md.
#
#  scoop creates every one of its junctions as you, and re-creates them on every
#  upgrade, so this is a maintenance job rather than a one-off. It runs from two
#  places: a Step in maint/Maintenance.ps1 (which only does the work when that run
#  happens to be elevated), and the `dotfiles-maint-scoop-junctions` scheduled
#  task, which is registered to run as SYSTEM precisely so it does not depend on
#  someone remembering to run maint from an admin shell.
#
#  SCOPE is the part that is easy to get wrong. `apps\<app>\current` is the obvious
#  junction, but scoop also wires persisted state back OUT of an app dir with more
#  junctions into `scoop\persist\<app>\...` — bat\themes, bat\syntaxes,
#  btop-lhm\themes, composer\cache, php\cli, syncthing\config — and
#  `scoop\modules\gsudoModule` points into `apps\gsudo\current` from outside
#  `apps\` altogether. All were made by the same non-admin scoop process and are
#  untrusted for the same reason: re-stamp only `current` and `bat --list-themes`
#  is still broken over ssh. So the walk is every DIRECTORY reparse point under the
#  scoop root, not a hand-written tour of the app dirs.
#
#  The policy is Get-DotScoopJunctionPlan in the Dotfiles module (pure, unit
#  tested); this script does the walk and the re-creation.
# ============================================================================
[CmdletBinding()] param(
    # scoop install root. Passed explicitly by the scheduled task: it runs as
    # SYSTEM, whose USERPROFILE is not yours, so it must never be inferred there.
    [string]$ScoopRoot,
    # When set, tee the report into this file as well as stdout. Maintenance.ps1
    # omits it on purpose — its Step already redirects every stream into maint.log,
    # and teeing as well would write each line twice.
    [string]$LogPath,
    # Report the plan without touching any junction.
    [switch]$DryRun,
    # Test seam, same shape as Test-CanSymlink in install.ps1.
    [nullable[bool]]$IsElevatedOverride,
    [switch]$Help
)

if ($Help) {
    @(
        'Repair-ScoopJunctions.ps1 - re-create scoop junctions so ssh can traverse them'
        ''
        'USAGE'
        '  pwsh -NoProfile -File maint\Repair-ScoopJunctions.ps1 [-ScoopRoot <path>]'
        '                       [-LogPath <file>] [-DryRun] [-Help]'
        ''
        'WHY'
        '  Redirection Guard refuses a junction CREATED by a non-admin, and scoop'
        '  creates all of its junctions as you — so scoop tools are invisible over'
        '  ssh. Trust is stamped at creation, so re-creating elevated is the only'
        '  fix, and scoop undoes it on every upgrade. See docs/REMOTE-ACCESS.md.'
        ''
        'NEEDS ELEVATION. Unelevated it reports one line and exits 0 — re-creating'
        'as a non-admin would only re-stamp the junction untrusted.'
        ''
        '  -ScoopRoot <path>  scoop install root (default: $env:SCOOP, else ~\scoop)'
        '  -LogPath <file>    also append the report to this file'
        '  -DryRun            print the plan, change nothing'
    ) | ForEach-Object { Write-Host $_ }
    return
}

$ErrorActionPreference = 'Stop'

if (-not $ScoopRoot) { $ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' } }

function Write-Line {
    param([string]$Msg)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    if ($LogPath) { $line | Tee-Object -FilePath $LogPath -Append } else { $line }
}

if (-not (Get-Command Get-DotScoopJunctionPlan -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\powershell\Dotfiles\Dotfiles.psd1') -ErrorAction Stop
}

$isElevated = if ($null -ne $IsElevatedOverride) { [bool]$IsElevatedOverride } else {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Path -LiteralPath $ScoopRoot)) {
    Write-Line "scoop junctions: no scoop root at $ScoopRoot — nothing to do"
    return
}

# -Recurse does NOT descend through a reparse point, so each physical junction is
# reported exactly once, under its canonical path — `apps\bat\0.26.1\themes` rather
# than also as `apps\bat\current\themes`. That is what makes a plain recursive walk
# correct here instead of needing to de-duplicate spellings afterwards.
$candidates = [System.Collections.Generic.List[object]]::new()
foreach ($link in (Get-ChildItem -LiteralPath $ScoopRoot -Recurse -Directory -Force `
                     -Attributes ReparsePoint -ErrorAction SilentlyContinue)) {
    $candidates.Add([pscustomobject]@{
        Link     = $link.FullName
        Target   = @($link.Target)[0]
        LinkType = [string]$link.LinkType
    })
}

$plan = Get-DotScoopJunctionPlan -Candidate $candidates.ToArray() -IsElevated $isElevated

# Unelevated: exactly ONE line, and exit 0. A maintenance run that reliably prints
# one failure per app is worse than one that prints a single honest "skipped".
if ($plan.Blocked -gt 0) {
    Write-Line ("scoop junctions SKIPPED: {0} junction(s) need re-creating but this run is not elevated — the dotfiles-maint-scoop-junctions task does this; register it with maint-install from an admin shell (see docs/REMOTE-ACCESS.md)" -f $plan.Blocked)
    return
}

$done = 0; $inUse = 0; $failed = 0
foreach ($row in ($plan.Rows | Where-Object { $_.Action -eq 'recreate' })) {
    if ($DryRun) { Write-Line ("scoop junctions: WOULD re-create {0} -> {1}" -f $row.Link, $row.Target); $done++; continue }
    try {
        # Clear scoop's ReadOnly bit (rmdir refuses it), drop the LINK only — never
        # the target — and re-make it from this elevated process so the new junction
        # is stamped trusted.
        $item = Get-Item -LiteralPath $row.Link -Force -ErrorAction Stop
        $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        & cmd /c rmdir "$($row.Link)" 2>&1 | Out-Null
        if (Test-Path -LiteralPath $row.Link) {
            # Files in use — pwsh running this very script is the usual one. Left
            # for the next run rather than treated as a failure.
            $inUse++
            Write-Line ("scoop junctions: in use, left as-is: {0}" -f $row.Link)
            continue
        }
        & cmd /c mklink /J "$($row.Link)" "$($row.Target)" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $row.Link)) {
            throw "mklink did not re-create the junction (exit $LASTEXITCODE)"
        }
        $done++
    } catch {
        $failed++
        Write-Line ("scoop junctions: FAILED {0} : {1}" -f $row.Link, $_.Exception.Message)
    }
}

$verb = if ($DryRun) { 'would re-create' } else { 're-created' }
$extra = if ($inUse) { ", $inUse in use" } else { '' }
Write-Line ("scoop junctions: {0} {1}, {2} skipped{3}, {4} failed (of {5} reparse points scanned)" -f
    $verb, $done, ($plan.NotJunction + $plan.Unresolved), $extra, $failed, $plan.Total)

# Surface real failures as a TERMINATING error. Maintenance.ps1's Step runs its body
# as `& $Body *>> $Log` under $ErrorActionPreference='Continue', so a native exe's
# exit code is swallowed and the step would log "ok" even if every mklink failed —
# only a terminating error reaches its catch.
if ($failed -gt 0) { throw "scoop junctions: $failed junction(s) could not be re-created" }
