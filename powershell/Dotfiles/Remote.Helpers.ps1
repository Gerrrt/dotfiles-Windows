# ============================================================================
#  Remote.Helpers.ps1  -  pure logic for reaching this host, and the distros
#  behind it, over ssh. Owned by the Dotfiles module.
#
#  Everything here is pure — no service probing, no registry writes, no firewall
#  rules. The host-touching half of "set up remote access" is deliberately NOT in
#  this repo: it is machine-global state (services, HKLM, firewall, scheduled
#  tasks, power settings) that varies per box and is far better done by hand,
#  with eyes on it, than by a script that assumes a stock install. See
#  docs/REMOTE-ACCESS.md for the runbook.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: ConvertTo-DotSshAlias, Get-DotWslSshPlan, Format-DotWslSshConfig, Get-DotRemoteWiringResult, Get-DotScoopJunctionPlan
# requires: New-DoctorResult

# --- ConvertTo-DotSshAlias ----------------------------------------------------
# A WSL distro name is free-form ("Ubuntu-24.04", "kali-linux", "openSUSE-Tumbleweed");
# an ssh_config Host alias you type every day should be lower-case and free of
# dots (a dot reads as a hostname and makes `Host` patterns surprising). Collapse
# runs of separators so "Ubuntu--24.04" and "Ubuntu-24.04" don't become two
# different aliases for the same box.
function ConvertTo-DotSshAlias {
    [OutputType([string])]
    param([string]$Name)
    if (-not $Name) { return '' }
    return ($Name.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

# --- Get-DotWslSshPlan --------------------------------------------------------
# Map each distro to its own port, so every distro is reachable at a fixed address
# instead of fighting for one.
#
# The names are sorted ORDINALLY first, on purpose: `wsl --list` orders by
# install/default order, which changes when you install, unregister, or re-set the
# default distro. A port that moves is worse than no port at all — it is baked into
# ssh/config, the host firewall, and muscle memory — so the map has to depend on the
# NAME SET only, never on the order WSL happened to report. (Adding a distro that
# sorts early still shifts the ones after it; that is unavoidable without a stored
# map, and is why -Pinned exists.)
#
# -HostPort reserves whatever port the WINDOWS sshd is on so the allocator can never
# hand it to a distro. It is a parameter rather than a hardcoded 22 because a host
# that moved its sshd off 22 is common, and assuming 22 there produces a "port
# collision" diagnosis that is simply wrong — check `Port` in sshd_config first.
function Get-DotWslSshPlan {
    [OutputType([pscustomobject])]
    param(
        [string[]]$Distro = @(),
        [int]$BasePort = 2222,
        [int]$HostPort = 22,
        [string]$User,
        # Already-assigned distro->port pairs to honour verbatim (a hashtable of
        # name = port). Anything listed here keeps its port and is skipped by the
        # allocator, so an established map survives a new distro appearing.
        [hashtable]$Pinned = @{}
    )
    $rows  = [System.Collections.Generic.List[object]]::new()
    $names = @($Distro | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } |
        Sort-Object -Unique)

    # Ports already spoken for — by a pin, or by the Windows sshd — can't be handed out.
    $taken = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($k in $Pinned.Keys) { [void]$taken.Add([int]$Pinned[$k]) }
    [void]$taken.Add($HostPort)

    $next = $BasePort
    foreach ($name in $names) {
        $port = $null
        foreach ($k in $Pinned.Keys) {
            if ($k -and $k.ToString().Trim() -ieq $name) { $port = [int]$Pinned[$k]; break }
        }
        if ($null -eq $port) {
            while ($taken.Contains($next)) { $next++ }
            $port = $next
            [void]$taken.Add($port)
        }
        $rows.Add([pscustomobject]@{
            Distro = $name
            Alias  = ConvertTo-DotSshAlias $name
            Port   = $port
            User   = $User
        })
    }
    return $rows.ToArray()
}

# --- Format-DotWslSshConfig ---------------------------------------------------
# Render the plan as an ssh_config fragment for the CLIENT (laptop, phone, another
# box) — not for the Windows host.
#
# Two shapes, because the two reachability stories are different:
#   -Jump <alias>  the distro ports stay bound to the host's loopback and you reach
#                  them THROUGH the Windows sshd (one port open to the LAN, which is
#                  the shape to prefer from outside the house).
#   default        the distro ports are reachable directly at the host address
#                  (mirrored networking + a firewall rule per port).
function Format-DotWslSshConfig {
    [OutputType([string])]
    param(
        [object[]]$Plan = @(),
        [Parameter(Mandatory)][string]$HostName,
        [string]$Jump
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# --- WSL distros on the Windows host (generated by wsl-ssh-config) ---')
    foreach ($row in $Plan) {
        $lines.Add('')
        $lines.Add("Host $($row.Alias)")
        if ($Jump) {
            # Through the host: the distro port is dialled from the HOST's point of
            # view, so it is loopback there — and it never has to face the LAN.
            $lines.Add('    HostName 127.0.0.1')
            $lines.Add("    ProxyJump $Jump")
        } else {
            $lines.Add("    HostName $HostName")
        }
        $lines.Add("    Port $($row.Port)")
        if ($row.User) { $lines.Add("    User $($row.User)") }
    }
    return ($lines -join "`n")
}

# --- Get-DotRemoteWiringResult ------------------------------------------------
# Will this config actually resolve in an ssh session? Pure classifier: the caller
# does the two filesystem/OS reads (is the wired path a reparse point, and is
# Redirection Guard enforced here) and this decides what that MEANS, so the whole
# triage is unit-tested without needing an ssh session or a mitigation to poke at.
#
# The rule, from docs/REMOTE-ACCESS.md: under Redirection Guard a reparse point
# into a non-admin-owned tree cannot be traversed, and the policy is inherited and
# non-relaxable. So a reparse point is a problem EXACTLY when enforcement is on —
# and a Kind='Stub' row that is still a symlink is a latent problem even on a box
# where nothing enforces it yet, because the day OpenSSH Server lands it breaks.
function Get-DotRemoteWiringResult {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        # 'Stub' | 'Symlink' — the plan's intent for this row.
        [Parameter(Mandatory)][string]$Kind,
        # Is what's actually on disk a reparse point (symlink/junction)?
        [bool]$IsReparsePoint,
        # Is ProcessRedirectionTrustPolicy enforced in the session being judged?
        [bool]$Enforced,
        # Does the wired path exist at all?
        [bool]$Exists = $true
    )
    $label = "remote: $Name"
    if (-not $Exists) {
        return (New-DoctorResult $label 'warn' 'not wired' 'run install.ps1 -SkipPackages')
    }
    if (-not $IsReparsePoint) {
        # A real file or directory — a stub, a forwarder directory, or the user's own
        # config. Either way nothing has to be traversed, so an ssh session reads it.
        $shape = if ($Kind -eq 'StubDir') { 'real directory' } else { 'real file' }
        return (New-DoctorResult $label 'ok' "$shape — resolves over ssh")
    }
    if ($Kind -in 'Stub', 'StubDir') {
        # Planned as a stub but still a symlink: install.ps1 has not been re-run since
        # the plan changed. Broken now if enforced, and broken later if not.
        $detail = if ($Enforced) { 'symlinked — will not resolve over ssh' }
                  else           { 'symlinked — will break once OpenSSH Server is installed' }
        return (New-DoctorResult $label 'warn' $detail 're-run install.ps1 -SkipPackages')
    }
    # A symlink row, honestly reported: fine interactively, unreadable over ssh, and
    # there is no stub form for it (see Get-DotfilesStubContent).
    if ($Enforced) {
        return (New-DoctorResult $label 'warn' 'symlink — interactive only, not readable over ssh' 'see docs/REMOTE-ACCESS.md')
    }
    return (New-DoctorResult $label 'ok' 'symlink')
}

# --- Get-DotScoopJunctionPlan -------------------------------------------------
# Which of scoop's reparse points have to be re-created from an elevated process
# so an ssh session can traverse them.
#
# The mechanism is in the header of this file's sibling doc, docs/REMOTE-ACCESS.md:
# NTFS stamps a trust level onto a junction AT CREATION from the creator's token,
# so a junction scoop made as you is untrusted under Redirection Guard and no
# amount of re-owning changes that. Re-creating it elevated is the only lever.
#
# The part worth being careful about is SCOPE. `apps\<app>\current` is the obvious
# junction, but scoop also wires persisted state back OUT of an app dir with more
# junctions into `scoop\persist\<app>\...` (bat\themes, btop-lhm\themes,
# composer\cache, php\cli, syncthing\config), and `scoop\modules\gsudoModule`
# points into `apps\gsudo\current` from outside apps\ entirely. Those were created
# by the same non-admin scoop process and are untrusted for the same reason, so
# fixing only `current` leaves `bat --list-themes` still broken over ssh.
#
# Same split as the rest of this file: the caller does the filesystem walk and the
# elevation probe, and this decides what those reads MEAN — so the policy is unit
# tested without a scoop install, an ssh session or an admin token.
function Get-DotScoopJunctionPlan {
    [OutputType([pscustomobject])]
    param(
        # One row per reparse point found by the caller's walk:
        #   @{ Link = <path>; Target = <path>; LinkType = 'Junction'|'SymbolicLink'|'HardLink'|$null }
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidate,
        # Re-creating as a non-admin would just re-stamp the link untrusted, so
        # without a token there is nothing useful to do.
        [bool]$IsElevated
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Candidate) {
        $linkType = [string]$c.LinkType
        # Junctions only, matching what scoop actually creates. A HardLink is not a
        # reparse point at all; a plain directory (scoop's own app dir) has no link
        # to re-stamp; and a SymbolicLink is deliberately left alone — re-making one
        # is a different operation (mklink /D) with different semantics.
        if ($linkType -ne 'Junction') {
            $action = 'skip-not-junction'; $reason = "not a junction (LinkType '$linkType')"
        }
        elseif (-not $c.Target) {
            $action = 'skip-unresolved'; $reason = 'target could not be resolved'
        }
        elseif (-not $IsElevated) {
            $action = 'blocked-not-elevated'; $reason = 'needs an elevated token to re-create as trusted'
        }
        else {
            $action = 'recreate'; $reason = 'untrusted junction — re-create elevated'
        }

        $rows.Add([pscustomobject]@{
            Link     = [string]$c.Link
            Target   = [string]$c.Target
            LinkType = $linkType
            Action   = $action
            Reason   = $reason
        })
    }

    $count = { param($a) @($rows | Where-Object { $_.Action -eq $a }).Count }
    return [pscustomobject]@{
        Rows        = $rows.ToArray()
        Total       = $rows.Count
        ToRecreate  = (& $count 'recreate')
        NotJunction = (& $count 'skip-not-junction')
        Unresolved  = (& $count 'skip-unresolved')
        Blocked     = (& $count 'blocked-not-elevated')
    }
}
