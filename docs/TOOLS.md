# TOOLS.md — host toolchain

The guiding rule for this repo: **the Windows host owns the daily-driver shell
and the terminal experience.** Offensive tooling is not installed or configured
here — it lives on the **Kali station** (its own repo, inside WSL). See that
repo for the offensive catalog.

## Terminal / productivity (native host, via scoop)

| Tool              | Replaces   | scoop name            | Notes                                                    |
| ----------------- | ---------- | --------------------- | -------------------------------------------------------- |
| starship          | prompt     | `starship`            | Same `starship.toml` as the fleet (now tokyonight-storm) |
| zoxide            | `cd`       | `zoxide`              | `cd` is rebound to `z` in core                           |
| fzf               | —          | `fzf`                 | + PSFzf module for Ctrl+t / Ctrl+r                       |
| ripgrep           | grep       | `ripgrep`             | `grep` shadowed by `rg --smart-case`                     |
| fd                | find       | `fd`                  | named `fd` on Windows (no rename)                        |
| bat               | cat        | `bat`                 | `cat` shadowed; `catp` for paged                         |
| eza / lsd         | ls         | `eza` / `lsd`         | eza preferred; lsd is the fallback                       |
| delta             | diff pager | `delta`               | wired into `.gitconfig` (full decorations)               |
| bottom / btop-lhm | top        | `bottom` / `btop-lhm` | `btop-lhm` reads hardware sensors                        |
| lazygit           | —          | `lazygit`             | `lg`                                                     |
| yazi              | file mgr   | `yazi`                | TUI file manager                                         |
| atuin             | history    | `atuin`               | optional shell history sync                              |
| neovim            | editor     | `neovim`              | config vendored from Core (see nvim/)                    |
| jq / yq           | —          | `jq` / `yq`           | JSON/YAML wrangling                                      |
| hyperfine         | `time`     | `hyperfine`           | benchmarking                                             |
| tlrc              | man        | `tlrc`                | `tldr` client (Rust)                                     |

### 2026 additions (fleet parity with Core's `tools.zsh`)

| Tool  | Replaces    | scoop name            | Alias                                         | Notes                                                                                                                                                                                |
| ----- | ----------- | --------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| xh    | curl/HTTPie | `xh`                  | `http` / `https`                              | Rust HTTPie — poke APIs / web targets                                                                                                                                                |
| glow  | —           | `glow`                | `gmd`                                         | render markdown in the terminal (engagement notes/READMEs); `gmd` (not `md`, which is the built-in mkdir)                                                                            |
| doggo | dig         | `doggo`               | `dns`                                         | modern dig (DNS recon)                                                                                                                                                               |
| sd    | sed         | `sd`                  | —                                             | intuitive find/replace; own verb (never shadows sed)                                                                                                                                 |
| gron  | —           | `gron`                | —                                             | greppable JSON                                                                                                                                                                       |
| jnv   | —           | `jnv`                 | —                                             | interactive JSON explorer (jq-filter editor + collapsible viewer); own verb — `jnv file.json` or pipe in. The "explore" to jq's "transform" and gron's "grep".                       |
| lynx  | —           | `lynx`                | `web`                                         | terminal web browser. `web` resolves `w3m`→`lynx`→`links`→`elinks` (w3m has no scoop manifest; lynx is the default). GUI host, so `$BROWSER` is not exported.                        |
| gum   | —           | `gum`                 | —                                             | shell-script UI widgets (Charm)                                                                                                                                                      |
| tv    | —           | `television` (extras) | `tvim` `ttext` `tcd` `trepo` `tbranch` `tenv` | television fuzzy finder; wrappers in `core/25-television.ps1`. NOT given Ctrl+R (atuin owns it) — named verbs only. Channel availability (`dirs` etc.) depends on tv's cable config. |

Aliases are **guarded** (`if (Test-Cmd ...)`) the same way the zsh aliases are —
on a box where a tool isn't installed, the classic command is untouched.

### Mid-2026 additions (host gaps)

Filling holes the stack above didn't cover — each is deliberately **not** a
duplicate of an existing tool:

