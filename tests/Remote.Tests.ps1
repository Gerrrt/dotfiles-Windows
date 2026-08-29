# ============================================================================
#  tests/Remote.Tests.ps1  -  pure remote-access planning (Remote.Helpers.ps1).
#
#  The host side — the sshd service, the registry, the firewall, the scheduled
#  task — isn't exercised: it lives in windows/Enable-RemoteAccess.ps1 and needs
#  a real box. What IS exercised is everything the two failure modes actually
#  turn on: the port map that keeps the Windows sshd and the WSL distros off
#  each other's port 22, and the triage that decides why a profile an ssh
#  session can see is nonetheless refused.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Module = Import-Module (Join-Path $RepoRoot 'powershell/Dotfiles/Dotfiles.psd1') -Force -DisableNameChecking -PassThru
}
AfterAll { if ($script:Module) { Remove-Module $script:Module -Force -ErrorAction SilentlyContinue } }

Describe 'Get-DotWslSshPlan' {
    It 'never hands out 22 — that is the Windows sshd''s' {
        $plan = Get-DotWslSshPlan -Distro @('kali-linux', 'Ubuntu-24.04', 'Debian')
        $plan.Port | Should -Not -Contain 22
        ($plan.Port | Measure-Object -Minimum).Minimum | Should -BeGreaterOrEqual 2222
    }
    It 'gives each distro a distinct port' {
        $plan = Get-DotWslSshPlan -Distro @('a', 'b', 'c', 'd')
        @($plan.Port | Sort-Object -Unique).Count | Should -Be 4
    }
    It 'is stable against the order wsl --list happens to report' {
        # The whole point: `wsl --list` reorders when you install, unregister or
        # re-default a distro, and a port that moves is baked into ssh/config,
        # firewall rules and muscle memory.
        $a = Get-DotWslSshPlan -Distro @('kali-linux', 'Debian', 'Ubuntu')
        $b = Get-DotWslSshPlan -Distro @('Ubuntu', 'kali-linux', 'Debian')
        ($a | ForEach-Object { "$($_.Distro)=$($_.Port)" }) -join ',' |
            Should -Be (($b | ForEach-Object { "$($_.Distro)=$($_.Port)" }) -join ',')
    }
    It 'honours a pinned port and allocates around it' {
        $plan = Get-DotWslSshPlan -Distro @('alpha', 'beta') -Pinned @{ beta = 2222 }
        ($plan | Where-Object Distro -eq 'beta').Port  | Should -Be 2222
        ($plan | Where-Object Distro -eq 'alpha').Port | Should -Be 2223
    }
    It 'starts at -BasePort' {
        (Get-DotWslSshPlan -Distro @('only') -BasePort 2300).Port | Should -Be 2300
    }
    It 'de-duplicates and ignores blank names' {
        $plan = Get-DotWslSshPlan -Distro @('kali', 'kali', '', '  ')
        @($plan).Count | Should -Be 1
    }
    It 'carries the user through when one is given' {
        (Get-DotWslSshPlan -Distro @('kali') -User 'operator').User | Should -Be 'operator'
    }
    It 'returns nothing for no distros' {
        @(Get-DotWslSshPlan -Distro @()).Count | Should -Be 0
    }
    It 'slugs the distro name into a typeable ssh alias' {
        (Get-DotWslSshPlan -Distro @('Ubuntu-24.04')).Alias | Should -Be 'ubuntu-24-04'
        (Get-DotWslSshPlan -Distro @('openSUSE-Tumbleweed')).Alias | Should -Be 'opensuse-tumbleweed'
    }
}

