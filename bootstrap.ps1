# ============================================================================
#  bootstrap.ps1  -  one command to set up dotfiles-Windows on a fresh box.
#
#  Run it straight from the web (PowerShell 7+).
#  RECOMMENDED -- verify the published SHA-256 first, so a tampered or MITM'd fetch
#  of this `main` script can't run arbitrary code:
#      $b = irm https://raw.githubusercontent.com/dotgibson/dotfiles-Windows/main/bootstrap.ps1
#      # compare SHA-256 of $b to the hash pinned in the README, then: $b | iex
#
#  Quick (UNVERIFIED) one-liner -- only on a network you fully trust:
#      irm https://raw.githubusercontent.com/dotgibson/dotfiles-Windows/main/bootstrap.ps1 | iex
#
#  What it does: clone (or update) the repo, optionally check out a pinned ref,
#  then hand off to install.ps1. It NEVER pipes a further network script into
#  iex itself -- scoop's installer stays behind install.ps1's existing
#  DOTFILES_SCOOP_SHA256 gate, and a pinned DOTFILES_REF makes the clone exact.
#  Every other DOTFILES_* gate install.ps1/Install-Packages.ps1 honour is passed
#  through untouched (this just inherits the process environment).
#
#  Optional env knobs:
#    DOTFILES_REPO            git URL to clone     (default: the canonical repo)
#    DOTFILES_DIR             where to clone it    (default: ~/dotfiles-Windows)
#    DOTFILES_REF             commit/tag/branch to pin for a reproducible setup
#    DOTFILES_BOOTSTRAP_ARGS  extra args for install.ps1 (e.g. '-SkipPackages')
# ============================================================================
[CmdletBinding()]
param()

# --- pure resolvers (unit-tested via the DOTFILES_BOOTSTRAP_LIBONLY hook) -----
# Kept free of side effects and dependencies so they can be exercised offline and
# so this script stays self-contained (it runs BEFORE the repo is on disk, so it
# can't lean on 05-lib.ps1).

# The git URL to clone: an explicit DOTFILES_REPO wins, else the canonical repo.
function Get-BootstrapRepoUrl {
    [OutputType([string])]
    param([string]$Repo = $env:DOTFILES_REPO)
    if ($Repo) { return $Repo }
    return 'https://github.com/dotgibson/dotfiles-Windows.git'
}

# Where to clone: DOTFILES_DIR, else an existing DOTFILES_WIN, else ~/dotfiles-Windows.
function Get-BootstrapTargetDir {
    [OutputType([string])]
    param([string]$Dir = $env:DOTFILES_DIR, [string]$WinVar = $env:DOTFILES_WIN, [string]$HomeDir = $HOME)
    if ($Dir)    { return $Dir }
    if ($WinVar) { return $WinVar }
    return (Join-Path $HomeDir 'dotfiles-Windows')
}

# Whether to update an existing checkout or clone fresh.
function Get-BootstrapGitAction {
    [OutputType([string])]   # 'update' | 'clone'
    param([Parameter(Mandatory)][string]$Dir)
    if (Test-Path (Join-Path $Dir '.git')) { return 'update' }
    return 'clone'
}

# Split DOTFILES_BOOTSTRAP_ARGS into an argv array for install.ps1 (empty when unset).
function Get-BootstrapInstallArgs {
    [OutputType([string[]])]
    param([string]$Raw = $env:DOTFILES_BOOTSTRAP_ARGS)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    return @($Raw -split '\s+' | Where-Object { $_ })
}

# Library-only hook for the test suite: expose the resolvers without cloning.
if ($env:DOTFILES_BOOTSTRAP_LIBONLY -eq '1') { return }

$ErrorActionPreference = 'Stop'

# --- preflight ----------------------------------------------------------------
# A stock Windows box has NEITHER pwsh 7 NOR git, so both guards below fire on the
# machine this script most wants to serve. Point at configuration.dsc.yaml rather
# than at individual winget commands: it installs pwsh 7 + git + Windows Terminal
# AND enables Developer Mode in one pass -- and Developer Mode is what lets
# install.ps1 create real symlinks instead of silently degrading to copies.
$script:BootstrapStep0 = @(
    ''
    'On a fresh box, provision the prerequisites first:'
    '    winget configure -f configuration.dsc.yaml --accept-configuration-agreements'
    ''
    'That needs the repo on disk, so if you have not cloned it yet:'
    '    winget install Git.Git Microsoft.PowerShell'
    '    git clone https://github.com/dotgibson/dotfiles-Windows.git ~/dotfiles-Windows'
    '    cd ~/dotfiles-Windows'
    '    winget configure -f configuration.dsc.yaml --accept-configuration-agreements'
    ''
    'Then reopen PowerShell 7 (pwsh) and re-run this bootstrap.'
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "bootstrap targets PowerShell 7+; this is $($PSVersionTable.PSVersion)."
    $script:BootstrapStep0 | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
    return
}
# Windows-only: install.ps1 wires Windows paths (symlinks, %LOCALAPPDATA%, winget).
# $IsWindows is an automatic in pwsh 6+; abort cleanly elsewhere instead of cloning
# and failing deep inside the installer.
if (-not $IsWindows) {
    Write-Warning 'bootstrap (and install.ps1) target Windows; nothing to do on this OS.'
    return
}
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Warning 'git is required to bootstrap, and is not on PATH.'
    $script:BootstrapStep0 | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
    return
}

