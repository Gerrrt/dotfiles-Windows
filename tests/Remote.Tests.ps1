# ============================================================================
#  tests/Remote.Tests.ps1  -  remote-access logic: the pure helpers
#  (Remote.Helpers.ps1) and the thin fragment that calls them (os/34-remote.ps1).
#
#  The host side - the sshd service, the registry, the firewall, the scheduled
#  task - is deliberately not exercised, and deliberately not in this repo: it is
#  machine-global state that varies per box. See docs/REMOTE-ACCESS.md.
#
#  What IS exercised is the part that decides whether you can reach anything: the
#  distro port map, the ssh_config it renders, the triage that says whether a
#  wired config will survive an ssh session under Redirection Guard, and the one
#  impure step in front of them - reading the distro list back out of wsl.exe.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Module = Import-Module (Join-Path $RepoRoot 'powershell/Dotfiles/Dotfiles.psd1') -Force -DisableNameChecking -PassThru

    # Test-Cmd is a load-time FRAGMENT function (core/00-aliases.ps1), not a module
    # export, so it is absent in this unit context. Stub it GLOBALLY (the fragment
    # under test resolves it up the scope chain) and let each It decide the answer.
    $global:DotRemoteHasWsl = $true
    function global:Test-Cmd { param([string]$Name) [bool]$global:DotRemoteHasWsl }

    . (Join-Path $RepoRoot 'powershell/os/34-remote.ps1')
}
AfterAll {
    Remove-Item function:Get-WslDistroNames, function:wsl-ssh-config -ErrorAction SilentlyContinue
    Remove-Item function:global:Test-Cmd, function:global:wsl.exe -ErrorAction SilentlyContinue
    Remove-Variable -Name DotRemoteHasWsl, DotRemoteChildUtf8 -Scope Global -ErrorAction SilentlyContinue
    if ($script:Module) { Remove-Module $script:Module -Force -ErrorAction SilentlyContinue }
}

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

# --- the fragment: os/34-remote.ps1 -------------------------------------------
# The one impure step in the remote story is reading the distro list back out of
# wsl.exe, and it is impure in a way that has bitten before: the listing arrives
# UTF-16LE, so a naive reader "sees" no distros on a box that has several.
Describe 'Get-WslDistroNames' {
    BeforeEach {
        $global:DotRemoteHasWsl    = $true
        $global:DotRemoteWslOut    = @()
        $global:DotRemoteChildUtf8 = 'never-called'
        # PowerShell resolves a Function before an Application, so this shadows the
        # real wsl.exe for the fragment's `& wsl.exe` without touching PATH.
        function global:wsl.exe {
            $global:DotRemoteChildUtf8 = $env:WSL_UTF8
            $global:DotRemoteWslOut
        }
    }

    It 'strips the NULs a UTF-16LE listing arrives with' {
        # What the listing looks like when the UTF-8 hint is not honoured: a NUL
        # between every character. Without the strip these read as no distros.
        $global:DotRemoteWslOut = @(
            ('kali-linux'.ToCharArray()   -join "`0")
            ('Ubuntu-24.04'.ToCharArray() -join "`0")
        )
        Get-WslDistroNames | Should -Be @('kali-linux', 'Ubuntu-24.04')
    }
    It 'asks the child for UTF-8 in the first place' {
        $global:DotRemoteWslOut = @('kali-linux')
        Get-WslDistroNames | Out-Null
        $global:DotRemoteChildUtf8 | Should -Be '1'
    }
    It 'restores a pre-existing WSL_UTF8 instead of clobbering it' {
        $env:WSL_UTF8 = '0'
        try {
            $global:DotRemoteWslOut = @('kali-linux')
            Get-WslDistroNames | Out-Null
            $env:WSL_UTF8 | Should -Be '0'
        } finally { Remove-Item Env:WSL_UTF8 -ErrorAction SilentlyContinue }
    }
    It 'REMOVES WSL_UTF8 when it was unset before, rather than leaving it empty' {
        # An empty-string variable is not the same as an absent one: the next
        # caller would inherit a WSL_UTF8 that was never there.
        Remove-Item Env:WSL_UTF8 -ErrorAction SilentlyContinue
        $global:DotRemoteWslOut = @('kali-linux')
        Get-WslDistroNames | Out-Null
        (Test-Path Env:WSL_UTF8) | Should -BeFalse
    }
    It 'drops the blank and whitespace-only lines wsl pads the listing with' {
        $global:DotRemoteWslOut = @('kali-linux', '', '   ', 'Debian')
        Get-WslDistroNames | Should -Be @('kali-linux', 'Debian')
    }
    It 'yields nothing on a host with no wsl, without shelling out' {
        $global:DotRemoteHasWsl = $false
        @(Get-WslDistroNames).Count | Should -Be 0
        $global:DotRemoteChildUtf8  | Should -Be 'never-called'
    }
}

