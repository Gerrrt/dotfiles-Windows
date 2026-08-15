# ============================================================================
#  tests/Install-DevDeps.ps1  -  one-command dev environment for contributors.
#
#  Provisions the SAME test toolchain CI uses (Pester + PSScriptAnalyzer, at the
#  pinned versions below) so `Invoke-Pester` and the opportunistic analyzer in
#  Invoke-Validation.ps1 behave locally exactly as they do on the Windows runner.
#  Idempotent: already-present versions are left alone.
#
#      pwsh -NoProfile -File tests/Install-DevDeps.ps1
#      pwsh -NoProfile -File tests/Install-DevDeps.ps1 -Help
#
#  The pinned versions are the single source of truth; a Repo.Tests gate asserts
#  .github/workflows/ci.yml references the very same ones, so they can't drift.
# ============================================================================
[CmdletBinding()]
param([switch]$Help)

# Pure: the dev-dependency pins, exposed so both the installer and the drift test
# read one definition. Keep these equal to the PESTER_VERSION / PSSA_VERSION env
# in .github/workflows/ci.yml (a test enforces it).
function Get-DevDepVersions {
    [ordered]@{
        Pester             = '5.6.1'
        PSScriptAnalyzer   = '1.22.0'
    }
}

if ($Help) {
    @(
        'Install-DevDeps.ps1 - install the pinned dev/test toolchain (Pester + PSScriptAnalyzer)'
        ''
        'USAGE'
        '  pwsh -NoProfile -File tests/Install-DevDeps.ps1 [-Help]'
        ''
        'Installs, to CurrentUser scope, the same versions CI pins. Idempotent.'
        'After it runs:  pwsh -NoProfile -File tests/Invoke-Tests.ps1   (full gated suite)'
        '                pwsh -NoProfile -File tests/Invoke-Validation.ps1   (fast gate)'
    ) | ForEach-Object { Write-Host $_ }
    return
}

# Library-only hook for the drift test: expose Get-DevDepVersions without installing.
if ($env:DOTFILES_DEVDEPS_LIBONLY -eq '1') { return }

$pins = Get-DevDepVersions
try { Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch { }

foreach ($name in $pins.Keys) {
    $ver = $pins[$name]
    $have = Get-Module -ListAvailable $name | Where-Object { $_.Version -eq [version]$ver }
    if ($have) {
        Write-Host "  = $name $ver (already installed)" -ForegroundColor DarkGray
        continue
    }
    Write-Host "  -> installing $name $ver ..." -ForegroundColor Cyan
    $args = @{ Name = $name; RequiredVersion = $ver; Scope = 'CurrentUser'; Force = $true; ErrorAction = 'Stop' }
    if ($name -eq 'Pester') { $args['SkipPublisherCheck'] = $true }
    try { Install-Module @args; Write-Host "     done." -ForegroundColor Green }
    catch { Write-Host "     FAILED: $_" -ForegroundColor Red }
}

Write-Host ''
Write-Host 'Dev toolchain ready. Run the suite with:  pwsh -NoProfile -File tests/Invoke-Tests.ps1' -ForegroundColor Green
