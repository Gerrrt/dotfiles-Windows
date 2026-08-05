# ============================================================================
#  os/45-doctor.ps1  -  `dotfiles-doctor`: one command that audits whether this
#  host is wired up correctly, so a half-finished bootstrap stops being a silent
#  mystery. Every check reports ok / warn / fail with a concrete fix hint.
#
#      dotfiles-doctor            # human-readable report + summary line
#      dotfiles-doctor -Quiet     # just the summary
#      dotfiles-doctor -PassThru  # emit the result objects (for scripting/tests)
#
#  The probes are host-specific (registry, execution policy, symlinks, PATH) and
#  stay here behind the host. The result model, aggregation, group classifier,
#  detail formatters and fix planner are pure, so they now live in the Dotfiles
#  module (powershell/Dotfiles/Doctor.Helpers.ps1), imported by the profile BEFORE
#  this fragment and unit-tested in tests/Doctor.Tests.ps1. The probes, renderer
#  and `dotfiles-doctor` verb below call them via that module export.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: dotfiles-doctor, Get-DotRepoRevision
# requires: Format-DotWrap, Get-DoctorFixPlan, Get-DoctorGroup, Get-DoctorSummary, Get-DotConsoleWidth, Get-DotfilesLinkPlan, Get-DotGlyph, Get-DotRepoVersionDetail, Get-FragmentHealthResult, Get-NvimVendorDetail, modules-localize, New-DoctorResult, Test-Cmd, Test-CmdRuns, Test-DotUnicode, Write-DotErr, Write-DotHost, Write-DotWarn

# --- repo git revision (shared by the probe, the header, and core-version) -----
# The doctor's "Repo version" row, the report HEADER, and the `core-version` verb
# (os/48-core.ps1) all want the same three facts about the checkout: short SHA,
# commit date, and whether the tree is dirty. Resolve them ONCE here — one `git log`
# (SHA + date in a single spawn) plus one status probe — so nothing open-codes the
# same git calls a second or third time (C2/C3). Returns $null when $Root isn't a git
# checkout, so each caller renders its own "unversioned" copy. Lives in the fragment,
# not the pure Dotfiles module, because it spawns git (the module stays host-free).
function global:Get-DotRepoRevision {
    [OutputType([pscustomobject])]
    param([string]$Root)
    if (-not ($Root -and (Test-Path (Join-Path $Root '.git')) -and (Test-Cmd git))) { return $null }
    $rev   = @(& git -C $Root log -1 --format='%h%n%cs' HEAD 2>$null)
    $sha   = if ($rev.Count -ge 1) { $rev[0] } else { '' }
    $when  = if ($rev.Count -ge 2) { $rev[1] } else { '' }
    $dirty = [bool]((& git -C $Root status --porcelain 2>$null) | Select-Object -First 1)
    [pscustomobject]@{ Sha = $sha; When = $when; IsDirty = $dirty }
}

# --- render one result line ---------------------------------------------------
# Glyphs/colour route through the shared helpers (core/05-lib.ps1) so the report
# degrades cleanly under NO_COLOR / DOTFILES_ASCII like every other renderer.
function script:Write-DoctorLine {
    param([object]$Result)
    $glyph, $color = switch ($Result.Status) {
        'ok'   { (Get-DotGlyph ok),   'Green' }
        'warn' { (Get-DotGlyph warn), 'Yellow' }
        'fail' { (Get-DotGlyph fail), 'Red' }
    }
    # Wrap the detail to the console width too (U5), aligned under the detail
    # column. The continuation indent is the ACTUAL lead width ("  <glyph> " +
    # the 26-col name + " "), so it lines up in both Unicode and ASCII glyph modes.
    $lead   = ("  {0} " -f $glyph) + ("{0,-26}" -f $Result.Name) + ' '
    $indent = ' ' * $lead.Length
    $detail = @(Format-DotWrap -Text "$($Result.Detail)" -Width (Get-DotConsoleWidth) -Indent $indent)
    Write-DotHost "  $glyph " -Color $color -NoNewline
    Write-Host ("{0,-26}" -f $Result.Name) -NoNewline
    if ($detail.Count) {
        Write-DotHost (' ' + $detail[0].TrimStart()) -Color Gray
        for ($i = 1; $i -lt $detail.Count; $i++) { Write-DotHost $detail[$i] -Color Gray }
    } else {
        Write-Host ''
    }
    if ($Result.Status -ne 'ok' -and $Result.Hint) {
        # Word-wrap the hint to the console so a long fix instruction (or path)
        # doesn't run off a narrow terminal (U12). Derive the continuation indent
        # from the ACTUAL first-line lead-in ("      <arrow> "), whose width differs
        # between the Unicode arrow (1 col) and the ASCII '->' (2 cols), so the
        # wrapped lines stay aligned under the text — and the wrap width stays
        # correct — in both glyph modes.
        $lead    = "      {0} " -f (Get-DotGlyph arrow)
        $indent  = ' ' * $lead.Length
        $wrapped = @(Format-DotWrap -Text $Result.Hint -Width (Get-DotConsoleWidth) -Indent $indent)
        for ($i = 0; $i -lt $wrapped.Count; $i++) {
            if ($i -eq 0) { Write-DotHost ($lead + $wrapped[$i].TrimStart()) -Color DarkGray }
            else          { Write-DotHost $wrapped[$i] -Color DarkGray }
        }
    }
}

