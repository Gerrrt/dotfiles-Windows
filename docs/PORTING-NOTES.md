# PORTING-NOTES.md — how Windows fits the matrix

The fleet's `PORTING-MATRIX.md` has a column per OS. Windows is the odd one out
because it isn't a zsh/Unix target — it's a PowerShell host that also runs your
Linux distros under WSL2. Here's the row, translated.

| Matrix concept (Linux/Mac)                 | Windows equivalent                                                                                                                     |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Package manager block (`apt`/`dnf`/`brew`) | `scoop` (CLI) + `winget` (GUI) — `packages/`                                                                                           |
| Shell layer (`zsh`)                        | PowerShell 7 (`pwsh`) — `powershell/`                                                                                                  |
| Shell loader (sources core→os→local)       | `powershell/profile.ps1` (core→os→local)                                                                                               |
| Clipboard (`pbcopy` / `clip` / `xclip`)    | `Set-Clipboard` / `Get-Clipboard` (aliased `pbcopy`/`pbpaste`)                                                                         |
| Prompt (`starship`)                        | `starship` — same `starship.toml`, cross-shell                                                                                         |
| Multiplexer (`tmux`)                       | **host:** psmux (native Windows tmux, reads `~/.config/psmux/psmux.conf`) + Windows Terminal panes · **WSL:** the real tmux, from Core |
| Runtime manager (`mise`)                   | mise has Windows support but is secondary; scoop owns most CLI runtimes                                                                |
| Editor (`nvim`)                            | nvim reads `%LOCALAPPDATA%\nvim`; vendor Core's config (see `nvim/`)                                                                   |
| SSH config                                 | same hardened defaults **minus ControlMaster** (unsupported on Win OpenSSH)                                                            |
| `update.zsh` (`up` + nudge)                | `powershell/core/15-update.ps1` (scoop/winget, no elevation)                                                                           |
| `maint.zsh` + `dotfiles-maint.sh`          | `powershell/os/40-maint.ps1` + `maint/Maintenance.ps1` (Task Scheduler)                                                                |
| `op.zsh` (1Password helpers)               | `powershell/core/40-op.ps1` (`op` CLI is cross-platform)                                                                               |
| `history.zsh` (`HISTORY_IGNORE`)           | PSReadLine `AddToHistoryHandler` in `10-tools.ps1`                                                                                     |
| MAC helpers (SELinux/AppArmor)             | n/a                                                                                                                                    |
| Offensive layer (Kali only)                | n/a here — offensive role stays on the Kali station                                                                                    |

## Newly ported from Core (2026 sync)

- **`up` + update nudge** — `core/15-update.ps1`. Once/day, backgrounded
  (`Start-Job`), no elevation (scoop/winget are user-space). `up` is the
  fleet-standard verb; the older `update-host` stays as a convenience.
- **Scheduled maintenance** — `os/40-maint.ps1` drives a Task Scheduler job
  running `maint/Maintenance.ps1`. `StartWhenAvailable` ≈ systemd `Persistent`.
  scoop/mise/nvim/PS-modules auto-update; **winget is opt-in**
  (`MAINT_WINGET_UPGRADE=1`) since it can run MSI installers — the same caution
  Core applies to system packages on Arch/Gentoo/Kali.
- **1Password helpers** — `core/40-op.ps1`, 1:1 with `op.zsh`.
- **History secret-filtering** — PSReadLine `AddToHistoryHandler` keeps
  password/secret/token/`op …` lines out of the saved history file.
- **2026 CLI tools + aliases** — xh (`http`), glow (`gmd`), doggo (`dns`), plus
  sd/gron/gum as their own verbs. scoopfile + guarded aliases.
- **jnv + `web` (mid-2026 parity)** — `jnv` (scoop Main; the tool Core detects as
  `HAVE_JNV`) is the interactive JSON explorer, an own-command verb like jq/gron
  (`jnv file.json` or pipe in). Core's terminal-browser `web` verb is ported too:
  **w3m has no scoop manifest, so the host uses `lynx`** (Core's own next fallback,
  scoop Main). `web` resolves `w3m`→`lynx`→`links`→`elinks` and is skipped when none
  is installed; unlike Core's headless path it never exports `$BROWSER` (GUI host).
