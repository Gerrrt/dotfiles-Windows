# ============================================================================
#  Install-Packages.ps1  -  install the host toolchain from the manifests
#  Run from anywhere:  .\packages\Install-Packages.ps1
#
#  Resilient by design: a single package that fails (a flaky manifest, a
#  pre_install quirk like btop-lhm's, a transient download) is logged and
#  skipped - it never halts the whole batch. A summary prints at the end.
#
#  We force ErrorActionPreference = 'Continue' so that (a) scoop's own
#  pre/post-install scriptblocks, which run in THIS runspace, keep their normal
#  non-terminating behavior, and (b) we do NOT inherit a 'Stop' from install.ps1
#  when it calls us. Failures are tracked explicitly via $? and summarized.
# ============================================================================
[CmdletBinding()]
param(
    [switch]$SkipWinget,
    [switch]$SkipScoop,
    # Reproducible install: pin every app to the exact version in packages.lock.json
    # instead of letting scoop/winget float to latest. Requires the lockfile (run
    # Update-PackageLock.ps1 on a working box to produce it). A managed app with no
    # lock entry is skipped, not floated — frozen means frozen. (B4)
    [switch]$Frozen,
    # Never prompt: skip the optional-group picker and install every group (the
    # opt-out default). install.ps1 passes its own -NonInteractive through so a
    # CI/unattended run is unchanged. (U3)
    [switch]$NonInteractive,
    [switch]$Help
)

# Pure usage banner (returns the lines, so -Help and the test agree — same shape
# as install.ps1's Get-InstallUsage).
function Get-PackagesUsage {
    @(
        'Install-Packages.ps1 - install the host toolchain from the manifests'
        ''
        'USAGE'
        '  .\packages\Install-Packages.ps1 [-SkipScoop] [-SkipWinget] [-Frozen] [-NonInteractive] [-Help]'
        ''
        'OPTIONS'
        '  -SkipScoop       Skip the scoop bucket/app install pass.'
        '  -SkipWinget      Skip the winget package install pass.'
        '  -Frozen          Install exact versions from packages.lock.json (reproducible).'
        '  -NonInteractive  Never prompt; install every optional package group.'
        '  -Help            Show this help and exit.'
        ''
        'NOTES'
        '  Resilient: a package that fails is logged and skipped, never halting the'
        '  batch. Re-run to retry — already-installed items are detected and skipped.'
        '  PowerShell modules always install to a local (off-OneDrive) modules dir.'
        '  -Frozen needs packages.lock.json (generate it with Update-PackageLock.ps1).'
        '  Optional package groups: the first interactive run picks which to install'
        '  (gum), persisting the choice to powershell/local.ps1 (DOTFILES_PKG_GROUPS).'
    )
}

if ($Help) { Get-PackagesUsage | ForEach-Object { Write-Host $_ }; return }

$ErrorActionPreference = 'Continue'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$failed = [System.Collections.Generic.List[string]]::new()
. (Join-Path $here 'modules.ps1')
# Pure lockfile helpers (Read-PackageLock / Get-LockedVersion) for -Frozen. (B4)
. (Join-Path $here 'PackageLock.ps1')

# Shared rendering helpers (Write-DotWarn / Write-DotHost / glyphs). Dot-sourced
# so a standalone run gets the same NO_COLOR-aware layout as install.ps1.
$lib = Join-Path $here '../powershell/core/05-lib.ps1'
if (Test-Path $lib) { . $lib }

