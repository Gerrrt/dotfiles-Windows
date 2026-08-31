# ============================================================================
#  tests/Invoke-Tests.ps1  -  the ONE way to run the suite, locally and in CI.
#
#      pwsh -NoProfile -File tests/Invoke-Tests.ps1            # full gated run
#      pwsh -NoProfile -File tests/Invoke-Tests.ps1 -NoGate    # tests only, no gate
#
#  Why this exists: the gated run — coverage measurement, the baseline comparison,
#  the exact test-FILE match and the test-case floor — used to live only inline in
#  .github/workflows/ci.yml, while the documented local command was a bare
#  `Invoke-Pester -Path tests`. So "passes locally" and "passes CI" were different
#  assertions, and the difference was invisible until CI failed. Both now call this.
#
#  The gate is a pure decision (tests/CoverageGate.ps1) over a versioned, generated
#  baseline (tests/coverage-baseline.json) — never hand-edited literals. Refresh the
#  baseline with tests/Update-CoverageBaseline.ps1 after intentionally removing
#  tests (B5); Read-CoverageBaseline throws on a missing/corrupt file so the gate
#  cannot silently go soft.
#
#  Exit code is non-zero if any test fails OR the gate trips, so CI and hooks can
#  gate on this one command.
# ============================================================================
[CmdletBinding()]
param(
    # Run the tests but skip the coverage/floor gate. For a fast inner loop —
    # NOT what CI uses, and not what you should trust before pushing.
    [switch]$NoGate,
    # Pester's own verbosity. 'Detailed' matches what CI prints.
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Verbosity = 'Detailed',
    # Which Pester to load. Defaults to the repo's single pin (Get-DevDepVersions in
    # tests/Install-DevDeps.ps1, which a Repo.Tests gate keeps equal to ci.yml's
    # PESTER_VERSION). Override only to reproduce a version-specific problem.
    [string]$PesterVersion,
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

# The pure-helper surface the coverage bar applies to: 05-lib.ps1 plus the
# Dotfiles module's extracted helper files (B7), each fully exercised by the
# Lib/Wsl/Doctor/Help/Module suites. A drop here means a test was deleted or a
# branch was added without a covering test. Grow this list as more pure helpers
# reach full coverage.
$script:CoveragePaths = @(
    './powershell/core/05-lib.ps1'
    './powershell/Dotfiles/Wsl.Helpers.ps1'
    './powershell/Dotfiles/Doctor.Helpers.ps1'
    './powershell/Dotfiles/Help.Helpers.ps1'
    './powershell/Dotfiles/Modules.Helpers.ps1'
)

# gen-theme.ps1 is deliberately NOT in the list, and this note is here so it does not
# get "helpfully" added. Its pure half (palette parser, line walker, drift verdict,
# residual scan) is covered by 32 tests in tests/GenTheme.Tests.ps1 — but its emitters
# and main body are exercised by SPAWNING pwsh against a fixture tree, which in-process
# instrumentation cannot see. Measured alone it reads 31%, so adding it would drag the
# aggregate under the target while saying nothing true about how well it is tested.
# Coverage here measures dot-sourceable pure helpers; a script whose real surface is a
# child process is the wrong shape for it.

# Library-only hook, matching the convention every other script here uses: lets
# tests/RunnerContract.Tests.ps1 assert the coverage set without running the suite
# (which would recurse).
if ($env:DOTFILES_INVOKETESTS_LIBONLY -eq '1') { return }

Push-Location $RepoRoot
try {
    # Load the PINNED Pester. A bare `Import-Module Pester` loads the HIGHEST
    # installed version, so a box with several (this one had 6.1.0, 6.0.1, 6.0.0,
    # 5.6.1 and 3.4.0) runs a different — here, a different MAJOR — Pester than the
    # runner does. That is exactly the local-vs-CI drift this script exists to
    # remove, so it would have quietly reintroduced the bug through the fix.
    #
    # The version comes from the repo's ONE pin definition rather than a literal
    # here: Get-DevDepVersions in Install-DevDeps.ps1, which a Repo.Tests gate keeps
    # equal to ci.yml's PESTER_VERSION.
    if (-not $PesterVersion) {
        $prev = $env:DOTFILES_DEVDEPS_LIBONLY
        $env:DOTFILES_DEVDEPS_LIBONLY = '1'
        try { . (Join-Path $PSScriptRoot 'Install-DevDeps.ps1'); $PesterVersion = (Get-DevDepVersions).Pester }
        finally {
            if ($null -eq $prev) { Remove-Item Env:DOTFILES_DEVDEPS_LIBONLY -ErrorAction SilentlyContinue }
            else { $env:DOTFILES_DEVDEPS_LIBONLY = $prev }
        }
    }

    $have = Get-Module -ListAvailable Pester | Where-Object { $_.Version -eq [version]$PesterVersion }
    if (-not $have) {
        Write-Error "Pester $PesterVersion (the pinned version) is not installed. Run: pwsh -NoProfile -File tests/Install-DevDeps.ps1"
        exit 1
    }
    Import-Module Pester -RequiredVersion $PesterVersion
    Write-Host "Pester $PesterVersion (pinned)" -ForegroundColor DarkGray

    . (Join-Path $PSScriptRoot 'CoverageGate.ps1')

    $testPath = './tests'   # single source for the run path AND the test-file glob
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $testPath
    # PassThru (not Run.Exit) so we get the result object back and can gate on BOTH
    # failures and coverage ourselves, with messages that say which one tripped.
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = $Verbosity

    if (-not $NoGate) {
        $baseline = Read-CoverageBaseline (Get-Content (Join-Path $PSScriptRoot 'coverage-baseline.json') -Raw)
        $cfg.CodeCoverage.Enabled = $true
        $cfg.CodeCoverage.Path = $script:CoveragePaths
        $cfg.CodeCoverage.CoveragePercentTarget = $baseline.CoveragePercentTarget
    }

    $r = Invoke-Pester -Configuration $cfg

    if ($NoGate) {
        Write-Host ''
        Write-Host "Tests: $($r.PassedCount) passed, $($r.FailedCount) failed, $($r.TotalCount) total."
        Write-Host 'Gate skipped (-NoGate) — CI runs the gated form.' -ForegroundColor DarkYellow
        exit ([int]($r.FailedCount -gt 0))
    }

    $pct = [math]::Round($r.CodeCoverage.CoveragePercent, 1)
    Write-Host ''
    Write-Host ("Tests: {0} passed, {1} failed, {2} total across {3} file(s). Coverage (pure-helper surface): {4}% (target {5}%)" -f `
        $r.PassedCount, $r.FailedCount, $r.TotalCount, $r.Containers.Count, $pct, $baseline.CoveragePercentTarget)

    # The test-FILE count is auto-derived (not stored): count *.Tests.ps1 under the
    # run path RECURSIVELY (matching Pester's own discovery) and assert Pester ran
    # EXACTLY that many — a suite that fails to load, or is removed/renamed, is
    # caught with no number to maintain (issue #29).
    $expectedFiles = @(Get-ChildItem $testPath -Recurse -File -Filter *.Tests.ps1 -ErrorAction Stop).Count

    # One pure decision over the whole result: hard failures, the coverage bar, the
    # exact file match, and the test-case floor. The floor also guards suites NOT in
    # CoveragePaths (install/uninstall/packages), whose removed tests wouldn't show
    # up as a coverage drop.
    $gate = Get-CoverageGateResult -CoveragePercent $r.CodeCoverage.CoveragePercent `
        -TotalCount $r.TotalCount -FileCount $r.Containers.Count -ExpectedFileCount $expectedFiles `
        -FailedCount $r.FailedCount -Baseline $baseline

    if (-not $gate.Passed) {
        # ::error:: is a GitHub Actions annotation and plain noise elsewhere, which
        # is exactly right — the same command has to serve both callers.
        $gate.Failures | ForEach-Object { Write-Host "::error::$_" }
        Write-Host ''
        Write-Host ("coverage gate failed:`n  " + ($gate.Failures -join "`n  ")) -ForegroundColor Red
        exit 1
    }

    Write-Host 'Gate passed.' -ForegroundColor Green
    exit 0
}
finally { Pop-Location }
