# ============================================================================
#  tests/Invoke-Validation.ps1  -  fast, dependency-free repo health gate.
#
#  Runs WITHOUT PSScriptAnalyzer or Pester (no PowerShell Gallery needed), so it
#  works in a locked-down/offline environment and as a pre-commit smoke test:
#    pwsh -NoProfile -File tests/Invoke-Validation.ps1
#
#  Checks:
#    1. every *.ps1 parses cleanly (real syntax/regression gate via the AST parser)
#    2. every *.json is well-formed and the package manifests have no dup entries
#    3. starship.toml parses as TOML (best-effort; skipped if no parser available)
#
#  Exit code is non-zero if anything fails, so CI and hooks can gate on it.
#  The richer lint (PSScriptAnalyzer) + behavioral tests (Pester) run in CI on a
#  Windows runner, where the Gallery is reachable — see .github/workflows/ci.yml.
# ============================================================================
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$fail = 0
function Fail { param([string]$m) $script:fail++; Write-Host "  ✗ $m" -ForegroundColor Red }
function Pass { param([string]$m) Write-Host "  ✓ $m" -ForegroundColor Green }

# --- 1. PowerShell syntax (AST parse) -----------------------------------------
Write-Host 'PowerShell syntax:' -ForegroundColor Cyan
$ps1 = Get-ChildItem -Path $RepoRoot -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
foreach ($f in $ps1) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) {
        Fail "parse: $($f.FullName)"
        $errors | ForEach-Object { Write-Host "      $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor DarkRed }
    }
}
if ($script:fail -eq 0) { Pass "$($ps1.Count) script(s) parsed clean" }

# --- 2. JSON well-formedness + manifest integrity -----------------------------
Write-Host 'JSON / manifests:' -ForegroundColor Cyan
$preJson = $script:fail
Get-ChildItem -Path $RepoRoot -Recurse -Filter *.json -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | ForEach-Object {
        try { Get-Content $_.FullName -Raw | ConvertFrom-Json | Out-Null }
        catch { Fail "json: $($_.FullName): $_" }
    }

$scoop = Join-Path $RepoRoot 'packages/scoopfile.json'
if (Test-Path $scoop) {
    $m = Get-Content $scoop -Raw | ConvertFrom-Json
    $dupApps = $m.apps.Name | Group-Object | Where-Object Count -gt 1
    if ($dupApps) { Fail "scoopfile.json duplicate apps: $($dupApps.Name -join ', ')" }
    $dupBkt = $m.buckets.Name | Group-Object | Where-Object Count -gt 1
    if ($dupBkt) { Fail "scoopfile.json duplicate buckets: $($dupBkt.Name -join ', ')" }
    # Provenance: every app names a declared bucket and looks like a real app id,
    # so a typo'd entry fails here instead of only on a live box at install time.
    $declared = @($m.buckets.Name)
    foreach ($app in $m.apps) {
        if ($app.Name -notmatch '^[\w.+-]+$') { Fail "scoopfile.json odd app name: '$($app.Name)'" }
        if ($declared -notcontains $app.Source) { Fail "scoopfile.json app '$($app.Name)' references undeclared bucket '$($app.Source)'" }
        # Optional version pin must be a non-whitespace token (scoop install name@ver).
        if ($app.PSObject.Properties.Name -contains 'Version' -and "$($app.Version)" -notmatch '^\S+$') {
            Fail "scoopfile.json app '$($app.Name)' has an empty/odd Version pin"
        }
    }
}
$wg = Join-Path $RepoRoot 'packages/winget.json'
if (Test-Path $wg) {
    $w = (Get-Content $wg -Raw | ConvertFrom-Json).packages
    # Entries may be a bare id string OR an object { id, version } (optional pin).
    # Normalize to ids for the dup/shape checks; validate any version separately.
    $ids = foreach ($e in $w) { if ($e -is [string]) { $e } else { $e.id } }
    $dupWg = $ids | Group-Object | Where-Object Count -gt 1
    if ($dupWg) { Fail "winget.json duplicate ids: $($dupWg.Name -join ', ')" }
    # Provenance: winget ids are Publisher.Package (at least one dot, no spaces).
    foreach ($id in $ids) {
        if ($id -notmatch '^[^\s.]+(\.[^\s.]+)+$') { Fail "winget.json malformed id: '$id'" }
    }
    foreach ($e in $w) {
        if ($e -isnot [string]) {
            if (-not $e.id)      { Fail "winget.json object entry missing 'id'" }
            if ($e.PSObject.Properties.Name -contains 'version' -and "$($e.version)" -notmatch '^\S+$') {
                Fail "winget.json entry '$($e.id)' has an empty/odd version pin"
            }
        }
    }
}
if ($script:fail -eq $preJson) { Pass 'all JSON valid; manifests have no duplicates' }

