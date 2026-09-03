# CLAUDE.md — dotfiles-Windows

Project memory for Claude Code, auto-loaded every session. The shared Core rules
live in [dotfiles-core](https://github.com/dotgibson/dotfiles-core).

## What this repo is

`dotfiles-Windows` is the **native-host layer** of an **eleven-repo dotfiles system**
built on a three-layer model (Core → OS-native → Role). It owns the Windows host:
PowerShell as the daily-driver shell, Windows Terminal, the scoop/winget package
layer, `psmux` (native tmux), and the bridge to Linux distros under WSL2.

## The rule that bites

It deliberately does **not** configure WSL distros — Core, `dotfiles-Debian`
(the OS layer, which covers Kali) and `dotfiles-Offense` (the role layer)
configure themselves from their own repos *inside* WSL. This repo's job is to make
the host excellent and then get out of the way.

This repo does **not** vendor the `dotfiles-core` `git subtree` (the canonical
fleet is `scripts/os-repos.txt` in dotfiles-core, which deliberately excludes
Windows). Don't confuse that with this repo's own PowerShell **`powershell/core/`**
module — same word, different thing: `powershell/core/` is native pwsh config that
lives and is edited here. Three assets are mirrored *from* dotfiles-core: `nvim/` (via
`nvim-sync.ps1`), `starship/starship.toml` (via `starship-sync.ps1`, since
starship.toml is cross-shell) and `theme/palette.toml` (via `theme-sync.ps1`) — sync
those rather than hand-editing drift.

The palette is the odd one out and the one to understand: it is an **input**, not a
leaf config. `gen-theme.ps1` renders it into nine marked `# core:theme:gen <id>` blocks
across `powershell/core/` and `psmux/`, plus — since #230 — the `Tokyo Night` scheme in
`windows-terminal/settings.json`, which is app-owned and so gets a *structural* JSON
rewrite keyed on the scheme's `"name"` instead of a marker pair (Windows Terminal strips
comments when it rewrites the file through the symlink). `gen-theme.ps1 -Check` gates
every PR. So **never hand-edit a colour** — and that now includes picking one in Windows
Terminal's Settings pane — change it in Core, re-sync, regenerate. Before #228 this
repo hand-copied its hexes and three fzf values had silently drifted from Core under a
comment claiming they matched.

## Where things are

- `powershell/` — pwsh profile + modules (incl. the `core/` pwsh layer)
- `windows-terminal/` — Terminal settings
- `packages/` — scoop/winget manifests
- `psmux/` — native tmux-alike
- `desktop/` — **opt-in** tiling-desktop layer: GlazeWM config + Zebar bar (symlinked into `~/.glzr`), plus the `desktop` winget group (GlazeWM/Zebar/PowerToys/TranslucentTB). Off the critical path — the host is shell-first; this is for ricing the desktop too. See `desktop/README.md`.
- `nvim/` — Neovim config mirrored from dotfiles-core via `nvim-sync.ps1`
- `starship/` — cross-shell prompt config mirrored from dotfiles-core via `starship-sync.ps1`
- `theme/` — `palette.toml`, the fleet's single colour source, mirrored via `theme-sync.ps1`; rendered into the terminal layer by `gen-theme.ps1`
- `git/` — `.gitconfig` / `.gitignore_global`
- `jj/` — jujutsu config (host twin of Core's `jujutsu/config.toml`; linked to `%APPDATA%\jj\config.toml`)
- `maint/Maintenance.ps1` — the daily maintenance runner (control surface: `os/40-maint.ps1`)
- `ssh/config` — SSH client config
- `docs/` — `TOOLS.md`, `PORTING-NOTES.md`, `ARCHITECTURE-AUDIT.md`
- `tests/` — Pester test suite
- `install.ps1`, `bootstrap.ps1`, `uninstall.ps1` — entry points
- `wsl/` — the WSL bridge
