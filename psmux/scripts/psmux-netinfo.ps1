# psmux-netinfo.ps1 — the "operator" segment of the status line.
# Windows/PowerShell port of dotfiles-core/tmux/scripts/tmux-netinfo.sh, so the
# Windows box shows the same at-a-glance fact as the Unix fleet.
# ──────────────────────────────────────────────────────────────────────────────
# Shows your VPN / tunnel IP in standout ORANGE when a tunnel interface is up.
# By DEFAULT it is tunnel-only — on plain LAN it renders nothing, so the bar stays
# quiet unless you're actually on a VPN (high signal, low noise). Pass -AllNetworks
# to also show the plain-LAN IP in GREEN (the old always-on behaviour).
#
# IMPORTANT — this is NOT called from the bar via #() any more. A #() that spawns
# pwsh blocks psmux's synchronous render path (that was the blank-cursor bug). The
# bar now reads a pre-written file with a cheap `type`; this script is what writes
# that file. Run it OUT of band: `psmux-pill-enable` (powershell/os/33-psmux-pill.ps1)
# arms a per-session timer that runs this every 60s while a psmux pane is open
# (no Scheduled Task, no elevation). The styled pill is also emitted to stdout, so
# the script still works standalone.
#
# Deliberately tolerant (SilentlyContinue): a status helper must never hard-fail.
# This is the bash original's Linux `ip`/macOS `ipconfig` logic re-expressed with
# the Windows NetTCPIP cmdlets (Get-NetIPAddress / Get-NetAdapter / Find-NetRoute).
# ──────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    # Also show the plain-LAN IP (green) when no tunnel is up. Default OFF: the
    # pill is TUNNEL-ONLY, so it stays invisible unless you're actually on a VPN —
    # high signal, low noise. Pass -AllNetworks for the old always-show-LAN feel.
    [switch]$AllNetworks,
    # Where the styled pill is cached for the status bar to read with a cheap
    # `type`. Must match the path the status-right segment uses in psmux.conf.
    [string]$OutFile = (Join-Path $env:LOCALAPPDATA 'dotfiles\psmux-netinfo.pill')
)

$ErrorActionPreference = 'SilentlyContinue'

# Stashed by Pill() so the file-write at the bottom can persist the chosen pill
# without re-running detection. Empty string = "render nothing".
$script:LastPill = ''
# The pill's accent colour travels in its OWN psmux option (@vpn_fg), applied as
# #[fg=#{@vpn_fg}] in status-left — see the Pill() note for why the colour can't ride
# inside @vpn_pill. Default green; Pill() overrides it per state (orange tunnel / green LAN).
$script:LastFg = '#9ece6a'

# tokyonight-storm palette. Literal hex on purpose: psmux does not expand #{@tn_*}
# inside #[...] (whether in style options or in #() output), and BG is the bar's
# highlight bg (@tn_bg_hl = #292e42) so the pill floats on the bar like the cwd /
# clock pills in psmux.conf.
$BGHL   = '#292e42'
$BG     = '#24283b'
$ORANGE = '#ff9e64'
$GREEN  = '#9ece6a'

# left/right rounded caps (Nerd Font) — same glyphs as @cap_l / @cap_r
$CAP_L = ""
$CAP_R = ""

function Pill {
    param([string]$Accent, [string]$Text)
    # Chip-less: plain colored icon+text, no caps/background — matches the transparent
    # bar's session/cwd/clock segments (macOS sketchybar + Zebar are chip-less too).
    #
    # Store the pill as PLAIN text (glyph + address, no #[...]). It's poked into psmux as
    # `set -g @vpn_pill '<text>'`, and an option VALUE that contains a #[…] style run is NOT
    # re-interpreted when the bar expands #{@vpn_pill} — the segment renders blank. So the
    # COLOUR travels separately in @vpn_fg (applied as #[fg=#{@vpn_fg}] in status-left, the
    # same way the @tn_* palette colours are consumed), and @vpn_pill carries text only.
    $script:LastFg   = $Accent
    $script:LastPill = $Text
    $script:LastPill
}

# Adapter Name / InterfaceDescription patterns that mean "tunnel"
# (OpenVPN TAP/Wintun, WireGuard, Tailscale, Proton, Nord, generic VPN).
$TunnelPattern = 'WireGuard|Wintun|TAP-Windows|OpenVPN|Tailscale|ProtonVPN|NordLynx|NordVPN|\bVPN\b|\btun\d|\bwg\d'

# Up IPv4 addresses, minus loopback and APIPA (169.254.*).
function Get-Ipv4Up {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -and
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*'
        }
}