Describe 'Format-DotWslSshConfig' {
    BeforeAll { $script:Plan = Get-DotWslSshPlan -Distro @('kali-linux') -User 'gerrrt' }

    It 'dials the host address directly when there is no jump host' {
        $out = Format-DotWslSshConfig -Plan $script:Plan -HostName '192.168.1.50'
        $out | Should -Match '(?m)^Host kali-linux$'
        $out | Should -Match '(?m)^\s+HostName 192\.168\.1\.50$'
        $out | Should -Match '(?m)^\s+User gerrrt$'
        $out | Should -Not -Match 'ProxyJump'
    }
    It 'routes through the host — on ITS loopback — when a jump host is given' {
        # The distro port is dialled from the Windows host's point of view, so it
        # is loopback there and never has to face the LAN.
        $out = Format-DotWslSshConfig -Plan $script:Plan -HostName '192.168.1.50' -Jump 'winbox'
        $out | Should -Match '(?m)^\s+ProxyJump winbox$'
        $out | Should -Match '(?m)^\s+HostName 127\.0\.0\.1$'
        $out | Should -Not -Match '192\.168\.1\.50'
    }
    It 'omits User when none was planned' {
        $plan = Get-DotWslSshPlan -Distro @('kali-linux')
        (Format-DotWslSshConfig -Plan $plan -HostName '10.0.0.1') | Should -Not -Match 'User'
    }
    It 'emits the mapped port, not 22' {
        (Format-DotWslSshConfig -Plan $script:Plan -HostName '10.0.0.1') | Should -Match '(?m)^\s+Port 2222$'
    }
}

Describe 'Get-DotSshExecutionPolicy' {
    # Shaped like Get-ExecutionPolicy -List's output: one row per scope, in the
    # documented precedence order. Defined in BeforeAll, not in the Describe body:
    # the body runs at DISCOVERY, so a function declared there does not exist by
    # the time an It block runs.
    BeforeAll {
        function New-ScopeList {
            param($MachinePolicy = 'Undefined', $UserPolicy = 'Undefined', $Process = 'Undefined',
                  $CurrentUser = 'Undefined', $LocalMachine = 'Undefined')
            @(
                [pscustomobject]@{ Scope = 'MachinePolicy'; ExecutionPolicy = $MachinePolicy }
                [pscustomobject]@{ Scope = 'UserPolicy';    ExecutionPolicy = $UserPolicy }
                [pscustomobject]@{ Scope = 'Process';       ExecutionPolicy = $Process }
                [pscustomobject]@{ Scope = 'CurrentUser';   ExecutionPolicy = $CurrentUser }
                [pscustomobject]@{ Scope = 'LocalMachine';  ExecutionPolicy = $LocalMachine }
            )
        }
    }

    It 'ignores Process scope — the whole reason this helper exists' {
        # The bug it is built to catch: a terminal shortcut that passes
        # -ExecutionPolicy Bypass makes a naive probe report health that no ssh
        # session ever gets.
        Get-DotSshExecutionPolicy -ScopeList (New-ScopeList -Process 'Bypass') | Should -Be 'Undefined'
    }
    It 'reports the persistent policy an ssh session would actually see' {
        Get-DotSshExecutionPolicy -ScopeList (New-ScopeList -Process 'Bypass' -CurrentUser 'RemoteSigned') |
            Should -Be 'RemoteSigned'
    }
    It 'prefers CurrentUser over LocalMachine' {
        Get-DotSshExecutionPolicy -ScopeList (New-ScopeList -CurrentUser 'RemoteSigned' -LocalMachine 'Restricted') |
            Should -Be 'RemoteSigned'
    }
    It 'lets Group Policy win over everything below it' {
        Get-DotSshExecutionPolicy -ScopeList (New-ScopeList -MachinePolicy 'AllSigned' -CurrentUser 'Bypass') |
            Should -Be 'AllSigned'
    }
    It 'falls back to LocalMachine when nothing above it is set' {
        Get-DotSshExecutionPolicy -ScopeList (New-ScopeList -LocalMachine 'RemoteSigned') | Should -Be 'RemoteSigned'
    }
    It 'reports Undefined rather than guessing the built-in default' {
        # Client and Server default differently; the remedy (set CurrentUser) is
        # the same either way, so say what is measured.
        Get-DotSshExecutionPolicy -ScopeList (New-ScopeList) | Should -Be 'Undefined'
        Get-DotSshExecutionPolicy -ScopeList @() | Should -Be 'Undefined'
    }
    It 'feeds the trust triage — an all-Undefined box fails' {
        $policy = Get-DotSshExecutionPolicy -ScopeList (New-ScopeList -Process 'Bypass')
        (Get-DotProfileTrustResult -Policy $policy -ProfilePath 'C:\p.ps1').Status | Should -Be 'fail'
    }
}

