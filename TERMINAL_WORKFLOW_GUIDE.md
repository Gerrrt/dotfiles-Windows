# TERMINAL_WORKFLOW_GUIDE.md — dotfiles-Windows

> A Principal-Engineer-grade audit and operating manual for the PowerShell + psmux
> terminal ecosystem shipped by **dotfiles-Windows**. This documents *reality as
> configured*: every path, binding, cache, and load-order rule was read out of the
> tree, not assumed. Where a config is **mirrored from `dotfiles-core`** (`nvim/`,
> `starship/starship.toml`) it is called out as such — sync those, don't hand-edit.

**Scope note.** This box is the **native-host layer** of an eleven-repo, three-layer
system (Core → OS-native → Role). Unlike the Linux/macOS repos it vendors **no
`core/` subtree** — its host config is replicated from scratch in PowerShell under
`powershell/`. PowerShell 7+ is the daily driver; `psmux` is the native tmux; the
host is deliberately **shell-first** and does **not** configure WSL distros (Core
and Kali configure themselves from inside WSL). Sections 1–5 cover the terminal
ecosystem the prompt centers on; **sections 6–8 extend to the rest of the repo** —
the tiling desktop, the maintenance/packages toolchain, and the editor/VCS configs
— so the manual documents every capability the repo ships (see the Coverage Ledger
at the end).

---

## 1. THE INITIALIZATION PIPELINE & VARIABLE FLOW

### 1.1 The load pipeline (`$PROFILE` → `profile.ps1` → fragments)

There is one entry point and one dispatcher. `bootstrap.ps1`/`install.ps1` wire the
symlink in the left column.

| Order | Repo file | Symlink target | Runs when | Job |
|------:|-----------|----------------|-----------|-----|
| 1 | `powershell/profile.ps1` | `…\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` (`$PROFILE`) | every interactive pwsh | forces UTF-8 I/O; prepends local `PSModulePath`; imports the `Dotfiles` module; dot-sources the fragment chain; loads `local.ps1` |
| 2 | `powershell/Dotfiles/Dotfiles.psd1` | *(imported, not linked)* | first, before fragments | the pure helper library (`Test-*`, `Write-Dot*`, `Get-DotfilesLinkPlan`, `Test-InMux`, `ConvertTo-WslPath`, …); unit-tested |
| 3 | `powershell/core/*.ps1` | *(dot-sourced in name order)* | interactive | the native pwsh config layer (aliases, tools, functions) |
| 4 | `powershell/os/*.ps1` | *(dot-sourced after `core/`)* | interactive | Windows-host overlay (scoop/winget verbs, psmux, maint, doctor) |
| 5 | `powershell/local.ps1` | *(gitignored, seeded from `.example`)* | last | untracked per-machine escape hatch — wins |

Repo root resolves from the persistent `$env:DOTFILES_WIN` (set by the installer),
exported as `$global:DOTFILES`. Each fragment is dot-sourced inside a `try/catch`:
a failing fragment is **recorded, never fatal** — the shell always starts, and (unless
`FAST_START=1`) a one-line warning names any fragment that failed.

> **Module-first invariant.** `05-lib.ps1` is the one fragment the loader **skips** in
> the `core/` loop *when the `Dotfiles` module import succeeded* (the module already
> provides those helpers globally). If the import fails, the loop dot-sources
> `05-lib.ps1` as a degraded fallback so the helper layer is never missing.

### 1.2 The fragment chain (`core/` then `os/`, name-sorted)

The dispatcher globs `core/*.ps1`, sorts by name, dot-sources each; then the same for
`os/*.ps1`. The numeric prefixes *are* the load order.

**`core/` (native pwsh config):**

- **`00-aliases.ps1`** — `Test-Cmd`/`Test-CmdRuns` (capability probes, §3.1); the modern-tool
  alias swaps (`ls`→eza, `cat`→bat, …); the ~55 `g*` git shorthands; `reload`, `which`,
  `vim`→nvim. Sets `BAT_THEME=ansi`.
- **`05-lib.ps1`** — the pure helper library (normally the module; see 1.1). No side effects,
  no shell-outs, prints nothing on load.
- **`08-git-safety.ps1`** — sets `GIT_TERMINAL_PROMPT=0` + `GCM_INTERACTIVE=Never` (unless
  `DOTFILES_GIT_ALLOW_PROMPT=1`); defines `Reset-StuckGit` (alias **`git-reap`**). §5.2.
- **`10-tools.ps1`** — the big interactive module: PSReadLine, starship, zoxide, PSFzf (lazy),
  mise, atuin, carapace, `Get-InitCache`, the sessionizer + Alt+Z. §3.
- **`15-update.ps1`** — throttled (once/day) backgrounded scoop+winget update **nudge**; the
  `up` updater; `update-check`. §7.1.
- **`20-functions.ps1`** — general helpers (myip/ports, extract/compress, mkbak, genpw, please,
  pullall, serve, fif, the fuzzy-git `fbr`/`gaf`/`grf`/`grsf`). §4.2.
- **`25-television.ps1`** — `tv` channel verbs (`tvim`/`ttext`/`tcd`/`trepo`/`tbranch`/`tenv`);
  deliberately does **not** run `tv init` (that would seize Ctrl+T/Ctrl+R).
- **`40-op.ps1`** — 1Password CLI helpers (`opsecret`/`openv`/`optoken`/`opssh`); no-op if `op` absent.
- **`45-crypto.ps1`** — `age` helpers + `croc` `send`/`recv`, each guarded on tool presence.
- **`50-completions.ps1`** — `Register-ArgumentCompleter` for the repo verbs (`sci`/`wgi`/`mux`/
  `cdwsl`/`maint-log`/`dothelp`) + native `git` branch completion.
- **`55-help.ps1`** — `dothelp` command index (+ `-Interactive` fzf picker) and the "did you
  mean?" `CommandNotFoundAction` hook.
- **`57-health-nudge.ps1`** — one-line startup nudge naming any missing essential tool
  (`git starship zoxide fzf rg fd bat eza nvim`). Suppressed under `FAST_START`.

**`os/` (Windows-host overlay), loaded after `core/` so it can override:**

- **`30-windows.ps1`** — scoop/winget verbs (`scu`/`sci`/`wgi`/…), `path`/`open`/`admin`/
  `setenv`/`getenv`, `modules-localize`, and the **psmux auto-attach** (`psmux new-session -A -s Gerrrt`).
