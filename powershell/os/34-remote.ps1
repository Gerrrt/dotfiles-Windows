# ============================================================================
#  os/34-remote.ps1  -  control surface for remoting INTO this host.
#
#  The host-side twin of 31-wsl-bridge: that fragment is for reaching a distro
#  from a shell you already have, this one is for the case where you have no
#  shell here at all and are coming in over ssh.
#
#    remote-doctor            what an ssh session would actually get (read-only)
#    remote-setup             apply the fixes (elevates — sshd, firewall, keepalive)
#    wsl-ssh-config           the client-side ssh_config block for every distro
#    wslup                    start the distros now and hold the WSL VM up
#
#  The probing and the applying live in windows/Enable-RemoteAccess.ps1 (same
#  runner-plus-control-surface split as 40-maint.ps1 / maint/Maintenance.ps1), so
#  they are usable from a rescue shell that has no profile — which is exactly the
#  shell you have when the profile is the thing that is broken.
#
#  Layer boundary: everything here is HOST side. Enabling sshd inside a distro,
#  and the port it listens on, belong to that distro's own repo (dotfiles-Debian
#  for the Kali/Debian/Ubuntu family) — this fragment only decides which host
#  port each distro answers on and gets out of the way.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: Get-RemoteRunnerPath, Get-WslDistroNames, remote-doctor, remote-setup, wsl-ssh-config, wslup
# requires: Format-DotWslSshConfig, Get-DotWslSshPlan, Test-Cmd, Write-DotErr, Write-DotHost, Write-DotOk, hostip

$script:RemoteRunner = if ($global:DOTFILES) { Join-Path $global:DOTFILES 'windows\Enable-RemoteAccess.ps1' } else { $null }

function Get-RemoteRunnerPath {
    if (-not $script:RemoteRunner -or -not (Test-Path $script:RemoteRunner)) {
        Write-DotErr "remote: runner not found at $script:RemoteRunner" 'set DOTFILES_WIN / re-clone the repo'
        return $null
    }
    return $script:RemoteRunner
}

# --- the installed distros ----------------------------------------------------
# `wsl --list --quiet` emits UTF-16LE by default, which lands in PowerShell as a
# string with a NUL between every character — the single most common reason a
# script that shells out to wsl "sees" no distros. WSL_UTF8=1 makes it emit UTF-8
# (recent WSL builds); the NUL strip is the belt for the ones that don't honour
# it. Set on the CHILD only, so nothing else in the session inherits it.
function Get-WslDistroNames {
    if (-not (Test-Cmd wsl)) { return @() }
    $prev = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try { $raw = & wsl.exe --list --quiet 2>$null }
    catch { return @() }
    finally {
        if ($null -eq $prev) { Remove-Item Env:WSL_UTF8 -ErrorAction SilentlyContinue }
        else { $env:WSL_UTF8 = $prev }
    }
    return @($raw |
        ForEach-Object { ($_ -replace "`0", '').Trim() } |
        Where-Object { $_ })
}

function remote-doctor {
    $runner = Get-RemoteRunnerPath
    if (-not $runner) { return }
    & $runner -Check @args
}

function remote-setup {
    $runner = Get-RemoteRunnerPath
    if (-not $runner) { return }
    # -Apply touches machine-global state (a service, a firewall rule, HKLM, a
    # scheduled task), so it needs elevation. Relaunch rather than half-apply and
    # report a pile of access-denied.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { & $runner -Apply @args; return }

    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) { Write-DotErr 'remote-setup: pwsh not found on PATH' 'scoop install pwsh'; return }
    Write-DotHost 'remote-setup needs elevation — accepting the UAC prompt opens a new window.' -Color Yellow
    $psArgs = @('-NoProfile', '-File', $runner, '-Apply') + $args
    Start-Process -FilePath $pwshPath -Verb RunAs -ArgumentList $psArgs
}

# --- the client-side ssh_config block ----------------------------------------
# Print (never write) the Host entries for every installed distro, for pasting
# into the ~/.ssh/config of the machine you ssh FROM. -Jump routes them through
# the Windows host instead of exposing a port per distro to the LAN.
function wsl-ssh-config {
    param(
        [string]$JumpHost,
        [int]$BasePort = 2222,
        [string]$User
    )
    $names = Get-WslDistroNames
    if (-not $names.Count) { Write-DotErr 'no WSL distros found' 'wsl --list --verbose'; return }

    $plan = Get-DotWslSshPlan -Distro $names -BasePort $BasePort -User $User
    # Without a jump host the distro ports have to be dialled at this box's LAN
    # address; hostip comes from 31-wsl-bridge, which returns early on a host with
    # no wsl — guarded so a degraded load prints a placeholder instead of throwing.
    $addr = if ($JumpHost) { '127.0.0.1' }
            elseif (Get-Command hostip -ErrorAction SilentlyContinue) { hostip }
            else { '<host-ip>' }
    if (-not $addr) { $addr = '<host-ip>' }

    Write-DotHost (Format-DotWslSshConfig -Plan $plan -HostName $addr -Jump $JumpHost)
    Write-DotHost ''
    Write-DotHost 'Each distro must listen on its mapped port — set it in that distro''s own repo' -Color DarkGray
    Write-DotHost '(Port <n> in /etc/ssh/sshd_config, then: sudo systemctl enable --now ssh).' -Color DarkGray
}

# --- hold the WSL VM up -------------------------------------------------------
# WSL2 stops a distro once its last process exits, and the utility VM follows
# after vmIdleTimeout. That is why sshd inside a distro is only reachable while
# you happen to have a terminal open on the host: nothing is running, so nothing
# is listening. This starts each distro's ssh service now; `remote-setup` makes
# it survive a reboot (a logon task plus vmIdleTimeout=-1 in .wslconfig).
function wslup {
    param([string[]]$Distro)
    if (-not (Test-Cmd wsl)) { Write-DotErr 'wsl not found on this host'; return }
    $names = if ($Distro) { $Distro } else { Get-WslDistroNames }
    foreach ($n in $names) {
        # `service ssh start` covers both init flavours: it is present with or
        # without systemd, and is a no-op when the daemon is already up.
        & wsl.exe -d $n -u root -- /usr/sbin/service ssh start 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-DotOk "$n : sshd started" }
        else { Write-DotErr "$n : could not start sshd" 'install it in the distro: sudo apt install openssh-server' }
    }
}