# --- a symlink that resolves into the dotfiles repo? --------------------------
function script:Test-LinkIntoRepo {
    param([string]$Link)
    if (-not (Test-Path -LiteralPath $Link)) { return $false }
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne 'SymbolicLink') { return $false }
    $target = @($item.Target)[0]
    return ($target -and $global:DOTFILES -and $target -like "*$($global:DOTFILES)*")
}

# --- the probes (host-specific; each returns a DoctorResult) ------------------
# -RepoRevision: the pre-resolved Get-DotRepoRevision record, threaded in by
# dotfiles-doctor so the "Repo version" row and the header share one git spawn.
function script:Get-DoctorResults {
    param([pscustomobject]$RepoRevision)
    $r = [System.Collections.Generic.List[object]]::new()

    # pwsh edition
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $r.Add((New-DoctorResult 'PowerShell 7 (pwsh)' 'ok' "v$($PSVersionTable.PSVersion)"))
    } else {
        $r.Add((New-DoctorResult 'PowerShell 7 (pwsh)' 'warn' 'running Windows PowerShell 5.1' 'do daily work in pwsh — the profile targets it'))
    }

    # execution policy (CurrentUser)
    try {
        $pol = Get-ExecutionPolicy -Scope CurrentUser
        if ($pol -in 'RemoteSigned', 'Unrestricted', 'Bypass') {
            $r.Add((New-DoctorResult 'Execution policy' 'ok' "$pol (CurrentUser)"))
        } else {
            $r.Add((New-DoctorResult 'Execution policy' 'fail' "$pol blocks the profile" 'Set-ExecutionPolicy RemoteSigned -Scope CurrentUser'))
        }
    } catch { $r.Add((New-DoctorResult 'Execution policy' 'warn' 'could not read (Group Policy?)' '')) }

    # symlink capability
    $devMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (($devMode -eq 1) -or $isAdmin) {
        $r.Add((New-DoctorResult 'Symlink capability' 'ok' $(if ($isAdmin) { 'elevated' } else { 'Developer Mode on' })))
    } else {
        $r.Add((New-DoctorResult 'Symlink capability' 'warn' 'no Dev Mode / not elevated' 'enable Developer Mode so install.ps1 links instead of copies'))
    }

    # Repo root: the profile sets $global:DOTFILES from $env:DOTFILES_WIN, but
    # accept either so a direct dot-source (no profile) still reports accurately.
    $root = if ($global:DOTFILES) { $global:DOTFILES } else { $env:DOTFILES_WIN }
    if ($root -and (Test-Path $root)) {
        $r.Add((New-DoctorResult 'Repo root' 'ok' $root))
    } else {
        $r.Add((New-DoctorResult 'Repo root' 'fail' 'DOTFILES_WIN unset/missing' 're-run install.ps1 to set DOTFILES_WIN'))
    }

    # Repo provenance: which revision is actually on this box (and is it dirty?).
    # Informational — a copy-install with no .git is fine, just unversioned. The
    # revision is resolved by the caller and passed in (so the header can reuse the
    # same object without a second git spawn — C2); resolve it here when the caller
    # handed us nothing. Gate on $null, NOT $PSBoundParameters: a caller that passes
    # `-RepoRevision $null` (dotfiles-doctor does, on a non-git checkout) genuinely
    # has no revision, so re-resolving is correct — and cheap, since Get-DotRepoRevision
    # fails fast on the .git check (no git spawn) and returns $null again.
    $rev = if ($null -ne $RepoRevision) { $RepoRevision } else { Get-DotRepoRevision -Root $root }
    if ($rev) {
        $r.Add((New-DoctorResult 'Repo version' 'ok' (Get-DotRepoVersionDetail -Sha "$($rev.Sha)" -IsDirty $rev.IsDirty -When "$($rev.When)")))
    } else {
        $r.Add((New-DoctorResult 'Repo version' 'ok' 'not a git checkout (copy install — unversioned)'))
    }

    # nvim vendor provenance (B1): which Core commit the vendored nvim/ tree came
    # from. Informational — a host whose nvim/ predates the provenance marker (or
    # that never ran nvim-sync) simply has no ref yet, which the formatter says.
    # Gated on Test-Path (not just $root non-empty) so a bad DOTFILES_WIN doesn't
    # add a misleading 'ok' row while 'Repo root' is already failing above.
    if ($root -and (Test-Path $root)) {
        $refFile = Join-Path $root 'nvim\.core-ref'
        $sha = ''; $when = ''
        if (Test-Path $refFile) {
            $ref  = Get-Content $refFile -ErrorAction SilentlyContinue
            $sha  = (($ref | Where-Object { $_ -match '^commit\s*=' } | Select-Object -First 1) -replace '^commit\s*=\s*', '')
            $when = (($ref | Where-Object { $_ -match '^date\s*='   } | Select-Object -First 1) -replace '^date\s*=\s*', '')
        }
        $r.Add((New-DoctorResult 'nvim vendor' 'ok' (Get-NvimVendorDetail -Sha "$sha" -When "$when")))
    }

    # profile symlink
    if (Test-LinkIntoRepo $PROFILE) {
        $r.Add((New-DoctorResult 'Profile link' 'ok' 'symlinked into the repo'))
    } elseif (Test-Path $PROFILE) {
        $r.Add((New-DoctorResult 'Profile link' 'warn' 'exists but not a repo symlink' 're-run install.ps1 -SkipPackages'))
    } else {
        $r.Add((New-DoctorResult 'Profile link' 'fail' 'no $PROFILE' 'run install.ps1'))
    }

    # modules off OneDrive
    $localModules = Join-Path $env:LOCALAPPDATA 'PowerShell\Modules'
    if ($env:PSModulePath -like "*$localModules*") {
        $r.Add((New-DoctorResult 'Modules off OneDrive' 'ok' 'local module path is on PSModulePath'))
    } else {
        $r.Add((New-DoctorResult 'Modules off OneDrive' 'warn' 'local module path not prepended' 'open a new shell; run modules-localize once'))
    }

    # key config links — enumerated from the SAME shared plan install.ps1 wires
    # and uninstall.ps1 removes (Get-DotfilesLinkPlan), so doctor can't fall out of
    # sync with the actual link set. The profile link is checked separately above,
    # so it's skipped here to avoid a duplicate row.
    if ($root) {
        # Windows Terminal keeps settings.json in a per-build location, so the plan lists
        # one ParentMustExist candidate per flavor (Store / unpackaged / Preview). Collect
        # them and report ONE summary row below instead of three (two forever "skipped").
        $wtRows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in (Get-DotfilesLinkPlan -RepoRoot $root)) {
            if ($row.Name -eq 'PowerShell profile') { continue }
            if ($row.ParentMustExist) { $wtRows.Add($row); continue }
            if (Test-LinkIntoRepo $row.Link)  { $r.Add((New-DoctorResult "link: $($row.Name)" 'ok' 'linked')) }
            elseif (Test-Path $row.Link)      { $r.Add((New-DoctorResult "link: $($row.Name)" 'warn' 'present, not a repo link' 're-run install.ps1 -SkipPackages')) }
            else                              { $r.Add((New-DoctorResult "link: $($row.Name)" 'warn' 'missing' 'run install.ps1')) }
        }
        # One Windows Terminal row, but keep the SAME four states the per-row logic above
        # reports so the collapse doesn't hide a real problem:
        #   linked        - a flavor's settings.json is our repo link
        #   present/not   - settings.json exists but isn't our link (foreign file)
        #   missing       - WT is installed (a flavor dir exists) but has no settings.json
        #   skipped       - no WT installed at all (nothing to link; not actionable)
        if ($wtRows.Count -gt 0) {
            $wtLinked    = @($wtRows | Where-Object { Test-LinkIntoRepo $_.Link })
            $wtFile      = @($wtRows | Where-Object { Test-Path -LiteralPath $_.Link })
            $wtInstalled = @($wtRows | Where-Object { Test-Path -LiteralPath (Split-Path -Parent $_.Link) })
            if ($wtLinked.Count -gt 0) {
                $r.Add((New-DoctorResult 'link: Windows Terminal settings' 'ok' 'linked'))
            } elseif ($wtFile.Count -gt 0) {
                $r.Add((New-DoctorResult 'link: Windows Terminal settings' 'warn' 'present, not a repo link' 're-run install.ps1 -SkipPackages'))
            } elseif ($wtInstalled.Count -gt 0) {
                $r.Add((New-DoctorResult 'link: Windows Terminal settings' 'warn' 'missing' 'run install.ps1'))
            } else {
                $r.Add((New-DoctorResult 'link: Windows Terminal settings' 'ok' 'skipped (Windows Terminal not installed)'))
            }
        }
    }

    # gitconfig.local identity
    $gcLocal = Join-Path $HOME '.gitconfig.local'
    if ((Test-Path $gcLocal) -and ((Get-Content $gcLocal -Raw) -notmatch 'YOUR NAME|you@example\.com')) {
        $r.Add((New-DoctorResult 'git identity' 'ok' 'name/email set in ~/.gitconfig.local'))
    } else {
        $r.Add((New-DoctorResult 'git identity' 'warn' 'placeholder or missing' 'set your name/email in ~/.gitconfig.local'))
    }

    # profile fragment load health (B7): the loader records any fragment that
    # threw into $global:DotfilesLoadErrors. Classification is pure (unit-tested).
    $r.Add((Get-FragmentHealthResult $global:DotfilesLoadErrors))

    # core toolchain on PATH
    $core = 'git', 'starship', 'zoxide', 'fzf', 'rg', 'fd', 'bat', 'eza', 'nvim', 'psmux'
    $missing = $core | Where-Object { -not (Test-Cmd $_) }
    if (-not $missing) {
        $r.Add((New-DoctorResult 'Core toolchain' 'ok' "$($core.Count) tools present"))
    } else {
        $r.Add((New-DoctorResult 'Core toolchain' 'warn' "missing: $($missing -join ', ')" 're-run .\packages\Install-Packages.ps1'))
    }

    # core toolchain EXECUTES (not just resolves): a shim can resolve via Get-Command
    # yet fail to LAUNCH — a stale Chocolatey shim, or a scoop shim whose app was
    # removed, shadowing the working binary. Test-Cmd above can't see that, so a
    # broken fzf/rg only bit inside fif/fbr/Ctrl+t. Probe the present tools for real
    # ("cannot find file" / "failed to run") and surface it with a concrete fix.
    # psmux is omitted on purpose: it's a shell tool with a non-standard version flag.
    $execCore = 'git', 'starship', 'zoxide', 'fzf', 'rg', 'fd', 'bat', 'eza', 'nvim'
    $broken   = $execCore | Where-Object { (Test-Cmd $_) -and -not (Test-CmdRuns $_) }
    if (-not $broken) {
        $r.Add((New-DoctorResult 'Core toolchain runs' 'ok' 'present tools launch'))
    } else {
        $r.Add((New-DoctorResult 'Core toolchain runs' 'fail' "on PATH but won't launch: $($broken -join ', ')" 'a stale Chocolatey/duplicate shim is shadowing the scoop binary — `scoop reset <pkg>` (e.g. ripgrep, fzf) or remove the duplicate, and put scoop\shims ahead of it on PATH'))
    }

    # scoop bucket clones must actually be pullable. A clone stuck mid-merge keeps
    # serving frozen manifests, so `scoop status` calls months-old packages "latest"
    # and the box quietly disagrees with the CI freshness bot — which is what happened
    # here with `extras` between mid-July and 2026-08-04. CI can't catch this (its
    # buckets are always freshly added), so the check has to live on the box.
    #
    # The detector is REUSED from packages/Check-PackageFreshness.ps1 via its
    # DOTFILES_PKGFRESH_LIBONLY hook rather than reimplemented — one definition of
    # "this bucket can't be trusted", and the freshness bot must stay self-contained
    # for CI (where this module isn't installed), so the dependency only goes this way.
    try {
        $bucketRoot = Join-Path $HOME 'scoop\buckets'
        if ((Test-Path $bucketRoot) -and $root -and (Test-Path $root)) {
            $pkgFresh = Join-Path $root 'packages\Check-PackageFreshness.ps1'
            if (Test-Path $pkgFresh) {
                $prev = $env:DOTFILES_PKGFRESH_LIBONLY
                try {
                    $env:DOTFILES_PKGFRESH_LIBONLY = '1'
                    . $pkgFresh
                } finally {
                    if ($null -eq $prev) { Remove-Item Env:DOTFILES_PKGFRESH_LIBONLY -ErrorAction SilentlyContinue }
                    else { $env:DOTFILES_PKGFRESH_LIBONLY = $prev }
                }
                $buckets = @(Get-ChildItem $bucketRoot -Directory -ErrorAction SilentlyContinue)
                $faults  = @()
                foreach ($b in $buckets) {
                    $fault = Get-ScoopBucketFault $b.FullName
                    if ($fault) { $faults += "$($b.Name) — $fault" }
                }
                $r.Add((Get-ScoopBucketHealthResult -Faults $faults -Checked $buckets.Count))
            }
        }
    } catch {
        # Never let a bucket probe take down the whole doctor run.
        $r.Add((New-DoctorResult 'Scoop buckets' 'warn' "could not check ($($_.Exception.Message))" ''))
    }

    return $r
}