# Make "best-effort if the lib is missing" actually true: if 05-lib didn't load
# (older/partial checkout), define minimal shims for the helpers this script uses
# so it degrades to plain output instead of erroring on an undefined command.
if (-not (Get-Command Write-DotHost -ErrorAction SilentlyContinue)) {
    function Write-DotHost { param([Parameter(Position = 0)][string]$Text = '', [string]$Color, [switch]$NoNewline) Write-Host $Text -NoNewline:$NoNewline }
    function Write-DotWarn { param([Parameter(Mandatory)][string]$Message, [string]$Hint) Write-Warning $Message; if ($Hint) { Write-Warning "  $Hint" } }
    function Write-DotErr  { param([Parameter(Mandatory)][string]$Message, [string]$Hint) Write-Error $Message; if ($Hint) { Write-Warning "  $Hint" } }
    function Write-DotOk   { param([Parameter(Mandatory)][string]$Message) Write-Host $Message }
    # Used by Write-DotInstallProgress; mirror 05-lib's NO_COLOR/TERM=dumb check so
    # the progress bar stays safe even in this degraded (lib-missing) mode.
    function Test-DotColor { return ((-not $env:NO_COLOR) -and ($env:TERM -ne 'dumb')) }
    # The scoop-installer integrity gate (DOTFILES_SCOOP_SHA256) depends on this;
    # without a shim a lib-less run throws CommandNotFound at exactly the moment it
    # is trying to VERIFY a downloaded script, which is the worst place to fail open.
    function Get-DotStringSha256 {
        [OutputType([string])]
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $sha.Dispose() }
    }
    # Degrade the spinner to a plain inline call — same result, no animation.
    function Invoke-DotSpinner {
        param(
            [Parameter(Mandatory)][string]$Label,
            [Parameter(Mandatory)][scriptblock]$Script,
            [object[]]$ArgumentList = @()
        )
        Write-Host "  $Label..."
        & $Script @ArgumentList
    }
}

# Tiny progress line: "  [n/total] -> name" so a long, silent install doesn't look
# frozen. Returns a stopwatch the caller stops to print the elapsed time. Uses
# Write-DotHost so the progress line honours NO_COLOR like the rest of the output.
function Write-PkgStep {
    param([int]$N, [int]$Total, [string]$Name)
    Write-DotHost ("  [{0}/{1}] " -f $N, $Total) -Color Cyan -NoNewline
    Write-DotHost "-> $Name" -Color DarkGray
    [System.Diagnostics.Stopwatch]::StartNew()
}

# --- Get-WingetInstalledIds ---------------------------------------------------
# Parse the PackageIdentifiers out of `winget export` JSON. Pulling the installed
# set ONCE this way replaces the old per-package `winget list --id` spawn (N
# subprocesses on a cold install). Pure, so it's unit-tested.
function Get-WingetInstalledIds {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    try { $obj = $Json | ConvertFrom-Json } catch { return @() }
    $ids = foreach ($s in $obj.Sources) { foreach ($p in $s.Packages) { $p.PackageIdentifier } }
    return @($ids | Where-Object { $_ })
}

# --- optional version pinning (pure, unit-tested) -----------------------------
# Reproducibility without freezing the whole rolling toolchain: any manifest entry
# MAY pin a version, and the rest float to latest. A scoop app object can carry a
# Version ("Name@Version"); a winget entry can be either a bare id string or an
# object { "id": "...", "version": "..." }. These two helpers turn a manifest entry
# into the exact install token/spec, so the pinning logic is testable offline.
function Get-ScoopInstallToken {
    param($App)
    if ($App.Version) { "$($App.Name)@$($App.Version)" } else { "$($App.Name)" }
}
function ConvertTo-DotWingetSpec {
    param($Entry)
    if ($Entry -is [string]) { return [pscustomobject]@{ Id = $Entry; Version = $null; Group = $null } }
    return [pscustomobject]@{
        Id      = "$($Entry.id)"
        Version = $(if ($Entry.version) { "$($Entry.version)" } else { $null })
        Group   = $(if ($Entry.group)   { "$($Entry.group)"   } else { $null })
    }
}

# --- optional package groups (U3) ---------------------------------------------
# A manifest entry MAY carry a "group" tag (e.g. { "id": "...", "group": "gui" }).
# Untagged entries are CORE and always install; a tagged entry belongs to an
# optional group the user can opt out of. The selection is resolved ONCE
# (persisted choice > interactive gum picker > opt-out default = everything) and
# applied per entry. These helpers are pure, so the policy is unit-tested; the
# gum picker + persistence (I/O) sit just below them.

# Distinct optional-group names present across the given manifest entries, sorted.
# Scoop apps / bare winget ids carry no .Group, so they contribute nothing.
function Get-DotOptionalGroups {
    [OutputType([string[]])]
    param([object[]]$Entries)
    $g = foreach ($e in $Entries) { if ($e -and $e.Group) { "$($e.Group)" } }
    return @($g | Sort-Object -Unique)
}