# --- 2b. module pins are EXACT versions (hermetic install gate) ---------------
# packages/modules.ps1 must pin every managed module to an exact x.y[.z] version
# so a fresh bootstrap is reproducible (Install-Packages uses -RequiredVersion).
# Catch a floor/range/prerelease tag sneaking back in here, dependency-free.
Write-Host 'Module pins (exact versions):' -ForegroundColor Cyan
$modScript = Join-Path $RepoRoot 'packages/modules.ps1'
if (Test-Path $modScript) {
    $preMod = $script:fail
    . $modScript
    if (-not $script:MaintModulePins) {
        Fail 'modules.ps1 did not define $script:MaintModulePins'
    } else {
        foreach ($name in $script:MaintModulePins.Keys) {
            $v = $script:MaintModulePins[$name]
            if ($v -notmatch '^\d+\.\d+(\.\d+)?$') { Fail "module pin '$name' is not an exact version: '$v'" }
        }
        if ($script:fail -eq $preMod) { Pass "$($script:MaintModulePins.Count) module pin(s) are exact versions" }
    }
}

# --- 3. TOML (best-effort) ----------------------------------------------------
Write-Host 'TOML (best-effort):' -ForegroundColor Cyan
$toml = Get-ChildItem -Path $RepoRoot -Recurse -Filter *.toml -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
if (Get-Command python3 -ErrorAction SilentlyContinue) {
    $preToml = $script:fail
    foreach ($t in $toml) {
        $py = "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))"
        & python3 -c $py $t.FullName 2>$null
        if ($LASTEXITCODE -ne 0) { Fail "toml: $($t.FullName)" }
    }
    if ($script:fail -eq $preToml) { Pass "$($toml.Count) TOML file(s) checked" }
} else {
    Write-Host '  - skipped (no python tomllib available)' -ForegroundColor DarkGray
}

