# ============================================================================
#  install.ps1  -  bootstrap the Windows host
#
#  Usage (from the repo root):
#      .\install.ps1                 # packages + symlinks
#      .\install.ps1 -SkipPackages   # just (re)wire the symlinks
#      .\install.ps1 -DryRun         # preview every change, touch nothing
#      .\install.ps1 -NonInteractive # never prompt (CI / unattended)
#      .\install.ps1 -Help           # this banner
#
#  Symlinks require either Developer Mode (Settings > System > For developers)
#  OR an elevated shell. The script detects this and falls back to copying
#  with a warning if neither is available.
# ============================================================================
[CmdletBinding()]
param(
    [switch]$SkipPackages,
    # Preview mode: print exactly what WOULD change (link / copy / back up / seed)
    # and mutate nothing. The safe way to inspect a bootstrap before trusting it.
    [switch]$DryRun,
    # Never prompt (overwrite confirmations, git identity). For CI / unattended
    # runs; existing real files are backed up automatically and identity is left
    # as a placeholder, exactly like the old behaviour.
    [switch]$NonInteractive,
    # Auto-confirm overwrite prompts without going fully non-interactive.
    [switch]$Yes,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Reuse the fleet's shared rendering helpers (Write-DotErr / Write-DotWarn /
# Get-DotGlyph / NO_COLOR-aware Write-DotHost). 05-lib is pure and side-effect-free
# on load, so the bootstrap and the daily profile share ONE error/colour layout.
$LibPath = Join-Path $RepoRoot 'powershell/core/05-lib.ps1'
if (Test-Path $LibPath) {
    . $LibPath
} else {
    # No shims here, deliberately: unlike Install-Packages.ps1 (which only needs the
    # rendering helpers and can degrade to plain output), this script depends on
    # Get-DotfilesLinkPlan for the ENTIRE link plan. Continuing would produce a
    # CommandNotFoundException cascade halfway through wiring the host. One clear
    # diagnostic beats ten confusing ones.
    Write-Error @"
powershell/core/05-lib.ps1 not found under '$RepoRoot'.
The checkout looks incomplete — install.ps1 cannot build the link plan without it.
Fix with:  git -C '$RepoRoot' status   then re-clone or restore the missing file.
"@
    exit 1
}

# --- usage banner (pure: returns the lines, so -Help and the test agree) -------
function Get-InstallUsage {
    @(
        'install.ps1 - bootstrap the Windows host (packages + config symlinks)'
        ''
        'USAGE'
        '  .\install.ps1 [-SkipPackages] [-DryRun] [-NonInteractive] [-Yes] [-Help]'
        ''
        'OPTIONS'
        '  -SkipPackages    Skip scoop/winget/module install; only (re)wire links.'
        '  -DryRun          Preview every change and mutate nothing.'
        '  -NonInteractive  Never prompt (CI/unattended); back up + replace silently.'
        '  -Yes             Auto-confirm overwrite prompts.'
        '  -Help            Show this help and exit.'
        ''
        'EXAMPLES'
        '  .\install.ps1                 # full bootstrap'
        '  .\install.ps1 -DryRun         # see what it would do'
        '  .\install.ps1 -SkipPackages   # just re-link configs'
    )
}

if ($Help) { Get-InstallUsage | ForEach-Object { Write-Host $_ }; return }

# --- can we make symlinks? ----------------------------------------------------
# Admin can ALWAYS create symlinks. Developer Mode only helps when the shell can
# pass SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE — pwsh 7 does, Windows
# PowerShell 5.1 does NOT. Trusting the registry key alone on 5.1 made this return
# $true and then every New-Item -ItemType SymbolicLink threw, AFTER Link-Item had
# already moved the user's real config to a .bak. Report the capability honestly
# instead and let the caller fall back to copy mode up front.
function Test-CanSymlink {
    param(
        [string]$Edition = $PSVersionTable.PSEdition,
        [nullable[bool]]$IsAdminOverride,
        [nullable[int]]$DevModeOverride
    )
    $isAdmin = if ($null -ne $IsAdminOverride) { [bool]$IsAdminOverride } else {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    if ($isAdmin) { return $true }
    $devMode = if ($null -ne $DevModeOverride) { [int]$DevModeOverride } else {
        (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
    }
    # Developer Mode without admin needs a host that requests the unprivileged flag.
    return (($devMode -eq 1) -and ($Edition -eq 'Core'))
}

# --- Test-SymlinkCurrent ------------------------------------------------------
# True only when $Link already exists, IS a symbolic link, and points at $Target.
# This is what makes re-running install.ps1 idempotent: a link that's already
# correct is left untouched instead of being backed up and recreated (which used
# to spawn a fresh `.bak` on every run). Pure/filesystem-only, so it's unit-tested.
function Test-SymlinkCurrent {
    param([string]$Link, [string]$Target)
    if (-not (Test-Path -LiteralPath $Link)) { return $false }
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne 'SymbolicLink') { return $false }
    $current = @($item.Target)[0]
    if (-not $current) { return $false }
    # Compare resolved absolute paths; fall back to a raw compare if either side
    # can't be resolved (e.g. a dangling link). Case-insensitive to match NTFS.
    try {
        $a = (Resolve-Path -LiteralPath $current -ErrorAction Stop).Path
        $b = (Resolve-Path -LiteralPath $Target  -ErrorAction Stop).Path
    } catch {
        return [string]::Equals($current, $Target, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
}

# --- is the copy at $Link already identical to $Target? -----------------------
# Copy-mode idempotency (used on a host with no symlink capability). Without it a
# repeat install with no upstream change still backs up + recopies every run — each
# pass drops a fresh timestamped .bak and re-copies identical bytes, so backups pile
# up unbounded (issue #129). Compare CONTENT instead: a file by its SHA-256, a
# directory (nvim\, psmux\scripts) by the full {relative path -> marker} set on both
# sides — files map to their SHA-256, subdirectories to a '<dir>' sentinel — so an
# added / removed / renamed / edited file OR an added/removed empty directory anywhere
# in the tree reads as different. A missing link (or a file-vs-directory mismatch) is
# "not current". This is a GUARD: any enumeration/hash error (a locked or vanishing
# file mid-walk) returns $false — "not current" — so the caller safely recopies rather
# than skipping on an incomplete comparison.
function Test-CopyCurrent {
    param([string]$Link, [string]$Target)
    if (-not (Test-Path -LiteralPath $Link))   { return $false }
    if (-not (Test-Path -LiteralPath $Target)) { return $false }
    $linkIsDir   = Test-Path -LiteralPath $Link   -PathType Container
    $targetIsDir = Test-Path -LiteralPath $Target -PathType Container
    if ($linkIsDir -ne $targetIsDir) { return $false }
    try {
        if (-not $targetIsDir) {
            return ((Get-FileHash -LiteralPath $Link -ErrorAction Stop).Hash -eq (Get-FileHash -LiteralPath $Target -ErrorAction Stop).Hash)
        }
        # Directory: map every entry to a marker, keyed by its path relative to the
        # tree root — files to their SHA-256, subdirectories to '<dir>' so empty-dir
        # drift is caught too. -ErrorAction Stop turns any traversal failure into a
        # throw the catch below converts to "not current".
        $hashTree = {
            param([string]$Root)
            $root = (Resolve-Path -LiteralPath $Root).Path
            $map  = @{}   # PowerShell hashtables are case-insensitive, matching NTFS
            Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop | ForEach-Object {
                $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
                $map[$rel] = if ($_.PSIsContainer) { '<dir>' } else { (Get-FileHash -LiteralPath $_.FullName -ErrorAction Stop).Hash }
            }
            $map
        }
        $a = & $hashTree $Link
        $b = & $hashTree $Target
    } catch { return $false }
    if ($a.Count -ne $b.Count) { return $false }
    foreach ($k in $a.Keys) {
        if (-not $b.ContainsKey($k) -or $b[$k] -ne $a[$k]) { return $false }
    }
    return $true
}

# --- run accounting + UI --------------------------------------------------------
# A single tally Link-Item updates, summarized at the end so the run reports what
# actually changed (linked/copied/skipped/backed-up) instead of scrolling past.
$script:LinkStats = [ordered]@{ linked = 0; copied = 0; skipped = 0; backedup = 0 }

# Numbered, consistent section header (visual hierarchy + progress: [n/total]).
# Keep in step with the Write-Step call count below (env, packages, configs,
# .wslconfig, local overrides, mise) — tests/Install.Tests.ps1 asserts they agree.
$script:StepTotal = 6
$script:StepNo    = 0
function Write-Step {
    param([string]$Title)
    $script:StepNo++
    Write-Host ''
    Write-Host ("[{0}/{1}] " -f $script:StepNo, $script:StepTotal) -ForegroundColor Cyan -NoNewline
    Write-Host $Title -ForegroundColor White
}

# Pure: turn the stats tally into the summary lines (unit-tested).
function Get-InstallSummaryLines {
    param([System.Collections.IDictionary]$Stats)
    @(
        "linked   : $($Stats.linked)"
        "copied   : $($Stats.copied)"
        "skipped  : $($Stats.skipped)  (already correct)"
        "backed up: $($Stats.backedup)"
    )
}

# --- transcript hygiene (pure helpers, unit-tested) ----------------------------
# Get-DotLogsToPrune: keep the newest $Keep install logs and return the rest (the
# older ones, newest-of-them first — order is irrelevant since the caller just
# deletes them) so install-*.log can't accumulate without bound across re-runs.
# Pure (the Get-ChildItem / Remove-Item live at the call site), so the retention
# policy is unit-tested. (B8)
function Get-DotLogsToPrune {
    param([object[]]$Logs, [int]$Keep = 10)
    if (-not $Logs) { return @() }
    @($Logs | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep)
}

# Get-DotRedactedTranscript: replace any captured line that looks like it carries a
# secret (reusing the PSReadLine history-filter heuristic) with a marker, so a
# token/password that scrolled past during the run can't persist in the on-disk
# transcript. Best-effort and pure, so it's unit-tested. (B8)
function Get-DotRedactedTranscript {
    param([string[]]$Lines)
    if (-not $Lines) { return @() }
    # Resolve the filter's presence ONCE, not per line — the answer is constant for
    # the whole call, and a large transcript would otherwise pay repeated command
    # discovery on every line.
    $hasFilter = [bool](Get-Command Test-SensitiveHistoryLine -ErrorAction SilentlyContinue)
    $Lines | ForEach-Object {
        if ($hasFilter -and (Test-SensitiveHistoryLine $_)) {
            '  <redacted: line matched a secret pattern>'
        } else { $_ }
    }
}

# --- overwrite confirmation ----------------------------------------------------
# A REAL (non-symlink) file at $Link is the user's own config; backing it up and
# replacing it without asking is the one genuinely destructive thing the bootstrap
# does. Prompt before doing it, unless told otherwise. A wrong/stale symlink (one
# of ours) is rewired silently — there's nothing to lose.
function Confirm-Overwrite {
    param([string]$Link)
    if ($Yes -or $NonInteractive) { return $true }
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'SymbolicLink') { return $true }
    # Re-prompts on a typo'd answer; defaults to yes (back up + replace) on a
    # non-interactive host, matching the previous auto-backup behaviour.
    return (Read-DotConfirm "  '$Link' exists. Back up and replace?" -DefaultYes $true)
}

# --- link helper --------------------------------------------------------------
function Link-Item {
    param([string]$Target, [string]$Link)

    $verb = if ($CanSymlink) { 'link' } else { 'copy' }

    # Idempotent: a link already pointing where we want needs no work — skip it so
    # repeated runs don't pile up `.bak` files. Only real files, or wrong/stale
    # links, get backed up and replaced.
    if ($CanSymlink -and (Test-SymlinkCurrent -Link $Link -Target $Target)) {
        Write-Host "  ok      $Link (already linked)" -ForegroundColor DarkGray
        $script:LinkStats.skipped++
        return
    }
    # Same idempotency for COPY mode (no symlink capability): if the destination
    # already matches the target's content, skip — otherwise every re-install backs
    # up + recopies identical bytes and the .bak files accumulate (issue #129).
    if (-not $CanSymlink -and (Test-CopyCurrent -Link $Link -Target $Target)) {
        Write-Host "  ok      $Link (already up to date)" -ForegroundColor DarkGray
        $script:LinkStats.skipped++
        return
    }

    # Dry-run: report the action and mutate nothing (no mkdir, no backup, no link).
    # NB: every existence/copy/move/remove below uses -LiteralPath. A profile path
    # containing `[` or `]` is a wildcard to bare Test-Path/Copy-Item/Move-Item, so
    # without -LiteralPath an existing real file can read as absent — silently
    # skipping the back-up branch and clobbering the user's own config with no .bak.
    if ($script:DryRun) {
        if (Test-Path -LiteralPath $Link) { Write-DotHost "  would back up + $verb  $Link" -Color DarkYellow }
        else                       { Write-DotHost "  would $verb  $Link" -Color Cyan }
        return
    }

    $parent = Split-Path -Parent $Link
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    # Track the backup so a failed link/copy can put the user's file back exactly
    # where it was. Without this, a throw below leaves them with no config at $Link
    # and a timestamped .bak they have to find and rename by hand.
    $backup = $null
    if (Test-Path -LiteralPath $Link) {
        if (-not (Confirm-Overwrite $Link)) {
            Write-Host "  skip    $Link (kept existing, by request)" -ForegroundColor DarkGray
            $script:LinkStats.skipped++
            return
        }
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$Link.$stamp.bak"
        Move-Item -LiteralPath $Link -Destination $backup -Force
        Write-DotHost "  backed up existing -> $backup" -Color DarkYellow
        $script:LinkStats.backedup++
    }

    try {
        if ($CanSymlink) {
            New-Item -ItemType SymbolicLink -Path $Link -Target $Target -Force -ErrorAction Stop | Out-Null
            Write-DotHost "  linked  $Link" -Color Green
            $script:LinkStats.linked++
        } else {
            # -Recurse so directory targets (nvim\, psmux\scripts) copy in full — a
            # plain Copy-Item only takes the top-level entry and leaves them empty.
            $recurse = (Test-Path -LiteralPath $Target -PathType Container)
            Copy-Item -LiteralPath $Target -Destination $Link -Force -Recurse:$recurse -ErrorAction Stop
            Write-DotHost "  copied  $Link" -Color Green
            $script:LinkStats.copied++
        }
    } catch {
        $failure = $_
        $wired = $false

        # ORDER MATTERS. Try the copy fallback BEFORE restoring the backup, not
        # after. Restoring first puts the user's file back at $Link, which the copy
        # then has to delete to make room — so if that copy also failed, BOTH the
        # original and the .bak were gone and the "has been restored" message was a
        # lie. The backup is the last resort, so it must stay untouched until we
        # know nothing else can land.
        #
        # A symlink failure is recoverable (copy instead), so one unlinkable row
        # doesn't abort a whole bootstrap: $ErrorActionPreference is 'Stop' here, so
        # without this the run would die mid-plan with the remaining links unwired.
        if ($CanSymlink) {
            Write-DotWarn "Could not symlink $Link — falling back to copy." "$failure"
            try {
                $recurse = (Test-Path -LiteralPath $Target -PathType Container)
                # Clear any partial artifact the failed attempt left behind. Safe:
                # the user's own file is still parked at $backup at this point.
                if (Test-Path -LiteralPath $Link) { Remove-Item -LiteralPath $Link -Recurse -Force -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $Target -Destination $Link -Force -Recurse:$recurse -ErrorAction Stop
                Write-DotHost "  copied  $Link" -Color Green
                $script:LinkStats.copied++
                $wired = $true
            } catch {
                Write-DotWarn "Copy fallback also failed for $Link." "$_"
            }
        }

        if (-not $wired) {
            # Nothing landed at $Link, so put the user's original back. Only now is
            # it safe to consume $backup.
            $restored = $false
            if ($backup -and (Test-Path -LiteralPath $backup)) {
                if (Test-Path -LiteralPath $Link) { Remove-Item -LiteralPath $Link -Recurse -Force -ErrorAction SilentlyContinue }
                Move-Item -LiteralPath $backup -Destination $Link -Force -ErrorAction SilentlyContinue
                $restored = Test-Path -LiteralPath $Link
                if ($restored) {
                    Write-DotHost "  restored $Link from backup" -Color DarkYellow
                    $script:LinkStats.backedup--
                }
            }
            # Say what is actually true on disk, rather than assuming the restore worked.
            $hint = if ($restored) { 'Your original file has been restored.' }
                    elseif ($backup) { "Your original file is at $backup — restore it by hand." }
                    else { 'Nothing was overwritten.' }
            Write-DotErr "Could not wire $Link : $failure" $hint
            $script:LinkStats.skipped++
        }
    }
}

# Library-only hook: dot-sourcing with DOTFILES_INSTALL_LIBONLY=1 exposes the
# functions above (for the test suite) without running the bootstrap below.
if ($env:DOTFILES_INSTALL_LIBONLY -eq '1') { return }

# Promote -DryRun to script scope so Link-Item (defined above) sees it.
$script:DryRun = [bool]$DryRun

if ($script:DryRun) {
    Write-Host ''
    Write-DotHost ' DRY RUN ' -Color Cyan
    Write-DotHost ' nothing will be installed, linked, copied, or written.' -Color DarkGray
}

# --- transcript log (B11) -----------------------------------------------------
# Capture the whole run to a timestamped log so a "it broke on machine X" report
# has something concrete to attach. Best-effort: skipped in dry-run and on hosts
# that don't support transcription.
$script:Transcribing = $false
if (-not $script:DryRun -and $env:LOCALAPPDATA) {
    try {
        $logDir = Join-Path $env:LOCALAPPDATA 'dotfiles/logs'
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        # Retention: prune all but the newest 10 install logs so they don't pile up
        # unbounded across re-runs (B8).
        Get-DotLogsToPrune (Get-ChildItem -Path $logDir -Filter 'install-*.log' -File -ErrorAction SilentlyContinue) -Keep 10 |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        $logFile = Join-Path $logDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -Path $logFile -Force | Out-Null
        $script:Transcribing = $true
    } catch { }
}

# Wrap the bootstrap so a Ctrl-C (or a thrown error) still prints where it stopped
# and closes the transcript, instead of dumping the user at a bare prompt with a
# half-wired host and no acknowledgement (U2: graceful interrupts).
$script:Completed = $false
try {

# --- preflight: shell version, Mark-of-the-Web, execution policy --------------
# Warn (do not block) if running under Windows PowerShell 5.1. Bootstrapping
# from 5.1 is fine - this run installs pwsh 7 - but the profile is wired for
# pwsh, so daily work should happen there afterward.
if ($PSVersionTable.PSEdition -ne 'Core') {
    Write-DotWarn 'Running under Windows PowerShell 5.1.' 'Do daily work in PowerShell 7 (pwsh) afterward — the profile targets the pwsh path.'
}

# Strip the "downloaded from the internet" flag off the repo so RemoteSigned
# policy will not block our own scripts. A `git clone` avoids this entirely;
# this matters when the repo arrived as a downloaded archive. Skip the .git tree:
# its thousands of objects never get loaded/executed and only slow the scan.
if ($script:DryRun) {
    Write-DotHost '  would unblock repo files + ensure RemoteSigned execution policy' -Color Cyan
} else {
    # A `git clone` never sets Mark-of-the-Web, so the whole-tree walk is pure
    # overhead on the bootstrap path — which is how most people get here. Only pay
    # for it when the repo could have arrived as a downloaded archive.
    if (Test-Path (Join-Path $RepoRoot '.git')) {
        Write-Host '  unblock: skipped (git clone — no Mark-of-the-Web to clear)' -ForegroundColor DarkGray
    } else {
        Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.git\*' } |
            Unblock-File -ErrorAction SilentlyContinue
    }

    # Ensure scripts can run for this user. RemoteSigned is the minimum the profile
    # needs to load each session. Leave it alone if Group Policy already pins one.
    try {
        $cur = Get-ExecutionPolicy -Scope CurrentUser
        if ($cur -notin 'RemoteSigned','Unrestricted','Bypass') {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
            Write-Host 'Set CurrentUser execution policy to RemoteSigned.' -ForegroundColor DarkGray
        }
    } catch {
        Write-DotWarn "Could not set execution policy (Group Policy may control it): $_"
    }
}

$CanSymlink = Test-CanSymlink
if (-not $CanSymlink) {
    # Prefer Developer Mode over elevation. Elevating also works — Install-Packages.ps1
    # passes -RunAsAdmin so scoop still installs — but scoop itself discourages an
    # admin install, so Developer Mode is the better of the two. configuration.dsc.yaml
    # turns it on for you.
    Write-DotWarn 'Neither Developer Mode nor admin detected — falling back to COPY (changes will not auto-track the repo).' 'For true symlinks enable Developer Mode: winget configure -f configuration.dsc.yaml --accept-configuration-agreements  (Settings > System > For developers also works). Elevating works too, but scoop discourages installing as administrator.'
}

# Wire the repo-local pre-commit gate when this is a git clone (so contributors
# get the dependency-free validator on every commit). Harmless for users.
if (Test-Path (Join-Path $RepoRoot '.git')) {
    if ($script:DryRun) {
        Write-DotHost '  would set git core.hooksPath = .githooks' -Color Cyan
    } else {
        git -C $RepoRoot config core.hooksPath .githooks 2>$null
        Write-Host '  git hooks: core.hooksPath = .githooks (pre-commit validation)' -ForegroundColor DarkGray
    }
}

# --- 1. persistent env var ----------------------------------------------------
Write-Step 'Setting DOTFILES_WIN'
if ($script:DryRun) {
    Write-DotHost "  would set DOTFILES_WIN = $RepoRoot (User)" -Color Cyan
} else {
    [Environment]::SetEnvironmentVariable('DOTFILES_WIN', $RepoRoot, 'User')
    $env:DOTFILES_WIN = $RepoRoot
    Write-Host "  DOTFILES_WIN = $RepoRoot" -ForegroundColor DarkGray
}

# --- 2. packages --------------------------------------------------------------
Write-Step $(if ($SkipPackages) { 'Installing packages (skipped: -SkipPackages)' } else { 'Installing packages' })
if (-not $SkipPackages) {
    if ($script:DryRun) {
        Write-DotHost '  would install scoop + winget + PowerShell-module packages' -Color Cyan
    } else {
        # Pass our interactivity through so an unattended install never blocks on
        # the optional-group picker (it installs every group instead). (U3)
        & (Join-Path $RepoRoot 'packages/Install-Packages.ps1') -NonInteractive:$NonInteractive
    }
}

# --- 3. wire symlinks ---------------------------------------------------------
Write-Step 'Wiring configs'

# All config links come from ONE shared plan (Get-DotfilesLinkPlan in 05-lib) so
# install, uninstall, and dotfiles-doctor can never disagree about the set. The
# Documents folder inside the plan is resolved the OneDrive-aware way via
# [Environment]::GetFolderPath('MyDocuments'), so the profile we link is the one
# pwsh ACTUALLY loads even when Documents is redirected to OneDrive.
# Windows Terminal keeps settings.json in a per-build location (packaged Store/winget,
# unpackaged/scoop, Preview), so the plan carries one candidate row per flavor, all
# flagged ParentMustExist. Wire them as a GROUP: link whichever flavor(s) are actually
# installed and stay silent about the ones that aren't — you normally have exactly one,
# so a "skipping" warning per absent flavor was just noise. Only nudge if NONE is present.
$wtRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in (Get-DotfilesLinkPlan -RepoRoot $RepoRoot)) {
    if ($row.ParentMustExist) { $wtRows.Add($row); continue }
    Link-Item -Target $row.Target -Link $row.Link
    if ($row.Name -eq 'PowerShell profile') {
        Write-Host "  (profile target: $($row.Link))" -ForegroundColor DarkGray
    }
}
$wtLinked = 0
foreach ($row in $wtRows) {
    if (Test-Path -LiteralPath (Split-Path -Parent $row.Link)) {
        Link-Item -Target $row.Target -Link $row.Link
        $wtLinked++
    }
}
if ($wtRows.Count -gt 0 -and $wtLinked -eq 0) {
    Write-DotWarn 'Windows Terminal settings not linked — no Windows Terminal install found.' `
        'Install Windows Terminal (Store/winget or scoop), then re-run install.ps1.'
}

# --- ppm (psmux plugin manager) -------------------------------------------------
# Mirrors psmux's documented install: clone the psmux-plugins monorepo to a temp
# dir, copy ONLY the ppm subfolder into ~/.psmux/plugins/ppm — psmux's standard
# plugin path. That's the same ~/.psmux tree psmux uses for its own runtime files
# (session port/key files, warm session) and where resurrect/continuum write their
# saves, so everything plugin-related lives under one root. The other @plugins
# declared in psmux.conf are fetched later by `prefix + I` inside psmux.
$ppmDir = Join-Path $HOME '.psmux/plugins/ppm'
if (-not (Test-Path -LiteralPath $ppmDir)) {
    if ($script:DryRun) {
        Write-DotHost "  would clone psmux-plugins and install ppm -> $ppmDir" -Color Cyan
    } else {
        $tmp = Join-Path $env:TEMP ('psmux-plugins-' + [guid]::NewGuid().ToString('N'))
        # Supply-chain: the clone tracks the default branch HEAD by default, but set
        # DOTFILES_PPM_REF to a commit SHA or tag to pin EXACTLY what gets installed
        # (a moved branch then can't change the code we copy in). We also verify the
        # expected ppm\ folder actually exists in the clone before copying it.
        $ppmRef = $env:DOTFILES_PPM_REF
        # A ref beginning with '-' could smuggle an option into the git commands
        # below (e.g. --upload-pack=… on fetch is a known argument-injection RCE),
        # so reject it exactly as bootstrap.ps1 guards DOTFILES_REF — that rejection
        # is the injection guard. The trailing `--` added to checkout below is the
        # ref/pathspec separator (matching bootstrap.ps1), not the guard itself.
        if ($ppmRef -and $ppmRef.StartsWith('-')) {
            Write-DotWarn "ignoring DOTFILES_PPM_REF '$ppmRef' (cannot start with '-')." 'Using the default branch.'
            $ppmRef = $null
        }
        try {
            git clone --depth 1 https://github.com/psmux/psmux-plugins.git $tmp
            if ($LASTEXITCODE -eq 0) {
                if ($ppmRef) {
                    git -C $tmp fetch --depth 1 origin $ppmRef 2>$null
                    git -C $tmp checkout --quiet $ppmRef -- 2>$null
                    if ($LASTEXITCODE -ne 0) { Write-DotWarn "could not pin ppm to '$ppmRef' — using default branch." }
                    else { Write-DotHost "  pinned ppm to $ppmRef" -Color DarkGray }
                }
                $ppmSrc = Join-Path $tmp 'ppm'
                if (Test-Path -LiteralPath $ppmSrc) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $ppmDir) | Out-Null
                    Copy-Item -LiteralPath $ppmSrc -Destination $ppmDir -Recurse -Force
                    Write-DotHost "  installed ppm -> $ppmDir" -Color Green
                } else {
                    Write-DotWarn 'ppm folder missing from the clone — skipping.' 'The psmux-plugins layout may have changed; install ppm by hand.'
                }
            } else {
                Write-DotWarn 'ppm clone failed.' 'Clone psmux-plugins by hand, copy ppm\ to ~\.psmux\plugins\ppm'
            }
        } finally {
            if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

# Windows Terminal settings are wired by the shared plan loop above (the row is
# flagged ParentMustExist, so it self-skips when WT isn't installed).

# --- 4. .wslconfig (COPY, don't symlink - it's host-global, edit per machine) -
Write-Step 'Seeding host-global .wslconfig'
$wslCfg = Join-Path $HOME '.wslconfig'
if (Test-Path -LiteralPath $wslCfg) {
    Write-DotHost "  exists  $wslCfg  (left as-is; compare against wsl\windows.wslconfig.example)" -Color DarkYellow
} elseif ($script:DryRun) {
    Write-DotHost "  would seed $wslCfg from wsl\windows.wslconfig.example" -Color Cyan
} else {
    # Guard the SOURCE: $ErrorActionPreference is 'Stop', so a renamed/missing
    # example would abort the whole install here rather than skipping a seed step
    # that is optional by design.
    $wslExample = Join-Path $RepoRoot 'wsl/windows.wslconfig.example'
    if (Test-Path -LiteralPath $wslExample) {
        Copy-Item -LiteralPath $wslExample -Destination $wslCfg
        Write-DotHost "  seeded  $wslCfg  (review it, then run: wsl --shutdown)" -Color Green
    } else {
        Write-DotWarn "wsl\windows.wslconfig.example is missing — skipped seeding $wslCfg."
    }
}

# --- 5. seed local override + gitconfig.local ---------------------------------
Write-Step 'Seeding local overrides'
$localPs = Join-Path $RepoRoot 'powershell/local.ps1'
if (-not (Test-Path -LiteralPath $localPs)) {
    $localExample = Join-Path $RepoRoot 'powershell/local.ps1.example'
    if ($script:DryRun) { Write-DotHost "  would seed $localPs from local.ps1.example" -Color Cyan }
    elseif (Test-Path -LiteralPath $localExample) { Copy-Item -LiteralPath $localExample -Destination $localPs }
    else { Write-DotWarn "powershell\local.ps1.example is missing — skipped seeding $localPs." }
}

# Zero-config onboarding (U9): instead of seeding a placeholder the user must
# remember to hand-edit, ask for the git identity up front. Falls back to the
# placeholder when non-interactive, in dry-run, or when input is left blank
# (dotfiles-doctor still flags a placeholder, so nothing is silently wrong).
$gcLocal = Join-Path $HOME '.gitconfig.local'
if (-not (Test-Path -LiteralPath $gcLocal)) {
    $gitName = 'YOUR NAME'; $gitEmail = 'you@example.com'
    # Pre-fill from any identity git already knows (a prior, non-dotfiles setup),
    # so an existing user just presses Enter twice instead of retyping. A blank
    # answer keeps the shown default; the placeholders only survive if there's no
    # prior identity AND nothing is entered.
    $priorName  = (& git config --global user.name)  2>$null
    $priorEmail = (& git config --global user.email) 2>$null
    if ($priorName)  { $gitName  = "$priorName".Trim() }
    if ($priorEmail) { $gitEmail = "$priorEmail".Trim() }
    if (-not $NonInteractive -and -not $script:DryRun) {
        # One shared, gum-aware prompt (Read-DotInput): blank keeps the default, the
        # email is validated (re-asking on garbage), and no interactive host falls
        # back to the defaults — the same behaviour as before, now reused everywhere.
        $nameDefault  = if ($gitName  -ne 'YOUR NAME')      { $gitName }  else { 'blank to fill in later' }
        $emailDefault = if ($gitEmail -ne 'you@example.com'){ $gitEmail } else { 'blank to fill in later' }
        $gitName  = Read-DotInput -Prompt '  git author name ' -Default $gitName -DefaultHint $nameDefault
        $gitEmail = Read-DotInput -Prompt '  git author email' -Default $gitEmail -DefaultHint $emailDefault `
            -Validate { param($v) Test-DotEmailish $v } `
            -ValidationMessage "  that doesn't look like an email — expected you@example.com, or blank to set it later."
    }
    if ($script:DryRun) {
        Write-DotHost "  would seed $gcLocal (git identity)" -Color Cyan
    } else {
@"
[user]
    name  = $gitName
    email = $gitEmail
"@ | Set-Content -LiteralPath $gcLocal -Encoding UTF8
        $note = if ($gitName -eq 'YOUR NAME') { '  (set your git name/email)' } else { "  ($gitName <$gitEmail>)" }
        Write-DotHost "  seeded  $gcLocal$note" -Color Green
    }
}

# --- 6. global gitignore wiring ----------------------------------------------
# Nothing to do: git\.gitconfig already sets `excludesfile = ~/.gitignore_global`,
# and that file is symlinked to ~/.gitconfig above. Running `git config --global`
# here would rewrite that line in-place with a machine-specific ABSOLUTE path,
# silently dirtying the tracked repo file (it edits the symlink target).

# --- 7. mise runtimes ---------------------------------------------------------
# Provision the tools pinned in mise\config.toml (node only — see that file).
# MUST run after step 3: mise reads ~/.config/mise/config.toml, which is the
# symlink wired there, so a fresh box has nothing to install before then.
# Non-fatal by design — a runtime download failure should not fail the bootstrap,
# and `mise install` is idempotent, so re-running install.ps1 retries it.
Write-Step $(if ($SkipPackages) { 'Provisioning mise runtimes (skipped: -SkipPackages)' } else { 'Provisioning mise runtimes' })
if (-not $SkipPackages) {
    if ($script:DryRun) {
        Write-DotHost '  would run: mise install' -Color Cyan
    } elseif (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-DotHost '  mise not installed - skipping (packages step installs it).' -Color DarkGray
    } else {
        try {
            mise install
            if ($LASTEXITCODE -eq 0) { Write-DotOk 'mise runtimes provisioned.' }
            else { Write-DotWarn "mise install exited $LASTEXITCODE - runtimes may be incomplete." 'run `mise install` by hand to see the failure.' }
        } catch {
            Write-DotWarn "mise install failed: $_" 'run `mise install` by hand to see the failure.'
        }
    }
}

Write-Host ''
Write-DotRule -Title 'Summary'
Get-InstallSummaryLines -Stats $script:LinkStats | ForEach-Object { Write-DotHost "  $_" -Color Gray }
if (-not $CanSymlink) {
    Write-DotHost '  mode    : COPY (no Dev Mode / not elevated — links would not track the repo)' -Color DarkYellow
}

Write-Host ''
if ($script:DryRun) {
    Write-DotHost 'Dry run complete — re-run without -DryRun to apply.' -Color Cyan
} else {
    Write-DotHost 'Bootstrap complete.' -Color Green
    Write-Host 'Next steps:' -ForegroundColor White
    Write-Host '  1. Open a NEW PowerShell window (pwsh) to load the profile.' -ForegroundColor Gray
    Write-Host '  2. Set your name/email in ~/.gitconfig.local.' -ForegroundColor Gray
    Write-Host '  3. Review ~/.wslconfig, then run: wsl --shutdown' -ForegroundColor Gray
    Write-Host '  4. Run `dotfiles-doctor` to verify everything is wired correctly.' -ForegroundColor Gray
}

$script:Completed = $true

} finally {
    # Runs on normal completion, on a thrown error, AND on Ctrl-C — so an
    # interrupted bootstrap acknowledges itself and leaves a readable log.
    if (-not $script:Completed) {
        Write-Host ''
        Write-DotWarn 'Bootstrap did not finish (interrupted or errored).' 'Re-run .\install.ps1 — it is idempotent and resumes cleanly.'
        if ($script:LinkStats) {
            Get-InstallSummaryLines -Stats $script:LinkStats | ForEach-Object { Write-DotHost "  $_" -Color Gray }
        }
    }
    if ($script:Transcribing) {
        try { Stop-Transcript | Out-Null } catch { }
        # Redact secret-looking lines before the transcript rests on disk (B8).
        try {
            if ($logFile -and (Test-Path -LiteralPath $logFile)) {
                Set-Content -LiteralPath $logFile -Encoding UTF8 -Value (Get-DotRedactedTranscript (Get-Content -LiteralPath $logFile))
            }
        } catch { }
        Write-DotHost "  log: $logFile" -Color DarkGray
    }
}