- **`31-wsl-bridge.ps1`** — `kali`, `wsls`, `wslip`, `cdwsl`, `hostip`, `wslhome`, `wsl-restart`. §8.7.
- **`32-psmux.ps1`** — the `mux` verb (attach-or-create). **`33-psmux-pill.ps1`** — the refresher
  behind both status pills, operator/VPN and power (§2.7).
- **`40-maint.ps1`** — the Task-Scheduler maintenance control surface (`maint-*`). §7.2.
- **`45-doctor.ps1`** — `dotfiles-doctor`. **`48-core.ps1`** — the `core` umbrella (`core help|doctor|
  version|update [check]|maint <verb>`).

### 1.3 Where each class of state is set

| State | Set in | Notes |
|-------|--------|-------|
| **Encoding / PSModulePath** | `profile.ps1` | UTF-8 no-BOM I/O; local `%LOCALAPPDATA%\PowerShell\Modules` prepended (off OneDrive) |
| **Env vars** | `08-git-safety` (`GIT_TERMINAL_PROMPT`/`GCM_INTERACTIVE`), `00-aliases` (`BAT_THEME=ansi`), `10-tools` (`STARSHIP_CONFIG`, `FZF_DEFAULT_OPTS`/`_COMMAND`, `CARAPACE_BRIDGES`) | `setenv`/`getenv` (os/30) write persistent User-scope vars |
| **PATH** | mise (`activate`/shims) in `10-tools`; `path` verb inspects it | runtime toolchains via mise |
| **Prompt** | starship, `10-tools` → `starship/starship.toml` (**mirrored from Core**) | init cached (§1.4) |
| **Completion** | carapace (opt-in, `10-tools`), repo verbs (`50-completions`), `CompletionPredictor` module feeds PSReadLine | — |
| **History** | atuin (Ctrl+E TUI) + PSReadLine file, `10-tools` | `MaximumHistoryCount 200000`, sensitive-line filter |
| **Aliases / functions** | `00-aliases`, `20-functions`, plus per-domain fragments | every optional-tool alias is `Test-Cmd`-guarded |

### 1.4 Startup-performance profile

This configuration is **aggressively optimised** — the warm hot path spawns effectively
zero tool subprocesses. Mechanisms found (all verified in `10-tools.ps1`):

1. **`Get-InitCache`** — each shell-integration tool (starship, zoxide, mise, atuin, carapace)
   has its init script generated once to `%LOCALAPPDATA%\dotfiles\init-cache\<name>.ps1` and
   dot-sourced thereafter. Two invalidation keys: the tool binary's **mtime** (busts on a
   scoop/winget upgrade) and the **SHA-256 of the generator scriptblock** (busts when flags
   change; stored as a `# initcache-hash:` marker on line 1). Bust manually with `init-cache-clear`.
2. **starship uses `--print-full-init`** (not the stub), so warm shells pay **zero** starship
   spawns at load (~300–650 ms/start saved).
3. **PSFzf is lazy-loaded** — the ~260 ms `Import-Module PSFzf` is deferred; Ctrl+T/Ctrl+R are
   bound to stub scriptblocks that import it on first press (`Invoke-DotLoadPSFzf`).
4. **mise uses `--shims` inside psmux panes** (or with `DOTFILES_MISE_SHIMS=1`) — ~180 ms/split
   cheaper than the full per-prompt hook; distinct caches `mise` vs `mise-shims`.
5. **psmux init-cache fast-path** — inside a pane, `Get-InitCache` skips the expensive
   `Get-Command`/mtime probe and trusts the cache when the generator-hash marker matches.
6. **Off-render background work** — the update nudge and the psmux pill run on `Start-ThreadJob`
   / a background `System.Timers.Timer` (with a delayed first tick), never on the load path.
7. **Opt-out heavies** — Terminal-Icons (~1 s) and carapace (~1.5 s) are **off by default**
   (`DOTFILES_TERMINAL_ICONS=1` / `DOTFILES_CARAPACE=1` to enable).

**Escape hatches** (env vars read before shell start): `FAST_START=1` (skip all heavy init →
stock prompt), `DOTFILES_PROFILE_TRACE=1` (per-fragment + per-tool timing table),
`DOTFILES_MISE_SHIMS=1`, `DOTFILES_PSRL_LISTVIEW=1`, `DOTFILES_CARAPACE=1`,
`DOTFILES_TERMINAL_ICONS=1`, `DOTFILES_NO_GUM=1`, `DOTFILES_ASCII=1`/`NO_COLOR`,
`DOTFILES_UPDATE_CHECK=0`, `DOTFILES_GIT_ALLOW_PROMPT=1`, `PSMUX_NO_AUTOLAUNCH=1`.

**To measure it yourself:** `shell-bench [N]` (times N cold `pwsh -NoLogo -Command exit` runs,
Min/Avg/Max) or `prof-trace` (loads the full profile in a clean child with tracing on and prints
the slowest-first table).

---

## 2. PSMUX ARCHITECTURE & SESSION MANAGEMENT

`psmux` is the **native Windows tmux-alike** (installed via scoop from the `psmux` bucket; puts
`psmux`, `pmux`, and a `tmux` shim on PATH). Its config mirrors Core's tmux keymap and the
tokyonight-storm palette but is **standalone** — it can't run bash status scripts, TPM, or
`clip`, so those are re-implemented natively.

### 2.1 File layout

| Repo file | Symlink | Role |
|-----------|---------|------|
| `psmux/psmux.reset.conf` | `~/.config/psmux/psmux.reset.conf` | the keybinding layer, **sourced first** |
| `psmux/psmux.conf` | `~/.config/psmux/psmux.conf` | options, status line, popups |
| `psmux/scripts/` | `~/.config/psmux/scripts` | popup helper pwsh scripts |

### 2.2 Prefix & options

Prefix is **`C-a`** (screen-style; `C-b` unbound). Key options: `base-index 1`,
`pane-base-index 1`, `escape-time 10`, `history-limit 100000`, `mode-keys vi`, `focus-events on`,
`allow-passthrough on`, `set-clipboard on` (OSC 52). The **mouse trio** — `mouse on`,
`mouse-selection off`, `pwsh-mouse-selection off` — forwards raw clicks to in-pane TUIs (nvim,
lazygit, htop) instead of psmux intercepting them.