$repo   = Get-BootstrapRepoUrl
$dir    = Get-BootstrapTargetDir
$ref    = $env:DOTFILES_REF
$action = Get-BootstrapGitAction -Dir $dir
# Git refnames can't legitimately begin with '-'; reject one outright so a crafted
# DOTFILES_REF can't smuggle a git option into the checkout below.
if ($ref -and $ref.StartsWith('-')) { Write-Error "invalid DOTFILES_REF '$ref' (cannot start with '-')."; return }

Write-Host 'dotfiles-Windows bootstrap' -ForegroundColor Cyan
Write-Host "  repo: $repo"
Write-Host "  dir:  $dir"
if ($ref) { Write-Host "  ref:  $ref" }

# --- clone or update ----------------------------------------------------------
if ($action -eq 'clone') {
    # `--` separates options from the repo/dir positionals, so neither (both from
    # env) can be mis-parsed as a git flag.
    git clone -- $repo $dir
    if ($LASTEXITCODE -ne 0) { Write-Error "git clone failed (exit $LASTEXITCODE)."; return }
} else {
    # An existing checkout at $dir is only trustworthy if it's actually THIS repo --
    # otherwise we'd run whatever install.ps1 happens to live there. Skip the check
    # only when the user explicitly pointed us at a repo via DOTFILES_REPO.
    if (-not $env:DOTFILES_REPO) {
        $origin = (git -C $dir remote get-url origin 2>$null)
        if ($LASTEXITCODE -ne 0 -or $origin -notmatch 'dotfiles-Windows(\.git)?/?$') {
            Write-Error "$dir is a git checkout of '$origin', not dotfiles-Windows. Set DOTFILES_DIR to an empty path, or DOTFILES_REPO to confirm."; return
        }
    }
    Write-Host '  (existing checkout -- fetching latest)' -ForegroundColor DarkGray
    git -C $dir fetch --all --tags
    if ($LASTEXITCODE -ne 0) { Write-Error "git fetch failed (exit $LASTEXITCODE)."; return }
    if (-not $ref) {
        git -C $dir pull --ff-only
        if ($LASTEXITCODE -ne 0) { Write-Error "git pull failed (exit $LASTEXITCODE) -- resolve it, then re-run."; return }
    }
}

# A pinned ref (commit/tag/branch) makes the setup reproducible; git's own content
# addressing is the integrity check here. Trailing `--` terminates the pathspec
# list so the ref is never confused with a file of the same name.
if ($ref) {
    git -C $dir checkout $ref --
    if ($LASTEXITCODE -ne 0) { Write-Error "git checkout '$ref' failed (exit $LASTEXITCODE)."; return }
}

$installer = Join-Path $dir 'install.ps1'
if (-not (Test-Path $installer)) { Write-Error "install.ps1 not found in $dir - the clone looks incomplete."; return }

# --- hand off to the real installer ------------------------------------------
# Bootstrap itself ran via `iex`, but install.ps1 is a script FILE: under a strict
# AllSigned/RemoteSigned policy that local script could be blocked. Relax it for
# THIS process only (best-effort -- never persisted), so the one-liner just works.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop } catch { }
# @(...) is load-bearing. Get-BootstrapInstallArgs returns @() when no extra args
# are set, and PowerShell unrolls an empty array on the output stream to $null on
# assignment -- so a bare `$installArgs = Get-BootstrapInstallArgs` yields $null.
# Splatting $null passes a literal $null POSITIONAL argument, and install.ps1 takes
# only switches, so it fails with "A positional parameter cannot be found that
# accepts argument '$null'." Wrapping forces a real (possibly empty) array; the
# guard below then splats nothing when it's empty (the common no-args case).
$installArgs = @(Get-BootstrapInstallArgs)
Write-Host ("Running install.ps1 {0}" -f ($installArgs -join ' ')).TrimEnd() -ForegroundColor Cyan
Push-Location $dir
try {
    if ($installArgs.Count) { & $installer @installArgs }
    else                    { & $installer }
}
finally { Pop-Location }