Describe 'wsl-ssh-config' {
    BeforeAll {
        # Capture what the command PRINTS. Global stubs, recording into global
        # lists, for the same scope reason Core.Tests.ps1 documents: a $script:
        # var set here resolves to a different scope inside a global function.
        $global:DotRemoteOut = [System.Collections.Generic.List[string]]::new()
        $global:DotRemoteErr = [System.Collections.Generic.List[string]]::new()
        function global:Write-DotHost {
            param([Parameter(Position = 0)][string]$Text = '', [string]$Color, [switch]$NoNewline)
            $global:DotRemoteOut.Add($Text)
        }
        function global:Write-DotErr {
            param([Parameter(Mandatory)][string]$Message, [string]$Hint, [switch]$PassThru)
            $global:DotRemoteErr.Add($Message)
        }
    }
    AfterAll {
        Remove-Item function:global:Write-DotHost, function:global:Write-DotErr -ErrorAction SilentlyContinue
        Remove-Variable -Name DotRemoteOut, DotRemoteErr -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $global:DotRemoteOut.Clear(); $global:DotRemoteErr.Clear()
        $global:DotRemoteHasWsl = $true
        $global:DotRemoteWslOut = @('kali-linux', 'Debian')
        function global:wsl.exe { $global:DotRemoteWslOut }
    }

    It 'renders a Host block per installed distro' {
        wsl-ssh-config
        $text = $global:DotRemoteOut -join "`n"
        $text | Should -Match '(?m)^Host kali-linux$'
        $text | Should -Match '(?m)^Host debian$'
    }
    It 'routes through the jump host rather than exposing a port per distro' {
        wsl-ssh-config -JumpHost winbox
        $text = $global:DotRemoteOut -join "`n"
        $text | Should -Match 'ProxyJump winbox'
        $text | Should -Match 'HostName 127\.0\.0\.1'
    }
    It 'keeps the Windows sshd off the distro map even when it moved off 22' {
        # The reason Get-DotWslSshPlan takes -HostPort at all: a host that moved
        # sshd to 2222 would otherwise be handed 2222 as a distro port, and the
        # collision is invisible until the distro silently fails to bind.
        wsl-ssh-config -BasePort 2222 -HostPort 2222
        ($global:DotRemoteOut -join "`n") | Should -Not -Match '(?m)^\s+Port 2222$'
    }
    It 'falls back to a placeholder host when hostip is unavailable' {
        # hostip lives in 31-wsl-bridge, which returns early on a host with no wsl.
        # A degraded load must print a placeholder, not throw.
        wsl-ssh-config
        ($global:DotRemoteOut -join "`n") | Should -Match 'HostName <host-ip>'
    }
    It 'reports and returns when there are no distros, instead of throwing' {
        $global:DotRemoteHasWsl = $false
        { wsl-ssh-config } | Should -Not -Throw
        $global:DotRemoteErr | Should -Contain 'no WSL distros found'
        ($global:DotRemoteOut -join "`n") | Should -Not -Match 'Host '
    }
}
