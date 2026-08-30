# ============================================================================
#  Maint.Helpers.ps1  -  pure logic for the maintenance scheduled tasks: which
#  pwsh a task should be registered against, and whether a registered task is
#  still able to run. Owned by the Dotfiles module.
#
#  Both live here rather than in os/40-maint.ps1 for the same reason
#  Get-DotScoopJunctionPlan does: the caller performs every host read (Test-Path,
#  Get-ScheduledTask, Get-ScheduledTaskInfo) and these functions decide what
#  those reads MEAN — so the policy is unit tested without registering a real
#  task, without an admin token, and without a particular pwsh install.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: Get-DotStablePwshPath, Get-DotMaintTaskHealth
# requires: (none)

# --- Get-DotStablePwshPath ----------------------------------------------------
# Which pwsh.exe to bake into a scheduled task's action.
#
# Task Scheduler stores an ABSOLUTE path and never re-resolves it, so that path
# has to still be valid months later. `(Get-Command pwsh).Source` is the wrong
# answer for that: when PowerShell is installed from the Store it resolves to the
# VERSION-PINNED package directory —
#   C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.5.0_x64__8wekyb3d8bbwe\pwsh.exe
# — and the moment Windows cleans up a superseded package that directory is gone
# and every run fails with 0x80070002 (ERROR_FILE_NOT_FOUND). Silently: a task
# that never launches writes nothing to maint.log, so the daily run just stops.
#
# So the caller probes the stable locations first (MSI install, machine-wide app
# alias, per-user app alias, scoop shim) and passes the Get-Command answer LAST,
# flagged Stable = $false — it is a real answer, just a version-pinned one, and a
# warned-about task beats no task at all.
#
# The asymmetry that makes this more than a list is RunAs. A per-user
# app-execution alias under %LOCALAPPDATA% is version-stable and perfectly good
# for the daily task, which runs as you — but the junction task runs as SYSTEM,
# whose LOCALAPPDATA is C:\Windows\System32\config\systemprofile\AppData\Local and
# holds no such alias. A UserScoped candidate is therefore not merely unstable for
# SYSTEM, it does not exist there, so it has to be rejected outright.
function Get-DotStablePwshPath {
    [OutputType([pscustomobject])]
    param(
        # One row per location the caller probed, ordered MOST STABLE FIRST:
        #   @{ Path = <path>; Kind = <label>; Stable = <bool>; UserScoped = <bool>; Exists = <bool> }
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidate,
        # Which principal the task will run as.
        [ValidateSet('User', 'System')][string]$RunAs = 'User'
    )

    $rejected = [System.Collections.Generic.List[object]]::new()
    $pick     = $null

    foreach ($c in $Candidate) {
        $path = [string]$c.Path
        $kind = [string]$c.Kind

        if (-not $path) {
            $rejected.Add([pscustomobject]@{ Path = ''; Kind = $kind; Reason = 'no path' })
            continue
        }
        if (-not $c.Exists) {
            $rejected.Add([pscustomobject]@{ Path = $path; Kind = $kind; Reason = 'not present' })
            continue
        }
        if ($RunAs -eq 'System' -and $c.UserScoped) {
            $rejected.Add([pscustomobject]@{
                Path   = $path
                Kind   = $kind
                Reason = 'user-scoped path — the SYSTEM task does not run in your profile'
            })
            continue
        }
        $pick = $c
        break
    }

    if (-not $pick) {
        return [pscustomobject]@{
            Path     = $null
            Kind     = 'none'
            IsStable = $false
            Reason   = 'no usable pwsh found'
            Warning  = "maint: no usable pwsh found for the $RunAs task — it cannot be registered"
            Rejected = $rejected.ToArray()
        }
    }

    $isStable = [bool]$pick.Stable
    $kindName = [string]$pick.Kind
    $warning  = if ($isStable) { $null } else {
        ("maint: no version-stable pwsh found — the '{0}' path baked into the {1} task is version-pinned, " +
         'so a PowerShell update will break it with 0x80070002') -f $kindName, $RunAs
    }

    return [pscustomobject]@{
        Path     = [string]$pick.Path
        Kind     = $kindName
        IsStable = $isStable
        Reason   = if ($isStable) { "version-stable ($kindName)" } else { "version-pinned ($kindName)" }
        Warning  = $warning
        Rejected = $rejected.ToArray()
    }
}

