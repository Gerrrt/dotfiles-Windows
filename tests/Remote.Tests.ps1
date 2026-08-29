# ============================================================================
#  tests/Remote.Tests.ps1  -  pure remote-access logic (Remote.Helpers.ps1).
#
#  The host side - the sshd service, the registry, the firewall, the scheduled
#  task - is deliberately not exercised, and deliberately not in this repo: it is
#  machine-global state that varies per box. See docs/REMOTE-ACCESS.md.
#
#  What IS exercised is the part that decides whether you can reach anything: the
#  distro port map, the ssh_config it renders, and the triage that says whether a
#  wired config will survive an ssh session under Redirection Guard.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Module = Import-Module (Join-Path $RepoRoot 'powershell/Dotfiles/Dotfiles.psd1') -Force -DisableNameChecking -PassThru
}
AfterAll { if ($script:Module) { Remove-Module $script:Module -Force -ErrorAction SilentlyContinue } }

Describe 'ConvertTo-DotSshAlias' {
    It 'slugs a distro name into something typeable' {
        ConvertTo-DotSshAlias 'Ubuntu-24.04'        | Should -Be 'ubuntu-24-04'
        ConvertTo-DotSshAlias 'openSUSE-Tumbleweed' | Should -Be 'opensuse-tumbleweed'
        ConvertTo-DotSshAlias 'kali-linux'          | Should -Be 'kali-linux'
    }
    It 'collapses separator runs so two spellings do not become two aliases' {
        ConvertTo-DotSshAlias 'Ubuntu--24.04' | Should -Be (ConvertTo-DotSshAlias 'Ubuntu-24.04')
    }
    It 'returns empty for nothing' {
        ConvertTo-DotSshAlias ''    | Should -Be ''
        ConvertTo-DotSshAlias $null | Should -Be ''
    }
}

Describe 'Get-DotWslSshPlan' {
    It 'gives each distro a distinct port' {
        $plan = Get-DotWslSshPlan -Distro @('a', 'b', 'c')
        @($plan.Port | Sort-Object -Unique).Count | Should -Be 3
    }
    It 'is stable against the order wsl --list happens to report' {
        # `wsl --list` orders by install/default order, which moves when you install,
        # unregister, or re-set the default. A port that moves is worse than no port.
        $one = Get-DotWslSshPlan -Distro @('kali-linux', 'Alpine', 'archlinux')
        $two = Get-DotWslSshPlan -Distro @('archlinux', 'kali-linux', 'Alpine')
        ($one | ForEach-Object { "$($_.Distro)=$($_.Port)" }) -join ';' |
            Should -Be (($two | ForEach-Object { "$($_.Distro)=$($_.Port)" }) -join ';')
    }
    It 'never hands out the port the Windows sshd is on' {
        (Get-DotWslSshPlan -Distro @('a') -BasePort 22 -HostPort 22).Port | Should -Not -Be 22
    }
    It 'reserves a NON-22 host port too - assuming 22 is how you get a wrong diagnosis' {
        # A host that moved sshd off 22 is common; the allocator has to reserve the
        # port that is actually in use, not the one the docs assume.
        (Get-DotWslSshPlan -Distro @('a') -BasePort 2220 -HostPort 2220).Port | Should -Not -Be 2220
    }
    It 'honours a pinned port and allocates around it' {
        $plan = Get-DotWslSshPlan -Distro @('a', 'b') -BasePort 2222 -Pinned @{ b = 2222 }
        ($plan | Where-Object Distro -eq 'b').Port | Should -Be 2222
        ($plan | Where-Object Distro -eq 'a').Port | Should -Not -Be 2222
    }
    It 'de-duplicates and ignores blank names' {
        $plan = Get-DotWslSshPlan -Distro @('a', 'a', '', '  ', 'b')
        @($plan).Count | Should -Be 2
    }
    It 'carries the user through when one is given, and returns nothing for no distros' {
        (Get-DotWslSshPlan -Distro @('a') -User 'me').User | Should -Be 'me'
        @(Get-DotWslSshPlan -Distro @()).Count | Should -Be 0
    }
}

