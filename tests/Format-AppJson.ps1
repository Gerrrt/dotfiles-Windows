# ============================================================================
#  tests/Format-AppJson.ps1  -  normalize configs that their own GUI app rewrites.
#
#  Some tracked configs are LIVE files: the app that owns them writes them back
#  through the symlink whenever it exits. windows-terminal/settings.json is the
#  standing example — open Windows Terminal once and it re-serializes the whole
#  file, reintroducing trailing whitespace and dropping the final newline, which
#  fails tests/Invoke-Validation.ps1 and therefore the pre-commit hook and CI.
#
#  This normalizes the three things the validator actually gates on:
#      • LF line endings          (end_of_line = lf)
#      • no trailing whitespace   (trim_trailing_whitespace = true)
#      • exactly one final LF     (insert_final_newline = true)
#
#  It deliberately does NOT re-indent. The app re-serializes with its own indent
#  on every launch, so normalizing that here would dirty the entire file each
#  time the user opens the app — maximizing diff churn instead of removing it.
#  The .editorconfig carries a matching carve-out so the declared style is the
#  truth rather than an aspiration. Everything the app cannot undo IS enforced.
#
#  Usage:
#    pwsh -NoProfile -File tests/Format-AppJson.ps1           # fix in place
#    pwsh -NoProfile -File tests/Format-AppJson.ps1 -Check    # report only, exit 1 on drift
#    pwsh -NoProfile -File tests/Format-AppJson.ps1 -Path a.json,b.json
#
#  Idempotent: running it twice on the same file is a no-op the second time.
# ============================================================================
[CmdletBinding()]
param(
    # Repo-relative or absolute paths. Defaults to the known app-rewritten set.
    [string[]]$Path,
    # Report drift without writing. Exit code 1 if any file would change.
    [switch]$Check,
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

# The tracked configs a GUI app owns and rewrites. Add to this list rather than
# teaching the hook about new paths — the hook just calls this script.
$script:AppOwnedConfigs = @(
    'windows-terminal/settings.json'
)

if (-not $Path) { $Path = $script:AppOwnedConfigs }

# Pure: given raw file text, return the normalized text. Unit-testable with no IO.
function Get-NormalizedAppJson {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($Text.Length -eq 0) { return '' }

    # CRLF and lone CR -> LF first, so the trailing-whitespace pass can't leave a
    # stranded \r behind (which the validator counts as a CRLF failure, not WS).
    $t = $Text -replace "`r`n", "`n" -replace "`r", "`n"

    # Strip trailing spaces/tabs from every line.
    $t = ($t -split "`n" | ForEach-Object { $_ -replace '[ \t]+$', '' }) -join "`n"

    # Exactly one final newline: trim any run of blank lines at EOF, then add one.
    $t = $t.TrimEnd("`n") + "`n"

    return $t
}

# The LIBONLY hook the rest of the suite uses: dot-source for the pure helper
# without running the file loop. See tests/Repo.Tests.ps1 for the convention.
if ($env:DOTFILES_FORMATAPPJSON_LIBONLY -eq '1') { return }

$changed = @()
$missing = @()

foreach ($rel in $Path) {
    $full = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $RepoRoot $rel }

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $missing += $rel
        continue
    }

    # Read as raw bytes -> UTF8 string so we neither add a BOM nor let PowerShell's
    # line-ending translation mask the very drift we are here to detect.
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $original = [System.Text.Encoding]::UTF8.GetString($bytes)
    $normalized = Get-NormalizedAppJson -Text $original

    if ($normalized -ceq $original) { continue }

    $changed += $rel
    if (-not $Check) {
        # UTF8Encoding($false) = no BOM. WriteAllText does not translate newlines,
        # so the LF we just normalized to survives the round trip on Windows.
        [System.IO.File]::WriteAllText($full, $normalized, [System.Text.UTF8Encoding]::new($false))
    }
}

foreach ($m in $missing) {
    Write-Host "  - skipped (not found): $m" -ForegroundColor DarkGray
}

if (-not $changed) {
    Write-Host '  ✓ app-owned configs already normalized' -ForegroundColor Green
    exit 0
}

if ($Check) {
    foreach ($c in $changed) { Write-Host "  ✗ needs normalizing: $c" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Fix with: pwsh -NoProfile -File tests/Format-AppJson.ps1' -ForegroundColor Yellow
    exit 1
}

foreach ($c in $changed) { Write-Host "  ✓ normalized: $c" -ForegroundColor Green }
exit 0
