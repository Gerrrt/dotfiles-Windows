# Changelog

All notable changes to this repo. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this is a personal dotfiles repo,
so entries are grouped by theme rather than strict semver releases.

## [Unreleased]

### Added

- **The scoop junction repair now covers every junction scoop makes, and runs on a
  schedule.** #218 established the mechanism — Redirection Guard refuses a junction
  *created* by a non-admin, trust is stamped at creation, so re-creating it elevated
  is the only lever — and fixed `apps\<app>\current`. Two gaps remained.

  **Scope.** scoop also wires persisted state back out of an app dir with junctions
  into `scoop\persist\<app>\...` (`bat\themes`, `bat\syntaxes`, `btop-lhm\themes`,
  `composer\cache`, `php\cli`, `syncthing\config`, the yt-dlp plugin dirs), and
  `scoop\modules\gsudoModule` points into `apps\gsudo\current` from outside `apps\`
  entirely — 15 further junctions on this host, created by the same non-admin scoop
  process and untrusted for the same reason. Re-stamp only `current` and
  `bat --list-themes` is still broken over ssh. The sweep is now every directory
  reparse point under the scoop root; `-Recurse` does not descend *through* a reparse
  point, so each physical junction is reported exactly once under its canonical path.

  **It never actually ran.** The step is gated on elevation, and `dotfiles-maint` is
  registered `RunLevel = Limited` — which is the open question issue #217 asked to
  resolve first. `maint-install` now also registers `dotfiles-maint-scoop-junctions`,
  running **as SYSTEM** an hour after the daily job. SYSTEM rather than the
  interactive user at `RunLevel Highest`, because an Interactive task only runs while
  someone is logged on and the case this fixes is nobody being; `-ScoopRoot` and
  `-LogPath` are baked into the action since SYSTEM's profile paths are not the
  user's. Sequencing is a time offset rather than an event trigger on the first task
  completing, because `Microsoft-Windows-TaskScheduler/Operational` is disabled by
  default and that subscription would never fire.

  The daily task deliberately stays unelevated — `scoop update *` must not run as
  admin. The sweep moved out of `Maintenance.ps1` into
  `maint/Repair-ScoopJunctions.ps1` so the elevated task has an entry point; the
  policy behind it is `Get-DotScoopJunctionPlan`, pure and unit-tested. Registering
  an elevated task itself needs an elevated shell, so `maint-install` run unelevated
  installs the daily task and says plainly that it skipped the other one.
  `maint-status` reports both tasks with their run level; `maint-uninstall` removes
  both.

### Added

- **`wsl-ssh-config` — the client-side ssh_config for the distros behind this host.**
  `docs/REMOTE-ACCESS.md` §4 told you to hand-write the `Host <distro>` block that
  `Format-DotWslSshConfig` could already generate: the renderer, the port allocator
  and the alias slug all shipped as tested module exports with nothing calling them.
  `powershell/os/34-remote.ps1` is that caller.

  Ports are allocated from the **sorted** distro list, because `wsl --list` reorders
  on install / unregister / re-default and a port that moves is worse than no port —
  it is already baked into ssh_config, into firewall rules and into muscle memory.
  `-HostPort` reserves the port the Windows sshd actually answers on instead of
  assuming 22; assume otherwise and a distro is handed the host's port, a collision
  that stays invisible until that distro silently fails to bind. `-JumpHost` emits
  the `ProxyJump` shape — one LAN port, distro ports on the host's loopback — rather
  than a network-facing listener per distro.

  It **prints and never writes**: the file this output belongs in lives on the
  machine you ssh *from*, which by definition is not this one.

  Reading the distro list back out of `wsl.exe` is the one impure step, and it is
  impure in a way that bites — `wsl --list --quiet` emits UTF-16LE, which lands in
  PowerShell as a string with a NUL between every character, so a naive reader finds
  no distros on a box that has several. `WSL_UTF8=1` is set on the **child** only
  (and restored, including the unset case, which must be removed rather than blanked),
  with the NUL strip as the belt for builds that ignore the variable.

  Still deliberately absent, and still a runbook rather than a script: standing sshd
  up. The service, the firewall rules, the `HKLM` DefaultShell key, the boot task and
  the power settings are machine-global state that varies per box.

### Fixed

- **`hostip` returned an address no other machine could reach.** It took the first
  non-link-local IPv4 Windows reported, and on any box with a Hyper-V or WSL virtual
  switch that is `vEthernet (Default Switch)` — a `Manual` 172.x address that exists
  only inside the host. Measured here: `hostip` answered `172.26.80.1` while the LAN
  address was `10.0.50.90`. Nothing about the address itself says which is which, so
  it read as correct right up until the connection timed out.

  What separates them is the **routing table**: the LAN interface carries a default
  route and a virtual switch has none. `hostip` now reads the default routes and the
  addresses and hands both to `Select-DotHostAddress`, a new pure module export that
  makes the choice — preferring a default-route interface in the caller's metric
  order, and falling back to the old `SkipAsSource` ordering on an offline box with
  no default route at all, rather than returning nothing.

  Surfaced by `wsl-ssh-config` above, which prints this address into a config you
  paste on another machine — the one place the wrong answer is guaranteed to bite.

- **Configs are unreadable over ssh, and it was never an execution-policy problem.**
  On a host running OpenSSH Server, the PowerShell profile failed to load in an ssh
  session with *"untrusted source"* while loading fine in Windows Terminal. The cause
  is **Redirection Guard** (`ProcessRedirectionTrustPolicy`), which Windows enforces
  across the whole service / session-0 lineage: a process with it enforced refuses to
  traverse a reparse point whose target sits under a non-admin-owned directory — i.e.
  every symlink this repo wired into a repo under `C:\Users\<you>`. The error is
  `ERROR_UNTRUSTED_MOUNT_POINT`.

  Measured, not theorised: `explorer` / `WindowsTerminal` / `glazewm` report `0x100`
  (not enforced), while `services.exe` / `wslservice` / Task Scheduler's `svchost` /
  `sshd` all report `0x105`. sshd inherits it, and every ssh session inherits it from
  sshd. That split is the whole symptom.

  **It cannot be configured away.** `fsutil ... R2L:1`, deleting the `sshd.exe` IFEO
  `MitigationOptions`, setting that value to `REDIRECTION_TRUST_ALWAYS_OFF`, and
  changing the symlink's owner were each tried on a real host and each did nothing —
  the policy is inherited and non-relaxable. Running sshd as a real Windows service
  would not help either (`services.exe` is `0x105` too). `docs/REMOTE-ACCESS.md`
  records all of it so nobody re-runs the experiment.

  The fix is to stop using reparse points for the configs that have to work over ssh.
  `Get-DotfilesLinkPlan` rows now carry a **`Kind`** (`'Symlink'` | `'Stub'`), and the
  three that matter are wired as real files that pull in the repo copy through the
  config format's own include mechanism — same single source of truth, no reparse
  point:

  | Config | Mechanism |
  | --- | --- |
  | `$PROFILE` | a real `.ps1` that dot-sources `powershell/profile.ps1` |
  | `~/.gitconfig` | `[include] path = <repo>/git/.gitconfig` |
  | `~/.ssh/config` | `Include <repo>\ssh\config`, first line |

  `~/.gitignore_global` deliberately stays a symlink — a `.gitignore` has nothing to
  include — so the `.gitconfig` stub overrides `core.excludesfile` to the repo copy
  instead, *after* the include, because last value wins for a single-valued key.

  `~/.ssh/config` bit twice: as a symlink it also stalled the ssh **client** on the
  host, because `ssh.exe` reads it at startup and inherits the same enforcement. A
  plain `ssh` hung while `ssh -F NUL` returned instantly.

  Re-wire an existing box with `.\install.ps1 -SkipPackages`.

  Not fixed, and called out honestly in the doc: **scoop**. Its `current` junctions
  have the same problem (77 of 78 apps unreachable over ssh on the host this was found
  on), and there is no include trick for a junction — only taking ownership of the app
  directories, which scoop undoes on every update.

- **`.core-ref` recorded `tag = v4-19-g10ad221` — the moving major alias, not the release
  it describes.** (#202) Every Core cut writes the specific `vX.Y.Z` and _then_ force-repoints
  the major alias `v4` onto the same commit (`tag-release.sh`, `git tag -fa`, alias second).
  Both tags are annotated and both sit on the release commit, so `git describe` breaks the tie
  by **tagger time** and picks the alias. That is a provenance field naming a target that is
  deliberately moved on the next release: the recorded string silently reinterprets itself, and
  re-running the same command against the same commit today returns `v4.15.1-19-g10ad221`.
  `commit` was always authoritative — only `tag` lied, and it lied in the direction that looks
  fine until you check.

  Both sync scripts now filter describe to the `vX.Y.Z` shape
  (`--match 'v[0-9]*.[0-9]*.[0-9]*'`), which excludes bare-major aliases by construction —
  the identical fix Core shipped for `core.lock` in dotgibson/dotfiles-core#515, so the
  Windows row and the Unix repos' `core_tag` agree on what a release name means. When only an
  alias exists, describe finds nothing and the `tag` line is **omitted**: an absent tag is
  honest where `v4` was not, and the SHA stays the source of truth either way. `nvim/.core-ref`
  is corrected in place; `starship/.core-ref` already read `v4.9.0` because its last sync was a
  pinned `-Ref` landing exactly on a release commit — the same latent bug, just not yet visible.
  The filter also immunizes `-CoreLocal` runs against a **locally stale** alias, since a plain
  `git fetch` never force-updates an existing tag (this box's own Core clone has `v4` frozen at
  v4.7.0's commit).

  The describe call also moved **above** each script's `*_LIBONLY` hook as `Get-CoreDescribeTag`,
  which is the part that keeps it fixed: the old inline call sat below the hook and was
  structurally unreachable from Pester, which is exactly why a wrong value shipped unnoticed.
  The new fixture (`New-DotCoreTagFixture` in `tests/_TestHelpers.ps1`) tags one commit
  `v9.9.9` then `v9` in release order, and a companion assertion proves a bare `describe --tags`
  still gets that fixture *wrong* — so if the reproduction ever stops reproducing, the suite says
  so instead of going quietly green.
  (`nvim-sync.ps1`, `starship-sync.ps1`, `nvim/.core-ref`, `tests/_TestHelpers.ps1`,
  `tests/NvimSync.Tests.ps1`, `tests/StarshipSync.Tests.ps1`)

### Added

- **`Get-DotfilesStubContent`** and **`Test-StubIntoRepo`** (`powershell/core/05-lib.ps1`,
  exported from the `Dotfiles` module) — the stub body renderer and the "is this wired?"
  predicate for `Kind='Stub'` rows. `Test-StubIntoRepo` is a *reference* check, not an
  equality check, so a user's own added lines survive a re-install; it compares with
  forward slashes and uses `String.Contains` rather than `-like`, because it gates a
  delete in `uninstall.ps1` and a `[` read as a wildcard would be a false positive.
- **`powershell/Dotfiles/Remote.Helpers.ps1`** (+ `tests/Remote.Tests.ps1`) — pure logic
  for reaching this host and the distros behind it: `Get-DotWslSshPlan` (a stable
  distro->port map, sorted by name so a port never moves when you install or unregister
  a distro), `Format-DotWslSshConfig` (the client-side ssh_config, direct or via
  `ProxyJump`), `ConvertTo-DotSshAlias`, and `Get-DotRemoteWiringResult` — the triage
  that says whether a wired config survives an ssh session.

  `Get-DotWslSshPlan` takes the Windows sshd's port as a **parameter** rather than
  assuming 22. A host that moved sshd off 22 is common, and assuming otherwise produces
  a confident "port collision" diagnosis that is simply wrong.

  Deliberately absent: anything that touches the service, registry, firewall, scheduled
  tasks, or power settings. That is machine-global state which varies per box and is
  better done by hand with eyes on it — the runbook is in `docs/REMOTE-ACCESS.md`.
- **A `Remote (ssh) configs` row in `dotfiles-doctor`** — probes whether Redirection
  Guard is enforced in the current session and reports any stub-kind config still wired
  as a symlink. Only the actionable rows are listed: plain symlinks are also unreadable
  over ssh under enforcement, but that has no fix at this layer, and listing all eleven
  every run would bury the one you can do something about.
- **`docs/REMOTE-ACCESS.md`** — the full diagnosis, the one-command way to confirm
  Redirection Guard in a broken session, the list of fixes that do *not* work, the
  scoop limitation, and a corrected WSL section (banner-grabbing to identify which
  daemon is on which port; `who` rather than `ss` for per-distro attribution, since
  `networkingMode=mirrored` makes `ss` show the host's whole peer list).

### Changed

- **`install.ps1`** grows `Write-StubItem`, dispatching on the plan row's `Kind`. It
  mirrors `Link-Item`'s contract deliberately — idempotent skip, back up before
  overwrite, honour `-DryRun`, same stats — and the install summary gains a `stubbed`
  line (emitted only when the caller tracks it, so an older stats bag renders unchanged).
- **`uninstall.ps1`** now treats *either* shape as ours (symlink into the repo, or a
  stub that references it), so it can no longer orphan the files `install.ps1` wrote.
- **`dotfiles-doctor`** is `Kind`-aware: a stub row reports `stub -> repo`, and a
  stub-kind row still wired as a symlink is flagged *"will not resolve over ssh"* with
  the re-install fix. A symlinked profile is a warn, not a fail — nothing is broken
  until you ssh in.

- **`auto-tag.yml`'s Core pin moved from v4.12.0 to v5.0.2** — a major and eight minors
  in one step, because nothing advances it automatically. This repo vendors no `core/`,
  so it is absent from `scripts/os-repos.txt`: the fan-out never opens a PR here and
  `make fleet-drift` cannot see it. The pin advances when a human moves it, and between
  2026-08-16 and 2026-08-26 nobody did.

  **Behaviourally this is a no-op, and it is worth being precise about why.**
  `auto-tag-call.yml` and `scripts/auto-tag.sh` are byte-identical at v4.12.0 and v5.0.2
  (`git rev-parse` on both blobs agrees), and the workflow re-checks-out dotfiles-core at
  a moving alias for the scripts it runs — so this host was already executing the same
  code as every "current" repo. What changes is that the recorded pin now matches what
  actually runs, instead of reporting eighteen releases of drift that were not real.

  The genuine defect the audit surfaced is upstream and is being fixed there: the
  reusable workflows fetched their scripts from `v4` while every caller ran at `@v5`
  (dotgibson/dotfiles-core#672). The comment above the pin now records that a SHA pin
  freezes the workflow body but not the scripts it pulls, so the next reader does not
  over-trust it.

### Docs

- **Why Mason can't install `ruby-lsp` on this host, written down where package
  decisions live.** The winget package the box runs, `RubyInstallerTeam.Ruby.4.0`,
  ships no MSYS2 DevKit, so every gem with a C extension fails to build — `ruby-lsp`
  and `rubocop` both die on `prism`. The error names neither ruby nor the DevKit
  (`No rule to make target '/C/Ruby40-x64/include/ruby-4.0.0/ruby.h'`): with no
  `msys64`, `gem` falls back to scoop's `mingw` make, which has no `rm` and mangles
  the drive-letter path into an MSYS-style one. `docs/PACKAGE-OWNERSHIP.md` now
  carries the symptom, the mechanism, and the one-line elevated fix
  (`ridk install 1 3`), next to the existing ruby-ownership reasoning.

  Confirmed fixed on the reference host on 2026-08-24: `ridk install 1 3` (elevated)
  populated `C:\Ruby40-x64\msys64`, and `gem install ruby-lsp` now builds both native
  extensions clean. That is host state, not repo state — a rebuilt box gets plain
  `Ruby.4.0` again and needs the same command.

  It also records why ruby stays **out** of `winget.json` rather than being declared
  like node was: the lock-drift gate only accepts ids `Update-PackageLock.ps1` can
  resolve to an installed version, so declaring `RubyWithDevKit.4.0` on a box running
  plain `Ruby.4.0` would sit permanently unlockable and red. (`docs/PACKAGE-OWNERSHIP.md`)

## [v1.6.0] - 2026-08-05

### Added

- **psmux power pill — the battery segment the macOS tmux bar has.** New
  `psmux/scripts/psmux-power.ps1`, rendered **right-most** in `status-right`, which is where
  Core puts it too (its last slot is `#{@status_right_os}`, the hook each OS repo fills). It is
  the Windows port of Core's `tmux/scripts/tmux-battery.sh` and uses that scale, so the two
  _terminal_ bars agree: green ≥60 / yellow ≥20 / red <20, with the level glyph swapped for a
  charging bolt on AC and the colour still tracking the level. **One deliberate divergence** —
  Core prints nothing when there's no battery, so its segment vanishes on a desktop; here it
  falls back to Zebar's AC placeholder, a lone green `md-power-plug` 󰚥, since an empty segment
  reads as a broken pill on a desktop-first host. Power state comes from
  `SystemInformation.PowerStatus` (one in-process `GetSystemPowerStatus` read), not
  `Win32_Battery` — a desktop returns nothing from the latter, so "no battery" and "the query
  failed" would be indistinguishable. Refreshed by the existing in-session timer alongside the
  VPN pill, so nothing new touches psmux's synchronous render path. `psmux.conf` seeds
  `@pwr_pill` with `set -og` (only-if-unset) so the desktop plug is right before the first
  tick, while a `prefix + r` reload can't clobber a live laptop reading.
  (`psmux/`, `powershell/os/33-psmux-pill.ps1`)

  Note this means the psmux bar and Zebar disagree between 40 and 60 % — deliberately. The
  bars are matched terminal-to-terminal (psmux ↔ Core tmux) and desktop-to-desktop
  (Zebar ↔ sketchybar), and those two references use different scales.

- **Test coverage for the power pill's every state.** The dev box is a desktop, so the laptop
  branches would otherwise ship unexecuted. `psmux-power.ps1` takes a `-SimulateState` testing
  seam (no host read, no poke) and `tests/Repo.Tests.ps1` asserts each colour and glyph
  threshold — including that a charging 15 % battery stays **red**, which is the case a naive
  "on AC → blue" reading would silently hide.
- **The package-freshness check now validates its own inputs — a wedged scoop bucket is a
  finding, not a silent green.** A bucket is a git clone, and a stuck clone keeps serving
  manifests from whatever commit it froze at. Those stale versions still parse and still
  compare as _matching_, so the check reported "everything's current" on data months old —
  wrong in the **reassuring** direction, the worst way for a check to fail. That is not
  hypothetical: on 2026-08-04 the local `extras` clone had been stuck mid-merge on an upstream
  rename (`UD bucket/pycharm.json`) since mid-July, so `scoop status` called lazygit and
  tailscale "latest version" while the CI bot correctly had them behind. The box contradicted
  CI and the box was wrong.

  `Check-PackageFreshness.ps1` now checks every bucket it reads manifests from — present, a
  real clone, not stuck on a merge/rebase/cherry-pick, clean tree — and **writes a report even
  when nothing looks outdated**, since that silent-green case is the entire point. The warning
  leads the issue body, because it invalidates every row under it. Also catches a bucket the
  `scoop bucket add` loop failed to create (its catch is empty), which today degrades quietly
  into a "no manifest version" skip for every app in it. Unit-tested via a new
  `DOTFILES_PKGFRESH_LIBONLY` hook, matching the `*_LIBONLY` idiom the sync scripts use.
  (`packages/Check-PackageFreshness.ps1`, `tests/Packages.Tests.ps1`)

- **`dotfiles-doctor` now checks scoop bucket health too, because CI structurally can't.** The
  guard above lives in a script whose CI runs on a fresh runner, where buckets are added
  moments earlier and are always clean — so it protects the local-run path but can never
  observe the box this actually happened on. The wedge was a **local** condition that made the
  machine disagree with the bot for three weeks, and the doctor is where "is this box healthy"
  belongs. New `Scoop buckets` row under _Health & toolchain_: `6 bucket(s) clean and pullable`
  when fine, and on a fault it names the bucket, says why (`stuck mid-merge (MERGE_HEAD)`,
  dirty tree, missing directory, not a clone) and hints the exact unwedge.

  `warn`, not `fail` — nothing is broken and no tool is missing; the box just can't be trusted
  to tell you what's current. The detector is **reused** from
  `packages/Check-PackageFreshness.ps1` through its `DOTFILES_PKGFRESH_LIBONLY` hook rather
  than reimplemented, so there's one definition of "this bucket can't be trusted"; the
  dependency deliberately only points this way, since the freshness bot must stay
  self-contained for CI, where the Dotfiles module isn't installed. The whole probe is wrapped
  so a bucket check can never take down a doctor run.
  (`powershell/Dotfiles/Doctor.Helpers.ps1`, `powershell/os/45-doctor.ps1`, `tests/Doctor.Tests.ps1`)

### Fixed

- **The load-budget perf test was measuring the runner, not the code.** `Perf.Tests.ps1`'s
  "dot-sources the tool-independent fragments quickly" timed a single **cold** dot-source, so it
  also charged the fragments for PowerShell's one-time parse/compile and module autoload — work
  they don't do. On a shared GitHub runner that noise is unbounded, and on 2026-08-05 it landed a
  CI run at 3012 ms against the 3000 ms budget: a 0.4 % overshoot on a body whose real cost is
  roughly **100× under** the gate. A re-run passed untouched, which is the tell. A red CI that
  actually means "the runner was busy" is worse than no gate at all, because it teaches you to
  re-run instead of read. Now: one untimed warm-up, then the **fastest of three** timed runs.
  Noise only ever adds time, so the minimum is the closest estimate of true load cost — while the
  regression this exists to catch (a network or subprocess call added to a load path) is slow on
  every run and still trips it. The 3000 ms budget is deliberately unchanged; raising it would
  have hidden the flake instead of removing it. (`tests/Perf.Tests.ps1`)
- **The VPN/IP pill never rendered — a PowerShell splatting bug.** `psmux-netinfo.ps1` poked the
  bar with `psmux set -g @vpn_pill $text`. In argument position a bare `@name` is PowerShell's
  **splatting operator**, so the undefined `$vpn_pill` expanded to nothing and the option name
  was dropped from the command line entirely; psmux received a single positional and silently
  discarded the whole command — exit 0, nothing on stderr, option never set. Every other layer
  (detection, cache file, timer, `psmux.conf`) was working, which is why it survived so long.
  Fixed by quoting `'@vpn_pill'` / `'@vpn_fg'`. (`psmux/scripts/psmux-netinfo.ps1`)
- **A config reload repainted a live pill in the wrong colour.** `@vpn_fg` was defaulted with a
  plain `set -g`, so every `prefix + r` overwrote whatever the refresher last poked. Because the
  pill's _text_ is never defaulted, the two halves then disagreed until the next tick — up to a
  full refresh interval — and these pills encode their state in the colour: an active tunnel kept
  showing its address in the no-tunnel green, losing the orange that is the entire signal. Both
  colour options now use `set -og` (only-if-unset), which still guarantees a non-empty colour on
  first paint. Caught on review of the same mistake in `@pwr_fg`, where it would paint a 15 %
  battery healthy-green.
  `psmux set -g @vpn_pill ''`, but an empty-string argument is dropped on the way to the exe and
  the set no-ops exactly like the splat above. Clearing now uses `set -gu` (unset).
  `psmux-pill-disable` clears the segment too, instead of only stopping the timer.
- **Holding the prefix key shoved the IP pill two columns right.** The prefix/mode indicator sits
  between `#S` and the pill with each branch padded to the same width — but the idle branch was
  three literal spaces, which psmux's parser collapsed to one (see the next entry), against a
  prefix branch of `space + glyph + space` that survived as three. The branches are now spaced
  with `#{p<n>:}` and are five rendered cells each, verified in both directions on a real
  terminal. A test asserts the three branches stay equal width, since eyeballing this is
  exactly what failed before.
- **Multi-space gaps in the status bar were rendering as a single space.** psmux parses option
  values as `split_whitespace()` + `join(" ")`, so every run of spaces collapses to one, quoted
  or not — which means the twelve-space cwd→clock gap added in
  [#163](https://github.com/dotgibson/dotfiles-Windows/pull/163) had never actually widened
  anything. Bar gaps now use **`#{p<n>:}`**, which pads an empty body at _render_ time — after
  the parser has had its way — and is the same idiom Core's `tmux.conf` already uses
  (`#{p19:}`), so the two configs now read the same. The session→IP gap is wider as a result,
  and a test forbids multi-space runs in `status-left`/`status-right` so this can't silently
  regress. Note `#{p<n>:}` only works written directly in the config: a format arriving via a
  user option is not re-expanded, which is the same rule that keeps a `#[…]` style run from
  working inside `@vpn_pill`.
- **Two stale psmux config tests.** They asserted the pill was read via
  `#(cmd /c type %LOCALAPPDATA%…)` and passed only because that string still appeared in the
  _comment block_ describing the retired transport — they had stopped testing anything real.
  Repointed at the live `@vpn_pill` / `@pwr_pill` segments, plus a static guard that every
  `psmux set` in the repo quotes its `@option` name, since the splatting bug above is invisible
  at runtime. (`tests/Repo.Tests.ps1`)

## [v1.5.0] - 2026-08-02

_**Core → Windows parity pass (2026-07).** A focused sweep to close the drift that had
built up between recent `dotfiles-core` / `dotfiles-MacBook` work and the Windows host,
kicked off by a host `:checkhealth` dump. In short: the stale `nvim/` mirror was
re-vendored from Core (bringing the `regex` Tree-sitter parser and the new
`:checkhealth gerrrt` LSP/formatter/linter readiness sections); the native-Windows
clipboard false-warning was fixed upstream in Core and pulled in; the psmux
`:checkhealth` tmux noise was documented as the cosmetic wart it is; and the two
mid-2026 Core CLI tools the
host still lacked were wired up — `jnv` (interactive JSON explorer) and a `web`
terminal-browser verb (via `lynx`, since `w3m` has no scoop manifest)._

_**Status-bar redesign (2026-07/08).** The parity pass then widened into a full bar
rework across both surfaces the host draws — psmux (terminal) and Zebar (desktop) — with
macOS sketchybar as the reference. Both converged on the same **chip-less items on a
transparent bar** language, and `PARITY.md` was rewritten to describe the three-island
layout the macOS bar had already drifted to (adopt, not revert), so the shared contract
is true for both hosts again. Several entries below are live-testing fixes from actually
running it. Per-change detail below._

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
- **Command-block separators (parity with Core's `_cmd_block_*`).** A thin full-width rule
  is drawn above each prompt that followed a command, colored by exit status — dim
  (`#414868`) on success, red (`#f7768e`) on failure — turning scrollback into scannable
  blocks. Ported as precmd/preexec (**not** a key handler, so it can't collide with
  PSReadLine vi-mode): the `AddToHistoryHandler` sets `$global:DotCmdBlockRan` (a bare Enter
  never accepts a line, so no rule is drawn on an empty prompt), and
  `Invoke-Starship-PreCommand` draws the rule via `[Console]::Write`. Colour tracks
  `$LASTEXITCODE` (the status reliable at that point); pure-cmdlet failures still surface in
  starship's `[status]`. (`powershell/core/10-tools.ps1`)
- **Zebar caffeine / keep-awake indicator.** A placeholder matching sketchybar's
  `caffeinate.sh` — grey asleep, yellow awake — in the left island. **Visual only for now**:
  it renders state but doesn't yet drive a keep-awake mechanism on the host (see the Caffeine
  component comment in the HTML). (`desktop/zebar/vanilla-clear/`)
- **Zebar battery shows an AC-power placeholder on desktops.** A machine with no battery
  rendered nothing at all, leaving a gap in the right island; it now shows a green plug glyph.
  (`desktop/zebar/vanilla-clear/`)

### Changed

- **Re-vendored `nvim/` from Core** (was `v4.4.0-3`, now current). Brings the Core
  changes that had not yet reached the host: the `regex` Tree-sitter parser (silences
  `:checkhealth noice`'s "regex parser is not installed" cmdline-highlighting warning),
  the new `:checkhealth gerrrt` **LSP / formatter / linter** readiness sections, and the
  `servers/init.lua` read-only `status()` export those sections consume. `nvim/.core-ref`
  updated to the synced commit. (`nvim/`, via `nvim-sync.ps1`)
- **Re-synced `nvim/` to Core `main` `a53ac4f`** — a follow-up mirror picking up the
  `lazy-lock.json` plugin-pin refresh (4 SHAs); `nvim/.core-ref` re-pointed from the
  pre-merge branch tip to `main`. `starship.toml` verified byte-identical to Core (no
  sync needed). (`nvim/lazy-lock.json`, `nvim/.core-ref`)
- **Windows Terminal cursor → `bar`** — `cursorShape` `filledBox` → `bar` to match
  MacBook's ghostty `cursor-style = bar` for cross-terminal parity.
  (`windows-terminal/settings.json`)
- **psmux status bar → Core's centered floating-island look.** Ported Core `tmux.conf`'s
  island redesign to `psmux/psmux.conf`: a 2-line, **centered**, **transparent** bar
  (`status 2` + blank `status-format[1]`, `status-justify centre` — later `absolute-centre`,
  see Fixed — `status-style bg=default`, `bg=default` pill caps + pane borders) with flat **underlined** window tabs
  and `monitor-activity` **•** dots for unseen output (psmux has no `monitor-bell`) — replacing the
  old left-justified opaque-pill bar. All five psmux features were probed as supported
  (psmux 3.3.7) before porting. Stays within psmux's no-shell-out / no-process-table rules:
  the cwd pill keeps `#{b:pane_path}` (OSC 7) and Core's nvim-gated `pane_current_path`
  segment is intentionally **not** ported. (`psmux/psmux.conf`)
- **Zebar adopts sketchybar's floating-islands design, and `PARITY.md` now describes it.**
  The macOS bar had drifted to a 3-island look (transparent bar + bordered panels) without
  the shared contract being updated, so `PARITY.md` was false for one host. Resolved by
  **adopting, not reverting**: the bar goes transparent and `.left`/`.center`/`.right` each
  become a rounded island (`rgba(29,32,47,0.93)` fill, 2px rim, r=9) accented blue/magenta/
  green. Weather moves into the left island (stable-width, non-urgent); two grey `│`
  separators chunk the right island into I/O · load · power, each gated on its own group so
  a provider-startup transient can't leave a stray separator leading the island. `PARITY.md`
  (identical copy in `dotfiles-MacBook`) rewritten to match: three islands, weather left,
  transparent bar geometry, blur off, purple un-reserved and orange added to the palette.
  **Not render-verified on a Windows host** — reload Zebar and eyeball.
  (`desktop/zebar/vanilla-clear/`, `desktop/PARITY.md`)
- **psmux bar is chip-less.** Dropped the rounded pill caps (`@cap_l`/`@cap_r`) from the
  session / cwd / clock / IP segments in favour of plain coloured icon+text on the
  transparent bar — matching sketchybar, Zebar, and `PARITY.md`'s "items are chip-less"
  spec. Also fixes the prefix and copy-mode glyphs being clipped by the cap they sat
  against. (`psmux/psmux.conf`, `psmux/scripts/psmux-netinfo.ps1`)
- **Default psmux session renamed `main` → `Gerrrt`** — both the `30-windows.ps1` auto-launch
  and the `mux` verb default in `32-psmux.ps1`, with the docs/comments that still said `main`
  updated to match. (`psmux/`, `docs/TOOLS.md`, `TERMINAL_WORKFLOW_GUIDE.md`)
- **Zebar weather reads °F** instead of °C (`fahrenheitTemp`).
  (`desktop/zebar/vanilla-clear/vanilla-clear.html`)
- **Zebar workspace pills match sketchybar's `aerospace.sh`.** Only the _focused_ workspace
  is highlighted (blue background, dark text); every other one is a plain grey number with no
  chip — GlazeWM's `.displayed` distinction is deliberately dropped for macOS parity, since
  aerospace shows only the single focused workspace. (`desktop/zebar/vanilla-clear/styles.css`)
- **Zebar spacing and font tuning from live use on a large external monitor.** `--item-gap`
  20px → 8px to match sketchybar's per-item padding (`padding_left` 4 + `padding_right` 4);
  left-island items dropped from a 16px to an 8px margin so both islands read at the same
  density; `--bar-font-size` 16px → 18px, since sketchybar's ~17pt suits a laptop panel but
  reads too small on a large panel (still fits the 28px island; 20px is the next comfortable
  step). (`desktop/zebar/vanilla-clear/styles.css`)

### Fixed

- **psmux tabs no longer drift off-center — `status-justify absolute-centre`.** Plain
  `centre` (Core's value) centers the window list in the gap _between_ `status-left` and
  `status-right`, so the host's variable-width session pill (wider while prefix is active)
  and the `#{b:pane_path}` cwd in `status-right` pushed the tabs off the true middle —
  most visibly as a jump when a pane running nvim widened the right float. Switched to
  `absolute-centre`, which anchors the tabs to the bar's absolute center regardless of
  either float's width. Deliberate divergence from Core's `centre` (see `docs/PORTING-NOTES.md`);
  probed on psmux 3.3.7. This is the real fix for the tab-shifting the equal-width prefix
  cell below was working around. (`psmux/psmux.conf`)
- **psmux IP / VPN pill rendered blank.** Two distinct causes, found in that order. First,
  `psmux.conf` ran `set -gq @vpn_pill ""`, which clobbered the refresher's poked value on
  every `source-file` reload — removed, so `#{@vpn_pill}` persists what the refresher sets.
  The segment still rendered empty, because the option was poked as a single **pre-styled**
  string (`'#[fg=#9ece6a,bold]<glyph> <ip>'`) and an option _value_ embedding a `#[…]` style
  run is not re-interpreted when the format expands it. That's why `psmux-pill-status` showed
  a populated cache (a plain file write, a separate code path) while the bar stayed empty.
  Split the transport to mirror the proven `@tn_*` colour pattern: `@vpn_pill` carries plain
  text only, `@vpn_fg` carries the accent hex, applied in `status-left` as
  `#[fg=#{@vpn_fg}]#{@vpn_pill}`. Only the colour is defaulted in the conf (so it's never
  empty on first paint); defaulting the _text_ is what caused the original clobber.
  (`psmux/psmux.conf`, `psmux/scripts/psmux-netinfo.ps1`)
- **psmux prefix indicator style leaked into the window tabs.** A `#[default]` reset after
  `#{@vpn_pill}` stops the pill's bold/fg bleeding into the tabs. The indicator was also
  widened to an equal-width padded cell (` 󰠠 ` / idle `   `) so its branches couldn't shift
  the tabs — kept for stable width, though `absolute-centre` above is what actually holds
  the tabs still. (`psmux/psmux.conf`)
- **psmux nvim cwd jammed against the clock.** Two passes: the `status-right` cwd↔clock gap
  sat inside a `#{?}` branch and psmux trims in-branch trailing spaces, so it was moved
  outside the branch — then widened (6 → 12 spaces) once the branch fix made the gap
  actually render and it was still too tight to read. (`psmux/psmux.conf`)
- **psmux config warning: `unknown option 'monitor-bell'`.** psmux 3.3.7 doesn't implement
  `monitor-bell` at all — its CLI `setw`/`set` returns exit 0 (so the capability probe was a
  false positive) but the config parser rejects it on load. Removed the setting;
  `monitor-activity` (which psmux does support) stays, so activity dots still work — only the
  bell dot is inert. (`psmux/psmux.conf`)
- **Zebar network readout rendered white instead of blue.** The `.network` module had no
  color class, so only its glyph got the global blue while the ↓↑ throughput values fell
  back to `fg` (white). Added `.network { color: var(--tn-blue) }` so icon **and** values
  are blue, matching sketchybar's `network.sh` (icon + label accent).
  (`desktop/zebar/vanilla-clear/styles.css`)
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

## [v1.3.0] - 2026-07-16

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
  PowerShell unrolls to `$null`on assignment; splatting`$null` into the
  switch-only `install.ps1` passed a literal `$null`positional argument. The call
site now wraps the result in`@()`and guards the splat, so a fresh`.\bootstrap.ps1`(or the`irm | iex` one-liner) runs the installer cleanly.

### Added - v1.2.0

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

### Fixed - v1.2.0

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
