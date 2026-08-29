# ============================================================================
#  Remote.Helpers.ps1  -  pure remote-access planning, owned by the Dotfiles
#  module.
#
#  Standing up OpenSSH Server on the host changes two things at once, and both
#  failures look like something else:
#
#   1. The Windows sshd service takes 0.0.0.0:22 at boot. Under
#      networkingMode=mirrored the distros share the host's interfaces, so a WSL
#      sshd that also wants :22 simply never binds — "ssh stopped reaching my
#      Linux boxes" is a port collision, not a WSL fault. The fix is a stable,
#      per-distro port map, which is what Get-DotWslSshPlan computes.
#   2. An SSH session is not the shell you tested from. It inherits no Process
#      -scope execution policy and no interactive-session niceties, so a profile
#      that loads fine in Windows Terminal can be refused as untrusted over ssh.
#      Get-DotProfileTrustResult encodes that triage.
#
#  Everything here is host-INDEPENDENT so it is unit-tested without an sshd, a
#  distro, or a registry (tests/Remote.Tests.ps1). The probes and the applying
#  live in windows/Enable-RemoteAccess.ps1 and os/34-remote.ps1.
# ============================================================================

# --- Get-DotWslSshPlan --------------------------------------------------------
# Map each distro to its own host port, so the Windows sshd keeps 22 and every
# distro is reachable at a fixed address instead of fighting for one.
#
# The names are sorted ORDINALLY first, on purpose: `wsl --list` orders by
# install/default order, which changes when you install, unregister, or re-set
# the default distro. A port that moves is worse than no port at all — it is
# baked into ssh/config, the host firewall, and muscle memory — so the map has
# to depend on the NAME SET only, never on the order WSL happened to report.
# (Adding a distro that sorts early still shifts the ones after it; that is
# unavoidable without a stored map, and is why -Pinned exists.)
function Get-DotWslSshPlan {
    [OutputType([pscustomobject])]
    param(
        [string[]]$Distro = @(),
        [int]$BasePort = 2222,
        [string]$User,
        # Already-assigned distro->port pairs to honour verbatim (a hashtable of
        # name = port). Anything listed here keeps its port and is skipped by the
        # allocator, so an established map survives a new distro appearing.
        [hashtable]$Pinned = @{}
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    $names = @($Distro | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } |
        Sort-Object -Unique)

    # Ports already spoken for by a pin can't be handed out again.
    $taken = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($k in $Pinned.Keys) { [void]$taken.Add([int]$Pinned[$k]) }

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
    $slug = ($Name.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    return $slug
}

# --- Format-DotWslSshConfig ---------------------------------------------------
# Render the plan as an ssh_config fragment for the CLIENT (laptop, phone, another
# box) — not for the Windows host.
#
# Two shapes, because the two reachability stories are different:
#   -Jump <alias>  the distro ports stay bound to the host's loopback and you
#                  reach them THROUGH the Windows sshd (one port open to the LAN,
#                  which is the shape to prefer from outside the house).
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

# --- Get-DotSshExecutionPolicy ------------------------------------------------
# The execution policy an SSH SESSION would get — which is not the one the shell
# you are checking from has.
#
# `Get-ExecutionPolicy` returns the EFFECTIVE policy of the caller, and Process
# scope wins over everything below it. So a terminal shortcut that launches pwsh
# with `-ExecutionPolicy Bypass` makes the check report Bypass while every ssh
# session — which inherits no Process scope — is still refused. A probe that
# reports the health of the shell it is run from is worse than no probe.
#
# So: walk the documented precedence order with Process REMOVED, and take the
# first scope that is set. All-Undefined is reported as Undefined rather than
# guessed at: the fallback default differs between Windows client and Server, and
# the remedy (set CurrentUser explicitly) is the same either way.
function Get-DotSshExecutionPolicy {
    [OutputType([string])]
    param([object[]]$ScopeList = @())
    foreach ($scope in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
        $row = @($ScopeList | Where-Object { "$($_.Scope)" -eq $scope }) | Select-Object -First 1
        if ($row -and "$($row.ExecutionPolicy)" -ne 'Undefined') { return "$($row.ExecutionPolicy)" }
    }
    return 'Undefined'
}

# --- Get-DotProfileTrustResult ------------------------------------------------
# Why won't the profile load over ssh when it loads fine in a local terminal?
#
# All four causes below produce the same user-visible symptom — a profile that
# is skipped, or a "do you want to run" prompt that an ssh session answers with
# the default "no" — so guessing between them wastes an evening. Ordered
# most-fundamental first; the caller supplies the measurements, this decides.
#
#   -ProfileExists  $false  the ssh session resolved a DIFFERENT $PROFILE than
#                           your desktop session (a different account, or a
#                           Documents redirect that only exists interactively).
#   -Policy                 Restricted/AllSigned/Undefined refuses the profile.
#                           Undefined matters especially, and is why the caller
#                           should pass Get-DotSshExecutionPolicy rather than a
#                           bare Get-ExecutionPolicy: a host that "works" only
#                           because its terminal launches with -ExecutionPolicy
#                           Bypass fails over ssh and nowhere else.
#   -HasMotw        $true   Mark-of-the-Web on the profile (arrived as a download
#                           rather than a clone) => untrusted under RemoteSigned.
#   -IsRemotePath   $true   the profile resolves through a UNC / redirected path.
#                           RemoteSigned judges by ZONE, and a \\server\share or
#                           \\wsl.localhost\ path is not the local zone, so an
#                           unsigned script there is refused however local the
#                           file feels.
function Get-DotProfileTrustResult {
    [OutputType([pscustomobject])]
    param(
        [string]$Policy = '',
        [string]$ProfilePath = '',
        [bool]$ProfileExists = $true,
        [bool]$HasMotw = $false,
        [bool]$IsRemotePath = $false
    )
    if (-not $ProfileExists) {
        return New-DoctorResult 'Profile trust (SSH)' 'fail' "no profile at $ProfilePath" `
            'the ssh session resolves a different $PROFILE than your desktop session — compare `whoami` and $PROFILE in both, then run install.ps1 -SkipPackages as THAT user'
    }
    if ($Policy -in 'Restricted', 'AllSigned', 'Undefined') {
        $detail = if ($Policy -eq 'Undefined') { 'no effective policy in the ssh session' } else { "$Policy blocks the profile" }
        return New-DoctorResult 'Profile trust (SSH)' 'fail' $detail `
            'Set-ExecutionPolicy RemoteSigned -Scope CurrentUser  (a Process-scope policy from your terminal shortcut does not reach an ssh session)'
    }
    if ($HasMotw) {
        return New-DoctorResult 'Profile trust (SSH)' 'fail' 'Mark-of-the-Web on the profile' `
            'Unblock-File $PROFILE; and unblock the repo: Get-ChildItem $env:DOTFILES_WIN -Recurse -File | Unblock-File'
    }
    if ($IsRemotePath) {
        return New-DoctorResult 'Profile trust (SSH)' 'fail' 'profile resolves through a remote/UNC path' `
            'RemoteSigned refuses unsigned scripts outside the local zone — move the repo to a local path (or point DOTFILES_WIN at one) and re-run install.ps1 -SkipPackages'
    }
    return New-DoctorResult 'Profile trust (SSH)' 'ok' "$Policy, local path, no Mark-of-the-Web"
}

# --- Get-DotSshKeyFileTarget --------------------------------------------------
# The trap that costs everyone their first hour with Windows OpenSSH: for an
# account in the local Administrators group, the stock sshd_config redirects
# AuthorizedKeysFile to a SHARED, machine-level file —
#
#     Match Group administrators
#         AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
#
# — so a key appended to ~/.ssh/authorized_keys is read by nobody and you fall
# back to a password prompt with no error anywhere. That file's ACL is enforced
# too: it must grant only Administrators and SYSTEM, or sshd ignores it.
function Get-DotSshKeyFileTarget {
    [OutputType([pscustomobject])]
    param(
        [bool]$IsAdmin,
        [string]$ProgramData = $env:ProgramData,
        [string]$UserProfile = $env:USERPROFILE
    )
    # Composed by hand rather than with Join-Path: this helper is pure and gets
    # unit-tested with literal Windows paths, and Join-Path resolves 'C:' as a
    # PSDrive — which does not exist off Windows, so the test would fail for a
    # reason that has nothing to do with the logic.
    if ($IsAdmin) {
        return [pscustomobject]@{
            Path    = ($ProgramData.TrimEnd('\', '/') + '\ssh\administrators_authorized_keys')
            IsAdmin = $true
            Note    = 'account is in Administrators — sshd reads the machine-level file, NOT ~/.ssh/authorized_keys. It must be ACL-limited to Administrators + SYSTEM or sshd ignores it.'
        }
    }
    return [pscustomobject]@{
        Path    = ($UserProfile.TrimEnd('\', '/') + '\.ssh\authorized_keys')
        IsAdmin = $false
        Note    = 'standard account — sshd reads the per-user file.'
    }
}