# Run one planned action. Side-effecting (host), so it's kept tiny and out of the
# pure planner (Get-DoctorFixPlan, in the module). Unknown keys are a no-op.
function script:Invoke-DoctorFix {
    param([string]$Key)
    switch ($Key) {
        'execpolicy' {
            Write-DotHost '  → setting CurrentUser execution policy to RemoteSigned' -Color Cyan
            try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force } catch { Write-DotErr "failed: $_" }
        }
        'rewire' {
            $install = Join-Path $global:DOTFILES 'install.ps1'
            if (Test-Path $install) {
                Write-DotHost '  → re-wiring config symlinks (install.ps1 -SkipPackages)' -Color Cyan
                & $install -SkipPackages -NonInteractive
            } else { Write-DotErr 'install.ps1 not found' 'set DOTFILES_WIN / re-clone the repo' }
        }
        'localize-modules' {
            if (Get-Command modules-localize -ErrorAction SilentlyContinue) {
                Write-DotHost '  → moving modules off OneDrive (modules-localize)' -Color Cyan
                modules-localize
            } else { Write-DotErr 'modules-localize not available' 'open a new pwsh shell, then run it' }
        }
        'install-packages' {
            Write-DotWarn 'missing tools need the package installer.' 'run: .\packages\Install-Packages.ps1'
        }
    }
}

