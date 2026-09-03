# ============================================================================
#  tests/Assert-ThemeParity.ps1  -  CI gate: theme/palette.toml must match Core
#
#  The third sibling of Assert-NvimParity.ps1 / Assert-StarshipParity.ps1, for the
#  third asset this standalone repo mirrors from dotfiles-core. theme-sync.ps1 stamps
#  theme/.core-ref with the Core commit it copied from; this gate fetches Core at THAT
#  commit and compares the single file, failing if they diverge — so a hand-edit
#  straight into theme/palette.toml can't silently fork the fleet's colour.
#
#  WHY THIS ONE MATTERS MORE THAN THE OTHER TWO. palette.toml is not just vendored,
#  it is an INPUT: gen-theme.ps1 renders it into ten blocks across seven files. A local
#  edit here would not merely fork one config, it would fan a half-recoloured terminal
#  layer out through a generator that faithfully reports success. The tempting local
#  "fix" — nudge a hex here rather than in Core — is exactly what this refuses.
#
#  Like its siblings it diffs against the RECORDED commit, not Core's HEAD: the
#  mirrored file is expected to lag Core, so the invariant is "faithful copy of what
#  we synced", not "up to date with Core". Freshness is the scheduled sync bot's job.
#  Skips cleanly when .core-ref is absent or carries no resolved commit (a checkout
#  that never ran the sync).
#
#  Pure helpers are exposed for unit tests via DOTFILES_THEMEPARITY_LIBONLY=1.
# ============================================================================
[CmdletBinding()]
param([string]$CoreRemoteFallback = 'https://github.com/dotgibson/dotfiles-core.git')

# Reuse the nvim gate's helpers rather than copying them. Get-CoreRefField,
# Test-DotGitSha and Resolve-CoreRemote are SECURITY-CRITICAL — they are what stop
# a PR-edited .core-ref from steering CI's outbound clone or smuggling a git option
# — so they must exist in exactly one place. Two copies would drift, and the copy
# that drifts is the one that stops protecting anything. The LIBONLY hook imports
# them without running the nvim gate. (Note the deliberate asymmetry with the SYNC
# scripts, which copy Write-CoreRefFile verbatim: that helper is inert formatting,
# these three are a trust boundary.)
$script:PrevNvimLibOnly = $env:DOTFILES_NVIMPARITY_LIBONLY
$env:DOTFILES_NVIMPARITY_LIBONLY = '1'
try { . (Join-Path $PSScriptRoot 'Assert-NvimParity.ps1') }
finally {
    if ($null -eq $script:PrevNvimLibOnly) { Remove-Item Env:DOTFILES_NVIMPARITY_LIBONLY -ErrorAction SilentlyContinue }
    else { $env:DOTFILES_NVIMPARITY_LIBONLY = $script:PrevNvimLibOnly }
}

# --- Get-ThemeParityDiff ------------------------------------------------------
# Pure: compare the two file hashes. A single file, so this is deliberately much
# simpler than the nvim tree walk — but kept as a named function so the result shape
# (and the InSync verdict) is unit-testable without any IO. Identical in shape to
# Get-StarshipParityDiff; kept separate rather than shared because the two gates are
# free to diverge (this one may grow a palette-key check) and a shared verdict helper
# would make that a cross-gate edit.
function Get-ThemeParityDiff {
    [OutputType([pscustomobject])]
    param([string]$LocalHash, [string]$CoreHash)
    [pscustomobject]@{
        LocalHash = $LocalHash
        CoreHash  = $CoreHash
        InSync    = ($LocalHash -and $CoreHash -and ($LocalHash -eq $CoreHash))
    }
}

# Library-only hook: let the test suite import the pure helpers without fetching.
if ($env:DOTFILES_THEMEPARITY_LIBONLY -eq '1') { return }

# --- main --------------------------------------------------------------------
$RepoRoot  = Split-Path -Parent $PSScriptRoot
$themeDir  = Join-Path $RepoRoot 'theme'
$localToml = Join-Path $themeDir 'palette.toml'
$refFile   = Join-Path $themeDir '.core-ref'

if (-not (Test-Path $refFile)) {
    Write-Host 'theme parity: no theme/.core-ref — skipped (run theme-sync.ps1 to stamp provenance).'
    exit 0
}
if (-not (Test-Path $localToml)) {
    Write-Error 'theme parity: theme/.core-ref exists but theme/palette.toml is missing.'
    exit 2
}

$refLines = Get-Content $refFile
$commit = Get-CoreRefField $refLines 'commit'
$source = Get-CoreRefField $refLines 'source'
if (-not $commit -or $commit -eq 'unknown') {
    Write-Host 'theme parity: .core-ref has no resolved commit — skipped.'
    exit 0
}
# .core-ref is tracked and PR-editable — same untrusted-input treatment as the nvim
# gate: the commit must look like a real SHA (hard fail, exit 2, distinct from the
# intentional "unknown => skip" above), and the clone target is allowlisted so a
# hostile PR cannot point CI's outbound fetch at an attacker-controlled URL.
if (-not (Test-DotGitSha $commit)) {
    Write-Error "theme parity: .core-ref commit '$commit' is not a valid git SHA — refusing to use it."
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
Write-Host "theme parity: checking theme/palette.toml against $remote @ $commit"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('core-theme-parity-' + [guid]::NewGuid().ToString('N'))
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

    $coreToml = Join-Path $tmp 'theme/palette.toml'
    if (-not (Test-Path $coreToml)) { Write-Error "Core @ $commit has no theme/palette.toml"; exit 2 }

    $diff = Get-ThemeParityDiff `
        -LocalHash (Get-FileHash -LiteralPath $localToml -Algorithm SHA256).Hash `
        -CoreHash  (Get-FileHash -LiteralPath $coreToml  -Algorithm SHA256).Hash

    $short = $commit.Substring(0, [Math]::Min(7, $commit.Length))
    if ($diff.InSync) {
        Write-Host "theme parity: OK — palette.toml matches Core @ $short." -ForegroundColor Green
        exit 0
    }
    Write-Host 'theme parity: DRIFT detected between theme/palette.toml and the recorded Core commit.' -ForegroundColor Red
    Write-Host "  vendored SHA-256: $($diff.LocalHash)" -ForegroundColor Yellow
    Write-Host "  Core @ $short   : $($diff.CoreHash)" -ForegroundColor Yellow
    Write-Host 'Fix by editing Core and re-running theme-sync.ps1 (do not hand-edit theme/palette.toml).'
    Write-Host 'Then re-run gen-theme.ps1 so the consumers follow the palette.'
    exit 1
} finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
