# ============================================================================
#  os/31-wsl-bridge.ps1  -  the seam between the host and your WSL distros
#
#  Your Linux dotfiles (Core / Kali) live INSIDE WSL and configure
#  themselves there. This file is the host-side glue: jump into a distro,
#  cross the filesystem boundary cleanly, and surface the host IP (handy when
#  a service in WSL needs to be reachable from the host LAN - see
#  wsl/windows.wslconfig.example for mirrored networking).
#
#  The pure path translation (ConvertTo-WslPath) now lives in the Dotfiles module
#  (powershell/Dotfiles/Wsl.Helpers.ps1), imported by the profile BEFORE this
#  fragment, so it stays available and unit-tested even on a host without wsl.
#  The wsl-dependent verbs below call it via that module export.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: kali, wsls, wslip, cdwsl, hostip, wslhome, wsl-restart
# requires: ConvertTo-WslPath, Select-DotHostAddress, Test-Cmd, Write-DotHost

if (-not (Test-Cmd wsl)) { return }

# --- distro shortcuts ---------------------------------------------------------
function kali   { wsl -d kali-linux @args }
function wsls   { wsl --list --verbose }       # status of all distros
function wslip  { wsl -d kali-linux -- hostname -I }   # the distro's IP(s)

# --- drop into a distro at the *current* Windows directory --------------------
# `cdwsl` translates C:\path -> /mnt/c/path (via ConvertTo-WslPath) and starts a
# shell there; a non-drive CWD just opens the distro at its default location.
function cdwsl {
    param([string]$Distro = 'kali-linux')
    # ConvertTo-WslPath comes from the Dotfiles module. If a degraded load left it
    # unavailable (module import failed), fall back to opening the distro at its
    # default location instead of throwing — same path as a non-drive CWD.
    $wslPath = if (Get-Command ConvertTo-WslPath -ErrorAction SilentlyContinue) {
        ConvertTo-WslPath (Get-Location).Path
    }
    if ($wslPath) { wsl -d $Distro --cd $wslPath }
    else          { wsl -d $Distro }
}

# --- host primary IPv4 --------------------------------------------------------
# With networkingMode=mirrored, the host and WSL share interfaces, so the
# host's LAN IP is the address other machines use to reach a service running
# in WSL. This surfaces it fast.
#
# The two OS reads live here; the CHOICE is Select-DotHostAddress in the module,
# because picking right is not obvious: a box with a Hyper-V or WSL virtual
# switch also reports a Manual 172.x address on `vEthernet (Default Switch)`
# that no other machine can reach, and taking the first address hands you that
# one. The default route is what tells them apart - see the helper.
function hostip {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -ExpandProperty InterfaceIndex)
    $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -in 'Dhcp','Manual' })
    Select-DotHostAddress -Candidate $addrs -DefaultRouteInterface $routes
}

# --- open the current Windows folder inside WSL's $HOME quickly ---------------
function wslhome { wsl -d kali-linux --cd '~' }

# --- restart the WSL subsystem (clears stuck mounts / network) ----------------
function wsl-restart { wsl --shutdown; Write-DotHost 'WSL shut down; next `wsl` call cold-starts it.' -Color Yellow }
