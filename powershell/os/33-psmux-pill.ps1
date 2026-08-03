# ============================================================================
#  os/33-psmux-pill.ps1  -  the psmux status pills: operator/VPN + power
#
#  The status bar must never spawn pwsh on its render path — psmux expands
#  status-right SYNCHRONOUSLY while building each client's state push, so a cold
#  pwsh `#()` stalls the first paint (that was the "blank screen, blinking cursor"
#  bug). So the pills are poked in out of band: the refreshers below push their
#  values into psmux user options (@vpn_pill / @pwr_pill and their @*_fg colours)
#  and the bar reads them as free in-process lookups. The VPN pill also still writes
#  a cache file, an artifact of the retired `#(cmd /c type ...)` transport.
#
#  TWO pills, ONE timer:
#    psmux-netinfo.ps1  VPN/LAN IP  -> @vpn_pill (status-left)
#    psmux-power.ps1    battery/AC  -> @pwr_pill (status-right, right-most)
#  The power pill is the psmux twin of Zebar's battery module — a green plug 󰚥 on a
#  desktop, a real charge glyph + % on a laptop — so the terminal bar carries the
#  battery segment the macOS tmux bar has.
#
#  The "something" is an IN-SESSION TIMER, not a Scheduled Task. A System.Timers
#  .Timer registered in the pane's own pwsh refreshes the file every 60s. Why not
#  a Scheduled Task? Registering one needs rights many machines withhold from a
#  non-elevated shell ("Access is denied"). The timer needs no elevation, runs only
#  while a psmux pane is open (exactly when the bar is visible), writes on a
#  background thread (never blocks your prompt), and dies with the shell — no
#  orphaned daemons. Multiple panes cooperate via the cache file's mtime so they
#  don't all do the work.
#
#    psmux-pill-enable [-AllNetworks]   turn it on (persists; new panes auto-start)
#    psmux-pill-disable                 turn it off and blank the VPN segment
#    psmux-pill-now [-AllNetworks]      refresh both pills once, now
#    psmux-pill-status                  refresher state + what the bar is reading
#
#  -AllNetworks also shows the plain-LAN IP (green) when no tunnel is up. Default
#  is tunnel-only: the VPN pill is invisible unless you're on a VPN, keeping the bar
#  quiet. Until you enable the refresher @vpn_pill is never poked and status-left
#  renders session-only. The power pill needs no opt-in to LOOK right — psmux.conf
#  defaults @pwr_pill to the desktop plug with `set -og` — the refresher just keeps
#  it honest on a laptop.
#
#  ⚠ Every `psmux set` here quotes its '@option' name. A bare @name is PowerShell's
#  splatting operator and vanishes from the command line, making the set a silent
#  no-op — the bug that hid the VPN pill entirely. See psmux/psmux.conf.
#
#  Loads automatically (profile.ps1 globs os/ in name order, after 32-psmux).
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: psmux-pill-now, psmux-pill-enable, psmux-pill-disable, psmux-pill-status
# requires: Test-Cmd, Test-InMux, Write-DotErr, Write-DotHost, Write-DotOk

if (-not (Test-Cmd psmux)) { return }

$script:PillCache  = Join-Path $env:LOCALAPPDATA 'dotfiles\psmux-netinfo.pill'
$script:PillSource = 'PsmuxPillRefresh'   # Register-ObjectEvent SourceIdentifier

# Pane detection (Test-InMux — "is the bar showing?") is shared from
# core/05-lib.ps1 now, so it can't drift from the psmux auto-attach guard's copy.

function script:Get-PillScript {
    param([string]$Name = 'psmux-netinfo.ps1')
    $p = if ($global:DOTFILES) { Join-Path $global:DOTFILES "psmux\scripts\$Name" } else { $null }
    if (-not $p -or -not (Test-Path $p)) {
        Write-DotErr "psmux-pill: $Name not found at $p" 're-run install.ps1 -SkipPackages to relink the psmux scripts'
        return $null
    }
    return $p
}

