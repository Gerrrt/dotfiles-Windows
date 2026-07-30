# desktop/ — the opt-in tiling-desktop layer

Everything under `desktop/` is **optional**. The rest of `dotfiles-Windows` makes
the *shell host* excellent (PowerShell, Windows Terminal, scoop/winget, psmux) and
otherwise stays out of the way. This layer is for when you also want the *desktop*
tiled and themed — a Linux-rice feel on the Windows host — adapted from
[Gerrrt/make-windows-pretty](https://github.com/Gerrrt/make-windows-pretty) and
retuned to the fleet's Tokyo Night Storm palette.

It ships three things: a **tiling window manager** (GlazeWM), a **top bar**
(Zebar), and two **quality-of-life apps** (PowerToys, TranslucentTB).

## What's here

| Path | What | Symlinked to |
| --- | --- | --- |
| `glazewm/config.yaml` | GlazeWM tiling-WM config (Tokyo Night, vim-key focus) | `~/.glzr/glazewm/config.yaml` |
| `zebar/vanilla-clear/` | Zebar v3 widget pack (`zpack.json`) — three islands: `logo · workspaces · front-app · pomodoro · weather` \| `clock` \| `network · volume · disk · memory · cpu · battery · power` (kept at parity with macOS sketchybar; see `PARITY.md`) | `~/.glzr/zebar/vanilla-clear` |

The symlinks are wired by `install.ps1` from the shared link plan
(`Get-DotfilesLinkPlan`), so `dotfiles-doctor` verifies them and `uninstall.ps1`
removes them — same as every other config in this repo.

## Install

The four apps live in the **`desktop` optional package group** in
`packages/winget.json`. They install by default; to opt out on a shell-only box,
deselect `desktop` at the first `Install-Packages.ps1` prompt, or set
`DOTFILES_PKG_GROUPS` in `powershell/local.ps1` (see `local.ps1.example`).

| App | winget id | Role |
| --- | --- | --- |
| GlazeWM | `glzr-io.glazewm` | tiling window manager |
| Zebar | `glzr-io.zebar` | top status bar |
| PowerToys | `Microsoft.PowerToys` | launcher (PowerToys Run), FancyZones, etc. |
| TranslucentTB | `CharlesMilette.TranslucentTB` | translucent taskbar |

The config files are linked regardless of the package selection (harmless if the
apps aren't installed), so opting in later is just a re-run of the package step.

## Manual steps (one-time, per the apps' own setup)

These aren't things a dotfile can do for you:

1. **Launch on login.** Add GlazeWM to startup (it launches Zebar via
   `startup_commands`). PowerToys and TranslucentTB each have their own
   "run at startup" toggle in-app.
2. **Enable the Zebar widget.** The `vanilla-clear` pack is a Zebar **v3 widget
   pack** (`zpack.json`); Zebar 3.x discovers it under `~/.glzr/zebar/`. Open Zebar,
   pick the `vanilla-clear` widget, and mark it to start (disable the bundled
   samples you don't want). GlazeWM's `startup_commands` runs `zebar`, which opens
   whatever you've marked as startup.
3. **PowerToys Run** defaults to `Alt+Space`. That does **not** collide with the
   GlazeWM binds here (which are `Alt`/`Alt+Shift` + letters/numbers).

## Keybindings (GlazeWM)

This is the fleet's **shared cross-OS keymap** — kept keystroke-for-keystroke
identical to the Mac's AeroSpace config
([`dotfiles-MacBook/aerospace/aerospace.toml`](https://github.com/dotgibson/dotfiles-MacBook/blob/main/aerospace/aerospace.toml)),
so the same muscle memory drives the tiled desktop on both Windows and macOS. Only
bindings both window managers can express identically are kept; edit one side and
mirror the change on the other.

Retuned from upstream to **not** fight Windows Terminal. WT already uses
`Alt+<arrow>` for pane focus (`windows-terminal/settings.json`), so this config
drops the `Alt+<arrow>` window binds and drives the WM with **vim keys** instead:

| Keys | Action |
| --- | --- |
| `Alt+H/J/K/L` | focus window left/down/up/right |
| `Alt+Shift+H/J/K/L` | move window left/down/up/right |
| `Alt+1..5` | focus workspace *n* |
| `Alt+Shift+1..5` | send window to workspace *n* and follow |
| `Alt+A` / `Alt+S` / `Alt+D` | prev / next / most-recent workspace |
| `Alt+U/P` / `Alt+O/I` | nudge-resize width −/+ · height +/− |
| `Alt+Enter` | launch Windows Terminal (`wt`) |
| `Alt+Shift+Space` / `Alt+F` | toggle floating / fullscreen |
| `Alt+V` | toggle split direction |
| `Alt+R` | enter resize mode (then H/J/K/L; `Esc` exits) |
| `Alt+Shift+Q` | close window |
| `Alt+Shift+R` | reload config |

> **Dropped for cross-OS parity** (no identical AeroSpace equivalent): minimize
> (`Alt+M`), toggle-tiling (`Alt+T`), pause mode (`Alt+Shift+P`), redraw
> (`Alt+Shift+W`), exit-WM (`Alt+Shift+E`), workspaces 6–9, and the arrow-key
> duplicates inside resize mode. To quit GlazeWM without the keybind, use its
> **system-tray icon → Exit** (or re-add a personal `wm-exit` bind locally).

## Bar widget (Zebar)

The bar is kept at **design parity with the macOS host's sketchybar** bar
(`dotfiles-MacBook/sketchybar`): same module order, floating rounded geometry,
CaskaydiaCove Nerd Font, Tokyo Night Storm palette, semantic load colors
(cpu/mem/disk green→yellow→red, volume cyan) and glyphs. The shared contract lives
in **`PARITY.md`** (an identical copy sits in `dotfiles-MacBook/sketchybar/`) —
change both bars together. Layout — **three floating islands** (transparent bar; each
zone is its own rounded panel with a colored rim: left blue · center magenta · right green):

```
[ logo · workspaces · [binding-mode] · front-app · pomodoro · weather ]   [ clock ]   [ network · volume · │ · disk · memory · cpu · │ · battery · power ]
```

`binding-mode` is Windows-only (GlazeWM binding modes; macOS has no twin); macOS's
`caffeinate` keep-awake toggle is likewise macOS-only. `weather` sits in the left
island; the right island carries two grey `│` separators (I/O · load · power).

Two widgets are interactive, ported from
[`Gerrrt/yasb-glazewm-config`](https://github.com/Gerrrt/yasb-glazewm-config):

| Widget | What | Interaction |
| --- | --- | --- |
| **Pomodoro** (left) | 25/5 work-break timer | click the time to start/pause, right-click to reset |
| **Power menu** (far right) | lock / sleep / restart / shut down | click the power icon to expand, click an action to run |

The power menu runs its actions with Zebar's `shellExec` (`shutdown` and
`rundll32`), so those two programs are whitelisted under
`privileges.shellCommands` in `zpack.json` — Zebar refuses any shell command a
widget hasn't declared. The `zebar` client is pinned to the `@3` major to match
the pinned Zebar app, so `shellExec` is present.

## Editing

`glazewm/config.yaml` is the source of truth — edit it here, and (once symlinked)
`Alt+Shift+R` reloads it live. The Zebar widget is buildless React
(`vanilla-clear.html`); every file it needs lives under the symlinked directory
(a bundled `normalize.css`, no zebar-root dependency), so it drops in cleanly and
Zebar hot-reloads on edit. Like any buildless Zebar widget it still pulls React,
the Zebar client, and the Nerd Font icon CSS from CDNs at runtime, so first paint
needs a network round-trip — it is self-contained on disk, not offline-only.
