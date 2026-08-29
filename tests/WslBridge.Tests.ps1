# ============================================================================
#  tests/WslBridge.Tests.ps1  -  pure host-layer logic from os/31-wsl-bridge.ps1.
#  The wsl-dependent verbs aren't exercised; the path translation is.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    # ConvertTo-WslPath now lives in the Dotfiles module (B7); import it rather than
    # dot-sourcing the wsl-bridge fragment (whose verbs are guarded behind wsl).
    $script:Module = Import-Module (Join-Path $RepoRoot 'powershell/Dotfiles/Dotfiles.psd1') -Force -DisableNameChecking -PassThru
}
AfterAll { if ($script:Module) { Remove-Module $script:Module -Force -ErrorAction SilentlyContinue } }

Describe 'ConvertTo-WslPath' {
    It 'maps a C: path to /mnt/c' {
        ConvertTo-WslPath 'C:\Users\me\src' | Should -Be '/mnt/c/Users/me/src'
    }
    It 'lower-cases the drive letter' {
        ConvertTo-WslPath 'D:\Repo' | Should -Be '/mnt/d/Repo'
    }
    It 'handles a forward-slash drive path' {
        ConvertTo-WslPath 'E:/data/x' | Should -Be '/mnt/e/data/x'
    }
    It 'returns null for a non-drive path (UNC)' {
        ConvertTo-WslPath '\\server\share' | Should -BeNullOrEmpty
    }
    It 'returns null for an already-translated path' {
        ConvertTo-WslPath '/mnt/c/already' | Should -BeNullOrEmpty
    }
}

# --- Select-DotHostAddress ----------------------------------------------------
# The bug this exists to stop: on a box with a Hyper-V/WSL virtual switch, the
# naive pick returns a 172.x address on `vEthernet (Default Switch)` that no
# client on the LAN can reach — and it looks perfectly plausible in a printed
# ssh_config, so nothing tells you until the connection times out.
Describe 'Select-DotHostAddress' {
    BeforeAll {
        function script:Addr([string]$Ip, [int]$Index, [bool]$Skip = $false) {
            [pscustomobject]@{ IPAddress = $Ip; InterfaceIndex = $Index; SkipAsSource = $Skip }
        }
        # The real shape measured on a host with the Hyper-V default switch: the
        # virtual switch sorts first, and only the routing table says it is wrong.
        $script:Real = @(
            (Addr '172.26.80.1' 45)   # vEthernet (Default Switch) — no default route
            (Addr '10.0.50.90'  17)   # Ethernet 2 — carries the default route
        )
    }

    It 'prefers the default-route interface over a virtual switch' {
        Select-DotHostAddress -Candidate $script:Real -DefaultRouteInterface @(17) |
            Should -Be '10.0.50.90'
    }
    It 'honours the caller''s ranking when several interfaces have a default route' {
        Select-DotHostAddress -Candidate $script:Real -DefaultRouteInterface @(45, 17) |
            Should -Be '172.26.80.1'
    }
    It 'skips a routed interface that has no address of its own' {
        Select-DotHostAddress -Candidate $script:Real -DefaultRouteInterface @(99, 17) |
            Should -Be '10.0.50.90'
    }
    It 'falls back to the SkipAsSource order on an offline box with no default route' {
        Select-DotHostAddress -Candidate @((Addr '10.0.50.90' 17 $true), (Addr '192.168.1.5' 12)) |
            Should -Be '192.168.1.5'
    }
    It 'never returns a link-local address' {
        Select-DotHostAddress -Candidate @((Addr '169.254.7.7' 3), (Addr '10.0.50.90' 17)) |
            Should -Be '10.0.50.90'
        Select-DotHostAddress -Candidate @((Addr '169.254.7.7' 3)) | Should -BeNullOrEmpty
    }
    It 'returns nothing when there is nothing to pick' {
        Select-DotHostAddress -Candidate @()   | Should -BeNullOrEmpty
        Select-DotHostAddress -Candidate $null | Should -BeNullOrEmpty
    }
}
