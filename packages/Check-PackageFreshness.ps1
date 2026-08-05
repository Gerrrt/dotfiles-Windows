#!/usr/bin/env pwsh
#requires -Version 7
<#
.SYNOPSIS
  Report managed scoop/winget apps whose upstream version is ahead of packages.lock.json.

.DESCRIPTION
  FINDINGS ONLY — this never edits the lock. Re-pinning requires the apps actually
  installed (run Update-PackageLock.ps1 on your box), so this just flags what is behind.
  Built to run on a windows-latest runner via .github/workflows/package-freshness.yml,
  where scoop + winget resolve real versions. Writes a markdown report to -ReportPath
  when anything is behind; removes the file and exits 0 when everything matches.

  Reuses Read-PackageLock / Get-LockedVersion from packages/PackageLock.ps1 so it reads
  the lock exactly as the rest of the package tooling does, and Test-PackageVersionMatch
  to compare so trailing-zero padding ("2.7.10.0" vs "2.7.10") isn't reported as an
  update. Per-app failures are warned and skipped — a single unresolvable package never
  fails the run.
#>
[CmdletBinding()]
param(
    [string]$ReportPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'package-freshness.md'),
    [switch]$SkipScoop,
    [switch]$SkipWinget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'PackageLock.ps1')

$lock       = Read-PackageLock (Get-Content (Join-Path $here 'packages.lock.json') -Raw)
$scoopfile  = Get-Content (Join-Path $here 'scoopfile.json') -Raw | ConvertFrom-Json
$wingetfile = Get-Content (Join-Path $here 'winget.json')   -Raw | ConvertFrom-Json

$outdated  = [System.Collections.Generic.List[object]]::new()
$skipped   = [System.Collections.Generic.List[string]]::new()
$unhealthy = [System.Collections.Generic.List[string]]::new()

function Get-ScoopBucketFault {
    <#
      Return why a bucket clone can't be trusted, or $null when it's fine.

      This exists because a bucket is a git clone, and a git clone can get STUCK.
      A wedged clone doesn't error — `scoop update` prints its failure and moves on,
      and every manifest this script then reads is served from whatever commit the
      bucket froze at. The versions still parse, still compare, and still come back
      "matching", so the freshness check goes green on stale data. That is the worst
      possible failure mode for a check: wrong in the REASSURING direction.

      Not hypothetical. On 2026-08-04 the `extras` clone was stuck mid-merge on an
      upstream rename (`UD bucket/pycharm.json`) and had been since mid-July. Locally
      `scoop status` reported lazygit and tailscale "latest version" while this bot
      correctly had them months behind — the box contradicted CI, and the box was
      wrong. Reset to origin and it immediately reproduced the bot's findings.

      Cheap enough to run unconditionally: a handful of git calls. On a CI runner the
      buckets are freshly added so this is a no-op, but it also catches the case where
      the `scoop bucket add` loop above swallowed a failure (its catch is empty) and
      left a bucket missing — today that degrades quietly into a "no manifest version"
      skip for every app in it.
    #>
    param([string]$Path)

    if (-not (Test-Path $Path)) { return 'bucket directory is missing (did `scoop bucket add` fail?)' }
    $gitDir = Join-Path $Path '.git'
    if (-not (Test-Path $gitDir)) { return 'not a git clone — cannot verify it is current' }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }  # can't check; don't cry wolf

    # An interrupted merge/rebase is exactly the extras case: HEAD is pinned at the
    # pre-merge commit and every subsequent pull refuses with "unmerged files".
    # NB single-quoted strings below — in a double-quoted PowerShell string a backtick
    # is the escape character, so the markdown code ticks would be silently eaten.
    $stuck = [ordered]@{
        'MERGE_HEAD'       = 'merge'
        'rebase-merge'     = 'rebase'
        'rebase-apply'     = 'rebase'
        'CHERRY_PICK_HEAD' = 'cherry-pick'
    }
    foreach ($marker in $stuck.Keys) {
        if (Test-Path (Join-Path $gitDir $marker)) {
            return ('stuck mid-{0} ({1}) — every `git pull` here fails, so its manifests are frozen' -f $stuck[$marker], $marker)
        }
    }

    $status = @(git -C $Path status --porcelain 2>&1)
    if ($LASTEXITCODE -ne 0) { return "git status failed: $($status -join ' ')" }
    if ($status.Count -gt 0) {
        $sample = ($status | Select-Object -First 3) -join '; '
        return "working tree is dirty ($($status.Count) path(s): $sample) — a pull may be blocked"
    }
    return $null
}

