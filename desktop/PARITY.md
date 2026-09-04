<!-- desktop-parity:gen -->
<!-- ============================================================================
     GENERATED BLOCK — do not edit this text in dotfiles-Windows or dotfiles-MacBook.
     Canonical source : dotfiles-core/desktop/PARITY.shared.md
     Regenerate       : make gen-desktop-parity   (from a dotfiles-core checkout)
     Gate             : scripts/gen-desktop-parity.sh --check — run weekly by Core's
                        parity-check workflow, which clones BOTH desktop repos.

     Editing one copy by hand is the exact failure this block exists to prevent: the
     two files sat 3.5 KB apart because "edit both together" was the only mechanism
     (#693). Fix the canonical source and regenerate instead.
     ============================================================================ -->

# Bar parity contract — Zebar ↔ sketchybar

Two bars, two hosts, one design: **Zebar** on the Windows/GlazeWM host
(`dotfiles-Windows/desktop/zebar/vanilla-clear/`, buildless React/HTML/CSS) and
**sketchybar** on the macOS/AeroSpace host (`dotfiles-MacBook/sketchybar/`, bash +
`sketchybar` CLI). Different tech, deliberately identical result. This block is the
canonical spec — authored once in `dotfiles-core/desktop/PARITY.shared.md` and rendered
into both repos, so neither copy can drift from the other; both bars follow it.

## Divergence status

Every difference between the two bars is one of three things — the same vocabulary
Core's own `PARITY.md` uses for zsh ↔ pwsh:

- **`aligned`** — same result on both bars. Changing one side without the other is a
  regression; this document is what "the same" means.
- **`deliberate`** — intentionally different because the hosts differ (a widget has no
  counterpart on the other WM). Documented so it is a _decision_, not drift.
- **`gap`** — something one bar has and the other could, but doesn't yet. An open item,
  not a promise.

Everything below is `aligned` unless it says otherwise. Anything a single host adds on
top lives **outside this generated block**, under a "Host-specific addenda" heading in
that repo's own copy.

## Layout (three islands, left → center → right)

The bar renders as **three floating "islands"**: the bar itself is transparent and
each zone carries its own translucent rounded panel with a colored rim (see Geometry).

| Island (rim)             | Modules (in order)                                                                                                           |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| **Left** (blue rim)      | `logo` · `workspaces` · _(binding-mode — Windows only)_ · `front_app` · `pomodoro` · _(caffeinate — macOS only)_ · `weather` |
| **Center** (magenta rim) | `clock`                                                                                                                      |
| **Right** (green rim)    | `network` · `volume` · `│` · `disk` · `memory` · `cpu` · `│` · `battery` · `power`                                           |

The right island carries two thin grey `│` separators that chunk it into
**I/O · load · power/ambient** — one after `volume`, one after `cpu`.

Two sanctioned platform exceptions, both `deliberate` (no cross-platform equivalent):

- **binding-mode** — `deliberate`, Windows only. GlazeWM binding modes (e.g. `resize`);
  shown after `workspaces` only while a mode is active. AeroSpace has no equivalent.
- **caffeinate / keep-awake** — `deliberate`, macOS only. The `caffeinate -di` toggle, in
  the **left island** beside `pomodoro`. No matching one-shot toggle on the Windows host.

`weather` lives in the **left island** on both hosts (a stable-width, non-urgent
readout kept clear of the volatile right-island network figures and the centered clock).

`logo` is a per-host brand glyph: Apple `` (macOS) / Windows `` (nf-fa-windows).
`clock` uses the format `EEE d MMM t` → e.g. `Mon 13 Jul 2:45 PM`.

## Geometry (three floating rounded islands)

| Token                | Value                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------- |
| Island fill          | `#1d202f` @ ~93% alpha — `0xee1d202f` (sketchybar) / `rgba(29,32,47,0.93)` (Zebar)             |
| Bar itself           | **transparent** — the islands carry the background, the gaps between them are bare             |
| Outer float gap      | 8px                                                                                            |
| Island corner radius | 9px                                                                                            |
| Island rim           | 2px solid — left **blue** `#7aa2f7` · center **magenta** `#bb9af7` · right **green** `#9ece6a` |
| Island height        | 28px, inset within the 36px bar                                                                |
| Blur                 | **off** — a transparent bar has nothing to blur; islands are plain translucent fills           |

Within each island, items stay **chip-less** — plain spaced icon+text on the island's
translucent fill (no per-item background). The three islands are the only rounded
containers; the focused-`workspace` highlight pill draws _over_ the left island. The
colored rims are JankyBorders-style and echo the accent (`#7aa2f7`) window borders the
tiling WM draws.

Sizes/spacing are **per-host tuning knobs**, kept in one place on each side so
they're easy to iterate: sketchybar's `--bar` / `--default` / `ISLAND_ARGS` blocks in
`sketchybarrc`, and Zebar's `:root` "tuning knobs" block at the top of `styles.css`
(`--bar-font-size` / `--bar-height` / `--bar-gap` / `--bar-radius` / `--island-height` /
`--island-pad-x` / `--item-gap`). They're tuned to _look_ the same, not pixel-identical.

- **sketchybar**: transparent bar `--bar color=0x00000000 blur_radius=0 height=36 y_offset=4 margin=8 corner_radius=9 padding=2`; each island is a `bracket` with `background.color=0xee1d202f corner_radius=9 background.height=28 border_width=2` + its rim color.
- **Zebar**: the `.app` grid is transparent; `.left` / `.center` / `.right` each paint an island (`background: rgba(29,32,47,0.93); border: 2px solid <rim>; border-radius: 9px`), sized by the `:root` knobs. Keep the `zpack.json` window `height` ≥ `--bar-height + 2×--bar-gap` or the islands clip; GlazeWM's `gaps.outer.top` clears them.

## Font

**CaskaydiaCove Nerd Font** on both (macOS: Homebrew cask; Windows: the
`CascadiaCode-NF` scoop package installs this exact family). Sizes are tuned per
host to match visually, not pixel-identical across DPI: sketchybar `17.0` pt, Zebar
`16px` (`--bar-font-size`) — adjust via each bar's knobs.

The variable-width **front-app** label is capped at ~22 chars on both bars (Zebar:
`max-width: 22ch` + ellipsis; sketchybar: `label.max_chars=22`) so a long app name
can't grow into the centered clock.

## Colors — semantic load scheme (Tokyo Night Storm)

| Token            | Hex       | `0xAARRGGBB` | Role                                                                                      |
| ---------------- | --------- | ------------ | ----------------------------------------------------------------------------------------- |
| bg               | `#24283b` | `0xff24283b` | item background                                                                           |
| fg               | `#c0caf5` | `0xffc0caf5` | default text                                                                              |
| fg-dim           | `#a9b1d6` | —            | dimmed text (workspaces, power btns)                                                      |
| blue / accent    | `#7aa2f7` | `0xff7aa2f7` | active highlight, logo, workspaces, front_app, network, battery-charging, left-island rim |
| green            | `#9ece6a` | `0xff9ece6a` | load: low                                                                                 |
| yellow           | `#e0af68` | `0xffe0af68` | load: mid                                                                                 |
| red              | `#f7768e` | `0xfff7768e` | load: high                                                                                |
| cyan             | `#7dcfff` | `0xff7dcfff` | volume                                                                                    |
| purple / magenta | `#bb9af7` | `0xffbb9af7` | clock text + center-island rim                                                            |
| orange           | `#ff9e64` | `0xffff9e64` | weather + warm accents                                                                    |
| grey / comment   | `#565f89` | `0xff565f89` | inactive / dim · `│` island separators                                                    |

Shared thresholds (glyph **and** value colored together):

| Module             | low (green) | mid (yellow) | high (red) |
| ------------------ | ----------- | ------------ | ---------- |
| cpu                | 0–49        | 50–79        | 80+        |
| memory             | <70         | 70–87        | 88+        |
| disk (used %)      | <80 (green) | 80–89        | 90+        |
| battery (charge %) | >40         | 21–40        | ≤20        |

`network` = blue. `volume` = cyan. `clock` = magenta/purple. `weather` = orange.
`workspaces` focused = blue pill with dark text. Island rims: left **blue** · center **magenta** · right **green**.

## Glyphs (one nerd-font icon per module, used verbatim by both)

sketchybar embeds the literal glyph; Zebar uses the matching `nf-*` class from the
Nerd Fonts webfont. Same icon on both.

| Module                              | Nerd Font name                                          | glyph                           | Zebar `nf-*` class                                                   |
| ----------------------------------- | ------------------------------------------------------- | ------------------------------- | -------------------------------------------------------------------- |
| logo (macOS)                        | fa-apple                                                |                                | —                                                                    |
| logo (Windows)                      | fa-windows                                              |                                | `nf-fa-windows`                                                      |
| pomodoro                            | md-timer-outline                                        | 󰔛                               | `nf-md-timer_outline`                                                |
| clock                               | md-clock-outline                                        | 󰅐                               | `nf-md-clock_outline`                                                |
| network                             | md-speedometer                                          | 󰓅                               | `nf-md-speedometer`                                                  |
| volume high/med/low/off             | md-volume-high / medium / low / off                     | 󰕾 󰖀 󰕿 󰖁                         | `nf-md-volume_high` / `_medium` / `_low` / `_off`                    |
| disk                                | md-harddisk                                             | 󰋊                               | `nf-md-harddisk`                                                     |
| memory                              | md-memory                                               | 󰍛                               | `nf-md-memory`                                                       |
| cpu                                 | md-cpu-64-bit                                           | 󰻠                               | `nf-md-cpu_64_bit`                                                   |
| battery full/¾/½/¼/empty            | fa-battery-4/3/2/1/0                                    |                            | `nf-fa-battery_4` … `_0`                                             |
| battery charging bolt               | md-power-plug                                           | 󰚥                               | `nf-md-power_plug`                                                   |
| weather                             | weather-\* (day/night × clear/cloudy/rain/snow/thunder) | see weather.sh / getWeatherIcon | `nf-weather-*`                                                       |
| caffeinate awake/asleep             | md-coffee / md-power-sleep                              | 󰅶 󰒲                             | —                                                                    |
| power                               | md-power                                                | 󰐥                               | `nf-md-power`                                                        |
| power → lock/sleep/restart/shutdown | md-lock / power-sleep / restart / power                 | 󰌾 󰤄 󰜉 󰐥                         | `nf-md-lock` / `nf-md-power_sleep` / `nf-md-restart` / `nf-md-power` |

## Behaviour parity

- **network** — throughput `↓<down> ↑<up>`, compact units (`B`/`K`/`M` per second).
- **pomodoro** — 25/5 work-break timer; left-click start/pause, right-click reset;
  states colored green (work) / blue (break) / grey (paused).
- **power** — collapsed icon expands to lock · sleep · restart · shutdown.
- **clock + battery** also appear here even though the macOS tmux status bar shows
  them too — a deliberate choice for cross-host parity.

<!-- desktop-parity:end -->

## Host-specific addenda (Windows) — `deliberate`

Outside the generated block on purpose: psmux is the Windows PowerShell analogue of tmux
and macOS has no twin for it, so this section has no sketchybar counterpart. It is
`deliberate`, not drift — the generated block above is everything the two bars share.

- **battery on a desktop** — `deliberate`, Windows only. A machine with no battery shows
  the AC placeholder: a lone green `md-power-plug` 󰚥. The **psmux status bar shows the
  same placeholder**, right-most in `status-right`, so both Windows bars agree that the
  host is on AC.

> ⚠ **The psmux bar does NOT use the generated block's battery scale.** That block is the
> **desktop-bar** contract — Zebar ↔ sketchybar. The terminal bars are matched to each
> other instead: `psmux/scripts/psmux-power.ps1` is a port of Core's
> `tmux/scripts/tmux-battery.sh` and follows _its_ scale (green ≥60 / yellow ≥20 / red
> <20, three level glyphs plus a charging bolt), so the psmux bar and the macOS tmux bar
> draw the identical pill. The two scales disagree between 40 and 60 % on purpose. The
> only thing psmux borrows from here is the 󰚥 no-battery placeholder, which Core doesn't
> draw at all. `tests/Repo.Tests.ps1` pins the psmux side against Core's thresholds.
