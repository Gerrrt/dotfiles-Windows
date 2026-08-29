# ============================================================================
#  Wsl.Helpers.ps1  -  pure WSL path logic, owned by the Dotfiles module (B7).
#
#  Extracted from os/31-wsl-bridge.ps1 so the pure, host-independent translation
#  lives in the module (exported, unit-tested) instead of as a global: function.
#  The wsl-DEPENDENT command verbs (kali/cdwsl/...) stay in the fragment,
#  behind its `Test-Cmd wsl` guard, and call this via the module export.
# ============================================================================

# --- ConvertTo-WslPath --------------------------------------------------------
# Translate a Windows path to its /mnt form: C:\Users\me -> /mnt/c/Users/me
# (drive lower-cased, backslashes normalized). Accepts forward- or back-slash
# separators; returns $null for anything that isn't a drive-letter path (UNC, or
# an already-translated /mnt path) so callers can fall back.
function ConvertTo-WslPath {
    [OutputType([string])]
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLower()
        $rest  = $Matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    return $null
}

# --- Select-DotHostAddress ----------------------------------------------------
# Pick the host's LAN IPv4 — the address ANOTHER machine dials — out of the set
# Windows reports. Pure: the caller does the two OS reads and this decides, so
# the choice is unit-tested without a network stack to arrange.
#
# The naive "first non-link-local address" is wrong on any box with a Hyper-V or
# WSL virtual switch: `vEthernet (Default Switch)` holds a Manual 172.x address
# that no client on the LAN can reach, and nothing about the address itself says
# so. What distinguishes the real one is the ROUTING TABLE — the LAN interface
# is the one carrying a default route, and a virtual switch has none. So prefer
# a candidate on a default-route interface, honouring the order the caller
# ranked them in (lowest metric first).
#
# Without a default route at all (an offline box) there is no better signal, so
# fall back to the old SkipAsSource ordering rather than returning nothing.
function Select-DotHostAddress {
    [OutputType([string])]
    param(
        # Rows as Get-NetIPAddress returns them: IPAddress, InterfaceIndex, SkipAsSource.
        [object[]]$Candidate = @(),
        # InterfaceIndex values carrying a default route, best first.
        [int[]]$DefaultRouteInterface = @()
    )
    $rows = @($Candidate | Where-Object { $_ -and $_.IPAddress -and $_.IPAddress -notlike '169.254.*' })
    if (-not $rows.Count) { return $null }

    foreach ($idx in $DefaultRouteInterface) {
        $hit = $rows | Where-Object { $_.InterfaceIndex -eq $idx } | Select-Object -First 1
        if ($hit) { return [string]$hit.IPAddress }
    }
    return [string](($rows | Sort-Object SkipAsSource | Select-Object -First 1).IPAddress)
}