- **starship palette** — realigned to **tokyonight-storm**, then revised so the
  bright accents are segment _text_ over two dark surface fills instead of
  glaring background bands (was a near-white-on-bright eye-strain prompt).
- **psmux (native host tmux)** — NEW. tmux now has no-WSL home on the host:
  scoop install (`psmux` bucket), config at `psmux/psmux.conf` symlinked to
  `~/.config/psmux/`, `mux` helper in `os/32-psmux.ps1`. See "Multiplexer" below.
- **git config** — picked up Core's 2026 additions (fsmonitor, untrackedCache,
  rerere, rebase.updateRefs/autosquash, maintenance, fuller delta, expanded
  aliases) while keeping the Windows bits (autocrlf=true, longpaths, GCM,
  Windows excludesfile path).
- **init-output caching** — `core/10-tools.ps1` now caches the shell-integration
  script each tool prints (`starship`/`zoxide`/`mise`/`atuin`/`carapace`) under
  `%LOCALAPPDATA%\dotfiles\init-cache`, re-spawning only when the tool's binary
  is newer (i.e. after a scoop upgrade). This is the Windows analog of Core's
  cached `init zsh`; process spawn is the slow part on Windows. Each call site
  falls back to the live `init` if the cache can't be built, so the prompt is
  never lost. Helpers: `init-cache-clear` (bust it) and `shell-bench` (time a
  cold `pwsh` start). The old note said this wasn't worth porting — it is, now
  that the rest of the startup is lean.
- **Windows Terminal command marks** — `autoMarkPrompts` + `showMarksOnScrollbar`
  plus `ctrl+alt+up`/`down` to jump between prompts; starship grew `cmd_duration`
  (slow-command timing) and a `status` exit-code marker. UTF-8 I/O is now forced
  in `profile.ps1` so Nerd Font glyphs survive a legacy console codepage.
- **single Git source** — dropped scoop `git`; the host uses winget's `Git.Git`
  (Git for Windows), which bundles Git Credential Manager. scoop's `git` does
  not, so with both installed `credential.helper = manager` could break depending
  on PATH order. `gh` still comes from scoop.

> The new `core/` and `os/` fragments load automatically — `profile.ps1` globs
> each layer directory in name order, so no `install.ps1` change is needed for
> them. (`install.ps1` _was_ touched once, to symlink `psmux/psmux.conf` →
> `~/.config/psmux/psmux.conf`, since psmux reads a real config file rather than being sourced.)
> The maintenance runner is invoked by path, so it doesn't need a symlink either.

## Multiplexer: the host story changed

Previously this repo punted host-side multiplexing entirely to Windows Terminal
panes and kept tmux strictly inside WSL. As of 2026 there's a native option:
**psmux** is a Rust/ConPTY Windows multiplexer that speaks tmux's command
language and reads `~/.config/psmux/psmux.conf`. So the host now has three layers of choice:

1. **Windows Terminal panes** — zero install, GUI-native, still fine for quick
   splits (keybinds in `windows-terminal/settings.json`).
2. **psmux** — real tmux semantics (sessions/windows/panes, persistence, copy
   mode, scripting) in pwsh, no WSL. This is the new default for serious
   host-side multiplexing.
3. **tmux in WSL** — unchanged; the genuine article for Linux-side work, owned
   by Core/Kali.

The vendored `psmux/psmux.conf` sticks to portable tmux options so it can later
be unified with Core's tmux config (same filename, same language). What does NOT
carry to the host: the `vim-tmux-navigator` smart-pane script (Unix-shell
`is_vim` detection) and any `clip`/xclip copy commands — host clipboard goes
through `set-clipboard on` (OSC52) instead.

### Known cosmetic wart: `:checkhealth` tmux under psmux