# Parse a persisted selection ("gui security", "gui,security", or "none"/"") into
# a clean, lowercased, de-duplicated string[]. 'none' is the explicit empty marker
# so "chose nothing optional" round-trips distinctly from "never chose".
function ConvertFrom-DotGroupList {
    [OutputType([string[]])]
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    # Lowercase FIRST so 'NONE'/'None' are recognised as the empty marker too.
    $parts = $Value -split '[,\s]+' | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $_ -and $_ -ne 'none' }
    return @($parts | Sort-Object -Unique)
}

# Format a selection back to the persisted token ('none' when empty).
function ConvertTo-DotGroupList {
    [OutputType([string])]
    param([string[]]$Groups)
    $clean = @($Groups | Where-Object { $_ } | Sort-Object -Unique)
    if ($clean.Count -eq 0) { return 'none' }
    return ($clean -join ' ')
}

# Should an entry install, given the selected optional groups? Core (no group)
# always installs. For a tagged entry, $null $Selected means "selection unknown"
# (e.g. discovery failed) and falls back to the opt-out default — install it;
# only an explicit (possibly empty) list gates a tagged entry by membership.
function Test-DotGroupSelected {
    [OutputType([bool])]
    param([string]$Group, [string[]]$Selected)
    if ([string]::IsNullOrWhiteSpace($Group)) { return $true }
    if ($null -eq $Selected) { return $true }   # unknown selection -> opt-out default (install all)
    return ($Selected -contains $Group)
}

# Pure: return $Content with the managed DOTFILES_PKG_GROUPS line upserted to
# $Value. ANY prior $env:DOTFILES_PKG_GROUPS assignment (whether written by us or
# by hand) is dropped, then our managed line is appended — so the result has
# exactly one assignment and the write is idempotent. A List avoids PowerShell's
# single-element-array unwrap (which would turn the append into string concat).
function Set-DotGroupLine {
    [OutputType([string])]
    param([AllowEmptyString()][string]$Content, [string]$Value)
    $line = "`$env:DOTFILES_PKG_GROUPS = '$Value'   # U3: optional package groups (managed by Install-Packages.ps1)"
    $kept = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($Content)) {
        foreach ($l in ($Content -split "`r?`n")) {
            if ($l -notmatch '^\s*\$env:DOTFILES_PKG_GROUPS\s*=') { $kept.Add($l) }
        }
        while ($kept.Count -gt 0 -and [string]::IsNullOrEmpty($kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }
    }
    $kept.Add($line)
    return (($kept -join "`n") + "`n")
}

# Persist the selection to powershell/local.ps1 (gitignored) so future runs — and
# the next shell — reuse it without re-prompting. Best-effort: a write failure
# warns but never aborts the install.
function Save-DotPackageGroupSelection {
    param([string]$Path, [string[]]$Groups)
    try {
        $value = ConvertTo-DotGroupList $Groups
        $existing = if (Test-Path $Path) { Get-Content $Path -Raw } else {
            # Seed from the example rather than clobbering a not-yet-created local.ps1.
            $ex = Join-Path (Split-Path $Path) 'local.ps1.example'
            if (Test-Path $ex) { Get-Content $ex -Raw } else { '' }
        }
        Set-DotGroupLine -Content $existing -Value $value | Set-Content -Path $Path -Encoding UTF8
        $env:DOTFILES_PKG_GROUPS = $value   # so the rest of THIS run agrees with the choice
        Write-DotHost "  saved selection to local.ps1 (DOTFILES_PKG_GROUPS = $value)" -Color DarkGray
    } catch {
        Write-DotWarn "couldn't persist package-group selection: $_" 'install proceeds; it will ask again next time.'
    }
}

