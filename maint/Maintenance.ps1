# ============================================================================
#  maint/Maintenance.ps1  -  the daily "update everything (that's safe)" runner.
# ============================================================================
#  Windows port of Core's maint/dotfiles-maint.sh. Invoked by Task Scheduler
#  (install it with `maint-install` from os/40-maint.ps1). Designed to run
#  UNATTENDED and NON-INTERACTIVE: every step is guarded and a failure of one
#  step never aborts the rest.
#
#  What it touches automatically (all USER-SPACE, low-risk):
#    • scoop:   update buckets, upgrade apps, cleanup
#    • scoop:   re-create the junctions scoop just remade, admin-trusted, so an
#               ssh session can traverse them. No-op unless the run is elevated —
#               it logs one SKIPPED line. See docs/REMOTE-ACCESS.md.
#    • mise:    plugin update + upgrade   (if installed)
#    • neovim:  Lazy! sync / TSUpdate / MasonUpdate  (headless, timeout-guarded)
#    • PowerShell modules: PSReadLine / Terminal-Icons / PSFzf / CompletionPredictor
#
#  winget is OPT-IN: `winget upgrade --all` can launch MSI installers that prompt
#  or restart apps, which isn't safe to run blind. Enable it deliberately:
#    $env:MAINT_WINGET_UPGRADE = '1'   (set in the scheduled task or before a run)
#
#  Env knobs:
#    MAINT_ENABLED          1     # 0 = no-op
#    MAINT_WINGET_UPGRADE   0     # 1 = also `winget upgrade --all` (see above)
#    MAINT_NVIM_TIMEOUT     600   # seconds
# ============================================================================
[CmdletBinding()] param([switch]$Help)

if ($Help) {
    @(
        'Maintenance.ps1 - unattended daily "update everything (that is safe)" runner'
        ''
        'USAGE'
        '  pwsh -NoProfile -File maint\Maintenance.ps1 [-Help]'
        '  (normally invoked by Task Scheduler — register it with: maint-install)'
        ''
        'WHAT IT DOES (all user-space, guarded, one failure never aborts the rest):'
        '  scoop: update buckets, upgrade apps, cleanup, then re-create the'
        '  junctions scoop just remade so an ssh session can traverse them (needs'
        '  elevation — logs one SKIPPED line otherwise; docs/REMOTE-ACCESS.md).'
        '  Then: mise update/upgrade; neovim Lazy/TS/Mason sync (headless,'
        '  timeout-guarded); PowerShell modules.'
        ''
        'ENV KNOBS'
        '  MAINT_ENABLED=1          set 0 to make the run a no-op'
        '  MAINT_WINGET_UPGRADE=0   set 1 to also run winget upgrade --all (can'
        '                           launch MSI installers, so it is opt-in)'
        '  MAINT_NVIM_TIMEOUT=600   seconds before the headless nvim step is killed'
        ''
        ('LOG: {0}' -f [System.IO.Path]::Combine(("$env:LOCALAPPDATA" -as [string]), 'dotfiles\maint\maint.log'))
    ) | ForEach-Object { Write-Host $_ }
    return
}

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\packages\modules.ps1')
# Test-DotModuleUpToDate, for the module step below. Dot-sourced directly rather
# than via the Dotfiles module: this runs under -NoProfile from a scheduled task,
# where nothing has imported that module and PSModulePath may not even include it.
# The file is pure and side-effect-free on load, which is what makes that safe.
. (Join-Path $PSScriptRoot '..\powershell\Dotfiles\Modules.Helpers.ps1')

# --- env knobs ----------------------------------------------------------------
if (-not $env:MAINT_ENABLED)        { $env:MAINT_ENABLED = '1' }
if (-not $env:MAINT_WINGET_UPGRADE) { $env:MAINT_WINGET_UPGRADE = '0' }
if (-not $env:MAINT_NVIM_TIMEOUT)   { $env:MAINT_NVIM_TIMEOUT = '600' }
if ($env:MAINT_ENABLED -ne '1') { return }