psmux speaks tmux's command _language_ but not its whole surface — notably it has
no `show-option`/`show-options` verb. Neovim's built-in `:checkhealth` (the
`vim.health` "tmux" section) shells out to the real tmux to read settings, e.g.
`tmux show-option -qvg escape-time` / `focus-events` / `default-terminal`. Under
psmux (its scoop-installed `tmux` shim) those queries return
`psmux: unknown command: show-option`, so the section shows three ❌ ERRORs plus a
"True color support could not be detected" ⚠️. **This is purely cosmetic:**

- Nothing is broken. Those health probes only _read_ optional tmux settings; the
  session, panes, keybinds, and copy mode all work.
- The truecolor warning is a false negative — psmux renders 24-bit colour
  natively (see the "Colours & Terminal" note in `psmux/psmux.conf`, which is
  why it drops `terminal-features`/`terminal-overrides`), so `termguicolors`
  works despite the probe being unable to confirm it.

Not fixed in-repo on purpose: the `tmux` command is psmux's own binary (owned by
its scoop bucket, not this repo), and interposing our own `tmux` shim on PATH to
answer `show-option` would risk psmux's normal operation for a health-check
cosmetic. If psmux gains a `show-option` no-op upstream, the section goes green on
its own.

## Things that DON'T port (by design)

- **Offensive layer** — unique to the Kali station, same as everywhere else in
  the fleet. The Windows host is a productivity/host repo only.
- **sesh** — the tmux session-manager wrapper stays in Core for use inside WSL;
  on the host, `mux` (attach-or-create) covers the common case.
- **Full nvim tree** — belongs in Core and is vendored, not duplicated.
- **MAC/SELinux/AppArmor** — no equivalent.
- **`getent`/`/etc/passwd` shell detection** — n/a on the host.

## Remaining manual steps

- **Keep `nvim/` current with Core.** The full tree
  (`lua/gerrrt/{config,plugins,servers,utils}`) is authored in Core and vendored
  here via `nvim-sync.ps1` (a `robocopy /MIR` mirror, no subtree — see the script
  header). Run it after a Core release and commit the diff; `nvim/.core-ref`
  records which Core commit the tree came from. The old U16 keymap wart is gone —
  `config/keymaps.lua`'s `<leader>rc` resolves the config dir at runtime with
  `vim.fn.stdpath("config")` upstream in Core, so it opens the right `init.lua`
  on every platform (`%LOCALAPPDATA%\nvim` on the host) and survives the mirror.
- **Align `psmux/psmux.conf` with Core's tmux config.** The host config is a
  standalone, portable starter that already remaps the prefix to `C-a`
  (`psmux.reset.conf`). When convenient, reconcile the remaining keybinds with
  Core. Note psmux reads `psmux.conf`, not `.tmux.conf`, so vendoring Core's
  tmux tree here means a copy-with-rename rather than a same-filename subtree.

## 2026-07-30 parity sweep (Core + MacBook → host)

A pass to catch the host up to recent Core/MacBook tmux, nvim, shell, terminal, and
prompt work. Split by what can be verified off-host vs. what needs a Windows box.

**Landed (mechanical / low-risk):**

- **nvim re-synced** — the vendored tree was one Core commit behind
  (`af35f3c`, a `lazy-lock.json` 4-plugin-SHA refresh). Re-mirrored; `nvim/.core-ref`
  now points at Core `main` `a53ac4f` (was the pre-merge branch tip `e4dbbda`). The
  rest of the tree (checkhealth LSP/formatter/clipboard work, statusline, alpha,
  treesitter `regex` parser) was already current.
- **starship** — verified **zero drift**: `starship/starship.toml` is byte-identical to
  Core's, already carrying the minimal-capsule rewrite (`[cmd_duration]`, `[status]`,
  hostname/container/shlvl). Nothing to sync.
- **Windows Terminal cursor** — `cursorShape` `filledBox` → `bar` to match MacBook's
  ghostty `cursor-style = bar`. (Opacity + acrylic already match ghostty's
  translucency/blur; `padding` left at `0` by choice.)