# Resolve which optional groups to install. Precedence:
#   1. $env:DOTFILES_PKG_GROUPS set (persisted choice / explicit override) -> use it.
#   2. interactive + gum available -> gum choose --no-limit (all preselected;
#      deselect to opt out), then persist the result.
#   3. otherwise (-NonInteractive / CI / no gum) -> opt-out default: install all.
function Resolve-DotPackageGroupSelection {
    [OutputType([string[]])]
    param([string[]]$Available, [bool]$NonInteractive, [string]$LocalPs1Path)
    if (-not $Available -or $Available.Count -eq 0) { return @() }   # nothing optional to choose

    if ($env:DOTFILES_PKG_GROUPS) {
        return @((ConvertFrom-DotGroupList $env:DOTFILES_PKG_GROUPS) | Where-Object { $Available -contains $_ })
    }
    if ($NonInteractive -or -not (Test-DotGum)) { return @($Available) }

    Write-DotHost 'Optional package groups — space toggles, enter confirms (all on by default):' -Color Cyan
    $gumArgs = @('choose', '--no-limit')
    foreach ($g in $Available) { $gumArgs += @('--selected', $g) }
    $gumArgs += $Available
    $picked = @(& gum @gumArgs 2>$null)
    if ($LASTEXITCODE -ne 0) { $picked = @($Available) }   # ESC/Ctrl-C: keep the default (all)
    $picked = @($picked | Where-Object { $_ })
    Save-DotPackageGroupSelection -Path $LocalPs1Path -Groups $picked
    return $picked
}

# --- overall install progress + ETA (U2) --------------------------------------
# The per-item "[n/total]" lines are per-phase; over a multi-minute install
# there's no single sense of "how far along, how much longer". Get-DotInstallProgress
# is the pure model — percent complete and an ETA extrapolated from the average
# pace so far (-1 until at least one item finishes, 0 once done). Format-DotDuration
# renders seconds as "45s" / "1m05s". Both pure, so they're unit-tested; the
# Write-Progress bar (below) is the only non-testable I/O.
function Get-DotInstallProgress {
    [OutputType([pscustomobject])]
    param([int]$Completed, [int]$Total, [double]$ElapsedSeconds)
    if ($Total -le 0) { return [pscustomobject]@{ Percent = 0; EtaSeconds = -1 } }
    $c = [Math]::Max(0, [Math]::Min($Completed, $Total))
    # Floor (not Round) so the bar never shows 100% with work still left — e.g.
    # 199/200 is 99%, not a rounded-up 100%. Only a fully-done count reads 100.
    $percent = if ($c -ge $Total) { 100 } else { [int][Math]::Floor(100.0 * $c / $Total) }
    $eta = -1
    if ($c -ge $Total) { $eta = 0 }
    elseif ($c -gt 0 -and $ElapsedSeconds -gt 0) { $eta = [int][Math]::Round(($ElapsedSeconds / $c) * ($Total - $c)) }
    return [pscustomobject]@{ Percent = $percent; EtaSeconds = $eta }
}

function Format-DotDuration {
    [OutputType([string])]
    param([int]$Seconds)
    if ($Seconds -lt 0) { return '?' }
    if ($Seconds -lt 60) { return "${Seconds}s" }
    return ('{0}m{1:d2}s' -f [Math]::Floor($Seconds / 60), ($Seconds % 60))
}

# Render the overall determinate bar via Write-Progress. Only a live, colour-capable
# console gets it — under NO_COLOR/redirected/CI it's skipped and the per-item log
# lines carry the detail (so transcripts/logs stay clean). Non-testable I/O.
function Write-DotInstallProgress {
    param([int]$Completed, [int]$Total, [System.Diagnostics.Stopwatch]$Stopwatch, [switch]$Done)
    try { if ([Console]::IsOutputRedirected) { return } } catch { }
    if (-not (Test-DotColor)) { return }
    if ($Done) { Write-Progress -Activity 'Installing packages' -Completed; return }
    if ($Total -le 0) { return }
    $p = Get-DotInstallProgress -Completed $Completed -Total $Total -ElapsedSeconds $Stopwatch.Elapsed.TotalSeconds
    $status = "$Completed/$Total"
    if ($p.EtaSeconds -ge 0 -and $Completed -lt $Total) { $status += "  -  ETA $(Format-DotDuration $p.EtaSeconds)" }
    Write-Progress -Activity 'Installing packages' -Status $status -PercentComplete $p.Percent
}