### 2.3 The status line (hand-rolled Tokyo Night Storm)

`status-position top`, refreshed every 5 s. The palette is set as `@tn_*` user options; pills use
rounded Nerd-Font caps. **Left**: a session pill whose colour tracks mode (blue normal, orange
when the prefix is held, yellow in copy mode), followed by the operator/VPN IP pill (§2.7).
**Windows**: muted pills, current is blue with a zoom marker when zoomed. **Right**: the cwd
basename (nvim panes only), the clock (`%H:%M`), and the **power pill** right-most — where the
macOS tmux bar puts its battery. Each live segment carries a Nerd-Font glyph.

The power pill is the Windows port of Core's `tmux/scripts/tmux-battery.sh`, so the two terminal
bars draw the identical segment: a level glyph plus percentage, green ≥60 / yellow ≥20 / red <20,
with the glyph swapped for a charging bolt on AC (the colour keeps tracking the level, so a
charging 15 % battery still reads red). On a desktop, where Core draws nothing at all, it falls
back to Zebar's AC placeholder — a lone green plug 󰚥. Written by
`psmux/scripts/psmux-power.ps1` on the same refresher as the VPN pill. Note it deliberately does
*not* use Zebar's scale: the bars are matched terminal-to-terminal and desktop-to-desktop, and
those two references disagree between 40 and 60 % (see `desktop/PARITY.md`).

> **Design rule — no shell spawns on the render path.** psmux expands `status-right`
> *synchronously* on the server's state-push (a blocking `Command::output()`), so a cold
> `pwsh -NoProfile` pill stalled first paint (the "blank screen, blinking cursor" bug). The
> netspeed/CPU pills were **removed entirely**; the VPN and power pills travel as **psmux user
> options** (`@vpn_pill` / `@pwr_pill`), poked in out of band by their refreshers and read by the
> bar as free in-process lookups — the `cmd /c type` cache-file read they replaced measured 88 ms
> per push. `resurrect`/`continuum` are intentionally not loaded (they caused the slow-attach +
> "restored environment" banner). Plugin manager is `ppm` (`prefix + I` to fetch).

> **Gotcha that cost this repo its IP pill.** In PowerShell a bare `@name` in argument position is
> the **splatting operator**, so `psmux set -g @vpn_pill $text` drops the option name from the
> command line entirely; psmux receives one positional and silently discards the command — exit 0,
> nothing on stderr. Always quote: `psmux set -g '@vpn_pill' $text`. Clearing needs `set -gu`
> (unset), because an empty-string argument is dropped the same way. `tests/Repo.Tests.ps1` has a
> static guard.

### 2.4 `warm on` / `destroy-unattached off` (the paired flip)

- **`destroy-unattached off`** lets psmux's hidden `__warm__` standby server persist so a new
  session (auto-attach, or the Ctrl+G sessionizer) claims a pre-warmed server. **Trade-off:**
  detached sessions now **persist and can pile up** — manage with `psmux ls` / `psmux kill-session -t <name>`.
- **`warm on`** pre-spawns pane shells into a background pool, so a new split/window attaches to
  an already-loaded shell instead of paying a cold pwsh + full `$PROFILE` (moves ~350 ms starship
  + ~210 ms atuin off the split keypress). The pool fills at **server** start, so the full effect
  lands on the next fresh psmux launch, not a live `prefix r`.

### 2.5 Popups (the command surface)

| Binding | Script / command | Use |
|---------|------------------|-----|
| `prefix g` | `popup … lazygit` | Git TUI in the pane's cwd |
| `prefix f` | `psmux-sesh.ps1` | Sessionizer: zoxide frecency + project roots → fzf (eza-tree preview) → attach-or-create |
| `prefix w` | `psmux-menu.ps1` | Session/window switcher (fzf → `switch-client`) |
| `prefix T` | `psmux-scratch.ps1` | Scratch terminal (persistent hidden `_popup_scratchpad` session) |
| `prefix u` | `psmux-url.ps1` | Pick a URL off the pane (`capture-pane` → regex → fzf → `clip.exe`) |
| `prefix ?` | `psmux-cheat.ps1` | Searchable cheatsheet (Enter copies the token) |

### 2.6 Session workflows

- **`mux [name]`** (`os/32-psmux.ps1`) = `psmux new-session -A -s <name>` (attach-or-create; default `Gerrrt`).
- **Auto-attach** (`os/30-windows.ps1`): a top-level interactive shell auto-runs `psmux new-session
  -A -s Gerrrt`. Guards: `psmux` present, not already `Test-InMux`, not re-entrant, and
  `PSMUX_NO_AUTOLAUNCH != 1`. Escape hatch: `PSMUX_NO_AUTOLAUNCH=1`.
- **Pane detection**: `Test-InMux` = `[bool]($env:TMUX -or $env:PSMUX_SESSION)` — the single
  source of truth used by mise-shims, the pill, and the init-cache fast-path.
- The bare-prompt **Ctrl+G sessionizer** (`Invoke-DotfilesSessionizer`, §3.2) is the shell twin
  of `prefix f` — both attach-or-create a psmux session.

### 2.7 The status pills (operator/VPN + power)

`psmux-pill-enable` opts a box in (persisted as `DOTFILES_PSMUX_PILL=1`; `-AllNetworks` adds the
plain-LAN IP). In opted-in panes an **in-session `System.Timers.Timer`** (not a Scheduled Task —
avoids elevation) runs **both** refreshers on a background thread (first tick ~2.5 s, then 60 s),
cooperating across panes via the cache file's mtime so only one pane does the work:

| Script | Pokes | Segment |
|--------|-------|---------|
| `psmux-netinfo.ps1` | `@vpn_pill` / `@vpn_fg` | status-left, after the session name |
| `psmux-power.ps1` | `@pwr_pill` / `@pwr_fg` | status-right, right-most |