# psmux-pill-now — refresh both pills once, synchronously, in the foreground.
function psmux-pill-now {
    [CmdletBinding()] param([switch]$AllNetworks)
    $netScript = Get-PillScript 'psmux-netinfo.ps1'
    if ($netScript) {
        if ($AllNetworks) { & $netScript -AllNetworks | Out-Null } else { & $netScript | Out-Null }
        Write-DotHost "refreshed -> $script:PillCache" -Color DarkGray
    }
    # The power pill has no cache file — it pokes @pwr_pill straight into psmux — so a
    # missing netinfo script must not stop it from refreshing.
    $pwrScript = Get-PillScript 'psmux-power.ps1'
    if ($pwrScript) {
        & $pwrScript | Out-Null
        Write-DotHost "refreshed -> @pwr_pill" -Color DarkGray
    }
}

# Start-PillRefresher — arm the per-session timer (idempotent within a session).
function script:Start-PillRefresher {
    param([int]$IntervalSeconds = 60, [switch]$AllNetworks)
    if ($global:PsmuxPillTimer) { return }           # already armed in this pwsh
    $netScript = Get-PillScript 'psmux-netinfo.ps1'
    $pwrScript = Get-PillScript 'psmux-power.ps1'
    if (-not $netScript -and -not $pwrScript) { return }

    $steadyMs = [math]::Max(5, $IntervalSeconds) * 1000

    $timer = New-Object System.Timers.Timer
    # CRITICAL: do NOT prime synchronously here — psmux-netinfo.ps1's Get-Net*/WMI
    # calls take SECONDS, and running them at profile-load time blocked every new
    # shell/pane by that much (this fragment was ~10s of startup). Instead the
    # FIRST refresh is just an early timer tick (~2.5s) that runs on the timer's
    # background thread; the handler then settles the cadence to the steady value.
    # Net effect: arming the pill costs ~milliseconds at load; the WMI work happens
    # off the startup path.
    $timer.Interval  = 2500
    $timer.AutoReset = $true

    # The Elapsed action runs in its own runspace and only sees $Event — pass
    # everything it needs via -MessageData (no closure over this scope).
    $data = @{
        Script    = $netScript
        PwrScript = $pwrScript
        All       = [bool]$AllNetworks
        OutFile   = $script:PillCache
        MinAge    = [math]::Max(2, [int]($IntervalSeconds / 2))   # cross-pane dedup window
        SteadyMs  = $steadyMs
    }
    $null = Register-ObjectEvent -InputObject $timer -EventName Elapsed `
        -SourceIdentifier $script:PillSource -MessageData $data -Action {
            $d = $Event.MessageData
            $Sender.Interval = $d.SteadyMs    # after the quick first tick, settle to the steady cadence
            try {
                # If another pane refreshed the file very recently, skip the work. Both pills
                # share this gate (the netinfo cache mtime is the marker), so one pane does the
                # work for all of them — the power pill has no cache file of its own to time.
                if ((Test-Path $d.OutFile) -and
                    (([DateTime]::UtcNow - (Get-Item $d.OutFile).LastWriteTimeUtc).TotalSeconds -lt $d.MinAge)) { return }
                if ($d.Script) {
                    if ($d.All) { & $d.Script -AllNetworks | Out-Null } else { & $d.Script | Out-Null }
                }
                if ($d.PwrScript) { & $d.PwrScript | Out-Null }
            } catch { }
        }
    $timer.Start()
    $global:PsmuxPillTimer = $timer
}

function script:Stop-PillRefresher {
    if ($global:PsmuxPillTimer) {
        try { $global:PsmuxPillTimer.Stop(); $global:PsmuxPillTimer.Dispose() } catch { }
        $global:PsmuxPillTimer = $null
    }
    Unregister-Event -SourceIdentifier $script:PillSource -ErrorAction SilentlyContinue
}

# psmux-pill-enable — persist the opt-in (User env var, so new panes auto-start
# it at shell load) and arm it in the current session right now. No elevation.
function psmux-pill-enable {
    [CmdletBinding()] param([switch]$AllNetworks)
    [Environment]::SetEnvironmentVariable('DOTFILES_PSMUX_PILL', '1', 'User')
    $env:DOTFILES_PSMUX_PILL = '1'
    if ($AllNetworks) {
        [Environment]::SetEnvironmentVariable('DOTFILES_PSMUX_PILL_ALL', '1', 'User')
        $env:DOTFILES_PSMUX_PILL_ALL = '1'
    }
    Start-PillRefresher -AllNetworks:$AllNetworks
    Write-DotOk 'psmux pill enabled — in-session refresher (no scheduled task, no elevation)'
    Write-DotHost '  refreshes every 60s while a psmux pane is open; new panes auto-arm it.' -Color DarkGray
    if (-not (Test-InMux)) {
        Write-DotHost '  (not inside psmux now — it kicks in when you `mux`.)' -Color DarkGray
    } else {
        Write-DotHost '  the bar picks it up within one status-interval; force a repaint with prefix + r.' -Color DarkGray
    }
}

# psmux-pill-disable — stop the refresher, drop the opt-in, blank the segment.
function psmux-pill-disable {
    [Environment]::SetEnvironmentVariable('DOTFILES_PSMUX_PILL', $null, 'User')
    [Environment]::SetEnvironmentVariable('DOTFILES_PSMUX_PILL_ALL', $null, 'User')
    Remove-Item Env:DOTFILES_PSMUX_PILL, Env:DOTFILES_PSMUX_PILL_ALL -ErrorAction SilentlyContinue
    Stop-PillRefresher
    Remove-Item $script:PillCache -Force -ErrorAction SilentlyContinue
    # Clear the IP out of the bar too — stopping the timer alone would leave the last
    # poked address frozen in status-left. Unset, not '': an empty-string argument gets
    # dropped before psmux sees it and the set silently no-ops (see psmux.conf's note).
    & psmux set -gu '@vpn_pill' 2>$null
    # @pwr_pill is deliberately left alone. It carries no network or location information,
    # it's a parity segment rather than an operator indicator, and psmux.conf defaults it
    # anyway — clearing it would just punch a hole in the right side of the bar.
    Write-DotOk 'psmux pill disabled (refresher stopped in this session; cache cleared)'
    Write-DotHost '  other open panes keep their timer until they close — or run this in each.' -Color DarkGray
    Write-DotHost '  the power pill stays — it is a parity segment, not an operator indicator.' -Color DarkGray
}

function psmux-pill-status {
    $armed   = [bool]$global:PsmuxPillTimer
    $enabled = ($env:DOTFILES_PSMUX_PILL -eq '1')
    [pscustomobject]@{
        Enabled          = $enabled
        ArmedThisSession = $armed
        InsideMux        = (Test-InMux)
        AllNetworks      = ($env:DOTFILES_PSMUX_PILL_ALL -eq '1')
        Cache            = $script:PillCache
    } | Format-List
    if (Test-Path $script:PillCache) {
        $raw = [System.IO.File]::ReadAllText($script:PillCache)
        if ([string]::IsNullOrEmpty($raw)) {
            Write-DotHost 'pill cache is empty (no tunnel up; pass -AllNetworks to show LAN too)' -Color DarkGray
        } else {
            Write-DotHost "pill cache: $raw" -Color DarkGray
        }
    } else {
        Write-DotHost "no pill cache yet at $script:PillCache (run psmux-pill-enable)" -Color DarkGray
    }
    # What the BAR is actually reading, which is the thing that matters — the cache file
    # above is only an artifact of the retired #() transport. Quote the @names: bare ones
    # are splatted away by PowerShell (see psmux.conf).
    $vpn = (& psmux show -gv '@vpn_pill' 2>$null)
    $pwr = (& psmux show -gv '@pwr_pill' 2>$null)
    Write-DotHost "bar @vpn_pill: $(if ([string]::IsNullOrWhiteSpace($vpn)) { '(empty)' } else { $vpn })" -Color DarkGray
    Write-DotHost "bar @pwr_pill: $(if ([string]::IsNullOrWhiteSpace($pwr)) { '(empty)' } else { $pwr })" -Color DarkGray
}

# --- auto-arm in opted-in psmux panes -----------------------------------------
# Only inside a psmux pane (where the bar shows) and only if you've opted in.
# Env var is read at shell start, so a freshly-opened pane arms itself.
if ($env:DOTFILES_PSMUX_PILL -eq '1' -and (Test-InMux)) {
    Start-PillRefresher -AllNetworks:($env:DOTFILES_PSMUX_PILL_ALL -eq '1')
}
