# ============================================================================
#  os/34-remote.ps1  -  the client-side ssh_config for the distros behind this host.
#
#  The host-side twin of 31-wsl-bridge: that fragment is for reaching a distro
#  from a shell you already have on this box, this one is for the machine coming
#  IN over ssh, which needs a Host entry per distro and a port that does not move.
#
#    wsl-ssh-config           the ssh_config block for every installed distro
#
#  It PRINTS and never writes. The output belongs in the ~/.ssh/config of the
#  machine you ssh FROM, which by definition is not this one — so writing it
#  here would put it on the wrong box.
#
#  Deliberately NOT here: standing sshd up. Enabling the service, the firewall
#  rules, the HKLM DefaultShell key, the boot task and the power settings are
#  machine-global state that varies per box, so they are a runbook
#  (docs/REMOTE-ACCESS.md) rather than something this repo does to your machine.
#  The omission is a decision, not a gap waiting to be filled.
#
#  Layer boundary: everything here is HOST side. Enabling sshd inside a distro,
#  and the port it listens on, belong to that distro's own repo (dotfiles-Debian
#  for the Kali/Debian/Ubuntu family) — this fragment only decides which host
#  port each distro answers on, and gets out of the way.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: Get-WslDistroNames, wsl-ssh-config
# requires: Format-DotWslSshConfig, Get-DotWslSshPlan, Test-Cmd, Write-DotErr, Write-DotHost, hostip

# --- the installed distros ----------------------------------------------------
# `wsl --list --quiet` emits UTF-16LE by default, which lands in PowerShell as a
# string with a NUL between every character — the single most common reason a
# script that shells out to wsl "sees" no distros. WSL_UTF8=1 makes it emit UTF-8
# (recent WSL builds); the NUL strip is the belt for the ones that don't honour
# it. Set on the CHILD only, so nothing else in the session inherits it, and
# restored in finally — including the unset case, which must be REMOVED rather
# than set to empty or the next caller inherits a variable that was never there.
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

# --- the client-side ssh_config block -----------------------------------------
# Print the Host entries for every installed distro, for pasting into the
# ~/.ssh/config of the machine you ssh FROM. -JumpHost routes them through the
# Windows host's own sshd instead of exposing a LAN port per distro, which is the
# shape to prefer for anything reachable from outside the house.
function wsl-ssh-config {
    param(
        [string]$JumpHost,
        [int]$BasePort = 2222,
        # The port the WINDOWS sshd answers on. Passed through so the allocator can
        # refuse to hand that port to a distro: a host that moved sshd off 22 is
        # common, and assuming 22 hands out a collision the plan cannot see.
        [int]$HostPort = 22,
        [string]$User
    )
    $names = Get-WslDistroNames
    if (-not $names.Count) { Write-DotErr 'no WSL distros found' 'wsl --list --verbose'; return }

    $plan = Get-DotWslSshPlan -Distro $names -BasePort $BasePort -HostPort $HostPort -User $User
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