# --- Get-DotMaintTaskHealth ---------------------------------------------------
# Is a registered maint task actually able to run, and did its last run launch?
#
# maint-status has always PRINTED LastTaskResult, as an inert hex field with no
# verdict attached — which is exactly how a dotfiles-maint sitting at 0x80070002
# for days went unnoticed. Two things are worth a verdict:
#
#   1. The action's executable no longer exists. Every future run fails.
#   2. A non-zero LastTaskResult. This is the higher-value signal, because
#      Maintenance.ps1's Step function catches every step failure by design, so
#      the runner essentially CANNOT exit non-zero — a non-zero task result almost
#      always means the script never ran at all.
#
# The SCHED_S_* codes are informational, not failures, and must not be reported as
# such: 0x41300 READY, 0x41301 RUNNING, 0x41303 HAS_NOT_RUN. 0x41306 TERMINATED
# deliberately falls through to 'warn' — that is ExecutionTimeLimit being hit,
# which is worth seeing but is not a broken registration.
function Get-DotMaintTaskHealth {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [bool]$Registered,
        # Actions[0].Execute, already env-expanded by the caller.
        [string]$Execute = '',
        [bool]$ExecuteExists,
        # Get-ScheduledTaskInfo().LastTaskResult, or $null when it is not known.
        $LastResult = $null,
        # The junction task only exists if maint-install was run elevated, so its
        # absence is a state to explain rather than a fault to report.
        [bool]$Optional,
        # Whether the CALLER could have seen an Optional task at all. Task Scheduler
        # ACLs a SYSTEM-principal registration to SYSTEM + BUILTIN\Administrators —
        # the interactive user has no read entry — so from an unelevated shell
        # Get-ScheduledTask returns nothing whether that task is missing, broken, or
        # perfectly healthy. Reporting "not installed" there is a confident lie, so
        # the unelevated case gets its own status instead of a fault.
        [bool]$Elevated = $true
    )

    $informational = @(0, 0x41300, 0x41301, 0x41303)
    $elevatedHint  = 're-run maint-install' + $(if ($Optional) { ' from an elevated shell' } else { '' })
    $status = 'ok'; $detail = ''; $hint = ''

    if (-not $Registered -and $Optional -and -not $Elevated) {
        $status = 'unknown'
        $detail = 'not visible from an unelevated shell (it runs as SYSTEM)'
        $hint   = 'run `admin`, then maint-status, to see whether it is installed and healthy'
    }
    elseif (-not $Registered) {
        $status = 'missing'
        $detail = 'not installed'
        $hint   = if ($Optional) { 're-run maint-install from an elevated shell' } else { 'run maint-install' }
    }
    elseif (-not $Execute) {
        $status = 'fail'
        $detail = 'the task has no action executable'
        $hint   = 're-run maint-install'
    }
    elseif (-not $ExecuteExists) {
        $status = 'fail'
        $detail = "its executable is GONE ($Execute) — every run fails with 0x80070002 (ERROR_FILE_NOT_FOUND)"
        $hint   = $elevatedHint
    }
    elseif ($null -eq $LastResult) {
        $detail = 'registered, executable present (no run recorded yet)'
    }
    elseif ([int64]$LastResult -eq 0x80070002) {
        $status = 'fail'
        $detail = "its last run could not launch $Execute (0x80070002)"
        $hint   = $elevatedHint
    }
    elseif ([int64]$LastResult -in $informational) {
        $detail = 'ok (last result 0x{0:X})' -f [int64]$LastResult
    }
    else {
        $status = 'warn'
        $detail = 'its last run returned 0x{0:X}' -f [int64]$LastResult
        $hint   = 'maint-log 50 — if the log shows nothing for that run, the task never launched'
    }

    return [pscustomobject]@{
        Task   = $TaskName
        Status = $status
        Detail = $detail
        Hint   = $hint
    }
}