| Tool                | Replaces / adds     | scoop name  | Notes                                                                                                   |
| ------------------- | ------------------- | ----------- | ------------------------------------------------------------------------------------------------------- |
| lsd                 | ls (eza fallback)   | `lsd`       | The `eza`-fallback the tables above already assumed — now actually installed, not just documented.      |
| gsudo               | sudo                | `gsudo`     | A real in-session `sudo` for Windows (cached elevation, `gsudo !!`); covers Win10 where native `sudo` is absent. |
| watchexec           | —                   | `watchexec` | Run a command **on file change** — the change-driven complement to `viddy`'s interval re-run.           |
| trippy (`trip`)     | mtr / traceroute    | `trippy`    | Traceroute + ping TUI; the hop/path analysis `gping`/`doggo` don't do.                                  |
| ast-grep (`sg`)     | —                   | `ast-grep`  | Structural (AST-aware) code search/replace; complements `rg` + `sd` for real refactors.                 |

> **Lockfile:** `packages.lock.json` was reconciled with these five apps — and the
> later `jnv` / `lynx` — from the ScoopInstaller **Main** bucket manifests (the same
> source `Update-PackageLock.ps1` queries) so the drift gate stays green. Re-run
> `packages/Update-PackageLock.ps1` on a Windows host to confirm against your
> actually-installed versions.
>
> The interactive JSON-explorer gap is now filled by **`jnv`** (scoop Main; the same tool
> Core detects as `HAVE_JNV`) — a jq-filter editor with a collapsible viewer, sitting between
> `jq` (transform) and `gron` (grep). `jless` was the earlier candidate and stays **left
> out** — it isn't in the scoop Main/Extras buckets and its Windows support is weak; install
> via `cargo install jless` if you specifically want it.

### From the awesome-windows sweep

A pass over the `awesome-windows` catalogue (mostly GUI apps) surfaced three
CLI tools that fit the shell-first host and weren't already covered:

| Tool   | Adds                | scoop name         | Notes                                                                                          |
| ------ | ------------------- | ------------------ | ---------------------------------------------------------------------------------------------- |
| yt-dlp | media downloader    | `yt-dlp`           | Feature-rich audio/video downloader; pairs with `mpv`.                                          |
| restic | backup / snapshots  | `restic`           | Fills a real gap — the stack had **no** backup tool. Encrypted, incremental, dedup.            |
| mpv    | media player        | `mpv` (extras)     | Scriptable, keyboard-driven player — fits the terminal ethos better than a GUI player.         |

Same lockfile handling as above: `packages.lock.json` reconciled from the Main/Extras
bucket manifests; re-run `packages/Update-PackageLock.ps1` on a Windows host to confirm.

The heavier picks from the same sweep were then added too, each in its proper home
rather than the always-on CLI core:

| Tool      | Home                          | Notes                                                                                                       |
| --------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------- |
| syncthing | `scoopfile.json` (`main`)     | P2P file sync. Ships the binary only — you still run/enable the service yourself.                            |
| tailscale | `scoopfile.json` (`extras`)   | Mesh VPN; pairs with the WSL bridge for host↔WSL↔remote reach. Binary only; `tailscale up` to enroll.       |
| ShareX    | `winget.json` **`gui` group** | Screenshot/capture/annotate power-tool. GUI, so it lives in the opt-out `gui` winget group (like QuickLook), not the scoopfile. |

`tailscale`/`syncthing` install as plain scoop binaries (no service auto-starts),
and `ShareX` opts out with the rest of the `gui` group via `DOTFILES_PKG_GROUPS`.

## Version control — jj (jujutsu, opt-in)

