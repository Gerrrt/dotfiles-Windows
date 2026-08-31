# psmux-power.ps1 — the "power" segment of the status line.
# The Windows port of dotfiles-core/tmux/scripts/tmux-battery.sh, so the Windows
# terminal bar carries the battery segment the macOS tmux bar has, drawn on the same
# scale. Rendered RIGHT-MOST in status-right, which is where Core's status-right puts
# it too (its last slot is #{@status_right_os}, the hook each OS repo fills).
# ──────────────────────────────────────────────────────────────────────────────
# On a LAPTOP this is Core's battery pill: a level glyph + percentage, coloured
# green ≥60 / yellow ≥20 / red <20, with the level glyph swapped for a charging bolt
# on AC (colour still tracks the level — that's Core's behaviour, not an oversight).
# Thresholds and glyphs are copied from tmux-battery.sh so the two terminal bars can
# never disagree about what "low" means.
#
# ONE DELIBERATE DIVERGENCE: Core prints nothing at all when there is no battery, so
# the segment vanishes on a desktop. Here it falls back to Zebar's AC placeholder — a
# lone green plug 󰚥 (desktop/zebar/vanilla-clear does the same) — because a silently
# empty segment reads as "the pill is broken again" on a desktop-first host.
#
# NB the SCALE here is Core's, not Zebar's: Zebar/sketchybar use green >40 / yellow
# 21-40 / red ≤20 with five fa-battery glyphs. The bars are matched terminal-to-
# terminal and desktop-to-desktop, which is why these two disagree between 40 and 60.
#
# IMPORTANT — like the netinfo pill, this is NOT called from the bar via #(). psmux
# expands status-right SYNCHRONOUSLY on its state-push path, so a #() that spawns
# pwsh stalls the first paint (the blank-cursor bug). The pill travels as a psmux
# user option instead: this script pokes @pwr_pill / @pwr_fg, and the bar reads them
# with a free in-process hashmap lookup. Run it OUT of band — `psmux-pill-enable`
# (powershell/os/33-psmux-pill.ps1) arms a per-session timer that runs this every
# 60s alongside psmux-netinfo.ps1. The pill TEXT is also emitted to stdout so the script
# works standalone — plain text, NOT a styled #[…] run: the colour cannot travel inside the
# value (an option value carrying a style run isn't re-interpreted on expansion), which is
# exactly why it goes in @pwr_fg instead. Read the two together to reconstruct the segment.
#
# Deliberately tolerant (SilentlyContinue): a status helper must never hard-fail.
# ──────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    # Testing seam. This box is a desktop, so the laptop branches below would otherwise
    # never execute anywhere — the pill would be "verified" only in the one state that
    # needs no logic. With -SimulateState the host's real power state is not read and
    # nothing is poked into psmux; the resolved pill is returned as an object instead, so
    # tests/Repo.Tests.ps1 can assert every glyph and colour. Never used at runtime.
    [ValidateSet('NoBattery', 'AC', 'Battery')]
    [string]$SimulateState,
    [ValidateRange(0, 100)]
    [int]$SimulatePercent = 100
)

$ErrorActionPreference = 'SilentlyContinue'

# tokyonight palette. Literal hex on purpose: psmux does not expand #{@tn_*} inside
# #[...], and the colour has to travel as a plain value in @pwr_fg anyway (see the
# poke note at the bottom). GENERATED from theme/palette.toml by gen-theme.ps1 - the
# same source Core's tmux/scripts/tmux-battery.sh renders from, so the two terminal
# bars can no longer disagree. Do not hand-edit.
# core:theme:gen power-palette
$GREEN  = '#9ece6a'   # ≥60%, and the no-battery AC placeholder
$YELLOW = '#e0af68'   # ≥20%
$RED    = '#f7768e'   # <20%
# core:theme:end power-palette

