# ============================================================================
#  Doctor.Helpers.ps1  -  pure dotfiles-doctor logic, owned by the Dotfiles
#  module (B7 stage 2b).
#
#  Extracted from os/45-doctor.ps1 so the host-INDEPENDENT pieces — the result
#  model, aggregation, the group classifier, the fragment-health mapper, the two
#  one-line detail formatters, and the remediation planner — live in the module
#  (exported, unit-tested in tests/Doctor.Tests.ps1) instead of as global:
#  functions. The host-SPECIFIC probes, the renderer, and the `dotfiles-doctor`
#  verb stay in the fragment and call these via the module export.
# ============================================================================

# --- result model -------------------------------------------------------------
function New-DoctorResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'fail')][string]$Status,
        [string]$Detail = '',
        [string]$Hint   = ''
    )
    [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Hint = $Hint }
}

# --- aggregate a set of results into counts + an overall verdict --------------
function Get-DoctorSummary {
    param([object[]]$Results)
    $ok   = @($Results | Where-Object Status -eq 'ok').Count
    $warn = @($Results | Where-Object Status -eq 'warn').Count
    $fail = @($Results | Where-Object Status -eq 'fail').Count
    $overall = if ($fail) { 'fail' } elseif ($warn) { 'warn' } else { 'ok' }
    [pscustomobject]@{ Ok = $ok; Warn = $warn; Fail = $fail; Total = $Results.Count; Overall = $overall }
}

# --- pure group classifier ----------------------------------------------------
# Bucket a result into a display section from its Name so the report reads as
# scannable groups instead of one flat list (U4). Pure, so it's unit-tested; the
# renderer just walks the fixed group order. Anything unmatched lands in 'Other',
# so a newly-added probe still shows up (merely ungrouped) instead of silently
# vanishing from the report.
function Get-DoctorGroup {
    [OutputType([string])]
    param([string]$Name)
    switch -Regex ($Name) {
        '^(PowerShell|Execution policy|Symlink)'                      { return 'Shell & environment' }
        '^(Repo|Profile link|link:|Modules|git identity|nvim vendor)' { return 'Repo & links' }
        '^(Profile fragments|Core toolchain|Scoop buckets|Maint tasks)' { return 'Health & toolchain' }
        default                                                       { return 'Other' }
    }
}

# --- fragment-load health (pure: maps the loader's error list to a result) ----
# $null  -> profile never loaded (probably a direct dot-source, not a real shell)
# empty  -> every fragment loaded clean
# items  -> at least one fragment threw; surface the count + the first failure.
function Get-FragmentHealthResult {
    param($LoadErrors)
    if ($null -eq $LoadErrors) {
        return New-DoctorResult 'Profile fragments' 'warn' 'not loaded via the profile' 'open a new pwsh shell so the profile loads'
    }
    $list = @($LoadErrors)
    if ($list.Count -eq 0) {
        return New-DoctorResult 'Profile fragments' 'ok' 'all fragments loaded clean'
    }
    return New-DoctorResult 'Profile fragments' 'fail' "$($list.Count) failed: $($list[0])" 'fix the fragment, then run: reload'
}

# --- pure provenance formatter ------------------------------------------------
# Render the repo's git state into a one-line detail: short SHA, a (dirty) marker
# when there are uncommitted changes, and the commit date when known. Pure (the
# git calls live in the probe), so the formatting is unit-tested.
function Get-DotRepoVersionDetail {
    param([string]$Sha, [bool]$IsDirty, [string]$When)
    if (-not $Sha) { return 'unknown (no git metadata)' }
    $detail = $Sha
    if ($When)    { $detail += "  ($When)" }
    if ($IsDirty) { $detail += '  [dirty]' }
    return $detail
}

# --- pure nvim-vendor formatter -----------------------------------------------
# Render nvim/.core-ref (written by nvim-sync.ps1) into a one-line detail: the
# short Core commit the vendored nvim/ tree came from, plus the commit date when
# known. Pure (the file read lives in the probe), so the formatting is unit-tested.
function Get-NvimVendorDetail {
    [OutputType([string])]
    param([string]$Sha, [string]$When)
    if (-not $Sha) { return 'no vendor ref recorded (run nvim-sync.ps1)' }
    $short = if ($Sha.Length -ge 7) { $Sha.Substring(0, 7) } else { $Sha }
    $detail = "vendored from core@$short"
    if ($When -and $When -ne 'unknown') { $detail += "  ($When)" }
    return $detail
}

