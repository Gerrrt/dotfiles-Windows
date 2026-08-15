# ============================================================================
#  tests/Assert-StarshipParity.ps1  -  CI gate: starship.toml must match Core
#
#  The sibling of Assert-NvimParity.ps1, for the OTHER asset this standalone repo
#  mirrors from dotfiles-core. starship-sync.ps1 stamps starship/.core-ref with the
#  Core commit it copied from; this gate fetches Core at THAT commit and compares
#  the single file, failing if they diverge — so a hand-edit straight into
#  starship/starship.toml can't silently fork the mirrored prompt.
#
#  This gate exists because that has already happened: starship/starship.toml
#  accumulated ten non-sync commits before `9deb31a` reconciled it ("ending the
#  prompt drift"). nvim had a gate and starship did not; nothing prevented a repeat.
#
#  Like the nvim gate it diffs against the RECORDED commit, not Core's HEAD: the
#  mirrored file is expected to lag Core, so the invariant is "faithful copy of
#  what we synced", not "up to date with Core". Skips cleanly when .core-ref is
#  absent or carries no resolved commit (a checkout that never ran the sync).
#
#  Pure helpers are exposed for unit tests via DOTFILES_STARSHIPPARITY_LIBONLY=1.
# ============================================================================
[CmdletBinding()]
param([string]$CoreRemoteFallback = 'https://github.com/dotgibson/dotfiles-core.git')

# Reuse the nvim gate's helpers rather than copying them. Get-CoreRefField,
# Test-DotGitSha and Resolve-CoreRemote are SECURITY-CRITICAL — they are what stop
# a PR-edited .core-ref from steering CI's outbound clone or smuggling a git option
# — so they must exist in exactly one place. Two copies would drift, and the copy
# that drifts is the one that stops protecting anything. The LIBONLY hook imports
# them without running the nvim gate.
$script:PrevNvimLibOnly = $env:DOTFILES_NVIMPARITY_LIBONLY
$env:DOTFILES_NVIMPARITY_LIBONLY = '1'
try { . (Join-Path $PSScriptRoot 'Assert-NvimParity.ps1') }
finally {
    if ($null -eq $script:PrevNvimLibOnly) { Remove-Item Env:DOTFILES_NVIMPARITY_LIBONLY -ErrorAction SilentlyContinue }
    else { $env:DOTFILES_NVIMPARITY_LIBONLY = $script:PrevNvimLibOnly }
}

# --- Get-StarshipParityDiff ---------------------------------------------------
# Pure: compare the two file hashes. A single file, so this is deliberately much
# simpler than the nvim tree walk — but kept as a named function so the result
# shape (and the InSync verdict) is unit-testable without any IO.
function Get-StarshipParityDiff {
    [OutputType([pscustomobject])]
    param([string]$LocalHash, [string]$CoreHash)
    [pscustomobject]@{
        LocalHash = $LocalHash
        CoreHash  = $CoreHash
        InSync    = ($LocalHash -and $CoreHash -and ($LocalHash -eq $CoreHash))
    }
}

# Library-only hook: let the test suite import the pure helpers without fetching.
if ($env:DOTFILES_STARSHIPPARITY_LIBONLY -eq '1') { return }

# --- main --------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
$starshipDir = Join-Path $RepoRoot 'starship'
$localToml   = Join-Path $starshipDir 'starship.toml'
$refFile     = Join-Path $starshipDir '.core-ref'

if (-not (Test-Path $refFile)) {
    Write-Host 'starship parity: no starship/.core-ref — skipped (run starship-sync.ps1 to stamp provenance).'
    exit 0
}
if (-not (Test-Path $localToml)) {
    Write-Error 'starship parity: starship/.core-ref exists but starship/starship.toml is missing.'
    exit 2
}

$refLines = Get-Content $refFile
$commit = Get-CoreRefField $refLines 'commit'
$source = Get-CoreRefField $refLines 'source'
if (-not $commit -or $commit -eq 'unknown') {
    Write-Host 'starship parity: .core-ref has no resolved commit — skipped.'
    exit 0
}
# .core-ref is tracked and PR-editable — same untrusted-input treatment as the nvim
# gate: the commit must look like a real SHA (hard fail, exit 2, distinct from the
# intentional "unknown => skip" above), and the clone target is allowlisted so a
# hostile PR cannot point CI's outbound fetch at an attacker-controlled URL.
if (-not (Test-DotGitSha $commit)) {
    Write-Error "starship parity: .core-ref commit '$commit' is not a valid git SHA — refusing to use it."
    exit 2
}
$AllowedRemotes = @(
    'https://github.com/dotgibson/dotfiles-core.git'
    'git@github.com:dotgibson/dotfiles-core.git'
)
$remote = Resolve-CoreRemote -Source $source -Allowed $AllowedRemotes -Fallback $CoreRemoteFallback
if ($source -and ($AllowedRemotes -notcontains $source)) {
    Write-Host "  note: .core-ref source '$source' is not an allowlisted Core remote — using $CoreRemoteFallback."
}
Write-Host "starship parity: checking starship/starship.toml against $remote @ $commit"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('core-starship-parity-' + [guid]::NewGuid().ToString('N'))
try {
    # Fetch exactly the recorded commit (GitHub allows fetch-by-SHA); fall back to a
    # full clone + checkout if the server refuses a bare-SHA fetch.
    git init --quiet $tmp
    git -C $tmp remote add origin $remote
    git -C $tmp fetch --depth 1 --quiet origin $commit 2>$null
    git -C $tmp checkout --quiet FETCH_HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  bare-SHA fetch unavailable — falling back to a full clone.'
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        git clone --quiet $remote $tmp
        if ($LASTEXITCODE -ne 0) { Write-Error "could not clone Core ($remote)"; exit 2 }
        git -C $tmp checkout --quiet $commit
        if ($LASTEXITCODE -ne 0) { Write-Error "Core has no commit $commit (force-pushed / gone?)"; exit 2 }
    }

    $coreToml = Join-Path $tmp 'starship/starship.toml'
    if (-not (Test-Path $coreToml)) { Write-Error "Core @ $commit has no starship/starship.toml"; exit 2 }

    $diff = Get-StarshipParityDiff `
        -LocalHash (Get-FileHash -LiteralPath $localToml -Algorithm SHA256).Hash `
        -CoreHash  (Get-FileHash -LiteralPath $coreToml  -Algorithm SHA256).Hash

    $short = $commit.Substring(0, [Math]::Min(7, $commit.Length))
    if ($diff.InSync) {
        Write-Host "starship parity: OK — starship.toml matches Core @ $short." -ForegroundColor Green
        exit 0
    }
    Write-Host 'starship parity: DRIFT detected between starship/starship.toml and the recorded Core commit.' -ForegroundColor Red
    Write-Host "  vendored SHA-256: $($diff.LocalHash)" -ForegroundColor Yellow
    Write-Host "  Core @ $short   : $($diff.CoreHash)" -ForegroundColor Yellow
    Write-Host 'Fix by editing Core and re-running starship-sync.ps1 (do not hand-edit starship/starship.toml).'
    exit 1
} finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