function global:dotfiles-doctor {
    [CmdletBinding()]
    param([switch]$Quiet, [switch]$PassThru, [switch]$Fix, [switch]$Json)

    # The result model + pure logic come from the Dotfiles module (imported before
    # this fragment). If a degraded load left the module out, the probes can't build
    # results — warn cleanly instead of throwing 'New-DoctorResult is not recognized'
    # from deep inside Get-DoctorResults.
    if (-not (Get-Command New-DoctorResult -ErrorAction SilentlyContinue)) {
        Write-Warning 'dotfiles-doctor: the Dotfiles module is not loaded, so its result helpers are unavailable. Open a new pwsh shell (or check $global:DotfilesLoadErrors) and retry.'
        return
    }

    # Resolve the repo root + git revision ONCE, up front, and thread the revision
    # through both the probe (the "Repo version" row) and the header below — one git
    # spawn shared, instead of the row computing it and the header re-deriving the SHA
    # with a third `git` call (C2). $root mirrors Get-DoctorResults' own resolution.
    $root = if ($global:DOTFILES) { $global:DOTFILES } else { $env:DOTFILES_WIN }
    $rev  = Get-DotRepoRevision -Root $root
    $results = Get-DoctorResults -RepoRevision $rev

    # -Json: emit a machine-readable summary+results object for tooling/CI and
    # return early — no human render, no colour, no -Fix (it's a query) (U4).
    if ($Json) {
        return ([pscustomobject]@{ summary = (Get-DoctorSummary $results); results = $results } |
            ConvertTo-Json -Depth 4)
    }

    if (-not $Quiet) {
        # Header mirrors Core's `core doctor` on Unix (dotfiles-core zsh/functions.zsh):
        # "<repo> <ver> — core-doctor (<glyph legend>)", cyan repo+version + dim legend,
        # so `core doctor` reads the same on both shells. Legend maps the row glyphs.
        # $ver is the SHA from the SAME $rev the "Repo version" row used, so the header
        # can't disagree with the report — and there's no extra git spawn (C2). Falls
        # back to 'dev' on a copy install with no git metadata.
        $ver = if ($rev -and $rev.Sha) { $rev.Sha } else { 'dev' }
        $sep    = if (Test-DotUnicode) { '·' } else { '|' }
        $dash   = if (Test-DotUnicode) { '—' } else { '-' }
        $legend = ('{0} ok {3} {1} warn {3} {2} fail' -f (Get-DotGlyph ok), (Get-DotGlyph warn), (Get-DotGlyph fail), $sep)
        Write-Host ''
        Write-DotHost ('dotfiles-Windows {0} ' -f $ver) -Color Cyan -NoNewline
        Write-DotHost ('{0} core-doctor ({1})' -f $dash, $legend) -Color DarkGray
        Write-Host ''
        # Grouped, in a fixed section order, so the report scans top-to-bottom
        # instead of as one undifferentiated list (U4). Get-DoctorGroup is pure.
        foreach ($group in 'Shell & environment', 'Repo & links', 'Health & toolchain', 'Other') {
            $rows = @($results | Where-Object { (Get-DoctorGroup $_.Name) -eq $group })
            if (-not $rows.Count) { continue }
            Write-DotHost "  $group" -Color Cyan
            foreach ($res in $rows) { Write-DoctorLine $res }
            Write-Host ''
        }
    }

    $s = Get-DoctorSummary $results
    $color = switch ($s.Overall) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'fail' { 'Red' } }
    $sep = if (Test-DotUnicode) { '·' } else { '|' }
    Write-DotHost ("  {0} ok {3} {1} warn {3} {2} fail" -f $s.Ok, $s.Warn, $s.Fail, $sep) -Color $color

    # Opt-in remediation: only acts on the checks it knows how to fix, and says
    # exactly what it's doing for each. Re-runs the probes afterward so you see
    # the result without another command.
    if ($Fix) {
        $plan = Get-DoctorFixPlan $results
        Write-Host ''
        if (-not $plan.Count) {
            Write-DotHost '  nothing auto-fixable here.' -Color DarkGray
        } else {
            Write-DotHost ("  applying {0} fix(es)..." -f $plan.Count) -Color Cyan
            foreach ($key in $plan) { Invoke-DoctorFix $key }
            Write-Host ''
            Write-DotHost '  re-checking...' -Color Cyan
            # Re-resolve the revision before the re-check: a fix action could have
            # touched the working tree, so the second "Repo version" row must reflect
            # current state, not the pre-fix snapshot. (Today's fixes all act outside
            # the repo, so this is defensive — but it keeps the re-check honest.)
            $rev     = Get-DotRepoRevision -Root $root
            $results = Get-DoctorResults -RepoRevision $rev
            $s = Get-DoctorSummary $results
            $color = switch ($s.Overall) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'fail' { 'Red' } }
            Write-DotHost ("  {0} ok {3} {1} warn {3} {2} fail" -f $s.Ok, $s.Warn, $s.Fail, $sep) -Color $color
        }
    }

    if ($PassThru) { return $results }
}
