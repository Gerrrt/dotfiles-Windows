# ============================================================================
#  os/40-maint.ps1  -  control surface for the daily maintenance job.
#
#  Windows analog of Core's zsh/maint.zsh. Where the Linux/Mac fleet wires the
#  runner to systemd / launchd / cron, the Windows host uses Task Scheduler.
#  The runner itself is maint/Maintenance.ps1 (port of dotfiles-maint.sh).
#
#    maint-install [HH:MM]   register + enable the daily task (default 13:00)
#    maint-run               run it now, in the foreground
#    maint-log [N|-f]        show last N log lines (default 50), or follow (-f)
#    maint-status            when each task next runs / last result
#    maint-uninstall         remove the scheduled tasks
#
#  `StartWhenAvailable` on the task is the Windows equivalent of systemd's
#  Persistent=true / launchd's catch-up: if the machine was off at the scheduled
#  time, the task runs at the next opportunity.
#
#  TWO tasks get registered, on purpose:
#
#    dotfiles-maint                  the daily runner, UNELEVATED (RunLevel
#                                    Limited). It stays that way deliberately:
#                                    `scoop update *`, `mise upgrade` and
#                                    `winget upgrade --all` must not run as admin
#                                    (scoop discourages it; see
#                                    packages/Install-Packages.ps1).
#    dotfiles-maint-scoop-junctions  an hour later, as SYSTEM. Does nothing but
#                                    re-create scoop's junctions so an ssh session
#                                    can traverse them — which needs an elevated
#                                    token and so cannot happen in the run above.
#                                    SYSTEM rather than the interactive user
#                                    because an Interactive task only runs while
#                                    someone is logged on, and the case this fixes
#                                    is nobody being. See
#                                    maint/Repair-ScoopJunctions.ps1.
#
#  Registering an elevated task itself needs an elevated shell, so maint-install
#  run unelevated installs the daily task and says plainly that it skipped the
#  other one, rather than failing the whole command.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: Get-MaintRunnerPath, Get-PwshPath, Get-MaintJunctionRepairPath, maint-install, maint-run, maint-log, maint-status, maint-uninstall
# requires: Write-DotErr, Write-DotHost, Write-DotOk, Write-DotWarn

$script:MaintTaskName = 'dotfiles-maint'
$script:ScoopTaskName = 'dotfiles-maint-scoop-junctions'
$script:MaintScript   = if ($global:DOTFILES) { Join-Path $global:DOTFILES 'maint\Maintenance.ps1' } else { $null }
$script:ScoopScript   = if ($global:DOTFILES) { Join-Path $global:DOTFILES 'maint\Repair-ScoopJunctions.ps1' } else { $null }
$script:MaintLog      = Join-Path $env:LOCALAPPDATA 'dotfiles\maint\maint.log'
$script:FollowArgs    = @('-f', '--follow')

function Get-MaintRunnerPath {
    if (-not $script:MaintScript -or -not (Test-Path $script:MaintScript)) {
        Write-DotErr "maint: runner not found at $script:MaintScript" 'set DOTFILES_WIN / re-clone the repo'
        return $null
    }
    return $script:MaintScript
}

function Get-MaintJunctionRepairPath {
    if (-not $script:ScoopScript -or -not (Test-Path $script:ScoopScript)) {
        Write-DotErr "maint: scoop junction repair script not found at $script:ScoopScript" 'set DOTFILES_WIN / re-clone the repo'
        return $null
    }
    return $script:ScoopScript
}

function Get-PwshPath {
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) {
        Write-DotErr 'maint: pwsh (PowerShell 7) not found on PATH' 'install it: scoop install pwsh (or winget install Microsoft.PowerShell)'
        return $null
    }
    return $pwshPath
}

function maint-install {
    param([string]$When = '13:00')

    if ($When -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
        Write-DotErr "not a valid 24h time: '$When'" 'usage: maint-install [HH:MM]   e.g. maint-install 13:00'; return
    }
    $maintScript = Get-MaintRunnerPath
    if (-not $maintScript) { return }
    $pwshPath = Get-PwshPath
    if (-not $pwshPath) { return }


    $action  = New-ScheduledTaskAction -Execute $pwshPath `
                 -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $maintScript)
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]$When)
    $settings = New-ScheduledTaskSettingsSet `
                 -StartWhenAvailable `
                 -AllowStartIfOnBatteries `
                 -DontStopIfGoingOnBatteries `
                 -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    try {
        Register-ScheduledTask -TaskName $script:MaintTaskName `
            -Action $action -Trigger $trigger -Settings $settings `
            -Description 'dotfiles daily maintenance (scoop, mise, nvim, PS modules)' `
            -Force -ErrorAction Stop | Out-Null
        Write-DotOk "scheduled task '$script:MaintTaskName' installed for $When"
        Write-DotHost '  (StartWhenAvailable: catches up if the machine was off at that time)' -Color DarkGray
        Write-DotHost '  winget upgrades are OFF by default — to include them, edit the task to set' -Color DarkGray
        Write-DotHost '  the MAINT_WINGET_UPGRADE=1 environment variable, or run maint manually with it set.' -Color DarkGray
    } catch {
        Write-DotErr "maint-install failed: $_"
        return
    }

    Install-ScoopJunctionTask -When $When
}