The VPN pill defaults to **tunnel-only**: an orange pill appears only when a VPN/tunnel adapter is
up (WireGuard/Wintun/OpenVPN/Tailscale/…). The power pill needs no opt-in to *look* right —
`psmux.conf` seeds `@pwr_pill` with the desktop plug via `set -og` (only-if-unset, so a
`prefix + r` reload can't clobber a live reading) — the refresher just keeps it honest on a laptop.
`psmux-pill-disable` clears the IP but deliberately leaves the power pill alone: it's a parity
segment, not an operator indicator.

Commands: `psmux-pill-now`, `psmux-pill-enable`, `psmux-pill-disable`, `psmux-pill-status` (which
reports what the **bar** is reading, not just the cache file).

---

## 3. MODERN TOOL INTEGRATION & INTERACTIVE SEARCH

### 3.1 Capability detection — the `HAVE_*` twin

- **`Test-Cmd <tool>`** (`00-aliases.ps1`) — a cached `Get-Command` probe. Two tiers: an in-session
  map (`$global:DotfilesCmdCache`, `{Found, Source}` per name — the `Source` is reused by
  `Get-InitCache` so no tool is re-resolved) plus a **cross-session on-disk cache**
  (`%LOCALAPPDATA%\dotfiles\cmd-cache.txt`, keyed by a PATH fingerprint) that skips the first-probe
  stat-storm on a cold start / psmux split. Every tool block is `if (Test-Cmd <tool>)`-guarded, so a
  missing tool silently falls back to the classic command.
- **`Test-CmdRuns <tool>`** — the stronger probe: actually launches `--version` to catch a
  *resolved-but-dead* scoop/Chocolatey shim. Used by `fif`/`fbr`.
- Idempotency sentinels (`$global:DotfilesInit`) stop `reload` from re-wiring hooks.

### 3.2 Interactive search — fzf/PSFzf + ripgrep + fd

PSFzf is lazy (§1.4). `FZF_DEFAULT_OPTS` is set eagerly (the tokyonight palette, **generated** from
`theme/palette.toml` by `gen-theme.ps1` — the same source Core renders its zsh `fzf.zsh` from, so the
two are rendered in step rather than kept in step by hand); `FZF_DEFAULT_COMMAND = fd --type f --hidden --follow --exclude .git`
when `fd` is present. The **final widget map** after atuin's init is re-asserted:

- **Ctrl+T** — PSFzf file picker (lazy).
- **Ctrl+R** — PSFzf fuzzy history (lazy; falls back to PSReadLine `ReverseSearchHistory` if PSFzf absent).
- **Ctrl+E** — atuin's full-history TUI (`Invoke-AtuinSearch`).
- **Ctrl+G** — the sessionizer (zoxide frecency + `$HOME\Projects|dev|work|.config` → fzf → `Set-Location` → `psmux new-session -A`).
- **Alt+Z** — zoxide interactive jump (`zi`).

> atuin's init ignores `ATUIN_NOBIND` and grabs Ctrl+R + arrows on load; the atuin block therefore
> **re-asserts** the arrows to prefix-history-search, moves atuin to **Ctrl+E**, and re-binds
> Ctrl+R to the fzf stub — so Ctrl+R stays quick-fzf-history and Ctrl+E is the deep TUI, matching zsh.

### 3.3 Directory traversal — zoxide

`zoxide init powershell --cmd cd` rebinds `cd` itself to zoxide (`z`/`zi` also available). `cdi`
aliases the interactive `zi`.

### 3.4 History — atuin + PSReadLine

PSReadLine keeps a 200 000-entry file history with `HistoryNoDuplicates`; atuin holds the real
searchable store. An `AddToHistoryHandler` returns **`MemoryOnly`** for any line matching
`Test-SensitiveHistoryLine` (op read/run verbs, `--password`/`--token`/`--secret` flags, secret
keywords) so credentials never hit the history file.

### 3.5 Modern visual replacements

All `Test-Cmd`-guarded; see the matrix (§4.1). `cd` → zoxide, `ls` → eza, `cat` → bat, `grep` →
rg, `du` → dust, `df` → duf, `top`/`htop` → btop, `watch` → viddy, `ping` → gping, `dns` → doggo,
`md` → glow (`gmd`), `fm`/`y` → yazi, `hex` → hexyl, `loc` → tokei.

### 3.6 Init caching (cold-start) & 3.7 multiplexing ↔ TUIs

Covered in §1.4 (`Get-InitCache`) and §2.2 (the mouse trio). In a split, panes inherit the env so
mise uses shims + the init-cache fast-path; popups (`display-popup -E`) are overlays, not panes, so
the active pane stays the key-press target (used by `psmux-url.ps1`'s `capture-pane`).

---

## 4. COMPREHENSIVE COMMAND & SHORTCUT MATRIX

> `Test-Cmd`-guarded entries fall back to the classic command when the modern tool is absent.
> `prefix` = `C-a`.

### 4.1 Shell — modern-stack aliases (`00-aliases.ps1`)

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| eza | `ls`/`l`/`ll`/`la`/`lt`/`llt` | `eza` (fallback lsd → `Get-ChildItem`) | Rich listing / tree view with git status |
| bat | `cat` / `catp` | `bat --paging=never` / `bat` | Syntax-highlighted file view (paged variant) |
| ripgrep | `grep` | `rg --smart-case` | Case-smart code search |
| fd | *(feeds fzf/fif)* | `fd --type f --hidden --follow --exclude .git` | Fast, gitignore-aware find |
| zoxide | `cd` / `cdi` | `z` / `zi` | Frecency dir jump / interactive pick |
| dust | `du` | `dust` | Visual disk-usage tree |
| duf | `df` | `duf` | Mountpoint-aware disk free |
| procs | `pss` | `procs` | Colourised process list |
| btop | `top`/`htop` | `btop` | Interactive resource monitor |
| viddy | `watch` | `viddy` | Re-run a command on interval with diff highlight |
| gping | `ping` | `gping` | Latency graph in the terminal |
| doggo | `dns` | `doggo` | Modern DNS lookup |
| xh | `http`/`https` | `xh` | Poke an API/web target |
| glow | `gmd` | `glow` | Render Markdown |
| yazi | `fm`/`y` | `yazi` | TUI file manager |
| hexyl / tokei | `hex` / `loc` | `hexyl` / `tokei` | Hex dump / count lines of code |
| nvim | `vim` | `nvim` | Edit |

### 4.2 Shell — custom functions (`20-functions.ps1`)

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| nav | `mkcd <dir>` / `cdup [n]` / `..`,`...`,`....` / `~` | make+enter / climb n / relative up | Move around fast |
| nav | `fcd` | fd → fzf → `Set-Location` | Fuzzy jump to a subdir |
| net | `myip` / `myip-full` / `localips` / `ports` | public IP / detail / local IPs / listeners | Quick network facts |
| files | `extract <archive>` / `compress` / `mkbak <file>` | multi-format unpack / pack / timestamped `.bak` | Safe archive & snapshot ops |
| misc | `please` / `genpw [n]` / `pullall [dir]` | elevated re-run / random password / parallel ff-pull | "forgot admin", secrets, morning refresh |
| misc | `serve [-Local] [port]` / `cheat <cmd>` | HTTP server + URL / `cht.sh` | Ad-hoc transfer / quick reference |
| clip | `pbcopy` / `pbpaste` | `Set-/Get-Clipboard` | Mac-muscle-memory clipboard |
| search | `fif <term>` | `rg -l` → fzf → nvim | Find which files contain text |
| tv | `tvim`/`ttext`/`tcd`/`trepo`/`tbranch`/`tenv` | television channels | Fuzzy pick files/dirs/repos/branches |
| doctor/help | `dotfiles-doctor` / `dothelp [-Interactive]` / `core …` | health audit / command index / umbrella | Diagnose & discover |

### 4.3 Shell — git aliases & fuzzy helpers (`00-aliases.ps1`, `20-functions.ps1`)

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| git | `g` / `gst` / `gss` / `gsb` | `git` / status / `-s` / `-sb` | Base verb + status |
| git | `ga` / `gaa` / `gap` | add / `--all` / `--patch` | Stage files / hunks |
| git | `gc` / `gcm` / `gca` / `gc!` / `gcn!` | commit `-v` / `-m` / `-a` / `--amend` / `--amend --no-edit` | Commit variants |
| git | `gco` / `gcb` / `gsw` / `gswc` / `gcom` / `gswm` | checkout / `-b` / switch / `--create` / trunk (`Get-DotGitMainBranch`) | Branch switching |
| git | `gd` / `gds` / `gdw` | diff / `--staged` / `--word-diff` | Review changes |
| git | `glog` / `glol` / `glola` | graph log variants | Visual history |
| git | `gf` / `gfa` / `gl` / `gpr` | fetch / `--all --prune --tags` / pull / `--rebase` | Sync from remote |
| git | `gp` / `gpu` / `gpf` / `gpf!` | push / `-u origin HEAD` / `--force-with-lease` / `--force` | Push / **safe** force vs raw |
| git | `gsta`/`gstp`/`gstl` · `grb*` · `grh*`/`grs*` | stash · rebase (`-i`/trunk/continue/abort) · reset/restore | WIP, rebase, undo |
| git | `gaf` / `grf` / `grsf` | fzf multi-select add / restore / unstage | Fuzzy stage/discard by file |
| lazygit | `lg` | `lazygit` | Full TUI git |
| difftastic | `gdft [ref]` | `git difftool --tool=difftastic` | Structural (AST) diff |
| jujutsu | `jjs`/`jjl`/`jjd` | `jj status`/`log`/`diff` | Opt-in jj on the same repo |

### 4.4 Shell — PSReadLine key bindings (Vi mode)

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| PSReadLine | `EditMode Vi` | modal editing (parity with zsh-vi-mode) | Vim keys at the prompt |
| PSReadLine | `Up` / `Down` | `HistorySearchBackward/Forward` | Prefix-filtered history |
| PSReadLine | `Tab` | `MenuComplete` | Cycle completion menu |
| PSReadLine | `Ctrl+←` / `Ctrl+→` | `BackwardWord` / `NextWord` (both Vi modes) | Jump by word while editing |
| PSReadLine | `Ctrl+t` | PSFzf file picker (lazy) | Insert a fuzzy-picked file |
| PSReadLine | `Ctrl+r` | PSFzf fuzzy history (lazy) | Quick history search |
| PSReadLine | `Ctrl+e` | `Invoke-AtuinSearch` | Atuin full-history TUI |
| PSReadLine | `Ctrl+g` | `Invoke-DotfilesSessionizer` | Session/project picker → psmux |
| PSReadLine | `Alt+z` | zoxide `zi` | Fuzzy dir jump |
| PSReadLine | `Ctrl+\` | toggle `PredictionSource` on/off | Silence autosuggestions |
| PSReadLine | `F2` | `SwitchPredictionView` | Flip Inline ↔ List prediction |

Prediction is `HistoryAndPlugin`, **InlineView by default** (`DOTFILES_PSRL_LISTVIEW=1` for List),
Tokyo Night colours. A version guard warns if PSReadLine < 2.2.0 (bracketed-paste safety).

### 4.5 psmux — prefix bindings (`C-a`)

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| psmux | `prefix C-a` / `prefix r` | last-window / reload conf | Toggle windows / apply edits |
| window | `prefix c` / `,` / `&` | new / rename / kill window (keeps path) | Window lifecycle |
| session | `prefix S` / `d` / `R` | choose-session / detach / refresh-client | Session control |
| pane | `prefix h/j/k/l` *(also root, no prefix)* | select-pane L/D/U/R | Move focus (vim keys) |
| pane | `prefix \|` / `-` / `\` / `_` | split V / H / full-height / full-width (keeps path) | Split panes |
| pane | `prefix H/J/K/L` | resize ±5 (**not** repeatable — avoids stuck prefix pill) | Resize |
| pane | `prefix m` / `x` / `X` / `*` / `P` / `F` | zoom / kill / swap-down / sync-panes / border-titles / floating popup | Pane verbs |
| window | `M-H` / `M-L` (Alt+Shift, no prefix) | previous / next window | Cycle windows |
| copy | `prefix Enter` · `v`/`C-v`/`y` | copy-mode · select / rectangle / copy-pipe `clip.exe` | Scrollback & yank to clipboard |

### 4.6 psmux root-table & Windows Terminal keys (`windows-terminal/settings.json`)

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| psmux | `C-h/j/k/l` (no prefix) | select-pane L/D/U/R | Move panes without the prefix |
| WT | `alt+↑/↓/←/→` | MoveFocus | Pane focus (WT owns Alt+arrow) |
| WT | `alt+shift+plus` / `alt+shift+minus` | SplitPaneRight / SplitPaneDown | Split at the terminal level |
| WT | `ctrl+shift+w` / `ctrl+shift+f` | ClosePane / FindText | Close pane / find |
| WT | `ctrl+alt+↑/↓` | scrollToMark previous/next | Jump between shell prompts |

WT ships **Tokyo Night**, CaskaydiaCove Nerd Font 16, `copyOnSelect`, 90% acrylic, atlas engine;
default profile is PowerShell (`pwsh -NoLogo`), with a `kali-linux` WSL profile and a JetBrains-Mono variant.

### 4.7 WSL bridge (`os/31-wsl-bridge.ps1`)

| Trigger | Logic | Use |
|---------|-------|-----|
| `kali` / `wsls` / `wslip` | `wsl -d kali-linux` / `--list --verbose` / distro IP | Enter Kali / list distros / get its IP |
| `cdwsl` | `ConvertTo-WslPath` (`C:\…`→`/mnt/c/…`) then open a shell there | Jump into WSL at the current dir |
| `hostip` / `wslhome` / `wsl-restart` | host IPv4 / `~` in the distro / `wsl --shutdown` | Host↔guest glue |

The host seeds `~/.wslconfig` (from `wsl/windows.wslconfig.example`: `networkingMode=mirrored`,
`firewall`, `localhostForwarding`, memory/CPU caps) but **does not** configure the distros — Core
and Kali do that from inside WSL.

---

## 5. SECURITY POSTURE & CREDENTIAL HANDLING

### 5.1 Secrets & credential audit

**No plaintext secrets are committed.** Git identity is prompted at install and written to the
**gitignored** `~/.gitconfig.local`; per-machine overrides live in the gitignored
`powershell/local.ps1`. `.gitignore_global` carries an explicit secrets block (`*.pem`, `*.key`,
`.env`, `.env.*`, `local.ps1`, `.gitconfig.local`, `**/.claude/settings.local.json`).
`commit.gpgsign` is present but commented (enable after setting `signingkey` in `.gitconfig.local`).

### 5.2 git-safety & history hygiene

- **Anti-hang git** (`08-git-safety.ps1`, loaded early): unless `DOTFILES_GIT_ALLOW_PROMPT=1`, sets
  `GIT_TERMINAL_PROMPT=0` + `GCM_INTERACTIVE=Never` so shell-spawned/background git **fails fast**
  instead of blocking on an unanswerable credential prompt — which previously left orphaned
  `git.exe` processes that locked the binary against updates. `git-reap` (`Reset-StuckGit`, supports
  `-WhatIf`) kills any stray `git`/`git-remote-https`/`git-credential-manager`.
- **History filter** (§3.4): `Test-SensitiveHistoryLine` keeps op/secret/token lines out of the
  PSReadLine history file (`MemoryOnly`); `Read-DotInput` supports masked input.
- **Credential store**: Git Credential Manager (`credential.helper = manager`, ships with Git for Windows).

### 5.3 1Password / age / croc helpers

- **1Password** (`40-op.ps1`, no-op if `op` absent): `opsecret <vault/item/field>` (`op read`),
  `openv <.env.op> <cmd…>` (`op run --env-file`), `optoken <item>` (TOTP → clipboard), `opssh` (list SSH-key items).
- **age / croc** (`45-crypto.ps1`): `age-enc`/`age-dec`/`age-enc-pw`, `age-setup`/`age-pubkey`
  (recommends backing up the age key in 1Password); `send`/`recv` for croc transfers.

---

## 6. WINDOWS DESKTOP & WINDOW MANAGEMENT

The `desktop/` tier is **opt-in and off the critical path** — the rest of the repo makes the
*shell host* excellent; this layer tiles and themes the desktop (Tokyo Night Storm). Config files
are symlinked into `~/.glzr` regardless of package selection, so opting in later is just a package
re-run.

### 6.1 GlazeWM — tiling WM (`desktop/glazewm/config.yaml`)

The keymap is kept keystroke-for-keystroke identical to the Mac's AeroSpace config. New windows
tile; focused border is blue `#7aa2f7`. `startup_commands` launches Zebar; `outer_gap` leaves
`50px` at top for the bar. Five workspaces (`"1"`–`"5"`).

| Binding | Action |
|---------|--------|
| `Alt+H/J/K/L` | Focus left/down/up/right |
| `Alt+Shift+H/J/K/L` | Move window |
| `Alt+U/P` · `Alt+O/I` | Width −/+2% · height +/−2% |
| `Alt+R` → `H/L/K/J` | Enter resize mode, then nudge (`Esc`/`Enter` exits) |
| `Alt+V` / `Alt+Shift+Space` / `Alt+F` | Toggle tiling direction / floating (centered) / fullscreen |
| `Alt+Shift+Q` | Close window |
| `Alt+Enter` | `shell-exec wt` (launch Windows Terminal) |
| `Alt+A` / `Alt+S` / `Alt+D` | Prev / next / recent workspace |
| `Alt+1..5` · `Alt+Shift+1..5` | Focus workspace n · move window to n + follow |
| `Alt+Shift+R` | Reload config (live) |

Some upstream binds are deliberately dropped for parity/collision-avoidance (notably `Alt+arrow`,
owned by Windows Terminal); quit GlazeWM via its tray icon.

### 6.2 Zebar — the top bar (`desktop/zebar/vanilla-clear/`)

A buildless React widget pack (Zebar `@3`), transparent, anchored top-center, 52 px, on all
monitors. Module order is kept at parity with the Mac's SketchyBar: **left** logo · workspaces ·
binding-mode (Windows-only) · front-app · pomodoro; **center** clock; **right** network · volume ·
disk · memory · cpu · battery · weather · power. Interactive widgets: a **Pomodoro** (25/5,
click start/pause, right-click reset) and a **Power menu** (lock/sleep/restart/shutdown). The power
menu uses Zebar `shellExec` with a **whitelist** — `zpack.json` `privileges.shellCommands` allows
exactly `shutdown` and `rundll32` with `argsRegex` guards; any undeclared command is refused.

### 6.3 Install & opt-in

Four apps ship in the **`desktop` optional winget group** (`packages/winget.json`):
`glzr-io.glazewm`, `glzr-io.zebar`, `Microsoft.PowerToys`, `CharlesMilette.TranslucentTB`. Group
selection is resolved once by `Install-Packages.ps1` (a `gum` multi-select, all on by default) and
persisted to `powershell/local.ps1` as `$env:DOTFILES_PKG_GROUPS`. Deselect `desktop` on a
shell-only box. A one-time manual step adds GlazeWM to login startup and enables the widget in Zebar.

---

## 7. MAINTENANCE, UPDATE & PROVISIONING

### 7.1 `up` — the interactive updater (`core/15-update.ps1`)

`up` runs `scoop update; scoop update *; scoop cleanup *` then `winget upgrade --all
--include-unknown` (adds `--silent --accept-*-agreements` with `up -y`). `up -Preview`/`-n` lists
pending and changes nothing. No elevation (both are user-space). A throttled once/day background
**nudge** (`Start-ThreadJob`) prints "N update(s) available — run 'up'"; `update-check` forces a
sync refresh; `DOTFILES_UPDATE_CHECK=0` disables it. Scoop/winget convenience verbs: `scu`/`scs`/
`sci`/`scl`/`sccl`, `wgu`/`wgs`/`wgi`.

### 7.2 `Maintenance.ps1` + the Task-Scheduler control surface

- **`maint/Maintenance.ps1`** — the unattended runner (Windows port of Core's maint script). Every
  step is labelled + `try/catch` (one failure never aborts); single-instance lock; logs to
  `%LOCALAPPDATA%\dotfiles\maint\maint.log` (rotated). Steps (all user-space): scoop update/cleanup,
  re-creating scoop's junctions admin-trusted (a no-op unless elevated — see below),
  `mise plugins update` + `mise upgrade`, headless neovim `Lazy! sync`/`TSUpdateSync`/`MasonUpdate`
  (timeout-guarded), `Save-Module` for the pinned PS modules. **winget upgrade
  is opt-in** (`MAINT_WINGET_UPGRADE=1`) since it can launch MSI installers. Knobs: `MAINT_ENABLED`,
  `MAINT_NVIM_TIMEOUT`.
- **`os/40-maint.ps1`** — the control surface (Task Scheduler is the systemd/cron analog):
  `maint-install [HH:MM]` (default 13:00; `-StartWhenAvailable`, battery-tolerant, 1 h limit),
  `maint-run` (foreground now), `maint-log [N|-f]`, `maint-status`, `maint-uninstall`.
  Run from an **elevated** shell it also registers `dotfiles-maint-scoop-junctions`,
  which runs as SYSTEM an hour after the daily job and re-creates scoop's junctions so
  an ssh session can traverse them. The daily task stays unelevated on purpose —
  `scoop update` must never run as admin. See `maint/Repair-ScoopJunctions.ps1`.
  Both tasks are registered against a **version-stable** pwsh where one exists: a task
  bakes an absolute path, and a Store pwsh lives in a version-pinned package dir that
  vanishes on update, after which the task fails `0x80070002` writing nothing to the
  log. `maint-status` shows each task's `Execute` and flags a missing one.

### 7.3 `packages/` — declare, install, freeze, freshness

- **Declaration**: `scoopfile.json` (buckets + ~52 apps, optional `Version`/`group`), `winget.json`
  (core ids always installed; `gui`/`desktop` grouped), `modules.ps1` (PS modules pinned exactly:
  PSReadLine 2.3.6, Terminal-Icons 0.10.0, PSFzf 2.4.0, CompletionPredictor 0.1.0).
- **Install** (`Install-Packages.ps1`, resilient/idempotent): bootstraps scoop (optional
  `DOTFILES_SCOOP_SHA256` gate), installs missing apps, `Save-Module` into the off-OneDrive module
  dir. Optional groups resolved via `DOTFILES_PKG_GROUPS` env > `gum` multi-select > install-all.
  Flags: `-SkipScoop`/`-SkipWinget`/`-Frozen`/`-NonInteractive`.
- **Freeze** (`-Frozen`): pins every app to `packages.lock.json`; **hard-stops** if the lock is
  missing; an app with no lock entry is **skipped**, not floated ("frozen means frozen").
- **Lock generation** (`Update-PackageLock.ps1`): reads installed versions via `scoop export` +
  `winget export --include-versions`, restricts to the managed set, writes byte-clean LF JSON.
  > **Gotcha** (see also `RELEASE-RUNBOOK.md` §3b): `winget export` omits an installed app it can't
  > map to a winget source (even though `winget install`/`upgrade` see it via ARP) — so the
  > regenerated lock **drops** that pin. Confirm with `winget list --id <id>` and re-add the line,
  > or `winget uninstall`+`install` it to register the source.
- **Freshness** (`Check-PackageFreshness.ps1`, CI, findings-only): compares each managed app's
  upstream version against the lock and writes a markdown table when anything is behind.

### 7.4 Install & dev entry points

- **`bootstrap.ps1`** — one-liner remote bootstrap (`irm … | iex`, SHA-gated). Env-driven
  (`DOTFILES_REPO`/`DOTFILES_REF`/`DOTFILES_BOOTSTRAP_ARGS`); requires pwsh 7 + git; clones or
  `pull --ff-only`, then hands off to `install.ps1`.
- **`install.ps1`** — 5 steps: set `DOTFILES_WIN` → install packages → wire symlinks (Developer
  Mode or elevation; **falls back to copy** with a warning) → seed `~/.wslconfig` → seed
  `local.ps1` + prompt git identity into `~/.gitconfig.local`. Flags: `-SkipPackages`, `-DryRun`,
  `-NonInteractive`, `-Yes`. Idempotent (skips already-correct links).
- **`uninstall.ps1`** — removes only symlinks that resolve back into this repo; leaves your data
  (`DOTFILES_WIN`, `~/.wslconfig`, `~/.gitconfig.local`, `local.ps1`) untouched. `-RestoreBackups`
  restores the newest `.bak` per link.
- **No Makefile.** The Pester suite (`tests/`, ~24 `*.Tests.ps1` + a coverage gate) validates
  bootstrap/install/uninstall round-trips, the load contracts (`# provides:`/`# requires:` per
  fragment), secret redaction, the package lock, nvim/starship parity, the WSL path translator, and
  cold-start invariants — run via `tests/Invoke-Validation.ps1` (CI: `.github/workflows/ci.yml`).

---

## 8. EDITOR & VERSION-CONTROL TOOLING

### 8.1 Neovim (`nvim/`, **mirrored from Core**)

`nvim-sync.ps1` mirrors Core's `nvim/` (incl. `lazy-lock.json`) via `robocopy /MIR`; flags
`-Ref <tag>` (reproducible pin), `-CoreLocal`, `-Branch`. Provenance is stamped into
`nvim/.core-ref`. The whole dir is symlinked to **`%LOCALAPPDATA%\nvim`** — that is where Windows
nvim reads config. Namespace `gerrrt` (`init.lua` = `require("gerrrt")`), **leader = Space**,
lazy.nvim plugin manager, netrw disabled (nvim-tree owns files). *(Do not hand-edit — fix upstream
in dotfiles-core and re-sync.)*

### 8.2 lazygit

No standalone config here (it lives in Core). Shell launcher `lg` (`00-aliases.ps1`); the nvim
plugin `kdheepak/lazygit.nvim` opens a LazyGit float on `<leader>gl`.

### 8.3 mise (runtime manager)

Activated in `10-tools.ps1` (`mise activate pwsh`, or `--shims` in psmux panes / with
`DOTFILES_MISE_SHIMS=1`; cached). **No mise config is shipped** — mise resolves per-directory
`.mise.toml`/`.tool-versions` at runtime.

### 8.4 jujutsu (`jj/config.toml`)

The host twin of Core's jj config (native copy, hand-maintained), symlinked to
`%APPDATA%\jj\config.toml`. Opt-in, colocated companion to git — never replaces it. `default-command = "log"`
(bare `jj` = `jj log`), `pager = ":builtin"` (Windows-safe), `auto-local-bookmark = true`; aliases
`l`/`st`. Identity is **not** hardcoded (`jj config set --user`). Shell verbs `jjs`/`jjl`/`jjd`.

### 8.5 git (`git/.gitconfig`, `.gitignore_global`)

`editor = nvim`, `pager = delta` (`syntax-theme = ansi`, true-color), **`autocrlf = true`** and
**`longpaths = true`** (Windows), `fsmonitor`/`untrackedCache` on. `diff.algorithm = histogram`,
`colorMoved`, difftastic wired as opt-in `git dft`. `merge.conflictstyle = zdiff3`, `rerere` on,
`pull.rebase = true`, `push.default = current` + `autoSetupRemote` + `followTags`. **URL rewrite**
clones HTTPS but pushes SSH (`pushInsteadOf`). Credential helper = **manager** (GCM). Per-directory
identity via `includeIf gitdir:~/work/`/`~/clients/`; private identity via the gitignored
`~/.gitconfig.local`. Fleet-parity aliases (`st`, `lg`, `graph`, `pushf` = `--force-with-lease`,
`wt`/`wa`/`wlist` worktrees, `wip`/`unwip`, `undo`, …).

### 8.6 starship & ssh

- **starship** (`starship/starship.toml`) — **mirrored from Core** via `starship-sync.ps1`
  (cross-shell, so it's synced not hand-edited; provenance in `starship/.core-ref`). Its
  `command_timeout` is what `08-git-safety` relies on to reap a wedged prompt-git.
- **theme** (`theme/palette.toml`) — **mirrored from Core** via `theme-sync.ps1` (provenance in
  `theme/.core-ref`), then rendered into `powershell/core/` and `psmux/` by `gen-theme.ps1`. It is
  an INPUT rather than a leaf config, so a stale copy looks perfectly consistent locally; the
  `theme vendor` doctor row is what surfaces it on the host.
- **ssh** (`ssh/config` → `~/.ssh/config`) — hardened `Host *`: `AddKeysToAgent`, `IdentitiesOnly`,
  `ServerAliveInterval`, `HashKnownHosts`, curve25519/chacha20 KEX/ciphers/etm-MACs. **No
  ControlMaster** (Windows OpenSSH can't multiplex — noted explicitly).

---

## APPENDIX: COVERAGE LEDGER

What this manual documents, end to end:

| Tier | Files | Section |
|------|-------|---------|
| Shell init | `powershell/profile.ps1`, `Dotfiles/`, `core/{00,05,08,10,15,55,57}` | §1 |
| psmux | `psmux/psmux.conf`, `psmux.reset.conf`, `psmux/scripts/`, `os/{30,32,33}` | §2 |
| Modern CLI | `core/{00,10,20,25}` | §3 |
| Command matrix | aliases + functions + git + PSReadLine + psmux + WT + WSL | §4 |
| Security | `core/{08,40,45}`, `Dotfiles` (`Test-SensitiveHistoryLine`), `git/`, `ssh/config` | §5 |
| Desktop/WM | `desktop/{glazewm,zebar}`, the `desktop` winget group | §6 |
| Maintenance/install | `core/15`, `maint/Maintenance.ps1`, `os/40`, `packages/`, `install.ps1`/`bootstrap.ps1`/`uninstall.ps1`, `tests/` | §7 |
| Editor/VCS | `nvim/` (mirrored), lazygit, mise, `jj/`, `git/`, `starship/` (mirrored), `ssh/` | §8 |

**Reading-depth caveat (honest):** the large modules — `core/10-tools.ps1`, `core/20-functions.ps1`,
`maint/Maintenance.ps1`, `packages/Install-Packages.ps1`, and the mirrored `nvim/` (~90 Lua files)
— are documented at the level of *every capability and command they expose*, not line-by-line. For
a per-line audit of any single module, that's a targeted follow-up.

---

*Generated by a read-only audit of `dotfiles-Windows` — the native-host layer of the eleven-repo
system — covering the PowerShell shell, psmux, the tiling desktop, maintenance/packages, and the
editor tiers. `nvim/`, `starship/starship.toml` and `theme/palette.toml` are **mirrored from
`dotfiles-core`** (via `nvim-sync.ps1` / `starship-sync.ps1` / `theme-sync.ps1`): change those
upstream in dotfiles-core and re-sync, never hand-edit here. The same goes for any hex inside a
`# core:theme:gen` marker and for the `Tokyo Night` scheme in `windows-terminal/settings.json` —
those are rendered from the palette by `gen-theme.ps1`. Everything else (`powershell/`, `psmux/`, `desktop/`, `packages/`, `git/`, `jj/`,
`ssh/`, `wsl/`, the entry points) is edited here directly — this repo vendors no `core/` subtree.*
