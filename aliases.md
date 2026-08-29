# Windows PowerShell Aliases Cheat Sheet

PowerShell functions and `Set-Alias` declarations for common interactive tasks,
sourced from the profile modules. Many tool-backed functions are guarded by
`Test-Cmd` — missing tools fall back gracefully. This covers the most-used
interactive shortcuts; not all profile functions are listed here.

## Core front door (`48-core.ps1`)

The umbrella `core` verb, mirroring `dotfiles-core` on macOS/Linux so the same
command works across the fleet. Thin dispatchers over the host's native verbs
(`dothelp` / `dotfiles-doctor` / `up`), which stay canonical; the old names
still work. Kept aligned by dotfiles-core's `PARITY.md` + `parity-check.sh`.

| Function | Purpose |
|----------|----------|
| `core` | Bare `core` prints the command index (`dothelp`); an unknown verb suggests the nearest |
| `core doctor [...]` | Health-check the setup — same as `dotfiles-doctor` (args pass through) |
| `core help [filter]` | The in-shell command index — same as `dothelp` |
| `core version` | Print `dotfiles-Windows <rev>` (this layer's revision) |
| `core update [-y]` | Apply scoop + winget updates — same as `up` |
| `core-doctor` / `core-help` / `core-version` | Standalone twins of the verbs above (match Core's `core-*` names) |

## Help (`55-help.ps1`)

| Function | Purpose |
|----------|----------|
| `dothelp [filter]` | Grouped, in-shell index of every custom command in this profile (the README cheatsheet, one word away). `dothelp git` filters to rows matching "git". `-Interactive` fuzzy-picks via fzf and places the command at the prompt (falls back to clipboard) |

## File Listing (`00-aliases.ps1` — eza / lsd / Get-ChildItem fallback)

> **Note:** Equivalents shown are the `eza` variants. When `eza` is absent, `lsd`
> is used (with different flags); when neither is installed, only `ll` and `la`
> fall back to `Get-ChildItem`.

| Function | Equivalent |
|----------|------------|
| `ls` | `eza --icons --group-directories-first` |
| `l` | `eza --icons --group-directories-first -1` |
| `ll` | `eza --icons --group-directories-first -lh --git` |
| `la` | `eza --icons --group-directories-first -lha --git` |
| `lt` | `eza --tree --level=2` |
| `llt` | `eza --tree --level=3 -lh` |

## File Viewer (bat / Get-Content fallback)

| Function | Equivalent |
|----------|------------|
| `cat` | `bat --paging=never` |
| `catp` | `bat` (paged) |

## Modern CLI Tools

| Function | Equivalent | Requires |
|----------|-----------|----------|
| `grep` | `rg --smart-case` | ripgrep |
| `http` | `xh` | xh |
| `https` | `xh --https` | xh |
| `gmd` | `glow [--pager]` | glow |
| `dns` | `doggo` | doggo |
| `web` | terminal web browser (`w3m`→`lynx`→`links`→`elinks`) | lynx (or any text browser) |
| `du` | `dust` | dust |
| `df` | `duf` | duf |
| `pss` | `procs` | procs |
| `top` / `htop` | `btop` | btop |
| `watch` | `viddy` | viddy |
| `hex` | `hexyl` | hexyl |
| `loc` | `tokei` | tokei |
| `fm` / `y` | `yazi` | yazi |
| `tree` | `eza --tree --icons` | eza |
| `ping` | `gping` | gping |
| `cdi` | `zi` (zoxide interactive jump) | zoxide |

## Git Functions (full OMZ-style set, parity with Core `git.zsh`)

> The built-in PowerShell aliases that collide with a git shorthand (`gc`→Get-Content,
> `gcm`→Get-Command, `gp`→Get-ItemProperty, `gl`→Get-Location, `gm`→Get-Member,
> `gcb`→Get-Clipboard) are removed at load so these functions win.
> `gbD` (force-delete) can't coexist with `gbd` — PowerShell is case-insensitive; use `gbd -D`.

| Function | Equivalent | Function | Equivalent |
|----------|------------|----------|------------|
| `g` | `git` | `gsw` | `git switch` |
| `gs` / `gsb` | `git status --short --branch` | `gswc` | `git switch --create` |
| `gst` | `git status` | `gswm` | `git switch <trunk>` |
| `gss` | `git status --short` | `gd` | `git diff` |
| `ga` | `git add` | `gds` | `git diff --staged` |
| `gaa` | `git add --all` | `gdw` | `git diff --word-diff` |
| `gap` | `git add --patch` | `glog` | `git log --oneline --decorate --graph` |
| `gc` | `git commit --verbose` | `gloga` | …`--all` |
| `gcm` | `git commit --message` | `glol` / `glola` | pretty graph log |
| `gca` | `git commit --verbose --all` | `gf` | `git fetch` |
| `gcam` | `git commit --all --message` | `gfa` | `git fetch --all --prune --tags` |
| `gc!` | `git commit --amend` | `gl` | `git pull` |
| `gcn!` | `git commit --no-edit --amend` | `gpr` | `git pull --rebase` |
| `gb` | `git branch` | `gp` | `git push` |
| `gba` | `git branch --all` | `gpu` | `git push --set-upstream origin <cur>` |
| `gbd` | `git branch --delete` | `gpf` | `git push --force-with-lease` (safe) |
| `gbm` | `git branch --move` | `gpf!` | `git push --force` |
| `gco` | `git checkout` | `gsta`/`gstaa` | `git stash push [--include-untracked]` |
| `gcb` | `git checkout -b` | `gstp`/`gstl`/`gstd` | stash pop / list / drop |
| `gcom` | `git checkout <trunk>` | `grb`/`grbi`/`grbm` | rebase / -i / onto trunk |
| `grbc`/`grba` | rebase --continue / --abort | `grh`/`grhh` | `git reset` / `--hard` |
| `grs`/`grss` | `git restore` / `--staged` | `gr`/`grv` | `git remote` / `--verbose` |
| `gm`/`gma` | `git merge` / `--abort` | `gdft` | `git difftool --tool=difftastic` |
| `jjs`/`jjl`/`jjd` | jujutsu status / log / diff | `lg` | `lazygit` |
| `gaf`/`grf`/`grsf` | fuzzy stage / restore / unstage | | |

## Git Safety (`08-git-safety.ps1`)

| Function | Purpose |
|----------|----------|
| `git-reap` | `Reset-StuckGit` — kill orphaned `git`/credential-helper processes left by a wedged shell-spawned git, so a locked git binary can be updated (`-WhatIf` previews without killing) |

## Navigation

| Function | Equivalent |
|----------|------------|
| `..` | `Set-Location ..` |
| `...` | `Set-Location ..\..` |
| `....` | `Set-Location ..\..\..` |
| `~` | `Set-Location $HOME` |
| `mkcd <path>` | Create directory and cd into it |
| `dotfiles` | `Set-Location $DOTFILES` |

## Utilities (`20-functions.ps1`)

| Function | Purpose |
|----------|----------|
| `which <cmd>` | Resolve command path |
| `reload` | Reload the PowerShell profile |
| `myip` | External IP address |
| `myip-full` | Full IP info |
| `localips` | All local IP addresses |
| `ports` | Listening TCP/UDP sockets + owning process |
| `pbcopy` / `pbpaste` | Clipboard (Mac-style parity) |
| `serve [port]` | Start a local HTTP server |
| `cdup [n]` | Climb N directories (default 1) |
| `fcd` | Fuzzy-cd into any subdirectory (fd + fzf) |
| `genpw [length]` | Random alphanumeric password (default 16, crypto RNG) |
| `please` | Re-run the last command elevated (previews + confirms) |
| `pullall [dir]` | Fast-forward every git repo under a dir, in parallel |
| `sha256 / sha1 / md5 <file>` | File hash |
| `mkbak <file>` | Timestamped backup |
| `extract <archive>` | Extract any archive format |
| `compress <target>` | Compress to archive |
| `cheat <topic>` | Fetch from cht.sh |
| `fif <pattern>` | Find in files (rg + fzf) |
| `fbr` | Fuzzy git branch checkout |
| `gaf / grf / grsf` | Fuzzy git add / restore / restore --staged |
| `tools` | Render the host tool docs (`docs/TOOLS.md`) — glow, falling back to bat, then nvim, then a plain dump |

## Diagnostics (`10-tools.ps1`)

| Function | Purpose |
|----------|----------|
| `shell-bench [N]` | Time N cold `pwsh` starts (default 5) and report min/avg/max — measure profile startup cost instead of guessing |
| `prof-trace` | Load the full profile in a clean child process with tracing on, and print the slowest-first fragment breakdown |

## Encryption / File Transfer (`45-crypto.ps1`)

Each function is only defined if its backing tool (`age` / `croc`) is installed — on a box without it, the command doesn't exist rather than running as a no-op.

| Function | Purpose |
|----------|----------|
| `age-setup` | Generate a new `age` key at `~/.age/key.txt` (idempotent — prints the existing public key if one is already there) |
| `age-pubkey` | Show the public key for the default `age` key |
| `age-enc <file> [output]` | Encrypt a file to yourself with your public key (defaults to `<file>.age`) |
| `age-dec <file.age> [output]` | Decrypt a file encrypted with your key (defaults to stripping the `.age` suffix) |
| `age-enc-pw <file> [output]` | Password-based encryption, no key file needed — for sharing with someone without your public key |
| `send <file...>` | Shorthand for `croc send` — accepts files, dirs, or multiple targets |
| `recv <code>` | Receive a `croc` transfer by the code the sender printed |

## Keybindings

| Chord | Purpose |
|-------|----------|
| `Ctrl+g` | Sessionizer — fuzzy-pick a project dir (zoxide frecency + project roots) and attach-or-create a psmux session for it (cross-shell parity with zsh's sesh-on-Ctrl+G; see `powershell/core/10-tools.ps1`) |
| `Alt+z` | zoxide interactive frecency jump (`zi`) |
| `Ctrl+t` | PSFzf file picker (lazy-loaded on first press) |
| `Ctrl+r` | PSFzf history search, or plain reverse-search if PSFzf/atuin aren't installed |
| `Ctrl+e` | Atuin interactive history search (present when atuin is installed) |

## Package Management (`30-windows.ps1`)

### Scoop

| Function | Equivalent |
|----------|------------|
| `sci` | `scoop install` |
| `scu` | `scoop update *` |
| `scs` | `scoop search` |
| `scl` | `scoop list` |
| `sccl` | `scoop cleanup * ; scoop cache rm *` |

### Winget

| Function | Equivalent |
|----------|------------|
| `wgi <id>` | `winget install --id <id> -e` |
| `wgu` | `winget upgrade --all --include-unknown` |
| `wgs` | `winget search` |

### Updates (`up` / `update-check` are in `15-update.ps1`)

| Function | Purpose |
|----------|----------|
| `up` | Apply all updates (scoop + winget) |
| `update-host` | Apply all updates (wrapper for `up`) |
| `update-check` | Check for available updates without applying |

## WSL Bridge (`31-wsl-bridge.ps1`)

| Function | Purpose |
|----------|----------|
| `kali` | Open Kali WSL shell |
| `wsls` | List WSL distros |
| `wslip` | WSL distro IP address |
| `cdwsl [distro]` | Open WSL distro at current Windows directory (translated to WSL path; falls back to distro default) |
| `wslhome` | Open WSL distro at its home directory (`~`) |
| `hostip` | Windows host IP (as seen from WSL) |
| `wsl-restart` | Restart the WSL subsystem |

## Remote access (`34-remote.ps1`)

Reaching this host *from elsewhere*, and keeping the distros reachable once the
Windows sshd owns port 22. The diagnosis behind each of these is in
[`docs/REMOTE-ACCESS.md`](docs/REMOTE-ACCESS.md).

| Function | Purpose |
|----------|----------|
| `remote-doctor` | What an ssh session into this host would actually get: sshd service + startup type, login shell, `authorized_keys` location, firewall, profile trust, `.wslconfig`, boot task, sleep, per-distro ports (read-only) |
| `remote-doctor -ProbeDistros` | Also enters each distro to read its `sshd_config` port — this **starts** the distro |
| `remote-setup` | Applies the host-side fixes (elevates): sshd automatic + running, `DefaultShell` → pwsh, firewall rule, `administrators_authorized_keys` with the ACL sshd demands, the WSL logon task |
| `remote-setup -OpenDistroPorts` | Also opens a LAN firewall rule per distro (prefer `ProxyJump` through port 22 instead) |
| `remote-setup -DisableSleepOnAC` | Stops the host sleeping on AC — a sleeping box answers no ssh |
| `wsl-ssh-config [-JumpHost h]` | Prints the client-side `ssh_config` blocks for every distro, with ports already assigned |
| `wslup` | Starts sshd inside each distro now (sshd is the process that keeps the distro from being torn down). Same code path the logon task runs |

## System (`30-windows.ps1`)

| Function | Purpose |
|----------|----------|
| `admin` | Relaunch current shell as Administrator |
| `path` | Print PATH entries one per line |
| `open` | Open file / dir in Explorer (alias: `explorer-here`) |
| `setenv <k> <v>` | Set a persistent user environment variable |
| `getenv <k>` | Read a user environment variable |
| `modules-localize` | Move PowerShell modules off OneDrive |

## psmux (`32-psmux.ps1`)

| Function | Purpose |
|----------|----------|
| `mux` | Attach to or create a psmux session |

## 1Password (`40-op.ps1`)

| Function | Purpose |
|----------|----------|
| `opsecret <ref>` | Read a secret by 1Password reference |
| `openv <item>` | Load item fields as environment variables |
| `optoken <item>` | Get a TOTP token |
| `opssh <key>` | Add an SSH key from 1Password |

## Fuzzy Pickers — Television (`25-television.ps1`)

| Function | Purpose |
|----------|----------|
| `tvim` | Fuzzy-pick a file and open in nvim |
| `ttext` | Fuzzy text search across files |
| `tcd` | Fuzzy cd |
| `trepo` | Fuzzy jump to a git repo |
| `tbranch` | Fuzzy git branch switcher |
| `tenv` | Fuzzy environment variable picker |

## psmux Pills (`33-psmux-pill.ps1`)

The psmux status-bar pills — the operator/VPN IP on the left, the power/battery
segment right-most — refreshed by one in-session timer (no scheduled task, no
elevation needed). Values are poked into psmux as user options so the bar never
spawns a process while drawing.

| Function | Purpose |
|----------|----------|
| `psmux-pill-now [-AllNetworks]` | Refresh both pills once, synchronously |
| `psmux-pill-enable [-AllNetworks]` | Turn the IP pill on — persists (new panes auto-start it) and arms the refresher now; `-AllNetworks` also shows the plain-LAN IP when no tunnel is up |
| `psmux-pill-disable` | Stop the refresher, drop the opt-in, clear the IP segment (the power pill stays — it's a parity segment, not an operator indicator) |
| `psmux-pill-status` | Show refresher state (enabled / armed this session / inside mux) and what the bar is actually reading for both pills |

## Maintenance (`40-maint.ps1`)

Windows analog of Core's `zsh/maint.zsh` — the control surface for the daily
maintenance job, backed by a Task Scheduler task instead of systemd/launchd/cron.

| Function | Purpose |
|----------|----------|
| `maint-install [HH:MM]` | Register + enable the daily task (default `13:00`); `StartWhenAvailable` catches up if the machine was off at that time |
| `maint-run` | Run the maintenance script now, in the foreground |
| `maint-log [N|-f]` | Show the last N log lines (default 50), or follow with `-f` |
| `maint-status` | When it next runs / last result |
| `maint-uninstall` | Remove the scheduled task |

## Doctor (`45-doctor.ps1`)

| Function | Purpose |
|----------|----------|
| `dotfiles-doctor [-Quiet] [-PassThru] [-Fix] [-Json]` | Audit whether the host is wired up correctly (registry, execution policy, symlinks, PATH); every check reports ok/warn/fail with a fix hint. `-Quiet` prints just the summary; `-PassThru` emits result objects for scripting/tests |

## Set-Alias Declarations

| Alias | Points To |
|-------|----------|
| `vim` | `nvim` (if installed) |
| `explorer-here` | `open` |
| `init-cache-clear` | `Clear-InitCache` |
