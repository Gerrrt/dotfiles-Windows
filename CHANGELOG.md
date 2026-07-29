# Changelog

All notable changes to this repo. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this is a personal dotfiles repo,
so entries are grouped by theme rather than strict semver releases.

## [Unreleased]

_**Core → Windows parity pass (2026-07).** A focused sweep to close the drift that had
built up between recent `dotfiles-core` / `dotfiles-MacBook` work and the Windows host,
kicked off by a host `:checkhealth` dump. In short: the stale `nvim/` mirror was
re-vendored from Core (bringing the `regex` Tree-sitter parser and the new `:checkhealth
gerrrt` LSP/formatter/linter readiness sections); the native-Windows clipboard
false-warning was fixed upstream in Core and pulled in; the psmux `:checkhealth` tmux
noise was documented as the cosmetic wart it is; and the two mid-2026 Core CLI tools the
host still lacked were wired up — `jnv` (interactive JSON explorer) and a `web`
terminal-browser verb (via `lynx`, since `w3m` has no scoop manifest). Per-change detail
below._

### Added

- **`jnv` — interactive JSON explorer (fleet parity with Core's `HAVE_JNV`).** Added to
  `packages/scoopfile.json` (scoop Main). A jq-filter editor with a collapsible viewer that
  fills the "explore an unfamiliar JSON response" gap between `jq` (transform) and `gron`
  (grep). Its own command with no alias — `jnv file.json` or pipe into it — like `jq`/`yq`/
  `gron`. This also retires the old `jless`-was-left-out caveat in `docs/TOOLS.md`: `jnv` is
  the packaged interactive explorer now.
- **`web` — terminal web browser verb (parity with Core's `web`).** Added a guarded `web`
  function in `core/00-aliases.ps1` that resolves `w3m`→`lynx`→`links`→`elinks` and runs the
  first present (skipped entirely when none is installed, matching Core). **`w3m` has no scoop
  manifest, so the host packages `lynx`** (Core's own next fallback; scoop Main) in
  `scoopfile.json`. Unlike Core's headless path, `$BROWSER` is never exported — the Windows
  host is GUI-first, so `web` stays an explicit opt-in verb.

### Changed

- **Re-vendored `nvim/` from Core** (was `v4.4.0-3`, now current). Brings the Core
  changes that had not yet reached the host: the `regex` Tree-sitter parser (silences
  `:checkhealth noice`'s "regex parser is not installed" cmdline-highlighting warning),
  the new `:checkhealth gerrrt` **LSP / formatter / linter** readiness sections, and the
  `servers/init.lua` read-only `status()` export those sections consume. `nvim/.core-ref`
  updated to the synced commit. (`nvim/`, via `nvim-sync.ps1`)

### Fixed

- **`:checkhealth gerrrt` no longer false-warns about the clipboard on the host.** It read
  "Core's cross-OS clipboard scripts are not on PATH (clip: found, clip-paste: missing)" —
  misleading, since `clip` only resolved to Windows' built-in `clip.exe` and the Unix/WSL
  `clip`/`clip-paste` ladder does not apply on the host: `config/clipboard.lua` wires the
  `clip-windows` provider (`clip.exe` copy + PowerShell paste) instead. Fixed upstream in Core
  (`health.lua` now detects native Windows via `has("win32")` and defers to `:checkhealth
  vim.provider` for the live backend) and pulled in with the nvim re-vendor above.

### Docs

- **Documented the psmux `:checkhealth` tmux cosmetic wart** in `docs/PORTING-NOTES.md`:
  psmux has no `show-option` verb, so Neovim's built-in `vim.health` tmux probe shows ❌
  ERRORs and a false "true color could not be detected" ⚠️ — cosmetic only (psmux renders
  24-bit colour natively; nothing functional is affected), and not shimmed on purpose.
- Refreshed the stale "re-vendor `nvim/`" manual step (the full tree is now vendored via
  `nvim-sync.ps1`, and the old `<leader>rc` keymap wart is fixed upstream), and dropped the
  now-inaccurate "Known Windows wart" banner `nvim-sync.ps1` printed after each sync.

## [v1.4.0] - 2026-07-23

### Changed

- **`Dotfiles.psd1` `Author` is now `dotgibson`, not the `Gerrrt` personal account.** The
  repos moved to the org, but the module manifest still presented the personal account as
  the owner — the last spot in the fleet doing so. Metadata only: nothing resolves this
  field, so it's a naming/identity fix rather than a functional one. The remaining
  `Gerrrt` references are all correct and deliberately untouched — the `nvim/lua/gerrrt/`
  namespace and `Gerrrt*` highlight groups (internal identifiers, not paths), historical
  `CHANGELOG` entries recording the migration itself, and attribution to
  `Gerrrt/make-windows-pretty` / `Gerrrt/yasb-glazewm-config`, which are genuinely
  external upstreams still living on that account.

### Fixed

- **`Check-PackageFreshness.ps1` no longer reports padded version strings as updates.**
  The lock is captured from `winget export`, which pads versions to four components,
  while `winget show` reports the source's own form — so `2.7.10.0` in the lock and
  `2.7.10` upstream are one build written two ways. The check compared them as raw
  strings, so three of the four packages in its 2026-07-21 report (`Microsoft.WSL`,
  `QL-Win.QuickLook`, `CharlesMilette.TranslucentTB`) were flagged as behind when they
  were current — and would have been flagged again every week, since re-pinning cannot
  fix a difference that isn't real. New pure helper `Test-PackageVersionMatch` in
  `PackageLock.ps1` compares component-wise with absent trailing components read as `0`,
  and falls back to exact string equality when either side isn't purely numeric-dotted
  (prereleases, scoop's date+hash strings, `nightly`), where there's no safe numeric
  reading. Applied to both the scoop and winget comparison sites. Unit-tested offline in
  `tests/Packages.Tests.ps1`.

## v1.3.0 - 2026-07-16

### Added

- **The `awesome-windows` sweep's heavier picks** — added in their proper homes rather
  than the always-on CLI core: `syncthing` (P2P sync) to `scoopfile.json` (`main`),
  `tailscale` (mesh VPN; pairs with the WSL bridge) to `scoopfile.json` (`extras`), and
  the GUI screenshot/capture tool **ShareX** (`ShareX.ShareX`) to the opt-out **`gui`
  winget group** in `winget.json` (alongside QuickLook/1Password). All install as plain
  binaries — no service auto-starts. `packages.lock.json` reconciled from the
  Main/Extras + winget manifests (`syncthing 2.1.2`, `tailscale 1.98.9`,
  `ShareX.ShareX 21.0.0`) so the scoop **and** winget drift gates pass; re-run
  `packages/Update-PackageLock.ps1` on a Windows host to confirm installed versions.
- **Three more host CLI tools from the `awesome-windows` sweep** in `scoopfile.json`:
  `yt-dlp` (feature-rich media downloader), `restic` (encrypted incremental backup —
  the stack had no backup tool at all), and `mpv` (scriptable keyboard-driven media
  player; extras bucket). Documented in `docs/TOOLS.md`. `packages.lock.json` reconciled
  from the Main/Extras bucket manifests (`restic 0.19.1`, `yt-dlp 2026.07.04`,
  `mpv 0.41.0`) so the drift gate stays green; re-run `packages/Update-PackageLock.ps1` on a
  Windows host to confirm against installed versions.
- **Five host CLI tools filling genuine gaps** in `scoopfile.json` (all scoop `main`):
  `lsd` (the `eza`-fallback `docs/TOOLS.md` already documented but wasn't installed),
  `gsudo` (in-session `sudo` for Windows — cached elevation, covers Win10), `watchexec`
  (run-on-file-change, the change-driven complement to `viddy`), `trippy` (`trip` —
  mtr/traceroute TUI), and `ast-grep` (`sg` — structural AST search/replace alongside
  `rg`/`sd`). Documented in `docs/TOOLS.md`. `packages.lock.json` was reconciled with
  their Main-bucket versions so the drift gate passes; re-run `packages/Update-PackageLock.ps1`
  on a Windows host to confirm against installed versions. (`jless` was dropped — not in
  the scoop buckets and weak on Windows; `gron`/`jq` cover it.)

### Fixed

- **`psmux/scripts/psmux-cheat.ps1` — `prefix ?` cheatsheet rendered as 3 columns of
  ~1 character each.** The `$rows` array was built from newline-separated `@(...)`
  literals, so PowerShell emitted each inner array as a separate pipeline statement and
  the collecting `@()` flattened them into one string array; `$_[0..2]` then indexed
  single characters (`'psmux'[0]='p'`). Added the leading-comma idiom (`,@(...)`) to each
  row so unrolling preserves the row, plus a comment documenting why it must stay.

## [v1.2.0] - 2026-07-14

### Added

- **QuickLook (`QL-Win.QuickLook`) — macOS-style spacebar file preview** added to the
  optional `gui` winget group (`winget.json` + `packages.lock.json`). Opt-in like the
  rest of the group; deliberately kept out of the core set. Flow Launcher was considered
  and left out — it overlaps PowerToys Run, which the `desktop` group already installs.
- **Everything (voidtools) instant file search + its `es` CLI.** `everything` (the
  MFT-indexed search service, extras bucket) and `everything-cli` (the `es` command,
  main bucket) added to `scoopfile.json` + `packages.lock.json`. `es` pairs with the
  shell — `es foo | fzf`, or as an `FZF_DEFAULT_COMMAND` source — and needs the
  Everything service running, which is why both are installed together.
- **`windows/defaults.ps1` — Windows preferences as code** (the pwsh twin of the sibling
  **dotfiles-MacBook** repo's `macos/defaults.sh`). A handful of privacy/telemetry + Explorer tweaks (disable the
  advertising ID, Start-menu suggestions, Bing-in-Start; show file extensions; open to
  This PC) codified as idempotent **HKCU** registry writes — no admin, nothing
  machine-wide. `-DryRun` previews, `-RestartExplorer` applies shell changes now. The
  point: the tweaks live in git (diffable, reproducible) instead of a one-shot debloat
  GUI. Standalone/opt-in — it is not wired into `install.ps1`.
- **jujutsu (`jj`) config on the host.** New `jj/config.toml` — the host-side twin of
  Core's `core/jujutsu/config.toml` — is symlinked to `%APPDATA%\jj\config.toml` (jj's
  native Windows config location) via `Get-DotfilesLinkPlan`, so the `jjs`/`jjl`/`jjd`
  aliases land on the same log-first, colocated-git setup as the Unix fleet. Windows-safe
  deviation: the pager is jj's built-in (`:builtin`) since Core's `less -FRX` isn't on the
  host. Identity stays unset (set once per machine with `jj config set --user …`).
- **Windows↔Mac terminal parity pass — the PowerShell/psmux/Windows Terminal stack
  now matches the Core (zsh) baseline the Mac inherits, wherever it's reproducible.**
  - _Git shorthands:_ the **full curated `git.zsh` set** (~55 `g*` verbs) is now on the
    host — `gap`, the `gca`/`gcam`/`gc!`/`gcn!` commit family, `gb*` branch, `gcb`/`gcom`/
    `gsw`/`gswc`/`gswm` checkout/switch, `gds`/`gdw`, `gloga`/`glol`/`glola`, `gf`/`gfa`/
    `gpr`/`gpu`, **`gpf` = `push --force-with-lease`** (the safe force), the `gsta*` stash
    and `grb*` rebase families, `grh`/`grhh`/`grs`/`grss`, `gr`/`grv`/`gm`/`gma`, plus
    `gdft` (difftastic) and `jjs`/`jjl`/`jjd` (jujutsu). The built-in PowerShell aliases
    that shadow a git shorthand (`gc`→Get-Content, `gcm`→Get-Command, `gp`→Get-ItemProperty,
    `gl`→Get-Location, `gm`→Get-Member, `gcb`→Get-Clipboard) are removed at load so the
    functions win — which also **fixes `gl`/`gc`/`gcm`/`gp`, previously shadowed** and
    silently not doing their git thing. `gbD` (force-delete) is dropped: PowerShell is
    case-insensitive, so it can't coexist with `gbd` (use `gbd -D`).
  - _Modern-CLI aliases:_ `df`→duf, `fm`/`y`→yazi, `top`/`htop`→btop, `tree`→eza,
    `ping`→gping, `cdi`→zoxide interactive, and `notes`.
  - _Functions:_ `ports` (listening sockets + process), `cdup`, `fcd`, `genpw`
    (crypto RNG), `please` (elevated re-run of the last command), and `pullall`
    (parallel fast-forward of every repo under a dir).
  - _Tools:_ `gping`, `difftastic`, and `jj` (jujutsu) added to `scoopfile.json`
    (+ `packages.lock.json`); the difftastic difftool + `dft` alias added to `git/.gitconfig`.
  - _psmux keys:_ full-span splits (`\`/`_`), zoom (`m`), kill/swap (`x`/`X`), toggle
    titles (`P`), synchronize-panes (`*`), a floating popup (`F`), window cycling
    (`Alt+Shift+H`/`L`), rename/kill window (`,`/`&`), enriched vi copy-mode
    (`Enter`/`v`/`C-v`/`Escape`), `R`/`S`/`d` QoL, double-tap-prefix → last-window, and a
    new **`prefix + u` URL picker** (`psmux-url.ps1`, host port of tmux-fzf-url). The
    cheatsheet moved from `prefix + D` to **`prefix + ?`** to match Core's tmux.
  - _`Ctrl+\`_ now toggles PSReadLine predictions, mirroring zsh's `autosuggest-toggle`.
- **A real `winget import`-compatible manifest and a `winget configure` baseline.**
  `winget.json` is this repo's own shape (`{ packages: [ id | { id, group } ] }`) so
  the installer can carry optional-group tags — which means it is _not_ consumable by
  `winget import`. New `packages/Export-WingetImport.ps1` projects it down to the
  official export schema at `packages/winget-import.json`, so a fresh box restores the
  whole set in one command (`winget import -i packages/winget-import.json …`);
  `-Frozen` pins versions from `packages.lock.json`. New root `configuration.dsc.yaml`
  goes further — an idempotent `winget configure` baseline that also enables Developer
  Mode (symlinks without an admin prompt).
- **Windows Terminal "PowerShell (JetBrains Mono)" profile.** `JetBrainsMono-NF` was
  installed by `scoopfile.json` but unused; it now has a home as a second pwsh profile,
  alongside the CaskaydiaCove default.
- **PSReadLine `F2` toggles the prediction view** (inline ghost ⇄ multi-row ListView)
  on demand, and the prediction UI is now tinted to the Tokyo Night palette instead of
  PSReadLine's default grey. The low-churn InlineView stays the default.
- **Tab-completion of local branch names for bare `git`** after a ref-consuming verb
  (`checkout`/`switch`/`merge`/`rebase`/`branch`) — filling the gap left by running no
  posh-git.

### Changed

- **Windows Terminal now matches Ghostty's look:** default font size **13 → 16** and
  **`useAcrylic: true`** (opacity stays 90) so the background is frosted glass like
  Ghostty's `background-blur`, rather than flat 90% opacity. The JetBrains Mono profile
  is bumped to 16 too.
- **PSReadLine history depth raised 50000 → 200000**, matching Core's zsh
  `HISTSIZE`/`SAVEHIST`.
- **delta already followed the Tokyo Night `ansi` theme here; Core adopts `ansi` too**
  (was `TwoDark`) so `git diff` renders identically on both OSes.
- **Windows Terminal opts into the AtlasEngine renderer explicitly**
  (`useAtlasEngine: true` in `profiles.defaults`) — it's the modern default, but the
  setting documents intent and guards an older WT build.
- **`dotfiles-doctor` and `core version` spawn one fewer `git` per run.** The "Repo
  version" detail collapsed two of its three `git` invocations into a single
  `git log -1 --format='%h%n%cs'`.

- **GlazeWM keymap reconciled with the Mac's AeroSpace into one shared cross-OS keymap.**
  The tiled desktop now has identical muscle memory on Windows and macOS: `desktop/glazewm/config.yaml`
  is kept keystroke-for-keystroke in step with `dotfiles-MacBook/aerospace/aerospace.toml`.
  Workspaces trimmed from 9 to **5** (matching AeroSpace's persistent 1–5); resize mode is now
  HJKL-only (arrow duplicates removed). Bindings with no identical AeroSpace equivalent were dropped
  for strict parity: minimize (`Alt+M`), toggle-tiling (`Alt+T`), pause mode (`Alt+Shift+P`), redraw
  (`Alt+Shift+W`), exit-WM (`Alt+Shift+E`), and directional move-workspace-to-monitor
  (`Alt+Shift+A/S/D/F`). Quit GlazeWM from its system-tray icon now that `wm-exit` has no bind.
  `desktop/README.md` updated to match.

### Removed

- **Dropped Visual Studio Code, Obsidian, and Firefox from the winget manifest.** VS Code
  was a core (always-installed) package; Obsidian and Firefox sat in the optional `gui`
  group. All three are editor/browser/app preferences rather than part of the host
  toolchain, so they're no longer installed by `bootstrap`/`install.ps1`. Removed from
  `winget.json` and `packages.lock.json` (the `gui` group is now just 1Password — the app
  and its CLI). Existing
  installs are untouched — this only stops future auto-installs; add any back by hand
  (`winget install …`) if you want it.

### Fixed

- **The multi-flavor Windows Terminal settings link no longer prints a "target folder
  not found — skipping" warning per flavor you don't have.** After the three-flavor
  support landed (Store / unpackaged / Preview), `install.ps1` warned once for each
  absent flavor and `dotfiles-doctor` showed three link rows (two forever "skipped") —
  noise, since you normally have exactly one WT install. Both now treat the flavors as
  a group: link whichever is present, stay silent about the rest, and warn/skip once
  only when **no** Windows Terminal is installed at all.
- **Windows Terminal settings now link for a scoop/unpackaged or Preview WT, not just
  the Store build.** `Get-DotfilesLinkPlan` (`powershell/core/05-lib.ps1`) hardcoded the
  packaged `…WindowsTerminal_8wekyb3d8bbwe\LocalState` path, and the row self-skips when
  that parent is absent — so an unpackaged WT silently never got its `settings.json`.
  Two more plan rows cover `%LOCALAPPDATA%\Microsoft\Windows Terminal\` (unpackaged) and
  the `…WindowsTerminalPreview…` package; only the installed flavor's row links.
- **`packages.lock.json` pinned 1Password to a range (`> 8.12.24.34`), not an exact
  version** — defeating `-Frozen` reproducibility for that one package. Pinned to an
  exact version (regenerate on a real box with `Update-PackageLock.ps1`).
- **GlazeWM and Zebar failed to install (`winget … NO_APPLICATIONS_FOUND`).** The
  `desktop` group used the CamelCase winget IDs `glzr-io.GlazeWM` / `glzr-io.Zebar`,
  but the community manifests publish them **lowercase** (`glzr-io.glazewm` /
  `glzr-io.zebar`) and `winget install -e` is case-sensitive — so both were skipped
  while PowerToys/TranslucentTB installed fine. Corrected the IDs in `winget.json`,
  `packages.lock.json`, and the docs.
- **`bootstrap.ps1` handoff to `install.ps1` failed with "A positional parameter
  cannot be found that accepts argument '$null'".** When no `DOTFILES_BOOTSTRAP_ARGS`
  were set (the common case), `Get-BootstrapInstallArgs` returned `@()`, which
  PowerShell unrolls to `$null` on assignment; splatting `$null` into the
  switch-only `install.ps1` passed a literal `$null` positional argument. The call
  site now wraps the result in `@()` and guards the splat, so a fresh
  `.\bootstrap.ps1` (or the `irm | iex` one-liner) runs the installer cleanly.

### Added

- **Zebar bar gains pomodoro, media controls, and a power menu.** Cherry-picked from
  [`Gerrrt/yasb-glazewm-config`](https://github.com/Gerrrt/yasb-glazewm-config) into the
  `vanilla-clear` widget: a 25/5 pomodoro (click to start/pause, right-click to reset),
  now-playing title/artist with prev/play-pause/next (Zebar `media` provider), and a
  lock/sleep/restart/shutdown power menu (via `shellExec`, with `shutdown`/`rundll32`
  whitelisted in `zpack.json`'s `privileges.shellCommands`). The `zebar` client import is
  bumped to the `@3` major to match the pinned app so those providers/APIs are present.
- **Opt-in tiling-desktop layer (`desktop/`).** A new optional layer that rices the
  _desktop_ on top of the shell host, adapted from `Gerrrt/make-windows-pretty` and
  retuned to the fleet's Tokyo Night Storm palette. Ships **GlazeWM** (i3-style tiling
  WM), a **Zebar** top bar (the buildless-React `vanilla-clear` widget as a native
  Zebar **v3 widget pack** (`zpack.json`), wired to GlazeWM for live, clickable
  workspaces), and adds **PowerToys** + **TranslucentTB**.
  All four install via the new `desktop` **optional package group** in `winget.json`
  (opt out at the picker or with `DOTFILES_PKG_GROUPS`), pinned in `packages.lock.json`.
  `desktop/glazewm/config.yaml` and the Zebar widget are symlinked into `~/.glzr` by the
  shared link plan, so `dotfiles-doctor` verifies them and `uninstall.ps1` removes them.
  The GlazeWM keymap is deliberately re-bound off `Alt+<arrow>` (which Windows Terminal
  uses for pane focus) to **vim keys** (`Alt+H/J/K/L`), and `Alt+Enter` launches `wt`.
  Setup + full keymap in `desktop/README.md`.
- **`duf` added to the scoop manifest.** The one modern-CLI tool `core-doctor`
  probes for that was missing from the Windows package set (macOS's Brewfile and
  the Linux lists lacked it too) — now installed from scoop `main` and pinned in
  `packages.lock.json`, closing the last doctor-tool gap on Windows.
- **`/release-readiness` + `/release-notes` routines** (`.claude/commands/` +
  `.github/workflows/claude-routines.yml`). The Windows twin of Core's release
  routines: `release-readiness` reads the Conventional Commits + CHANGELOG since the
  last **deliberate** release and files a **go/no-go verdict with the recommended next
  version** — purpose-built for Windows' quirk that `auto-tag` patch-bumps on
  nvim/starship mirror-syncs, so meaningful `feat`/`perf` work drifts under patch tags
  (the tag line has run ahead of the CHANGELOG headings); `release-notes` drafts the
  CHANGELOG entry from those commits. Both report-first (file a deduped issue, change
  nothing). `release-notes` is dispatch-only; `release-readiness` also runs a monthly
  nudge. **Inert by default** — dormant until a `CLAUDE_CODE_OAUTH_TOKEN` repo secret
  is added. Run via **Actions → claude-routines → Run workflow → routine**.

### Documentation

- **README second-pass polish.** The `dotgibson` shield now tracks the
  `dotfiles-core` release version (the system's version); dropped the showcase
  and LinkedIn shields for a one-line header (LinkedIn moved to Contact);
  "Explore the docs »" and the `[docs]` link now point at the documentation hub
  root (`/docs`); and About gained `Languages` (PowerShell) + `Tools` (Windows
  Terminal, Scoop, WinGet, psmux) subsections. The machine-checked Layout box and
  bootstrap SHA marker are unchanged.
- **README rebuilt as a lean showcase landing page.** Brought the README up to
  the `dotfiles-core` exemplar bar — a reference-style shields header, the org
  logo, a collapsible TOC, then a lean body (lead, three-layer at-a-glance, real
  Getting Started, a host-specific contribution contract, License/Contact). The
  lead states plainly that this host **replicates** Core in PowerShell rather than
  vendoring it. Deep detail (the fragment loader, coverage gate, and WSL bridge)
  now defers to the documentation hub and the migrated architecture audit. Added
  a `.markdownlint.jsonc` (mirrored from Core) scoping the showcase HTML via MD033
  `allowed_elements`.
- **`aliases.md` was missing three whole sections.** `os/33-psmux-pill.ps1`
  (`psmux-pill-now`/`-enable`/`-disable`/`-status`), `os/40-maint.ps1`
  (`maint-install`/`-run`/`-log`/`-status`/`-uninstall`), and `os/45-doctor.ps1`
  (`dotfiles-doctor`) had zero cheat-sheet coverage. Added sections for all
  three, and filled in the corresponding `CLAUDE.md` "Where things are" gaps
  (`git/`, `maint/`, `ssh/`, `docs/`, `tests/`).

### Fixed

- **`fix(module)`: the `Dotfiles` module surface runs under `Set-StrictMode -Version Latest`.**
  The non-interactive helper surface (`Dotfiles.psm1` → `core/05-lib.ps1` + the
  `*.Helpers.ps1`) had no strict-mode guard, so a typo'd variable, a missing property, or a
  bad array index silently returned `$null` instead of erroring. StrictMode is now set inside
  the module — **scoped to the module**, so even under `Import-Module -Global` the interactive
  session stays lenient (a blanket StrictMode on the dot-sourced interactive layer would change
  everyday shell behaviour, which is why it stays off there). The `Serve`/`Doctor`/`Help`/`WslBridge`
  suites already exercise the surface via `Import-Module`, and `Lib.Tests.ps1` now sets StrictMode
  too, so CI validates the helpers under strict mode.
- **`fix(profile)`: the local-modules `PSModulePath` dedup guard compares literally.**
  `profile.ps1` used `-notlike "*$LocalModules*"`, which treats the path as a **wildcard**
  pattern — a `%LOCALAPPDATA%` containing `[` or `]` (e.g. a `user[1]` name or a redirected
  profile) could mis-fire the guard and re-prepend `PSModulePath` on every shell start. It now
  splits on the path separator and uses `-notcontains` (a literal, case-insensitive compare).
- **Runaway `git.exe` processes that blocked updating git.** git gets spawned all
  the time without you asking — starship's `git_*` prompt modules on every render,
  the background `scoop update` bucket pulls in `core/15-update.ps1`, the daily
  maint job. Any of those can wedge on an INTERACTIVE credential prompt (git's own
  terminal prompt, or a Git Credential Manager dialog) in a context with nobody to
  answer, so the `git.exe` waits forever and the next spawn stacks another —
  hundreds of orphans that hold the git binary busy so `scoop update git` /
  `winget upgrade Git.Git` can't replace it. Fix: a new early fragment
  `core/08-git-safety.ps1` exports `GIT_TERMINAL_PROMPT=0` + `GCM_INTERACTIVE=Never`
  (before `15-update` and the prompt tools load) so shell-spawned git FAILS FAST
  instead of blocking on auth; escape hatch `DOTFILES_GIT_ALLOW_PROMPT=1`, and an
  already-set value is honoured. Adds a `git-reap` (`Reset-StuckGit`) verb to kill
  a pile that already formed. Paired with Core pinning starship `command_timeout`
  (reaps read-only prompt-git that wedges on a slow FS), synced into
  `starship/starship.toml` here (`.core-ref` bumped).

- **Large multi-line pastes no longer switch modes / reorder text / run vim
  commands.** Root cause: `core/10-tools.ps1` sets `EditMode Vi`, and PSReadLine
  versions before 2.2.0 have no bracketed-paste support, so a pasted block is
  replayed keystroke-by-keystroke and `:`/`d`/`i`/`a`/`o`/`Esc` are taken as Vi
  commands. Fix: bumped the `PSReadLine` pin in `packages/modules.ps1` from
  `2.2.0` to `2.3.6` (the current gallery release; first paste-safe release is
  2.2.0), kept Vi mode (deliberate parity with Core's zsh-vi-mode), and added a
  cheap `(Get-Module PSReadLine).Version` guard that emits a one-line
  `Write-DotWarn` with the upgrade command if a stale in-box PSReadLine (< 2.2.0)
  is loaded, so a stale box self-diagnoses. `tests/Repo.Tests.ps1` now asserts the
  `>= 2.2.0` floor.
- **Windows nvim plugins are now pinned to Core's `lazy-lock.json` like the rest
  of the fleet.** `nvim-sync.ps1` previously excluded `lazy-lock.json` from the
  `robocopy /MIR` (`/XF`) as "env-specific" — but it pins plugin commit SHAs,
  which are cross-platform, so Windows nvim floated on plugin HEAD while every
  Unix repo (and Core's weekly nvim-lock bot) stayed pinned. The sync now mirrors
  it; the file is removed from `.gitignore`, committed (from Core v2.4.1), and the
  nvim parity gate (`tests/Assert-NvimParity.ps1`) now includes it so the pin
  can't drift. Also bumped stale `nvim/.core-ref` provenance from v2.3.0 (6e923f9)
  to v2.4.1 (75195df) so fleet-drift stops falsely reporting Windows behind.

## [v1.1.0] - 2026-06-29 — DX/UX overhaul

A structural + terminal-UX pass focused on a world-class bootstrap and shell
experience, grouped by theme.

### Security / robustness (install)

- **`install.ps1` now uses `-LiteralPath` for every existence/copy/move/remove**
  in `Link-Item` and the seed/ppm steps. Bare `Test-Path`/`Copy-Item`/`Move-Item`
  treat `[`/`]` as wildcards, so a profile path containing brackets could read an
  existing real config as absent — skipping the back-up branch and clobbering it
  with no `.bak`. Brackets are now matched literally.
- **`DOTFILES_PPM_REF` is rejected when it begins with `-`**, closing the
  argument-injection seam (e.g. `--upload-pack=…`) that `bootstrap.ps1` already
  guards for `DOTFILES_REF`. The ppm `git checkout` also gained a `--`
  ref/pathspec separator to match (disambiguation, not the injection guard).
- **Dependency probes scoped to real executables** — `Get-Command gum/git/scoop/winget`
  now pass `-CommandType Application`, so a user-defined function/alias of the same
  name can no longer satisfy a presence check (the repo's profile encourages such
  wrappers, which previously could flip `Test-DotGum` true with no real `gum`).

### CI / structure (backend)

- **`nvim-sync` bot** (`.github/workflows/nvim-sync.yml`) — runs `nvim-sync.ps1`
  weekly (and on demand) and opens a PR when Core's `nvim/` tree has actually
  moved ahead, so the host editor config can't silently fall behind. Judges drift
  on the Lua tree only (ignores `.core-ref`'s per-run timestamp). First-party
  (`GITHUB_TOKEN` + `gh`), no third-party action.
- **`.core-ref` records the Core release tag** — `nvim-sync.ps1` now stamps a
  `tag` field (`git describe --tags` of the vendored commit) alongside `commit`,
  so dotfiles-core's `fleet-drift.sh` can label the Windows row by release name
  (e.g. `v2.0.0`) like the Unix repos' `core.lock` `core_tag`, instead of a bare
  SHA. Best-effort and backward compatible: the line is omitted when Core carries
  no tag (the `commit` SHA stays the source of truth and the drift verdict). Read
  path covered by a new `Get-CoreRefField` test case.
- **`package-freshness` bot** (`.github/workflows/package-freshness.yml` +
  `packages/Check-PackageFreshness.ps1`) — weekly on `windows-latest`, resolves the
  live scoop/winget version of each managed app and files a deduplicated findings
  issue when any is ahead of `packages.lock.json`. Findings only: re-pinning still
  runs locally via `Update-PackageLock.ps1` (it needs the apps installed).
- **Hermetic, incremental CI** — GitHub Actions pinned to commit SHAs; Pester and
  PSScriptAnalyzer pinned to exact versions; PSGallery modules cached; a
  `detect-changes` gate skips the Windows jobs for docs-only changes.
- **PSScriptAnalyzer signature gate** — after the pinned install, CI asserts the
  module manifest is Authenticode `Valid` and Microsoft-signed before running the
  analyzer, failing the build otherwise. Closes the last supply-chain gap in the
  fleet-wide CI-tool-download hardening (the Windows analogue of the SHA-256
  verification the Linux gate tools get via dotfiles-core's `setup-core-tools`).
- **Coverage gate** — Pester enforces ≥85% coverage on the pure-helper library.
- **`uninstall.ps1`** — reverse the bootstrap; removes only symlinks that point
  back into the repo, with `-DryRun` / `-RestoreBackups`.
- **Pre-commit hook** — `.githooks/pre-commit` runs the dependency-free validator;
  `install.ps1` wires `core.hooksPath`.
- **Fragment-load health gate** — the profile records any fragment that fails to
  load; `dotfiles-doctor` reports it.
- **More host-layer tests** — extracted pure helpers (`ConvertTo-WslPath`,
  `Get-FragmentHealthResult`, the uninstall link map) with behavioral tests.
- **Pinned module floors** — `packages/modules.ps1` carries `-MinimumVersion`
  floors for a reproducible baseline without freezing maintenance updates.
- **Dependabot** for the pinned actions.
- **Install transcript log** under `%LOCALAPPDATA%\dotfiles\logs`.
- **editorconfig enforcement** (final newline / trailing whitespace / LF) in the
  validator and Pester suite.
- **Manifest provenance** — winget ids must be `Publisher.Package`; scoop apps
  must name a declared bucket.
- This changelog.

### Terminal UX

- **`install.ps1 -DryRun`** previews every change and mutates nothing; `-Help`
  prints usage; `-NonInteractive` / `-Yes` for unattended runs.
- **Graceful interrupts** — `install.ps1` and the package installer print where
  they stopped (and close the log) on Ctrl-C or error.
- **Unified error/warning layout** — `Write-DotErr` / `Write-DotWarn` used across
  the entry points.
- **`NO_COLOR` + `DOTFILES_ASCII`** fallbacks across every renderer.
- **Install progress** — per-package `[n/total]` with elapsed time.
- **Interactive overwrite** — confirm before backing up a real user file; stale
  links are rewired silently.
- **Tab-completion** for `dothelp` filters, derived from the catalog.
- **Zero-config onboarding** — prompt for git name/email at install time.
- **`dotfiles-doctor -Fix`** opt-in remediation for the common issues.
- **`dothelp -i`** fuzzy command picker (fzf) that copies the pick.
- **`serve -Local`** — opt-in localhost-only bind (`127.0.0.1`) for the quick
  CWD HTTP server; LAN exposure stays the default.

### Fixes

- **Retired the `debian` WSL-jump helper** — `dotfiles-Debian` is no longer part of
  the fleet and Debian isn't a target distro, so the `debian` shortcut is removed
  from `os/31-wsl-bridge.ps1` (function + `provides:` line), the `dothelp` WSL-bridge
  catalog (`Help.Helpers.ps1`), and the module header comment (`Wsl.Helpers.ps1`).
  `kali` and the generic `cdwsl [distro]` remain for jumping into any WSL distro.
- **`md` no longer shadows `mkdir`** — the glow markdown-render alias was bound to
  `md`, clobbering PowerShell's built-in `md` (mkdir). It's now `gmd`; `md` is
  mkdir again. README, `docs/TOOLS.md`, and the `dothelp` catalog updated.
- **`tools` command implemented** — the cheatsheet advertised `tools` ("open the
  host tool docs") but nothing defined it. It now renders `docs/TOOLS.md` (glow →
  bat → nvim → plain), and is listed in `dothelp`.
- **Dead-shim guards for `fif` / `fbr`** — a tool that _resolves_ on PATH but
  won't _launch_ (a stale Chocolatey shim, or a scoop shim whose app was removed,
  shadowing the real binary) produced raw `Program rg.exe failed to run` /
  `cannot find file ...fzf.exe` errors. A new `Test-CmdRuns` helper probes
  executability so `fif`/`fbr` (and the same class of `Ctrl+t`/`Ctrl+r` breakage)
  fail with an actionable fix hint instead.
- **`dotfiles-doctor` now checks executability** — a new _Core toolchain runs_
  probe flags tools that resolve but won't launch, which the resolve-only check
  could not see.
- **`tools` / `gmd` no longer abort when `less` is absent** — glow (and bat) page
  through `$PAGER`, defaulting to `less`, which isn't on a stock Windows box, so
  `glow --pager` died with `exec: "less" not found`. Both now pass paging flags
  only when a pager actually exists and render inline otherwise.

_Per-finding backlog IDs and their status live in
[`docs/ARCHITECTURE-AUDIT.md`](docs/ARCHITECTURE-AUDIT.md) — the single ID
registry, so this log stays prose with no competing `B#`/`U#` scheme._
