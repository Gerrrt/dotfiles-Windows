# ============================================================================
#  packages/PackageLock.ps1  -  pure helpers for the package lockfile (B4).
#
#  The manifests (scoopfile.json / winget.json) are the DESIRED set and float to
#  latest. The lockfile (packages.lock.json) is the RESOLVED set: exact versions
#  captured from a real, working box, so `-Frozen` can reproduce that baseline
#  bit-for-bit — the same split npm/cargo use, and the same "reproducible at
#  install, current after maint" model packages/modules.ps1 already uses for PS
#  modules.
#
#  Everything here is PURE (string/JSON in, object out — no scoop/winget calls,
#  no disk writes), so it is unit-tested offline in tests/Packages.Tests.ps1.
#  Dot-sourced by Install-Packages.ps1 (the -Frozen consumer) and
#  Update-PackageLock.ps1 (the generator); side-effect-free on load.
# ============================================================================

# --- Read-PackageLock ---------------------------------------------------------
# Parse packages.lock.json text into { GeneratedAt; Scoop = @{name=ver}; Winget =
# @{id=ver} }. Tolerant by design: blank / malformed / partial JSON yields empty
# maps rather than throwing, so a missing or hand-corrupted lock degrades to "no
# pins" instead of breaking the installer. The maps are plain hashtables, so
# lookups are case-insensitive (scoop app names and winget ids both vary in case).
function Read-PackageLock {
    param([string]$Json)
    $empty = [pscustomobject]@{ GeneratedAt = $null; Scoop = @{}; Winget = @{} }
    if ([string]::IsNullOrWhiteSpace($Json)) { return $empty }
    try { $obj = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $empty }
    $toMap = {
        param($Section)
        $m = @{}
        if ($Section) {
            foreach ($p in $Section.PSObject.Properties) {
                if ($p.Value) { $m[$p.Name] = "$($p.Value)" }
            }
        }
        $m
    }
    [pscustomobject]@{
        GeneratedAt = $obj.generatedAt
        Scoop       = & $toMap $obj.scoop
        Winget      = & $toMap $obj.winget
    }
}

# --- Get-LockedVersion --------------------------------------------------------
# Case-insensitive lookup of one name in a lock map; $null when absent. (Hashtable
# indexing is already case-insensitive, but this keeps call sites readable and
# guards a $null map.)
function Get-LockedVersion {
    param([hashtable]$Map, [string]$Name)
    if (-not $Map -or [string]::IsNullOrEmpty($Name)) { return $null }
    if ($Map.ContainsKey($Name)) { return "$($Map[$Name])" }
    $null
}

# --- Test-PackageVersionMatch -------------------------------------------------
# Do two version strings name the SAME release? Deliberately not a plain -eq: the
# lock is captured from `winget export`, which pads to four components, while
# `winget show` reports the source's own form — so "2.7.10.0" in the lock and
# "2.7.10" upstream are one build written two ways. A string compare calls that
# "behind" forever, and the weekly freshness check nags about an update that does
# not exist (the false positives in issue #140).
#
# Compare component-wise with absent trailing components read as 0. Falls back to
# an exact string compare when either side is not purely numeric-dotted —
# prereleases ("0.5.0-beta"), scoop's date+hash strings, "nightly" — where there
# is no safe numeric reading and literal equality is the only claim we can make.
function Test-PackageVersionMatch {
    param([string]$A, [string]$B)
    if ($A -eq $B) { return $true }
    $numeric = '^[0-9]+(\.[0-9]+)*$'
    if ($A -notmatch $numeric -or $B -notmatch $numeric) { return $false }
    $x = @($A -split '\.')
    $y = @($B -split '\.')
    for ($i = 0; $i -lt [Math]::Max($x.Count, $y.Count); $i++) {
        $xi = if ($i -lt $x.Count) { [long]$x[$i] } else { 0 }
        $yi = if ($i -lt $y.Count) { [long]$y[$i] } else { 0 }
        if ($xi -ne $yi) { return $false }
    }
    return $true
}

# --- ConvertFrom-ScoopExport --------------------------------------------------
# `scoop export` (JSON) -> @{ appName = version }. Newer scoop emits
# { apps: [ { Name, Version, Source } ], buckets: [...] }; older scoop emitted a
# bare array of app objects. Accept both, keep only entries that actually carry a
# version (an app mid-install can lack one).
function ConvertFrom-ScoopExport {
    param([string]$Json)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Json)) { return $map }
    try { $obj = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $map }
    $apps = if ($null -ne $obj.apps) { $obj.apps } else { $obj }
    foreach ($a in @($apps)) {
        if ($a.Name -and $a.Version) { $map["$($a.Name)"] = "$($a.Version)" }
    }
    $map
}