# Tunnel interface in priority of "first up tunnel adapter with a v4 address".
function Get-TunnelInfo {
    # Pull ALL adapters once and index by InterfaceIndex. The previous version
    # called Get-NetAdapter once PER up-IP — each is a slow CIM query, so on a box
    # with several addresses this was seconds of work. One bulk call + a hashtable
    # lookup is the bulk of the speedup that got this pill off the startup path.
    $adapters = @{}
    foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue)) { $adapters[[int]$a.InterfaceIndex] = $a }
    foreach ($ip in Get-Ipv4Up) {
        $ad = $adapters[[int]$ip.InterfaceIndex]
        if (-not $ad -or $ad.Status -ne 'Up') { continue }
        if (($ad.InterfaceDescription -match $TunnelPattern) -or ($ad.Name -match $TunnelPattern)) {
            $iface = $ad.Name
            if ($iface.Length -gt 14) { $iface = $iface.Substring(0, 14) }
            return [pscustomobject]@{ Iface = $iface; Addr = $ip.IPAddress }
        }
    }
    return $null
}

# Primary LAN IP: the source address the box would use to reach the internet
# (the Windows equivalent of `ip route get 1.1.1.1` -> src).
function Get-LanIp {
    $src = Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty IPAddress -ErrorAction SilentlyContinue |
        Where-Object { $_ -and $_ -ne '127.0.0.1' -and $_ -notlike '169.254.*' } |
        Select-Object -First 1
    if ($src) { return $src }

    # Fallback: first up adapter that has a default gateway.
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1
    if ($cfg -and $cfg.IPv4Address) { return $cfg.IPv4Address.IPAddress }
    return $null
}

$tun = Get-TunnelInfo
if ($tun) {
    Pill $ORANGE " $($tun.Iface) $($tun.Addr)"   # shield: you're tunneled
}
elseif ($AllNetworks) {
    $lan = Get-LanIp
    if ($lan) {
        Pill $GREEN "󰈀 $lan"                       # ethernet: LAN only
    }
}

# ── Persist the chosen pill so the status bar can read it cheaply ─────────────
# The whole point of the file-backed design: the bar reads this file with a ~10ms
# `cmd /C type`, never spawning pwsh (and its slow Get-Net*/WMI calls) on psmux's
# synchronous render path. Refresh it OUT of band — see powershell/os/33-psmux-pill.ps1
# (psmux-pill-enable arms a per-session timer that runs this every 60s).)
# Write UTF-8 with NO BOM and NO trailing newline so the pill is exactly the bytes
# psmux re-parses; a trailing CRLF would push a blank line into status-right.
try {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($OutFile, $script:LastPill, (New-Object System.Text.UTF8Encoding($false)))
} catch { }

# Also poke the pill straight into psmux as a user option, so the status bar can read
# it with a free in-process lookup (#{@vpn_pill} in psmux.conf's status-left) instead of
# a #(type) shell-out — the lag-safe transport the retired-pill note recommends.
# Poke the colour first, then the text: the bar reads #[fg=#{@vpn_fg}]#{@vpn_pill}, so the
# colour option should be current before the text it paints appears. Harmless if no psmux
# server is up.
#
# ⚠ THE QUOTES AROUND '@vpn_fg' / '@vpn_pill' ARE LOAD-BEARING. Do not "tidy" them
# away. In argument position a bare @name is PowerShell's SPLATTING operator, not a
# literal: `psmux set -g @vpn_pill $text` splats the (undefined) $vpn_pill and the
# token is dropped from the command line entirely, so psmux receives `set -g <text>`
# — a single positional, which its set handler silently discards (psmux/psmux#535: exit)
# code 0, nothing on stderr, option never set). That was the "pill never shows" bug: the
# detection above worked and the cache file was correct, but nothing ever reached the bar.
# The quoting stays correct regardless of #535 — that issue only asks psmux to TELL you
# when it drops a set, which would have made this a two-minute diagnosis instead of months.
#
# ⚠ Clearing needs `set -gu` (UNSET), not `set -g <opt> ''`. An empty-string argument is
# dropped on the way to the exe, so the empty form arrives as a single positional and is
# discarded by the same silent path as the splat above (psmux/psmux#535) — the previous
# pill would stay on the bar forever (a dropped tunnel kept showing its old IP). Unset
# renders as nothing, and stays correct whatever #535 decides to do about warnings.
try {
    & psmux set -g '@vpn_fg' $script:LastFg 2>$null
    if ([string]::IsNullOrEmpty($script:LastPill)) {
        & psmux set -gu '@vpn_pill' 2>$null
    } else {
        & psmux set -g '@vpn_pill' $script:LastPill 2>$null
    }
} catch { }