Describe 'Get-DotProfileTrustResult' {
    It 'passes a local, unblocked profile under RemoteSigned' {
        $res = Get-DotProfileTrustResult -Policy 'RemoteSigned' -ProfilePath 'C:\Users\me\p.ps1'
        $res.Status | Should -Be 'ok'
    }
    It 'reports a missing profile as a different-account problem first' {
        # Ranked above policy on purpose: no amount of Set-ExecutionPolicy fixes a
        # session that resolved someone else's $PROFILE.
        $res = Get-DotProfileTrustResult -Policy 'Restricted' -ProfilePath 'C:\Users\other\p.ps1' -ProfileExists $false
        $res.Status | Should -Be 'fail'
        $res.Detail | Should -Match 'no profile'
    }
    It 'flags Undefined — an ssh session inherits no Process-scope policy' {
        $res = Get-DotProfileTrustResult -Policy 'Undefined' -ProfilePath 'C:\p.ps1'
        $res.Status | Should -Be 'fail'
        $res.Hint   | Should -Match 'RemoteSigned'
    }
    It 'flags <Policy> as blocking' -ForEach @(
        @{ Policy = 'Restricted' }
        @{ Policy = 'AllSigned' }
    ) {
        (Get-DotProfileTrustResult -Policy $Policy -ProfilePath 'C:\p.ps1').Status | Should -Be 'fail'
    }
    It 'flags Mark-of-the-Web with the unblock fix' {
        $res = Get-DotProfileTrustResult -Policy 'RemoteSigned' -ProfilePath 'C:\p.ps1' -HasMotw $true
        $res.Status | Should -Be 'fail'
        $res.Hint   | Should -Match 'Unblock-File'
    }
    It 'flags a UNC/redirected path — RemoteSigned judges by zone, not by feel' {
        $res = Get-DotProfileTrustResult -Policy 'RemoteSigned' -ProfilePath '\\wsl.localhost\kali\p.ps1' -IsRemotePath $true
        $res.Status | Should -Be 'fail'
        $res.Detail | Should -Match 'remote/UNC'
    }
    It 'ranks a blocking policy above Mark-of-the-Web (fix the policy first)' {
        $res = Get-DotProfileTrustResult -Policy 'Restricted' -ProfilePath 'C:\p.ps1' -HasMotw $true
        $res.Detail | Should -Match 'Restricted'
    }
    It 'is a doctor result, so the report renders it like every other row' {
        $res = Get-DotProfileTrustResult -Policy 'Bypass' -ProfilePath 'C:\p.ps1'
        $res.Name | Should -Be 'Profile trust (SSH)'
        $res.PSObject.Properties.Name | Should -Contain 'Hint'
    }
}

Describe 'Get-DotSshKeyFileTarget' {
    It 'sends an administrator to the machine-level file, not ~/.ssh' {
        # The stock sshd_config has `Match Group administrators` redirect
        # AuthorizedKeysFile, so a key in ~/.ssh/authorized_keys is read by nobody.
        $t = Get-DotSshKeyFileTarget -IsAdmin $true -ProgramData 'C:\ProgramData' -UserProfile 'C:\Users\me'
        $t.Path | Should -Be 'C:\ProgramData\ssh\administrators_authorized_keys'
        $t.Note | Should -Match 'Administrators'
    }
    It 'sends a standard account to the per-user file' {
        $t = Get-DotSshKeyFileTarget -IsAdmin $false -ProgramData 'C:\ProgramData' -UserProfile 'C:\Users\me'
        $t.Path | Should -Be 'C:\Users\me\.ssh\authorized_keys'
        $t.IsAdmin | Should -BeFalse
    }
}