# --- paths / logging ----------------------------------------------------------
$LogDir = Join-Path $env:LOCALAPPDATA 'dotfiles\maint'
$Log    = Join-Path $LogDir 'maint.log'
$Lock   = Join-Path $LogDir '.lock'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log { param([string]$Msg) $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg; $line | Tee-Object -FilePath $Log -Append }
function Have { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# --- single-instance lock (mkdir-style: New-Item -ItemType Directory is atomic)
try {
    New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null
} catch {
    Write-Log "another run holds the lock ($Lock) — exiting"
    return
}
try {
    # --- log rotation (keep last ~600 lines) ----------------------------------
    if ((Test-Path $Log) -and ((Get-Content $Log -ErrorAction SilentlyContinue | Measure-Object).Count -gt 800)) {
        $tail = Get-Content $Log -Tail 600
        Set-Content -Path $Log -Value $tail
    }

    # --- labeled step that never aborts the script ----------------------------
    # Two ways a step can fail, and both have to be caught or the log lies:
    #
    #   • it THROWS — a cmdlet with -ErrorAction Stop, or Invoke-WithTimeout's
    #     timeout. Always caught.
    #   • it EXITS NON-ZERO — a native command. PowerShell does not throw for these,
    #     so every one of them used to be logged `ok`. Observed live: `navi repo
    #     update` printed "Shim: Could not create process" and was recorded as ok.
    #
    # $LASTEXITCODE is nulled first because it is SESSION state, not step state: a
    # body made only of cmdlets leaves the PREVIOUS step's value in place, and
    # checking that would blame this step for the last one's exit code. Null after
    # the body means no native command ran, which is not a failure.
    #
    # Known limit: a body chaining several native commands (`scoop cleanup *; scoop
    # cache rm *`) only reports the LAST one's code. Fixing that means splitting the
    # step, not making this cleverer.
    function Step {
        param([string]$Label, [scriptblock]$Body)
        Write-Log "> $Label"
        try {
            $global:LASTEXITCODE = $null
            & $Body *>> $Log
            if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                Write-Log "  FAIL $Label : exited $LASTEXITCODE  — continuing"
            } else {
                Write-Log "  ok $Label"
            }
        }
        catch { Write-Log "  FAIL $Label : $_  — continuing" }
    }

    # --- run a process with a timeout (for the headless nvim session) ---------
    # Uses ProcessStartInfo rather than Start-Process, and the reason is the bug that
    # made this whole step a no-op for its entire life.
    #
    # `Start-Process -ArgumentList @(...)` JOINS the array with spaces and does not
    # quote the elements. So
    #     @('--headless', '+Lazy! sync', '+silent! TSUpdateSync', ..., '+qa!')
    # reached nvim as
    #     --headless +Lazy! sync +silent! TSUpdateSync +silent! MasonUpdate +qa!
    # and nvim read `sync`, `TSUpdateSync` and `MasonUpdate` as FILENAMES to open
    # rather than as parts of the preceding +commands. It opened three empty buffers,
    # hit +qa!, and exited 0 in 0.2s having synced nothing. Measured side by side on
    # a real host: Start-Process 0.2s / 0 lines, ProcessStartInfo 5.9s / 398 lines.
    # ProcessStartInfo.ArgumentList quotes each element individually, which is the
    # whole difference.
    #
    # Reading the pipes directly also retires the old temp-file dance
    # ("$Log.nvim.out"/".err"), which had its own failure: the output was appended
    # with Add-Content while Step's `*>> $Log` held the same file open, so Windows
    # refused it ("being used by another process") and — non-terminating — the step
    # still said ok. Output is EMITTED here instead, and Step's existing redirect
    # captures it with one handle on the log rather than two.
    #
    # Both pipes are read concurrently on purpose: a child that fills one while the
    # parent blocks on the other deadlocks, and headless nvim writes plenty to both.
    #
    # $LASTEXITCODE is set from the child, so Step's exit-code check can see it —
    # neither Start-Process -PassThru nor [Process]::Start sets it.
    function Invoke-WithTimeout {
        param([string]$File, [string[]]$ArgList, [int]$TimeoutSec)
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = $File
        foreach ($a in $ArgList) { [void]$psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        $p   = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            # Kill the whole tree: nvim spawns git/curl children of its own, and
            # leaving those behind would keep the pipes open and hang the read.
            try { $p.Kill($true) } catch { }
            throw "timed out after ${TimeoutSec}s"
        }
        ($out.Result + $err.Result) -split "`r?`n" | Where-Object { $_ -ne '' }
        $global:LASTEXITCODE = $p.ExitCode
    }

    Write-Log "=========== dotfiles-maint start ($([Environment]::MachineName)) ==========="

    # --- scoop ----------------------------------------------------------------
    if (Have scoop) {
        Step 'scoop update (buckets)' { scoop update }
        Step 'scoop upgrade (apps)'   { scoop update * }
        Step 'scoop cleanup'          { scoop cleanup *; scoop cache rm * }
    }

    # --- scoop: re-create app junctions so ssh sessions can traverse them ------
    # Under ProcessRedirectionTrustPolicy (Redirection Guard) an ssh/service-lineage
    # process refuses to follow a junction that was CREATED by a non-admin — and scoop
    # creates every `scoop\apps\<app>\current` junction as you, so all scoop tools
    # (starship, mise, psmux, jj…) are unreachable over ssh. Trust is stamped at
    # creation time from the creator's token; ownership is irrelevant (icacls does
    # NOTHING), so the only fix is to re-create the junction from an elevated process.
    # scoop remakes it (untrusted) on every upgrade, so re-do it here, after the
    # upgrade. Needs elevation — re-creating as a non-admin would just re-stamp it
    # untrusted — so the script reports ONCE when unelevated. See docs/REMOTE-ACCESS.md.
    #
    # `apps\<app>\current` is not the only junction scoop makes: it also wires
    # persisted state back out of the app dir into `scoop\persist\<app>\...`, and
    # `scoop\modules\gsudoModule` sits outside apps\ entirely. Those are untrusted
    # for exactly the same reason, so Repair-ScoopJunctions.ps1 walks every
    # directory reparse point under the scoop root rather than just the app dirs.
    #
    # The work lives in that script, not inline here, because the daily task runs
    # UNELEVATED (scoop must never be upgraded as admin) — so the elevated
    # dotfiles-maint-scoop-junctions task needs the same logic as an entry point.
    if (Have scoop) {
        Step 'scoop: re-create junctions (admin-trusted)' { & (Join-Path $PSScriptRoot 'Repair-ScoopJunctions.ps1') }
    }

    # NB there is deliberately no "is the elevated junction task still healthy?" step
    # here. It cannot work: that task is registered with a SYSTEM principal, and Task
    # Scheduler ACLs its registration to SYSTEM + BUILTIN\Administrators only — the
    # user this run executes as has no read entry at all. So an unelevated
    # Get-ScheduledTask returns nothing whether the task is broken, missing, or
    # perfectly fine, and a check built on that reports a confident FAIL every single
    # day. A run that reliably prints a false error is worse than one that says
    # nothing. That check lives in `maint-status` and `dotfiles-doctor`, which can
    # tell the difference — and which you run from the elevated shell you would need
    # to fix it from anyway.

    # --- mise (runtime/tool versions) -----------------------------------------
    if (Have mise) {
        Step 'mise plugins update' { mise plugins update }
        Step 'mise upgrade'        { mise upgrade --yes }
    }

    # --- neovim: lazy.nvim sync + treesitter parsers + Mason registry ---------
    if (Have nvim) {
        Step 'neovim: Lazy sync / TSUpdate / MasonUpdate' {
            Invoke-WithTimeout -File (Get-Command nvim).Source `
                -ArgList @('--headless', '+Lazy! sync', '+silent! TSUpdateSync', '+silent! MasonUpdate', '+qa!') `
                -TimeoutSec ([int]$env:MAINT_NVIM_TIMEOUT)
        }
    }

    # --- navi: no step, deliberately -----------------------------------------
    # There used to be a `navi repo update` step here. It never worked on any host:
    # `navi repo` takes only add / browse / help, so the command exited 2 with
    # "unrecognized subcommand 'update'" every single run. Nobody noticed because
    # Step did not check exit codes and logged it ok — the same blind spot that hid
    # the nvim step doing nothing.
    #
    # Removed rather than re-pointed at a working command, because there is no
    # equivalent: navi has no "refresh my repos" verb, and updating imported
    # cheatsheets means git-pulling each one under `navi info cheats-path` by hand.
    # Add that back the day cheat repos are actually imported (`navi repo add`);
    # until then a step that greps for a directory which does not exist is worth
    # less than the line it occupies.

    # --- PowerShell modules ---------------------------------------------------
    # Refresh into the LOCAL (non-OneDrive) modules dir with Save-Module -Force —
    # the same path profile.ps1 prepends and Install-Packages.ps1 seeds. Keeps
    # modules off OneDrive (fast shell start) and sidesteps the old PSReadLine
    # special case: Save-Module just writes the latest Name\Version with no
    # Update-Module-vs-shipped-module friction.
    # Only saved when the gallery actually has something NEWER. Save-Module -Force
    # rewrites <Path>\<Name>\<Version> wholesale even when that exact version is
    # already there, and for a module whose assemblies are mapped into a running
    # PowerShell that overwrite cannot succeed — the files are locked and it fails
    # with "Access to the path ... is denied". PSReadLine is loaded by EVERY session,
    # so on any box with a shell open it failed every single run while being
    # perfectly up to date. Measured here: all four managed modules already matched
    # the gallery, so this step re-downloaded four modules a day to achieve nothing
    # and failed on one of them.
    #
    # A genuinely new version lands in its OWN version directory and never touches
    # the locked one, so the update path that matters is unaffected.
    #
    # Find-Module failing (offline, gallery down) falls THROUGH to Save-Module rather
    # than skipping: an unknown latest version must not read as "up to date", or the
    # step would go quiet on exactly the days it cannot check.
    $localModules = Join-Path $env:LOCALAPPDATA 'PowerShell\Modules'
    New-Item -ItemType Directory -Force -Path $localModules | Out-Null
    foreach ($m in $script:MaintModuleNames) {
        Step "module update: $m" {
            $installed = @(Get-ChildItem -LiteralPath (Join-Path $localModules $m) -Directory -Force -ErrorAction SilentlyContinue |
                ForEach-Object Name)
            $latest = try { [string](Find-Module -Name $m -ErrorAction Stop).Version } catch { '' }
            if (Test-DotModuleUpToDate -InstalledVersions $installed -LatestVersion $latest) {
                "module $m already at $latest — nothing to save"
                return
            }
            Save-Module -Name $m -Path $localModules -Force -ErrorAction Stop
        }
    }

    # --- winget (OPT-IN — see header) -----------------------------------------
    if ($env:MAINT_WINGET_UPGRADE -eq '1' -and (Have winget)) {
        Step 'winget upgrade --all' {
            winget upgrade --all --include-unknown --silent `
                --accept-package-agreements --accept-source-agreements
        }
    } else {
        Write-Log "winget upgrade SKIPPED (set MAINT_WINGET_UPGRADE=1 to enable; can launch MSI installers)"
    }

    Write-Log "=========== dotfiles-maint done ==========="
}
finally {
    Remove-Item $Lock -Recurse -Force -ErrorAction SilentlyContinue
}
