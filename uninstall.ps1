# ============================================================================
#  uninstall.ps1  -  reverse install.ps1: remove the symlinks this repo created
#  and (optionally) restore the most recent backup install.ps1 set aside.
#
#  Usage (from the repo root):
#      .\uninstall.ps1                  # remove repo symlinks (prompts per item)
#      .\uninstall.ps1 -DryRun          # preview, remove nothing
#      .\uninstall.ps1 -RestoreBackups  # also restore newest *.bak for each link
#      .\uninstall.ps1 -Yes             # don't prompt
#      .\uninstall.ps1 -Help
#
#  Conservative on purpose: it ONLY removes links that actually point back into
#  this repo, so a user file or an unrelated config is never touched. Seeded
#  copies (~/.wslconfig, ~/.gitconfig.local, powershell/local.ps1) are left
#  alone — they're your data, not ours to delete.
# ============================================================================
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$RestoreBackups,
    [switch]$Yes,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$LibPath = Join-Path $RepoRoot 'powershell/core/05-lib.ps1'
if (Test-Path $LibPath) { . $LibPath }

# --- the set of links install.ps1 creates -------------------------------------
# Thin projection of the shared link plan (Get-DotfilesLinkPlan in 05-lib) down to
# just the destination paths uninstall reasons about. Keeping this a wrapper — not
# a second hand-maintained list — is the whole point: a link added to the plan is
# automatically removed here and checked by dotfiles-doctor, with no third edit.
# Still pure/testable: the injected roots flow straight through to the plan.
#
# LegacyLink paths are included: a row that has changed shape (nvim, whose config
# directory used to BE the symlink and is now a real directory holding a stub) left
# something on disk that the plan no longer names, and only uninstall can retire it.
# They are appended AFTER the current links so the stub inside a legacy directory is
# considered before the directory itself.
function Get-DotfilesLinkMap {
    param(
        [string]$HomeDir        = $HOME,
        [string]$LocalAppData   = $env:LOCALAPPDATA,
        [string]$RoamingAppData = $env:APPDATA,
        [string]$Documents      = [Environment]::GetFolderPath('MyDocuments')
    )
    # RepoRoot only feeds the plan's Target (the repo side); the Link paths we
    # return depend solely on the injected user-dir roots, so $RepoRoot is fine.
    $plan = @(Get-DotfilesLinkPlan -RepoRoot $RepoRoot -HomeDir $HomeDir `
        -LocalAppData $LocalAppData -RoamingAppData $RoamingAppData -Documents $Documents)
    @($plan.Link) + @($plan.LegacyLink | Where-Object { $_ })
}

# A legacy directory that is now EMPTY — the stub inside it has just been removed and
# nothing else ever lived there. Left behind it is a confusing husk: %LOCALAPPDATA%\nvim
# still exists, so nvim keeps reporting it as stdpath('config') after an uninstall.
# Deliberately narrow: only a real directory (never a reparse point — that shape is
# handled as a link above), only when empty, and only for a path the plan names.
function Remove-EmptyLegacyDir {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType) { return $false }
    if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -gt 0) { return $false }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return (-not (Test-Path -LiteralPath $Path))
}

# True when $Link is a symlink whose target resolves inside this repo. Pure-ish
# (filesystem read only), shared shape with install.ps1's Test-SymlinkCurrent.
# Uses a real path-PREFIX check (not a substring) so a target under C:\repo2 is
# never mistaken for one under C:\repo — this gates a delete, so a false positive
# would remove an unrelated symlink.
function Test-LinkIntoRepo {
    param([string]$Link, [string]$Root)
    if (-not (Test-Path -LiteralPath $Link)) { return $false }
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne 'SymbolicLink') { return $false }
    $target = @($item.Target)[0]
    if (-not $target -or -not $Root) { return $false }
    try {
        $t = [System.IO.Path]::GetFullPath($target)
        $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    } catch { return $false }
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    return ([string]::Equals($t, $r, $cmp) -or
            $t.StartsWith($r + '\', $cmp) -or
            $t.StartsWith($r + '/', $cmp))
}

function Get-UninstallUsage {
    @(
        'uninstall.ps1 - remove the symlinks install.ps1 created'
        ''
        'USAGE'
        '  .\uninstall.ps1 [-DryRun] [-RestoreBackups] [-Yes] [-Help]'
        ''
        'OPTIONS'
        '  -DryRun           Preview what would be removed; change nothing.'
        '  -RestoreBackups   Restore the newest *.bak for each removed link.'
        '  -Yes              Remove without prompting.'
        '  -Help             Show this help and exit.'
    )
}

if ($Help) { Get-UninstallUsage | ForEach-Object { Write-Host $_ }; return }

# Library-only hook for the test suite.
if ($env:DOTFILES_UNINSTALL_LIBONLY -eq '1') { return }

if ($DryRun) {
    Write-Host ''
    Write-DotHost ' DRY RUN ' -Color Cyan
    Write-DotHost ' nothing will be removed or restored.' -Color DarkGray
}

$removed = 0; $restored = 0; $skipped = 0
Write-Host ''
Write-DotHost 'Removing dotfiles-Windows symlinks...' -Color Cyan

foreach ($link in Get-DotfilesLinkMap) {
    # Two shapes count as ours now: a symlink into the repo, and a Kind='Stub' real
    # file that includes the repo copy (see Get-DotfilesLinkPlan). Checking both is
    # what stops uninstall silently orphaning the stubs install.ps1 wrote — the exact
    # drift the shared plan exists to prevent.
    if (-not ((Test-LinkIntoRepo -Link $link -Root $RepoRoot) -or (Test-StubIntoRepo -Link $link -Root $RepoRoot))) {
        # Not ours (missing, a real file of the user's own, or links elsewhere) — never touch it.
        continue
    }

    if ($DryRun) {
        Write-DotHost "  would remove  $link" -Color Cyan
        if ($RestoreBackups) { Write-DotHost "    and restore newest backup if present" -Color DarkGray }
        continue
    }

    if (-not $Yes -and -not (Read-DotConfirm "  remove '$link'?" -DefaultYes $true)) {
        Write-DotHost "  kept    $link" -Color DarkGray
        $skipped++
        continue
    }

    Remove-Item -LiteralPath $link -Force -Recurse -ErrorAction SilentlyContinue
    Write-DotHost "  removed $link" -Color Green
    $removed++

    if ($RestoreBackups) {
        $bak = Get-ChildItem -Path (Split-Path -Parent $link) -Filter ((Split-Path -Leaf $link) + '.*.bak') `
                -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($bak) {
            Move-Item -LiteralPath $bak.FullName -Destination $link -Force
            Write-DotHost "  restored $link  (from $($bak.Name))" -Color Green
            $restored++
        }
    }
}

# Husk sweep: a legacy directory whose only occupant was the stub we just removed.
# After the loop, so it can never race the removal of the file inside it.
if (-not $DryRun) {
    $plan = @(Get-DotfilesLinkPlan -RepoRoot $RepoRoot)
    foreach ($legacy in @($plan.LegacyLink | Where-Object { $_ })) {
        if (Remove-EmptyLegacyDir -Path $legacy) {
            Write-DotHost "  removed $legacy  (empty)" -Color Green
            $removed++
        }
    }
}

Write-Host ''
Write-DotHost ("Done: {0} removed, {1} restored, {2} kept." -f $removed, $restored, $skipped) -Color Green
if (-not $DryRun) {
    Write-Host 'Note: DOTFILES_WIN, ~/.wslconfig, ~/.gitconfig.local and powershell/local.ps1 were left as-is.' -ForegroundColor DarkGray
}