# --- ConvertFrom-WingetExport -------------------------------------------------
# `winget export --include-versions` (JSON) -> @{ id = version }. Shape is
# { Sources: [ { Packages: [ { PackageIdentifier, Version } ] } ] }. Skip entries
# with no usable version ("", "Unknown", "Latest") — winget without
# --include-versions omits versions entirely, and we must not pin to a non-version.
# ALSO reject constraint tokens: for a store/newer-than package, winget export can
# emit "> 8.12.28.25" (a comparison operator + space) instead of an exact pin. That
# is not a version — passing it to `winget install --version "> 8.12.28.25"` is
# rejected by winget and breaks -Frozen — so only accept a clean version literal
# (starts with a digit, no <>= or whitespace). This also subsumes ""/Unknown/Latest.
function ConvertFrom-WingetExport {
    param([string]$Json)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Json)) { return $map }
    try { $obj = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $map }
    foreach ($s in @($obj.Sources)) {
        foreach ($p in @($s.Packages)) {
            $v = "$($p.Version)".Trim()
            if ($p.PackageIdentifier -and $v -match '^\d' -and $v -notmatch '[<>=\s]') {
                $map["$($p.PackageIdentifier)"] = $v
            }
        }
    }
    $map
}

# --- Get-DscWingetId ----------------------------------------------------------
# The winget package ids declared in configuration.dsc.yaml, the file the README
# now names as Step 0 for a fresh box. That baseline and packages/winget.json (the
# manifest Install-Packages.ps1 actually reads) describe overlapping sets with
# nothing keeping them in step, so tests/Packages.Tests.ps1 gates them against each
# other and calls this.
#
# Parsed with a regex rather than a YAML module to keep the offline/dependency-free
# promise the rest of the package tooling makes. A winget id is Publisher.Package —
# at least one dot, no whitespace — which is exactly what separates the
# `settings: id:` values from the DSC *resource* ids (os-version, developer-mode,
# windows-terminal), none of which contain a dot.
function Get-DscWingetId {
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { if ($_ -match '^\s*id:\s*(\S+)\s*$') { $Matches[1] } } |
            Where-Object { $_ -match '^[^\s.]+(\.[^\s.]+)+$' } |
            Sort-Object -Unique
    )
}

# --- Get-UnpinnableWingetId ---------------------------------------------------
# winget ids that can NEVER appear in the lock, by design — not because someone
# forgot to re-run the generator. Some apps ship their own updater and move out
# from under winget, so `winget export` emits a constraint token ("> 8.12.28.25")
# instead of an exact version, and ConvertFrom-WingetExport rejects it above so
# -Frozen doesn't break. The consequence is a permanent lock gap, which the drift
# check must treat as expected rather than as staleness.
#
# Keep this list SHORT and justified: every entry is a package `-Frozen` cannot
# reproduce, so adding one is a real (if unavoidable) loss of reproducibility.
function Get-UnpinnableWingetId {
    @(
        # Self-updating installer; winget only ever reports "> <version>".
        'AgileBits.1Password'
    )
}

# --- Get-PackageLockDrift -----------------------------------------------------
# Compare the DESIRED names (from a manifest) against a lock map and report what's
# out of sync: Missing = desired-but-unlocked (added to the manifest without
# re-running the generator), Orphan = locked-but-no-longer-desired (removed from
# the manifest). This is the offline, CI-checkable half of B4 — it can't verify
# the version strings are the truly-installed ones, but it guarantees the lock and
# the manifest describe the SAME set. Case-insensitive.
#
# -Ignore drops names from BOTH sides before comparing (see Get-UnpinnableWingetId):
# an unpinnable package is neither Missing when absent from the lock nor Orphan if a
# stale lock still carries it, so the check stays quiet either way.
function Get-PackageLockDrift {
    param([string[]]$DesiredNames, [hashtable]$LockMap, [string[]]$Ignore)
    $skip = @($Ignore | Where-Object { $_ })
    $desired = @($DesiredNames | Where-Object { $_ -and $skip -notcontains $_ })
    $locked = @(if ($LockMap) { $LockMap.Keys | Where-Object { $skip -notcontains $_ } })
    $missing = @($desired | Where-Object { $locked -notcontains $_ } | Sort-Object -Unique)
    $orphan = @($locked  | Where-Object { $desired -notcontains $_ } | Sort-Object -Unique)
    [pscustomobject]@{
        Missing = $missing
        Orphan  = $orphan
        InSync  = ($missing.Count -eq 0 -and $orphan.Count -eq 0)
    }
}

# --- New-PackageLockObject ----------------------------------------------------
# Assemble the lockfile object from resolved maps, ready for ConvertTo-Json. Keys
# are sorted so the committed file has a stable, diff-friendly order regardless of
# scoop/winget enumeration order. GeneratedAt is injected (not read from the clock)
# so the builder stays pure and testable.
function New-PackageLockObject {
    param([hashtable]$Scoop, [hashtable]$Winget, [string]$GeneratedAt)
    $sorted = {
        param($Map)
        $o = [ordered]@{}
        # Tolerate a $null map (empty section) like the rest of the lock API.
        foreach ($k in @(if ($Map) { $Map.Keys | Sort-Object })) { $o[$k] = "$($Map[$k])" }
        $o
    }
    [ordered]@{
        _comment    = 'Generated by Update-PackageLock.ps1 - exact resolved versions for -Frozen installs. Do not hand-edit; re-run the generator.'
        generatedAt = $GeneratedAt
        scoop       = & $sorted $Scoop
        winget      = & $sorted $Winget
    }
}