# Nerd Font glyphs — the same codepoints tmux-battery.sh emits, so the two terminal
# bars draw the identical icon. $PLUG is the one import from Zebar (nf-md-power_plug,
# the PARITY.md glyph) for the no-battery case Core doesn't draw at all.
$BATT_HI  = "$([char]::ConvertFromUtf32(0xF0081))"   # 󰂁 battery high   (≥60)
$BATT_MID = "$([char]::ConvertFromUtf32(0xF007E))"   # 󰁾 battery medium (≥20)
$BATT_LO  = "$([char]::ConvertFromUtf32(0xF007B))"   # 󰁻 battery low    (<20)
$BATT_CHG = "$([char]::ConvertFromUtf32(0xF0084))"   # 󰂄 charging bolt
$PLUG     = "$([char]::ConvertFromUtf32(0xF06A5))"   # 󰚥 nf-md-power_plug

# Resolve the pill from an already-read power state. Pure — no I/O — so the laptop
# branches are reachable from a test on a desktop (see -SimulateState).
function Resolve-PowerPill {
    param([bool]$NoBattery, [bool]$OnAc, [int]$Percent)

    # Desktop: Zebar's AC placeholder, a green plug and nothing else. (Core vanishes here.)
    if ($NoBattery) { return [pscustomobject]@{ Text = $PLUG; Fg = $GREEN } }

    # Colour AND glyph by level, exactly as tmux-battery.sh does it...
    $pair = if ($Percent -ge 60)    { @{ Fg = $GREEN;  Glyph = $BATT_HI } }
            elseif ($Percent -ge 20) { @{ Fg = $YELLOW; Glyph = $BATT_MID } }
            else                     { @{ Fg = $RED;    Glyph = $BATT_LO } }

    # ...then charging REPLACES the level glyph with the bolt, leaving the colour alone.
    # Core does exactly this: a charging laptop at 15% is still red, just bolted.
    $glyph = if ($OnAc) { $BATT_CHG } else { $pair.Glyph }

    return [pscustomobject]@{ Text = "$glyph $Percent%"; Fg = $pair.Fg }
}

# ── Simulated state (tests only) ─────────────────────────────────────────────
# Return the resolved pill and stop: no host read, no poke into the live bar.
if ($SimulateState) {
    return Resolve-PowerPill `
        -NoBattery ($SimulateState -eq 'NoBattery') `
        -OnAc      ($SimulateState -eq 'AC') `
        -Percent   $SimulatePercent
}

# ── Read the power state ─────────────────────────────────────────────────────
# SystemInformation.PowerStatus is a thin wrapper over the Win32 GetSystemPowerStatus
# call: AC line status, charge fraction and a NoSystemBattery flag in ONE cheap
# in-process read (~13ms). Deliberately NOT Get-CimInstance Win32_Battery — that's a
# slower CIM round-trip whose BatteryStatus codes are unreliable across vendors, and
# on a desktop it returns nothing at all, so "no battery" is indistinguishable from
# "the query failed".
$pill = [pscustomobject]@{ Text = $PLUG; Fg = $GREEN }

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus

    # BatteryChargeStatus is a [Flags] enum; NoSystemBattery (128) is the desktop case.
    $noBattery = [bool]($ps.BatteryChargeStatus -band
        [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery)

    $pill = Resolve-PowerPill `
        -NoBattery $noBattery `
        -OnAc      ($ps.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online) `
        -Percent   ([int][math]::Round($ps.BatteryLifePercent * 100))
} catch {
    # Assembly missing or the API refused — keep the green plug. A desktop is the
    # common case for this repo, so the placeholder is the safe default.
}

$fg   = $pill.Fg
$text = $pill.Text

$text

# ── Poke the pill into psmux ─────────────────────────────────────────────────
# Colour first, then text: the bar reads #[fg=#{@pwr_fg}]#{@pwr_pill}, so the colour
# should be current before the text it paints. Harmless if no psmux server is up.
#
# ⚠ THE QUOTES AROUND '@pwr_fg' / '@pwr_pill' ARE LOAD-BEARING — see the long note in
# psmux-netinfo.ps1. In argument position a bare @name is PowerShell's SPLATTING
# operator, so `psmux set -g @pwr_pill $text` drops the option name entirely and the
# set silently no-ops (exit 0, no stderr — psmux/psmux#535). That bug hid the VPN pill
# for months.
try {
    & psmux set -g '@pwr_fg'   $fg   2>$null
    & psmux set -g '@pwr_pill' $text 2>$null
} catch { }