Describe 'Format-DotWslSshConfig' {
    BeforeAll { $script:Plan = Get-DotWslSshPlan -Distro @('kali-linux') -BasePort 2222 -User 'me' }

    It 'dials the host address directly when there is no jump host' {
        $out = Format-DotWslSshConfig -Plan $script:Plan -HostName '192.168.1.50'
        $out | Should -Match 'HostName 192\.168\.1\.50'
        $out | Should -Not -Match 'ProxyJump'
    }
    It 'routes through the host - on ITS loopback - when a jump host is given' {
        # The distro port is dialled from the HOST's point of view, so 127.0.0.1 is
        # correct here and the host address would be wrong.
        $out = Format-DotWslSshConfig -Plan $script:Plan -HostName '192.168.1.50' -Jump 'winbox'
        $out | Should -Match 'HostName 127\.0\.0\.1'
        $out | Should -Match 'ProxyJump winbox'
    }
    It 'emits the mapped port and the user' {
        $out = Format-DotWslSshConfig -Plan $script:Plan -HostName 'h'
        $out | Should -Match 'Port 2222'
        $out | Should -Match 'User me'
    }
    It 'omits User when none was planned' {
        $out = Format-DotWslSshConfig -Plan (Get-DotWslSshPlan -Distro @('a')) -HostName 'h'
        $out | Should -Not -Match 'User '
    }
}

Describe 'Get-DotRemoteWiringResult' {
    It 'passes a real file - nothing has to be traversed' {
        foreach ($enforced in $true, $false) {
            (Get-DotRemoteWiringResult -Name '.gitconfig' -Kind 'Stub' -IsReparsePoint $false -Enforced $enforced).Status |
                Should -Be 'ok'
        }
    }
    It 'flags a stub row still wired as a symlink, enforced or not' {
        # Broken now if enforced; broken the day OpenSSH Server lands if not. Either
        # way the fix is the same, so it must not read as healthy.
        $on  = Get-DotRemoteWiringResult -Name '.gitconfig' -Kind 'Stub' -IsReparsePoint $true -Enforced $true
        $off = Get-DotRemoteWiringResult -Name '.gitconfig' -Kind 'Stub' -IsReparsePoint $true -Enforced $false
        $on.Status  | Should -Be 'warn'
        $off.Status | Should -Be 'warn'
        $on.Detail  | Should -Match 'will not resolve over ssh'
        $off.Detail | Should -Match 'will break once OpenSSH Server is installed'
        $on.Hint    | Should -Match 'install\.ps1'
    }
    It 'calls a plain symlink fine interactively and unreadable over ssh' {
        (Get-DotRemoteWiringResult -Name 'nvim config' -Kind 'Symlink' -IsReparsePoint $true -Enforced $false).Status |
            Should -Be 'ok'
        $enforced = Get-DotRemoteWiringResult -Name 'nvim config' -Kind 'Symlink' -IsReparsePoint $true -Enforced $true
        $enforced.Status | Should -Be 'warn'
        $enforced.Detail | Should -Match 'not readable over ssh'
    }
    It 'reports a missing path as not wired, before judging anything else' {
        $r = Get-DotRemoteWiringResult -Name 'ssh config' -Kind 'Stub' -IsReparsePoint $true -Enforced $true -Exists $false
        $r.Status | Should -Be 'warn'
        $r.Detail | Should -Be 'not wired'
    }
    It 'is a doctor result, so the report renders it like every other row' {
        $r = Get-DotRemoteWiringResult -Name 'x' -Kind 'Stub' -IsReparsePoint $false -Enforced $true
        $r.PSObject.Properties.Name | Should -Contain 'Name'
        $r.PSObject.Properties.Name | Should -Contain 'Status'
        $r.PSObject.Properties.Name | Should -Contain 'Detail'
        $r.Name | Should -Be 'remote: x'
    }
}