- **pwsh command-block separator** — port of Core's `_cmd_block_*` (`zsh/00-tools.zsh`):
  a thin full-width rule above each prompt that followed a command, colored by exit
  status (dim `#414868` ok / red `#f7768e` fail). Implemented as precmd/preexec, **not**
  a key handler, so — like Core — it can't collide with PSReadLine vi-mode: the existing
  `AddToHistoryHandler` sets `$global:DotCmdBlockRan` (fires only on a non-empty accepted
  line, so a bare Enter draws nothing), and `Invoke-Starship-PreCommand` draws the rule
  via `[Console]::Write` (never enters starship's prompt string). Colour tracks
  `$LASTEXITCODE` (the only status reliable after starship's prompt fn reads `$?`); a
  failed pure-cmdlet still shows in starship's `[status]`. **Landed but not yet
  render-verified on a Windows host** — CI lints it (PSScriptAnalyzer); eyeball it on
  first pull. (`powershell/core/10-tools.ps1`)
- **psmux centered floating-island bar** — port of Core `tmux.conf`'s `19d7a98` island
  redesign: `status 2` + blank `status-format[1]` (2-line), `status-justify
  absolute-centre` (**divergence from Core**, which uses plain `centre`: the host's
  variable-width session pill — wider when prefix is active — and the `#{b:pane_path}`
  cwd in `status-right` shove `centre`-justified tabs off the true middle; `absolute-centre`
  anchors them independent of both floats),
  transparent `status-style bg=default` + `bg=default` pill caps and pane borders,
  `monitor-activity` with activity **•** dots in the tabs (psmux has no `monitor-bell`), and flat
  **underlined** window tabs instead of pills. All five features were probed as supported
  on psmux 3.3.7 before porting. Kept psmux-native: the cwd pill stays `#{b:pane_path}`
  (OSC 7, the shell's `Invoke-Starship-PreCommand` announces it) — Core's nvim-gated
  `#{pane_current_command}`/`#{pane_current_path}` segment was **deliberately not ported**
  (it walks the process table on every render — the documented keystroke-lag bug). No
  `#()` anywhere, per the bar's hard no-shell-out rule. **Landed but not yet
  render-verified on a Windows host** — reload psmux and eyeball. (`psmux/psmux.conf`)

**Deferred — needs on-device validation (can't be render-tested off-host).**
Tracked as **U17** in `docs/ARCHITECTURE-AUDIT.md`; the two "landed but not yet
render-verified" items below are **U18** and **U19**.


- **pwsh transient prompt** — Core collapses finished prompts to a status-colored `❖`
  (`olets/zsh-transient-prompt`). Held deliberately: the only pwsh route is a PSReadLine
  **Enter/AcceptLine key-handler override**, which interacts with the vi edit-mode and the
  existing menu-complete / history key handlers in `10-tools.ps1` — exactly the vi-mode
  collision Core avoids — so it must be built and tested against a live PSReadLine, not
  shipped blind. Core's own commit (`427e20e`) flags it a pwsh follow-up.

## Windows-only additions

- `wsl/windows.wslconfig.example` — canonical home for the host WSL2 config
  (mirrored networking) that dotfiles-Debian references.
- `powershell/os/31-wsl-bridge.ps1` — the host↔WSL seam (`kali`, `cdwsl`,
  `hostip`, `wsl-restart`).
- `powershell/os/32-psmux.ps1` + `psmux/psmux.conf` — native host multiplexer.
- `powershell/os/40-maint.ps1` + `maint/Maintenance.ps1` — Task Scheduler maint.
- Windows Terminal `settings.json`.

## Maintenance

- When **Core's** `starship.toml`, git config, or `.tmux.conf` changes, mirror
  the relevant bits here (or vendor them as a subtree the way the Linux repos do).
- Record the scoop/winget package names in the matrix's Windows column so
  future-you doesn't re-derive them (psmux lives in its own scoop bucket:
  `https://github.com/psmux/scoop-psmux`).