[jj](https://github.com/jj-vcs/jj) is a git-compatible VCS that works on a
**colocated** repo: it reads and writes the same `.git` directory, so it never
replaces git and you can stop using it at any time. Installed from scoop `main`;
config at `jj/config.toml`, symlinked to `%APPDATA%\jj\config.toml`.

| Verb  | Runs        |
| ----- | ----------- |
| `jjs` | `jj status` |
| `jjl` | `jj log`    |
| `jjd` | `jj diff`   |

All three are guarded on `Test-Cmd jj`, so they simply don't exist on a box
without it — the same opt-in shape as the rest of `00-aliases.ps1`.

**Identity is not committed.** `jj/config.toml` ships with `[user]` name/email
deliberately commented out, because the file is tracked and jj does not inherit
git's identity. Set it per-machine:

```powershell
jj config set --user user.name  "Your Name"
jj config set --user user.email "you@example.com"
```

One deliberate divergence from Core's `jujutsu/config.toml`: `pager = ":builtin"`
rather than `less -FRX`, since `less` is absent on a stock Windows box. Bare `jj`
runs `log` (`default-command`), and `auto-local-bookmark` imports git branches as
jj bookmarks so a colocated repo stays legible from both sides.

## Encryption & transfer — age + croc

`powershell/core/45-crypto.ps1` wraps two small tools into shell verbs. Both are
scoop-installed (`age` from extras, `croc` from main) and, like everything else
here, the verbs are guarded so they vanish on a host without the binary.

| Verb          | Does                                                     |
| ------------- | -------------------------------------------------------- |
| `age-setup`   | Generate a keypair for this host                          |
| `age-pubkey`  | Print the public key (what senders encrypt to)            |
| `age-enc`     | Encrypt to a recipient's public key                       |
| `age-dec`     | Decrypt with this host's key                              |
| `age-enc-pw`  | Encrypt with a passphrase instead of a key                |
| `send`        | Send a file to another machine (croc, relay-brokered)     |
| `recv`        | Receive a croc transfer                                   |

`age` is the file-at-rest half (small, modern, no PKI ceremony); `croc` is the
move-it-between-machines half and works without either end being reachable.

## Also installed (catalog)

Tools in `scoopfile.json` that don't warrant a section of their own but should be
discoverable rather than a surprise in the manifest:

| Tool                        | Adds                                                              |
| --------------------------- | ------------------------------------------------------------------ |
| `gh`                        | GitHub CLI — PRs, issues, releases, and the `gh api` escape hatch  |
| `navi`                      | Interactive cheatsheet launcher                                     |
| `carapace-bin`              | The multi-shell completion engine behind the completions layer      |
| `scoop-search`              | Fast `scoop search` replacement (the built-in is slow)              |
| `dust` / `duf`              | Disk usage by directory / by filesystem                             |
| `procs`                     | `ps` replacement with a readable default view                       |
| `hexyl`                     | Hex viewer with colour-coded byte classes                           |
| `tokei`                     | Lines-of-code counts by language                                    |
| `difftastic`                | Structural (AST-aware) diff; complements `delta`'s line diff        |
| `fastfetch`                 | System summary banner; declared but not wired into the profile      |
| `gping` / `viddy`           | Ping with a graph / `watch` with diffing (interval re-run)          |
| `ouch` / `7zip`             | Archive extract-anything / the general-purpose archiver             |
| `everything` + `-cli`       | Instant filename search (index-backed), plus its CLI front end      |
| `openssh`                   | Client used by `ssh/config` (Windows OpenSSH — no ControlMaster)    |
| `luacheck` / `tree-sitter`  | Lua lint (matches the CI job) / grammar tooling for nvim            |
| `php` `composer` `julia` `openjdk25` | Language runtimes kept scoop-owned — see PACKAGE-OWNERSHIP.md |

## Terminal multiplexer — psmux (native host)

The fleet runs tmux inside WSL, but the **host** now gets a real multiplexer too.
[psmux](https://github.com/psmux/psmux) is a native Windows terminal multiplexer
written in Rust: it drives Windows ConPTY directly, speaks the tmux command
language, and reads a `~/.config/psmux/psmux.conf` — so panes, windows, and session
persistence work in **pwsh on the host** without WSL, Cygwin, or MSYS2. It ships
`psmux`, `pmux`, and a `tmux` shim, so muscle memory carries straight over.

| Item     | Detail                                                                                                  |
| -------- | ------------------------------------------------------------------------------------------------------- |
| Install  | scoop (`psmux` bucket → `psmux` app), in `packages/scoopfile.json`                                      |
| Commands | `psmux` / `pmux` / `tmux` (identical)                                                                   |
| Config   | `psmux/psmux.conf` (+ `psmux.reset.conf`, `scripts/`), symlinked to `~/.config/psmux/` by `install.ps1` |
| Helper   | `mux [session]` (in `os/32-psmux.ps1`) — attach-or-create; defaults to `Gerrrt`                         |
| Requires | Windows 10/11 + PowerShell 7 (already the host target)                                                  |

The vendored `psmux/psmux.conf` sticks to mostly **portable** tmux options
(prefix remapped to `C-a`, mouse on with `mouse-selection off` so in-pane TUIs
own their mouse, vi copy-mode, `base-index 1`, OSC52 clipboard,
tokyonight-storm status bar) so the same file can later be shared with /
vendored from Core the way the nvim tree is. The one psmux-specific exception is
`pwsh-mouse-selection off` (no upstream-tmux equivalent) — it must stay off or
psmux re-encodes clicks as X10 and leaks `<leader>` into nvim, so the file is
not a drop-in for upstream tmux unchanged.

**Two caveats worth knowing:**

- psmux is **much newer** than the rest of the stack (first releases early 2026).
  It's solid and actively developed, but treat version bumps with the same
  caution you'd give any young tool — verify on update rather than blind-upgrade.
- **vim-tmux-navigator's** smart `<C-h/j/k/l>` pane-crossing is **not** wired in
  the host config: it relies on a Unix-shell `is_vim` detection script that
  doesn't apply to a native Windows multiplexer. Inside nvim those keys still
  move between nvim splits; crossing the boundary into a psmux pane uses psmux's
  own pane keys (prefix + arrows / your binds). It works as expected inside WSL,
  where the real navigator script runs.

## Secrets — 1Password CLI (`op`)

`op` is cross-platform, so Core's `op.zsh` helpers are ported to PowerShell in
`powershell/core/40-op.ps1`. Installed via winget (`AgileBits.1Password.CLI`).

| Function                          | Does                                                          |
| --------------------------------- | ------------------------------------------------------------- |
| `opsecret <vault>/<item>/<field>` | `op read op://...` — fetch one secret                         |
| `openv <env-file> <command...>`   | run a command with secrets injected from a `.env.op` template |
| `optoken <vault>/<item>`          | copy a TOTP code to the clipboard                             |
| `opssh`                           | list SSH keys stored in 1Password                             |

The history handler in `10-tools.ps1` keeps `op read` / `op item` lines (and
anything matching password/secret/token) out of the saved PSReadLine history —
the PowerShell analog of Core's `HISTORY_IGNORE`.

## Host utilities worth having

- **Sysinternals** (`scoop install sysinternals`) — Procmon, Process Explorer,
  Autoruns. The best way to understand what Windows is actually doing; useful
  for general troubleshooting and for learning Windows internals.
- **Wireshark** (winget) — packet capture on host interfaces.
- **win32yank** — clipboard provider so Neovim's `unnamedplus` works on the host.

## Desktop / window management (opt-in)

The `desktop` package group (`packages/winget.json`) adds a tiling-desktop layer
on top of the shell host — off the critical path, opt out at the install prompt or
via `DOTFILES_PKG_GROUPS`. Config lives in `desktop/` and is symlinked into
`~/.glzr` by the installer; the full keymap and setup notes are in
[`desktop/README.md`](../desktop/README.md).

- **GlazeWM** (`glzr-io.glazewm`) — i3-style tiling window manager for Windows 11.
  Vim-key focus/move (`Alt+H/J/K/L`), five workspaces, and a resize binding mode.
  Its keymap is kept identical to the Mac's AeroSpace (a single shared cross-OS keymap).
  Retuned to Tokyo Night Storm and deliberately **not** bound to `Alt+<arrow>` so
  it doesn't shadow Windows Terminal's pane-focus keys.
- **Zebar** (`glzr-io.zebar`) — the top bar. Buildless-React `vanilla-clear` widget
  showing clock, live GlazeWM workspaces (click to focus), net/cpu/mem/battery/weather,
  plus a pomodoro timer, now-playing media controls, and a lock/sleep/restart/shutdown
  power menu (ported from `Gerrrt/yasb-glazewm-config`).
- **PowerToys** (`Microsoft.PowerToys`) — PowerToys Run launcher (`Alt+Space`),
  FancyZones, and the rest of the utility suite.
- **TranslucentTB** (`CharlesMilette.TranslucentTB`) — translucent taskbar, to match
  the Terminal's `opacity: 90` glass look.

## Updates & maintenance

The fleet's "check + nudge, apply on demand" pattern (Core's `update.zsh` /
`maint.zsh`) is ported to the host:

| Command                                                                | Does                                                                                                 |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| _(startup nudge)_                                                      | once/day, backgrounded, prints `N updates available` if scoop/winget have upgrades                   |
| `up`                                                                   | apply updates: `scoop update *` + cleanup, then `winget upgrade --all`. `up -y` auto-confirms winget |
| `update-check`                                                         | force the check now and refresh the nudge                                                            |
| `update-host`                                                          | legacy one-shot scoop+winget update (kept; `up` is the fleet-standard verb)                          |
| `maint-install [HH:MM]`                                                | register the daily maintenance **Scheduled Task** (default 13:00); elevated, also the scoop junction task |
| `maint-run` / `maint-log [N\|-f]` / `maint-status` / `maint-uninstall` | run now / tail log / next-run info / remove                                                          |
| `shell-bench [runs]`                                                   | time a cold `pwsh` start (full profile), default 5 runs — measure before tuning startup              |
| `prof-trace`                                                           | load the full profile with tracing on and print a slowest-first per-fragment / per-tool breakdown    |
| `init-cache-clear`                                                     | drop the cached tool-init scripts (`%LOCALAPPDATA%\dotfiles\init-cache`); they regenerate next start |

Tool shell-integration scripts (`starship`/`zoxide`/`mise`/`atuin`/`carapace`)
are cached on first run and only regenerated when the tool's binary is newer
than the cache (e.g. after a scoop upgrade), trimming a subprocess spawn per tool
off every cold start. `init-cache-clear` forces a rebuild if you change a tool's
init flags in `core/10-tools.ps1`.

**Which profiler?** There are three, each for a different question:

| Use                         | When                                                                                                                                                                                               |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `shell-bench [runs]`        | "How long is a cold start?" — wall-clock totals only.                                                                                                                                              |
| `prof-trace`                | "Where does the time go?" — per-fragment / per-tool breakdown.                                                                                                                                     |
| `maint/Measure-Profile.ps1` | "Which fragment HANGS?" — writes a breadcrumb log before each fragment, so the last line names the one that froze. Reach for this only when a shell hangs on load and `prof-trace` prints nothing. |

**Startup speed.** Two items dominate a cold shell and are therefore **off by
default**: `Terminal-Icons` (~1.1s — only themes raw `Get-ChildItem`, which your
`ls`/`ll` bypass via `eza --icons`) and `carapace` (~1.5s completion generation —
pwsh native completion + CompletionPredictor + atuin cover most of it). Re-enable
either with a User-scope env var (`DOTFILES_TERMINAL_ICONS=1` / `DOTFILES_CARAPACE=1`;
see `powershell/local.ps1.example`). Measure with `shell-bench`, break it down with
`prof-trace`.

**Modules off OneDrive.** If `Documents` is redirected to OneDrive, the default
CurrentUser module path (`Documents\PowerShell\Modules`) is OneDrive-synced, and
importing modules from there can add **several seconds to every shell start**
(placeholder hydration / sync I/O). `profile.ps1` prepends a local dir
(`%LOCALAPPDATA%\PowerShell\Modules`) to `$env:PSModulePath`; the installer and
maintenance runner `Save-Module` managed modules there. To migrate an existing
machine, run `modules-localize` once (ideally from `pwsh -NoProfile` so no module
DLLs are locked), then open a new shell.

The scheduled runner (`maint/Maintenance.ps1`) updates the **user-space** stack
automatically (scoop, mise, nvim plugins/parsers, PowerShell modules). `winget
upgrade --all` is **opt-in** (`MAINT_WINGET_UPGRADE=1`) because it can launch MSI
installers that prompt or restart apps — the Windows analog of why Core's maint
won't auto-upgrade system packages on Arch/Gentoo/Kali. `StartWhenAvailable` on
the task is the equivalent of systemd's `Persistent=true` (catch up if the box
was off). Because psmux is installed through scoop, the maint job upgrades it
along with the rest of the scoop apps.

## Virtualization (manual install)

VMware Workstation is **not** in the winget manifest on purpose: since the
Broadcom acquisition, Workstation Player is discontinued and Workstation Pro
(free for personal use) is gated behind a Broadcom account login, so winget and
choco can no longer fetch it — grab it from the Broadcom support portal by hand.
If you want a CLI-installable hypervisor instead, `Oracle.VirtualBox` works
through winget. (Day-to-day Linux still lives in WSL2 via the bridge, so a full
VM is only needed for non-WSL guests or snapshot-heavy lab work.)

## The host ↔ WSL seam

WSL2 with `networkingMode=mirrored` (see `wsl/windows.wslconfig.example`) lets
the host and your distros share network interfaces, so a service bound inside
WSL is reachable at the host's LAN IP without NAT gymnastics. The bridge
functions (`kali`, `cdwsl`, `hostip`, `wsl-restart`) live in
`powershell/os/31-wsl-bridge.ps1`.

That's the whole point of the split: the host gives you a great terminal —
now with psmux for native multiplexing — and a clean way into WSL; the **Kali
station** owns everything offensive.