# Library-only hook for the test suite: expose the helpers without installing.
if ($env:DOTFILES_PKG_LIBONLY -eq '1') { return }

# --- resolve the lockfile (B4) ------------------------------------------------
# Always loaded (empty maps when absent) so the loops can branch on -Frozen
# uniformly. -Frozen without a lock is a hard stop: floating "latest" would defeat
# the whole point, so we refuse rather than silently un-freeze.
$script:PkgLockPath = Join-Path $here 'packages.lock.json'
$script:PkgLock = if (Test-Path $script:PkgLockPath) {
    Read-PackageLock (Get-Content $script:PkgLockPath -Raw)
} else {
    Read-PackageLock ''
}
if ($Frozen) {
    if (-not (Test-Path $script:PkgLockPath)) {
        Write-DotErr '-Frozen needs packages.lock.json, which is missing.' 'generate it on a working box: .\packages\Update-PackageLock.ps1'
        return
    }
    Write-DotHost 'Frozen install: pinning every app to packages.lock.json.' -Color Cyan
}

# --- resolve optional package groups (U3) -------------------------------------
# Discover the optional groups from BOTH manifests (a side-effect-free read), then
# resolve the selection ONCE so the picker shows up at most once per run. The
# scoop/winget loops below filter each entry through Test-DotGroupSelected.
# $null = "selection unknown" -> Test-DotGroupSelected installs everything (the
# opt-out default), so any read/parse failure errs toward installing, not skipping.
$script:DotSelectedGroups = $null
$script:PkgTotal = 0   # overall item count for the progress bar (U2)
try {
    $wgSpecs   = @((Get-Content (Join-Path $here 'winget.json')  -Raw | ConvertFrom-Json).packages | ForEach-Object { ConvertTo-DotWingetSpec $_ })
    $scApps    = @((Get-Content (Join-Path $here 'scoopfile.json') -Raw | ConvertFrom-Json).apps)
    $available = Get-DotOptionalGroups (@($wgSpecs) + @($scApps))
    $script:DotSelectedGroups = Resolve-DotPackageGroupSelection -Available $available -NonInteractive ([bool]$NonInteractive) -LocalPs1Path (Join-Path $here '../powershell/local.ps1')
    # Grand total across the phases that will actually run (every item is counted
    # once, including ones that turn out already-installed or group-skipped — the
    # ETA self-corrects as the fast ones fly by).
    $script:PkgTotal = @($script:MaintModuleNames).Count
    if (-not $SkipScoop)  { $script:PkgTotal += @($scApps).Count }
    # Count winget items only when the winget phase will actually run: it's skipped
    # wholesale when winget isn't on PATH, and counting it anyway would leave the
    # bar stuck short of 100% on a winget-less box.
    if (-not $SkipWinget -and (Get-Command winget -CommandType Application -ErrorAction SilentlyContinue)) { $script:PkgTotal += @($wgSpecs).Count }
} catch {
    Write-DotWarn "couldn't read optional package groups: $_" 'installing every group.'
    $script:DotSelectedGroups = $null   # unknown -> opt-out default (install all)
}