# The elevated half, kept separate from maint-install because it can fail on its
# own terms (no admin token) without that meaning the daily task failed to install.
function script:Install-ScoopJunctionTask {
    param([string]$When)

    $scoopScript = Get-MaintJunctionRepairPath
    if (-not $scoopScript) { return }
    $pwshPath = Get-PwshPath
    if (-not $pwshPath) { return }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-DotWarn "scoop junction task '$script:ScoopTaskName' NOT registered — registering an elevated task needs an elevated shell." 'run `admin`, then re-run maint-install (the daily task above is installed and fine)'
        return
    }

    # An hour after the daily run, whose ExecutionTimeLimit is 1h — so the two
    # cannot overlap. It has to come after `scoop update *`, which is precisely what
    # re-creates the junctions untrusted. (An event trigger on the first task
    # completing would be tighter, but Microsoft-Windows-TaskScheduler/Operational
    # is disabled by default, so that subscription would simply never fire.)
    $scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
    $action = New-ScheduledTaskAction -Execute $pwshPath `
                -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ScoopRoot "{1}" -LogPath "{2}"' -f $scoopScript, $scoopRoot, $script:MaintLog)
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]$When).AddHours(1)
    $settings = New-ScheduledTaskSettingsSet `
                 -StartWhenAvailable `
                 -AllowStartIfOnBatteries `
                 -DontStopIfGoingOnBatteries `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    # SYSTEM, not the interactive user at RunLevel Highest: an Interactive task only
    # runs WHILE SOMEONE IS LOGGED ON, and this exists for the headless case. SYSTEM's
    # profile paths are not the user's, which is why -ScoopRoot and -LogPath are baked
    # into the action above, resolved here in the installing session.
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    try {
        Register-ScheduledTask -TaskName $script:ScoopTaskName `
            -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description 'dotfiles: re-create scoop junctions admin-trusted (keeps scoop usable over ssh)' `
            -Force -ErrorAction Stop | Out-Null
        Write-DotOk "scheduled task '$script:ScoopTaskName' installed for $(([datetime]$When).AddHours(1).ToString('HH:mm')) (as SYSTEM)"
        Write-DotHost '  keeps scoop tools traversable over ssh — see docs/REMOTE-ACCESS.md' -Color DarkGray
    } catch {
        Write-DotErr "registering '$script:ScoopTaskName' failed: $_"
    }
}

function maint-run {
    $maintScript = Get-MaintRunnerPath
    if (-not $maintScript) { return }
    $pwshPath = Get-PwshPath
    if (-not $pwshPath) { return }

    Write-DotHost "running $maintScript ..." -Color Cyan
    & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $maintScript
}

function maint-log {
    param($Arg = 50)

    if (-not (Test-Path $script:MaintLog)) { Write-Host "no log yet at $script:MaintLog"; return }

    if ("$Arg" -in $script:FollowArgs) {
        Write-DotHost "following $script:MaintLog  (Ctrl-C to stop)" -Color DarkGray
        try { Get-Content $script:MaintLog -Wait -Tail 20 }
        finally { Write-DotHost "`nstopped following the log." -Color DarkGray }
    } else {
        $lineCount = 0
        if (-not [int]::TryParse("$Arg", [ref]$lineCount) -or $lineCount -le 0) {
            Write-DotErr "not a positive integer: '$Arg'" 'usage: maint-log [N|-f]   e.g. maint-log 50  or  maint-log -f'
            return
        }
        Get-Content $script:MaintLog -Tail $lineCount
    }
}

function maint-status {
    $any = $false
    foreach ($name in @($script:MaintTaskName, $script:ScoopTaskName)) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if (-not $task) {
            # The scoop task is genuinely optional — it only exists if maint-install
            # was run elevated — so name the missing one and say how to get it.
            if ($name -eq $script:ScoopTaskName) {
                Write-DotHost "$name : not installed (re-run maint-install from an elevated shell)" -Color DarkYellow
            }
            continue
        }
        $any = $true
        $info = Get-ScheduledTaskInfo -TaskName $name
        [pscustomobject]@{
            Task        = $task.TaskName
            State       = $task.State
            RunAs       = $task.Principal.UserId
            RunLevel    = $task.Principal.RunLevel
            NextRunTime = $info.NextRunTime
            LastRunTime = $info.LastRunTime
            LastResult  = ('0x{0:X}' -f $info.LastTaskResult)
        } | Format-List
    }
    if (-not $any) { Write-Host "not installed (run maint-install)" }
}

function maint-uninstall {
    $removed = @()
    foreach ($name in @($script:MaintTaskName, $script:ScoopTaskName)) {
        if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) { continue }
        try {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
            $removed += $name
        } catch {
            # The SYSTEM task needs elevation to unregister; say so rather than
            # reporting a clean removal that did not happen.
            Write-DotWarn "could not remove '$name': $_" 'run `admin`, then re-run maint-uninstall'
        }
    }
    if ($removed) {
        foreach ($name in $removed) { Write-DotOk "removed scheduled task '$name'" }
    } else {
        Write-DotHost 'nothing to remove (no dotfiles-maint tasks found)' -Color DarkYellow
    }
}