function Test-ExactVersion {
    # An exact pin we can compare; ranges/constraints like "> 8.12" are skipped.
    param([string]$Value)
    return $Value -match '^[0-9][0-9A-Za-z._+-]*$'
}

# Unit-test hook: dot-source for the pure helpers above without installing scoop or
# hitting the network. Same idiom as nvim-sync/starship-sync/install (see their
# *_LIBONLY hooks); Packages.Tests.ps1 drives Get-ScoopBucketFault through it.
if ($env:DOTFILES_PKGFRESH_LIBONLY -eq '1') { return }

# ---- scoop: install (no apps) + add buckets, then read manifest versions off disk ----
if (-not $SkipScoop) {
    try {
        if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
            # Fetch the installer to a STRING first so it can be integrity-checked
            # before it runs — the same opt-in gate install.ps1 applies, so ONE
            # DOTFILES_SCOOP_SHA256 value covers both the installer and this CI path
            # (that gap — CI had no gate — is what issue #129 flagged). The SHA is
            # computed over the UTF-8 string bytes exactly as install.ps1's
            # Get-DotStringSha256 does, so the same expected hash matches here.
            # Deliberately NO hardcoded pin: get.scoop.sh is a moving target, so a
            # baked-in SHA would break CI on every upstream installer edit.
            $scoopSrc = Invoke-RestMethod -Uri 'https://get.scoop.sh'
            # Hash and WRITE the exact same UTF-8 byte array, so the file that runs is
            # byte-for-byte what we verified (Set-Content re-encodes / appends a newline,
            # so it would NOT match the hashed bytes). These bytes are the BOM-less UTF-8
            # of the string — GetBytes never emits a preamble — matching install.ps1's
            # Get-DotStringSha256, so one DOTFILES_SCOOP_SHA256 value covers both paths.
            $scoopBytes = [System.Text.Encoding]::UTF8.GetBytes($scoopSrc)
            if ($env:DOTFILES_SCOOP_SHA256) {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try { $actual = (($sha.ComputeHash($scoopBytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
                finally { $sha.Dispose() }
                if ($actual -ne $env:DOTFILES_SCOOP_SHA256.ToLowerInvariant()) {
                    # A mismatched installer is a security STOP, not a transient setup
                    # hiccup — throw a tagged error the outer catch re-raises (below) so
                    # the run actually fails instead of warning and carrying on.
                    throw "scoop installer hash mismatch — expected $($env:DOTFILES_SCOOP_SHA256), got $actual"
                }
            }
            # Must run as a FILE (scoop's installer takes -RunAsAdmin, which iex can't
            # pass). WriteAllBytes emits exactly the verified bytes — no re-encoding.
            $installer = Join-Path ([System.IO.Path]::GetTempPath()) 'install-scoop.ps1'
            [System.IO.File]::WriteAllBytes($installer, $scoopBytes)
            & $installer -RunAsAdmin 2>&1 | Out-Null   # CI runs elevated; -RunAsAdmin lets scoop install anyway
            $env:PATH = "$HOME\scoop\shims;$env:PATH"   # make `scoop` resolvable in this session
        }
        foreach ($b in $scoopfile.buckets) {
            try { scoop bucket add $b.Name $b.Source 2>&1 | Out-Null } catch { }
        }
    } catch {
        # A tampered-installer hash mismatch must fail the run, not degrade to a
        # warning — re-throw it. Transient setup failures (network, bucket add) stay
        # tolerant so a single flaky source never fails the freshness check.
        if ($_.Exception.Message -like 'scoop installer hash mismatch*') { throw }
        Write-Warning "scoop setup failed: $($_.Exception.Message)"
    }

    $bucketRoot = Join-Path $HOME 'scoop\buckets'

    # Validate the inputs before trusting the comparison. Only the buckets apps
    # actually resolve manifests from — that's the data this script reads.
    foreach ($bucketName in (@($scoopfile.apps | ForEach-Object { $_.Source }) | Where-Object { $_ } | Sort-Object -Unique)) {
        $fault = Get-ScoopBucketFault (Join-Path $bucketRoot $bucketName)
        if ($fault) { $unhealthy.Add("``$bucketName`` — $fault") }
    }

    foreach ($app in $scoopfile.apps) {
        $name   = $app.Name
        $bucket = $app.Source
        $locked = Get-LockedVersion $lock.Scoop $name
        if (-not $locked) { continue }
        if (-not (Test-ExactVersion $locked)) { $skipped.Add("scoop/$name (lock '$locked' is not an exact pin)"); continue }
        $avail = $null
        try {
            $manifest = Get-ChildItem -Path (Join-Path $bucketRoot $bucket) -Recurse -Filter "$name.json" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($manifest) { $avail = (Get-Content $manifest.FullName -Raw | ConvertFrom-Json).version }
        } catch { $avail = $null }
        if (-not $avail) { $skipped.Add("scoop/$name (no manifest version in bucket '$bucket')"); continue }
        if (-not (Test-PackageVersionMatch "$avail" "$locked")) {
            $outdated.Add([pscustomobject]@{ Manager = 'scoop'; Name = $name; Locked = $locked; Available = "$avail" })
        }
    }
}

# ---- winget: ask the live source for the latest version of each managed id ----
if (-not $SkipWinget) {
    foreach ($entry in $wingetfile.packages) {
        $id = if ($entry -is [string]) { $entry }
              elseif ($entry.PSObject.Properties.Name -contains 'id') { $entry.id }
              else { $null }
        if (-not $id) { continue }
        $locked = Get-LockedVersion $lock.Winget $id
        if (-not $locked) { continue }
        if (-not (Test-ExactVersion $locked)) { $skipped.Add("winget/$id (lock '$locked' is not an exact pin)"); continue }
        $avail = $null
        try {
            $out = (winget show --id $id --exact --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
            $m = [regex]::Match($out, '(?im)^\s*Version:\s*(.+?)\s*$')
            if ($m.Success) { $avail = $m.Groups[1].Value.Trim() }
        } catch { $avail = $null }
        if (-not $avail) { $skipped.Add("winget/$id (version not resolved)"); continue }
        if (-not (Test-PackageVersionMatch $avail $locked)) {
            $outdated.Add([pscustomobject]@{ Manager = 'winget'; Name = $id; Locked = $locked; Available = $avail })
        }
    }
}

# ---- report ----
if (Test-Path $ReportPath) { Remove-Item $ReportPath -Force }

# An unhealthy bucket must file a report even when NOTHING looks outdated — that
# silent-green case is the entire reason the check exists. Reporting only when
# $outdated is non-empty would keep the exact failure it is meant to catch invisible.
if ($outdated.Count -eq 0 -and $unhealthy.Count -eq 0) {
    Write-Output "All managed scoop/winget packages match packages.lock.json ($($skipped.Count) skipped)."
    exit 0
}

$lines = [System.Collections.Generic.List[string]]::new()

# Leads the report: it invalidates everything below it, so it must not be a footnote.
if ($unhealthy.Count -gt 0) {
    $lines.Add('> [!WARNING]')
    $lines.Add('> **A scoop bucket clone is not in a trustworthy state, so the versions below may be wrong.**')
    $lines.Add('> A wedged bucket keeps serving manifests from whatever commit it froze at, and those')
    $lines.Add('> stale versions compare as *matching* — so the real risk is a package silently reported')
    $lines.Add('> as current when it is months behind.')
    $lines.Add('>')
    foreach ($u in $unhealthy) { $lines.Add("> - $u") }
    $lines.Add('>')
    $lines.Add('> Fix on the affected box, then re-run:')
    $lines.Add('>')
    $lines.Add('> ```powershell')
    $lines.Add('> git -C "$HOME\scoop\buckets\<bucket>" fetch origin')
    $lines.Add('> git -C "$HOME\scoop\buckets\<bucket>" reset --hard origin/HEAD   # buckets are pristine upstream clones')
    $lines.Add('> scoop update')
    $lines.Add('> ```')
    $lines.Add('')
}

if ($outdated.Count -gt 0) {
    $lines.Add('The following managed packages are behind their upstream version (vs `packages.lock.json`):')
    $lines.Add('')
    $lines.Add('| Manager | Package | Locked | Available |')
    $lines.Add('| --- | --- | --- | --- |')
    foreach ($o in ($outdated | Sort-Object Manager, Name)) {
        $lines.Add("| $($o.Manager) | ``$($o.Name)`` | $($o.Locked) | $($o.Available) |")
    }
    $lines.Add('')
    $lines.Add('Re-pin from a box with the apps installed: `.\packages\Update-PackageLock.ps1`, then commit `packages.lock.json`.')
}
else {
    $lines.Add('No package was found behind its upstream version — but see the warning above before trusting that.')
}
if ($skipped.Count -gt 0) {
    $lines.Add('')
    $lines.Add('<details><summary>Skipped (could not compare)</summary>')
    $lines.Add('')
    foreach ($s in $skipped) { $lines.Add("- $s") }
    $lines.Add('')
    $lines.Add('</details>')
}
Set-Content -Path $ReportPath -Value ($lines -join "`n") -Encoding UTF8
Write-Output ("$($outdated.Count) package(s) behind upstream, $($unhealthy.Count) unhealthy bucket(s)" +
    " — report written to $ReportPath")
exit 0