# Wrap the whole batch so a Ctrl-C mid-install still prints the skipped/failed
# summary (U2) instead of vanishing — you can see exactly how far it got.
$script:PkgCompleted = $false
$script:PkgDone = 0                                          # items finished so far (U2)
$script:PkgSw = [System.Diagnostics.Stopwatch]::StartNew()   # drives the ETA
try {

# --- scoop --------------------------------------------------------------------
if (-not $SkipScoop) {
    if (-not (Get-Command scoop -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing scoop...' -ForegroundColor Cyan
        try {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
            # TLS 1.2 explicitly. Under .NET Framework (Windows PowerShell 5.1, which
            # install.ps1 tolerates with only a warning) SecurityProtocol defaults to
            # SSL3|TLS1.0 on any host without the SchUseStrongCrypto registry value,
            # and get.scoop.sh requires 1.2 — the failure is an opaque "Could not
            # create SSL/TLS secure channel". Harmless no-op on pwsh 7/.NET Core.
            try {
                [Net.ServicePointManager]::SecurityProtocol =
                    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            } catch { }
            # Fetch the installer to a string first so it can be integrity-checked
            # before it runs, instead of piping the network straight into iex. Set
            # DOTFILES_SCOOP_SHA256 to the expected hash to gate execution; without
            # it we proceed (documented), but the seam for verification now exists.
            $scoopInstaller = Invoke-RestMethod 'https://get.scoop.sh'
            if ($env:DOTFILES_SCOOP_SHA256) {
                $actual = Get-DotStringSha256 $scoopInstaller
                if ($actual -ne ($env:DOTFILES_SCOOP_SHA256.ToLowerInvariant())) {
                    Write-DotErr 'scoop installer hash mismatch — refusing to run it.' "expected $($env:DOTFILES_SCOOP_SHA256), got $actual"
                    return
                }
                Write-DotOk 'scoop installer hash verified.'
            }
            # scoop's installer REFUSES to run elevated unless it is passed -RunAsAdmin,
            # so a bare `| iex` (which can take no arguments) aborts the whole package
            # phase for anyone who followed the old "re-run elevated" advice. Build it
            # as a scriptblock instead so the flag can be supplied when we are admin.
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
            if ($isAdmin) {
                Write-DotWarn 'Elevated shell detected — installing scoop with -RunAsAdmin.' 'Developer Mode is the preferred path; scoop discourages an admin install.'
                & ([scriptblock]::Create($scoopInstaller)) -RunAsAdmin
            } else {
                & ([scriptblock]::Create($scoopInstaller))
            }
        } catch {
            Write-DotErr "scoop bootstrap failed: $_"
            return
        }

        # The installer updates $env:PATH in THIS runspace, but if that ever fails we
        # would fall through and every `scoop install` below would report
        # command-not-found — ~75 entries in $failed instead of one clear cause.
        # $ErrorActionPreference is 'Continue' here, so nothing else would stop us.
        if (-not (Get-Command scoop -CommandType Application -ErrorAction SilentlyContinue)) {
            Write-DotErr 'scoop installed but is not on PATH in this session.' 'Open a new shell and re-run: .\install.ps1'
            return
        }
    }

    $manifest = Get-Content (Join-Path $here 'scoopfile.json') -Raw | ConvertFrom-Json

    Write-Host 'Adding buckets...' -ForegroundColor Cyan
    $existing = (scoop bucket list).Name
    foreach ($b in $manifest.buckets) {
        if ($existing -notcontains $b.Name) {
            scoop bucket add $b.Name $b.Source
            if (-not $?) { $failed.Add("bucket:$($b.Name)") }
        }
    }

    Write-Host 'Installing scoop apps...' -ForegroundColor Cyan
    $installed = (scoop list 6>$null).Name
    $apps = @($manifest.apps)
    $i = 0
    foreach ($app in $apps) {
        $i++
        try {
            $name = $app.Name
            if (-not (Test-DotGroupSelected -Group "$($app.group)" -Selected $script:DotSelectedGroups)) {
                Write-DotHost "  [$i/$($apps.Count)] - $name (optional group '$($app.group)' — not selected)" -Color DarkGray
                continue
            }
            if ($installed -contains $name) {
                Write-Host "  [$i/$($apps.Count)] = $name (already installed)" -ForegroundColor DarkGray
                continue
            }
            if ($Frozen) {
                # Frozen: the lock is authoritative. A managed app with no lock entry is
                # skipped (not floated) so the run stays reproducible end to end.
                $lockVer = Get-LockedVersion -Map $script:PkgLock.Scoop -Name $name
                if (-not $lockVer) {
                    Write-DotWarn "scoop:$name has no lock entry — skipping under -Frozen" 'install it, then re-run Update-PackageLock.ps1'
                    $failed.Add("scoop-unlocked:$name"); continue
                }
                $token = "$name@$lockVer"
            } else {
                $token = Get-ScoopInstallToken $app   # Name, or Name@Version when pinned
            }
            $sw = Write-PkgStep -N $i -Total $apps.Count -Name $token
            scoop install $token
            $sw.Stop()
            if ($LASTEXITCODE -ne 0) { $failed.Add("scoop:$name") }
            else { Write-DotHost ("      done in {0:n0}s" -f $sw.Elapsed.TotalSeconds) -Color DarkGray }
        } finally {
            # Count the item as FINISHED (not merely started) so the ETA reflects
            # completed work; runs on every path, including the `continue` skips.
            $script:PkgDone++
            Write-DotInstallProgress -Completed $script:PkgDone -Total $script:PkgTotal -Stopwatch $script:PkgSw
        }
    }
}

# --- winget -------------------------------------------------------------------
if (-not $SkipWinget) {
    if (Get-Command winget -CommandType Application -ErrorAction SilentlyContinue) {
        Write-Host 'Installing winget packages...' -ForegroundColor Cyan
        $wg = Get-Content (Join-Path $here 'winget.json') -Raw | ConvertFrom-Json

        # Query the installed set ONCE via `winget export` (clean JSON) instead of
        # spawning `winget list --id` for every package — N fewer subprocesses.
        # If export fails (older winget, non-zero exit), fall back to the per-id
        # `winget list` check so we don't blindly reinstall everything.
        $installedIds = @()
        $exportOk = $false
        $tmp = $null
        try {
            $tmp = Join-Path $env:TEMP ("winget-export-" + [guid]::NewGuid().ToString('N') + '.json')
            # winget export is silent and slow on a cold source — spin while it runs
            # (it writes $tmp on disk, so we still read the result back here). The job
            # returns winget's exit code so the original "export ok?" gate is intact.
            $rc = @(Invoke-DotSpinner -Label 'querying installed winget packages' -ArgumentList @($tmp) -Script {
                param($out)
                winget export -o $out --accept-source-agreements *> $null
                $LASTEXITCODE
            })[-1]
            if ($rc -eq 0 -and (Test-Path $tmp)) {
                $installedIds = Get-WingetInstalledIds (Get-Content $tmp -Raw)
                $exportOk = $true
            }
        } catch { }
        finally { if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
        if (-not $exportOk) {
            Write-DotWarn 'winget export unavailable — falling back to per-package checks (slower).'
        }

        $pkgs = @($wg.packages)
        $j = 0
        foreach ($entry in $pkgs) {
            $j++
            try {
                $spec = ConvertTo-DotWingetSpec $entry   # { Id; Version; Group (all optional) }
                $id = $spec.Id
                if (-not (Test-DotGroupSelected -Group $spec.Group -Selected $script:DotSelectedGroups)) {
                    Write-DotHost "  [$j/$($pkgs.Count)] - $id (optional group '$($spec.Group)' — not selected)" -Color DarkGray
                    continue
                }
                if ($Frozen) {
                    # Frozen: override any floating/inline spec with the locked version;
                    # skip (don't float) when this id isn't locked.
                    $lockVer = Get-LockedVersion -Map $script:PkgLock.Winget -Name $id
                    if (-not $lockVer) {
                        Write-DotWarn "winget:$id has no lock entry — skipping under -Frozen" 'install it, then re-run Update-PackageLock.ps1'
                        $failed.Add("winget-unlocked:$id"); continue
                    }
                    $spec = [pscustomobject]@{ Id = $id; Version = $lockVer }
                }
                $label = if ($spec.Version) { "$id @$($spec.Version)" } else { $id }
                # Already installed? Prefer the exported set (-contains is
                # case-insensitive); fall back to a per-id query when export failed.
                $already = if ($exportOk) {
                    $installedIds -contains $id
                } else {
                    winget list --id $id -e --accept-source-agreements *> $null
                    $LASTEXITCODE -eq 0
                }
                if ($already) {
                    Write-Host "  [$j/$($pkgs.Count)] = $label (already installed)" -ForegroundColor DarkGray
                    continue
                }
                $sw = Write-PkgStep -N $j -Total $pkgs.Count -Name $label
                $wgInstall = @('install', '--id', $id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements')
                # Only pin when the lock holds a clean version literal. A stale lock can
                # carry a winget constraint token like "> 8.12.28.25" (store/newer-than
                # case); passing that as --version makes winget reject the install. Skip
                # the pin and install floating rather than failing the package.
                if ($spec.Version -and $spec.Version -match '^\d' -and $spec.Version -notmatch '[<>=\s]') {
                    $wgInstall += @('--version', $spec.Version)
                }
                winget @wgInstall
                $sw.Stop()
                if ($LASTEXITCODE -ne 0) {
                    Write-DotWarn "$id failed (winget exit $LASTEXITCODE) — skipping, continuing the batch"
                    $failed.Add("winget:$id")
                } else {
                    Write-DotHost ("      done in {0:n0}s" -f $sw.Elapsed.TotalSeconds) -Color DarkGray
                }
            } finally {
                $script:PkgDone++   # finished (not started) — keeps the ETA honest on every path
                Write-DotInstallProgress -Completed $script:PkgDone -Total $script:PkgTotal -Stopwatch $script:PkgSw
            }
        }
    } else {
        Write-DotWarn 'winget not found.' 'Install "App Installer" from the Microsoft Store, then re-run with -SkipScoop.'
    }
}

# --- PowerShell modules -------------------------------------------------------
# Save to a LOCAL (non-OneDrive) modules dir. Install-Module -Scope CurrentUser
# lands in Documents\PowerShell\Modules, which is OneDrive-synced when Documents
# is redirected — and importing from there adds seconds to every shell start.
# Save-Module writes the importable Name\Version layout to an explicit path;
# profile.ps1 prepends this dir to $env:PSModulePath so it's found first.
Write-Host 'Installing PowerShell modules (local, off OneDrive)...' -ForegroundColor Cyan
$localModules = Join-Path $env:LOCALAPPDATA 'PowerShell\Modules'
New-Item -ItemType Directory -Force -Path $localModules | Out-Null
$mods = @($script:MaintModuleNames)
$k = 0
foreach ($m in $mods) {
    $k++
    try {
        if (Test-Path (Join-Path $localModules $m)) {
            Write-Host "  [$k/$($mods.Count)] = $m (already local)" -ForegroundColor DarkGray
            continue
        }
        $sw = Write-PkgStep -N $k -Total $mods.Count -Name $m
        # -RequiredVersion installs EXACTLY the pinned version (see packages/modules.ps1)
        # so a fresh bootstrap is reproducible; the daily maint runner rolls it forward.
        # Save-Module is silent and slow, so animate a spinner while it downloads (the
        # job returns 'ok' or 'fail: ...' so failure handling is preserved; inline on CI).
        $ver = $script:MaintModulePins[$m]
        $res = Invoke-DotSpinner -Label "downloading $m $ver" -ArgumentList @($m, $localModules, $ver) -Script {
            param($name, $path, $version)
            try { Save-Module -Name $name -Path $path -RequiredVersion $version -Force -ErrorAction Stop; 'ok' }
            catch { "fail: $_" }
        }
        $sw.Stop()
        $status = @($res)[-1]
        if ($status -eq 'ok') {
            Write-DotHost ("      done in {0:n0}s" -f $sw.Elapsed.TotalSeconds) -Color DarkGray
        } else {
            Write-DotWarn "module $m failed: $($status -replace '^fail:\s*', '')"; $failed.Add("module:$m")
        }
    } finally {
        $script:PkgDone++   # finished (not started) — keeps the ETA honest on every path
        Write-DotInstallProgress -Completed $script:PkgDone -Total $script:PkgTotal -Stopwatch $script:PkgSw
    }
}

$script:PkgCompleted = $true

} finally {
    # --- summary (prints on completion AND on Ctrl-C) -------------------------
    Write-DotInstallProgress -Done   # clear the progress bar (runs on completion AND Ctrl-C)
    Write-Host ''
    if (-not $script:PkgCompleted) {
        Write-DotWarn 'Package install interrupted — partial state below.' 'Re-run to resume (already-installed items are skipped).'
    }
    if ($failed.Count -eq 0 -and $script:PkgCompleted) {
        Write-DotHost 'Package install complete - no failures.' -Color Green
    } elseif ($failed.Count) {
        Write-DotHost "$($failed.Count) item(s) skipped:" -Color Yellow
        $failed | ForEach-Object { Write-DotHost "  - $_" -Color Yellow }
        Write-DotHost 'Re-run this script to retry them (already-installed apps are skipped).' -Color Yellow
    }
}