# --- pure starship-vendor formatter -------------------------------------------
# The sibling of Get-NvimVendorDetail for the OTHER mirrored asset. Doctor
# reported nvim's provenance but not starship's, so a stale starship.toml was
# invisible on the host. Also surfaces the PIN, because starship is the asset
# that carries one (`pinned = vX.Y.Z`) and a dropped pin is exactly the drift
# worth seeing. Pure (the file read lives in the probe), so it is unit-tested.
function Get-StarshipVendorDetail {
    [OutputType([string])]
    param([string]$Sha, [string]$When, [string]$Pinned)
    if (-not $Sha) { return 'no vendor ref recorded (run starship-sync.ps1)' }
    $short = if ($Sha.Length -ge 7) { $Sha.Substring(0, 7) } else { $Sha }
    $detail = "vendored from core@$short"
    if ($Pinned -and $Pinned -ne '(branch tip)' -and $Pinned -ne 'unknown') { $detail += " (pinned $Pinned)" }
    if ($When -and $When -ne 'unknown') { $detail += "  ($When)" }
    return $detail
}

# --- pure theme-vendor formatter ----------------------------------------------
# The third sibling, for theme/palette.toml (written by theme-sync.ps1). Carries a
# pin like starship's, so it takes the same -Pinned argument.
#
# This one is worth MORE than the other two on a host, because the palette is an
# INPUT rather than a leaf config: gen-theme.ps1 renders it into nine blocks across
# six files. A stale palette here does not look stale — every generated block is
# perfectly consistent with it, and the terminal layer is simply a version behind
# the fleet with nothing on screen to say so. Pure (the file read lives in the
# probe), so the formatting is unit-tested.
function Get-ThemeVendorDetail {
    [OutputType([string])]
    param([string]$Sha, [string]$When, [string]$Pinned)
    if (-not $Sha) { return 'no vendor ref recorded (run theme-sync.ps1)' }
    $short = if ($Sha.Length -ge 7) { $Sha.Substring(0, 7) } else { $Sha }
    $detail = "vendored from core@$short"
    if ($Pinned -and $Pinned -ne '(branch tip)' -and $Pinned -ne 'unknown') { $detail += " (pinned $Pinned)" }
    if ($When -and $When -ne 'unknown') { $detail += "  ($When)" }
    return $detail
}

# --- scoop bucket health -> a doctor result -----------------------------------
# Pure: takes the faults the host probe found (one string per unhealthy bucket,
# already formatted by packages/Check-PackageFreshness.ps1's Get-ScoopBucketFault)
# and turns them into a result row. Kept here, and unit-tested, because the
# WORDING is the whole value of this check.
#
# Why doctor cares at all: a scoop bucket is a git clone, and a stuck clone keeps
# serving manifests from whatever commit it froze at. `scoop status` then reports
# months-old packages as "latest version" and every freshness answer on the box is
# quietly wrong -- in the reassuring direction. This box sat that way from mid-July
# to 2026-08-04 with `extras` stuck mid-merge on an upstream rename, contradicting
# the CI freshness bot, which was right.
#
# `warn`, not `fail`: nothing is broken and no tool is missing -- the box just
# cannot be trusted to tell you what is current until the clone is unwedged.
function Get-ScoopBucketHealthResult {
    [OutputType([pscustomobject])]
    param([string[]]$Faults, [int]$Checked = 0)
    if (-not $Faults -or $Faults.Count -eq 0) {
        $detail = if ($Checked -gt 0) { "$Checked bucket(s) clean and pullable" } else { 'no scoop buckets found' }
        return (New-DoctorResult 'Scoop buckets' 'ok' $detail)
    }
    return (New-DoctorResult 'Scoop buckets' 'warn' ($Faults -join '; ') `
        ('a wedged bucket makes `scoop status` report stale packages as current — ' +
         'git -C "$HOME\scoop\buckets\<bucket>" fetch origin; ' +
         'git -C "$HOME\scoop\buckets\<bucket>" reset --hard origin/HEAD; scoop update'))
}

# --- pure remediation planner -------------------------------------------------
# Map the non-ok results to a DEDUPED, ordered list of fix actions dotfiles-doctor
# -Fix can run. Pure (no host calls), so the routing is unit-tested; the actions
# themselves live in Invoke-DoctorFix (host-side, in the fragment).
function Get-DoctorFixPlan {
    param([object[]]$Results)
    $plan = [System.Collections.Generic.List[string]]::new()
    $add  = { param($k) if ($plan -notcontains $k) { $plan.Add($k) } }
    foreach ($res in $Results) {
        if ($res.Status -eq 'ok') { continue }
        switch -Regex ($res.Name) {
            '^Execution policy$'     { & $add 'execpolicy' }
            '^Profile link$'         { & $add 'rewire' }
            '^link: '                { & $add 'rewire' }
            '^Modules off OneDrive$' { & $add 'localize-modules' }
            '^Core toolchain$'       { & $add 'install-packages' }
        }
    }
    return $plan
}