# --- 4. editorconfig basics (final newline, no trailing WS, LF endings) --------
# Enforces the shipped .editorconfig where it's cheap and unambiguous, so the
# whole fleet's formatting can't silently drift. Dependency-free (no editorconfig
# binary): we encode the few rules that matter here.
#   • every text file ends with a newline           (insert_final_newline = true)
#   • no trailing whitespace, except *.md            (trim_trailing_whitespace)
#   • LF line endings, except *.cmd/*.bat            (end_of_line = lf|crlf)
Write-Host 'editorconfig (final newline / trailing WS / LF):' -ForegroundColor Cyan
$preEc = $script:fail
$textExt = '.ps1', '.psm1', '.psd1', '.lua', '.json', '.yml', '.yaml', '.toml', '.md'
$crlfOk  = '.cmd', '.bat'
# .core-ref is written by the sync scripts, so it is exactly the kind of generated
# text that drifts unnoticed — it escaped this gate entirely until a sync was caught
# leaving CRLF behind that .gitattributes then silently normalized on commit.
$nameOk  = '.editorconfig', '.gitignore', '.gitignore_global', '.gitconfig', 'config', '.core-ref'
# Enumerate via `git ls-files` so we check EXACTLY the repo's own tracked text.
# This skips .git, gitignored paths, untracked build output AND nested git
# worktrees (e.g. .claude/worktrees/*) — separate checkouts whose line endings
# aren't ours to police, and which a plain filesystem walk would wrongly flag.
# Fall back to a filesystem walk (still excluding .git/.claude) if git is absent.
# try/catch because $ErrorActionPreference='Stop' turns a missing git into a
# terminating CommandNotFoundException — without it the fallback would never run
# and the validator would stop being dependency-free off a git PATH.
$tracked = $null
try { $tracked = & git -C $RepoRoot ls-files 2>$null } catch { $tracked = $null }
if ($tracked) {
    $ecFiles = $tracked |
        ForEach-Object { Get-Item -LiteralPath (Join-Path $RepoRoot $_) -ErrorAction SilentlyContinue } |
        Where-Object { $_ -and ($_.Extension -in $textExt -or $_.Name -in $nameOk) }
} else {
    $ecFiles = Get-ChildItem -Path $RepoRoot -Recurse -File |
        Where-Object {
            $_.FullName -notmatch '[\\/]\.git[\\/]' -and
            $_.FullName -notmatch '[\\/]\.claude[\\/]' -and
            ($_.Extension -in $textExt -or $_.Name -in $nameOk)
        }
}
foreach ($f in $ecFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -eq 0) { continue }                       # empty file: nothing to check
    if ($bytes[-1] -ne 0x0A) { Fail "no final newline: $($f.FullName)" }
    if ($f.Extension -notin $crlfOk -and ($bytes -contains 0x0D)) {
        Fail "CRLF line ending (want LF): $($f.FullName)"
    }
    if ($f.Extension -ne '.md') {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($text -split "`n" | Where-Object { $_ -match '[ \t]+\r?$' }) {
            Fail "trailing whitespace: $($f.FullName)"
        }
    }
}
if ($script:fail -eq $preEc) { Pass "$($ecFiles.Count) file(s) match editorconfig basics" }

# --- 5. PSScriptAnalyzer (opportunistic: only if already installed) -----------
# Keeps this script's dependency-free promise — it does NOT install anything. But
# when a contributor (or the pre-commit hook) has PSScriptAnalyzer available, run
# it here so lint regressions are caught locally instead of only on the Windows CI
# runner. Gates on ERRORS only (warnings are shown), matching the CI severity gate,
# and uses the repo's shared settings so local and CI agree on the ruleset.
# Skip with DOTFILES_VALIDATE_NO_PSSA=1.
Write-Host 'PSScriptAnalyzer (opportunistic):' -ForegroundColor Cyan
if ($env:DOTFILES_VALIDATE_NO_PSSA -eq '1') {
    Write-Host '  - skipped (DOTFILES_VALIDATE_NO_PSSA=1)' -ForegroundColor DarkGray
} elseif (Get-Module -ListAvailable PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer
    $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $findings = Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -Settings $settings -ErrorAction SilentlyContinue |
        Where-Object { $_.ScriptPath -notmatch '[\\/]\.git[\\/]' }
    $errs = @($findings | Where-Object Severity -eq 'Error')
    $warns = @($findings | Where-Object Severity -eq 'Warning')
    if ($warns.Count) {
        $warns | ForEach-Object { Write-Host ("      warn {0}:{1} {2}" -f (Split-Path -Leaf $_.ScriptPath), $_.Line, $_.RuleName) -ForegroundColor DarkYellow }
    }
    if ($errs.Count) {
        $errs | ForEach-Object { Write-Host ("      err  {0}:{1} {2}" -f (Split-Path -Leaf $_.ScriptPath), $_.Line, $_.RuleName) -ForegroundColor DarkRed }
        Fail "PSScriptAnalyzer reported $($errs.Count) error(s)"
    } else {
        Pass "no analyzer errors ($($warns.Count) warning(s))"
    }
} else {
    Write-Host '  - skipped (PSScriptAnalyzer not installed; runs on the Windows CI runner)' -ForegroundColor DarkGray
}

Write-Host ''
if ($script:fail) {
    Write-Host "VALIDATION FAILED ($script:fail issue(s))" -ForegroundColor Red
    exit 1
}
Write-Host 'VALIDATION PASSED' -ForegroundColor Green
exit 0
