<!-- Back to top link -->
<a id="readme-top"></a>

<!-- Project Shields -->
<div align="center"><nobr>

[![dotgibson][dotgibson-shield]][dotgibson-url]<!--
-->[![CI][ci-shield]][ci-url]<!--
-->![Last Commit][lastcommit-shield]<!--
-->[![Contributors][contributors-shield]][contributors-url]<!--
-->[![Forks][forks-shield]][forks-url]<!--
-->[![Stargazers][stars-shield]][stars-url]<!--
-->[![Issues][issues-shield]][issues-url]<!--
-->[![MIT License][license-shield]][license-url]

</nobr></div>

<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/dotgibson/">
    <img src="https://raw.githubusercontent.com/dotgibson/.github/main/profile/logo.png" alt="Logo" width="80" height="80">
  </a>

  <h3 align="center">🪟 dotfiles-Windows</h3>

  <p align="center">
    The native Windows host — PowerShell, Windows Terminal, scoop/winget, and the WSL2 bridge.
    <br />
    <a href="https://dotgibson.github.io/dotfiles-web/docs"><strong>Explore the docs »</strong></a>
    <br />
    <br />
    <a href="https://dotgibson.github.io/dotfiles-web/playground/">View Demo</a>
    &middot;
    <a href="https://github.com/dotgibson/dotfiles-Windows/issues/new?labels=bug">Report Bug</a>
    &middot;
    <a href="https://github.com/dotgibson/dotfiles-Windows/issues/new?labels=enhancement">Request Feature</a>
  </p>
</div>

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#languages">Languages</a></li>
        <li><a href="#tools">Tools</a></li>
      </ul>
    </li>
    <li><a href="#getting-started">Getting Started</a></li>
    <li><a href="#layout">Layout</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
  </ol>
</details>

<!-- ABOUT THE PROJECT -->
## About The Project

**`dotfiles-Windows` is the native-host layer** — one node in a cross-platform
dotfiles system. It owns the Windows host: PowerShell 7 as the daily-driver
shell, Windows Terminal, the scoop/winget package layer, `psmux` (native tmux),
and the bridge into Linux distros running under WSL2.

Unlike every OS repo, **Windows does _not_ vendor Core as a `git subtree`.** The
shared config is replicated natively in PowerShell — the `powershell/core/`
fragments mirror the feel of the zsh loader — so only three cross-shell assets are
synced from [`dotfiles-core`](https://github.com/dotgibson/dotfiles-core):
`nvim/` (via `nvim-sync.ps1`), `starship/starship.toml` (via
`starship-sync.ps1`) and `theme/palette.toml` (via `theme-sync.ps1`, then rendered
into the terminal layer by `gen-theme.ps1`). It also deliberately does **not** configure WSL distros —
Core, `dotfiles-Debian` and `dotfiles-Offense` configure themselves from their own repos _inside_ WSL. This repo
makes the host excellent, then gets out of the way. Full docs live on the
[documentation site][docs].

The system is three layers; Windows is a host that **replicates** Core rather
than vendoring it:

| Layer | Lives in | Owns |
| --- | --- | --- |
| **Core** | [`dotfiles-core`](https://github.com/dotgibson/dotfiles-core) → vendored into every OS repo's `core/` (Windows replicates it in pwsh instead) | zsh, tmux, nvim, git, starship — identical everywhere |
| **OS-native** | `dotfiles-{MacBook,Windows,Fedora,Arch,Debian,openSUSE,Alpine,Gentoo}` (Windows is the native host) | package manager, clipboard, paths |
| **Role** | `dotfiles-Offense`, `dotfiles-Defense` | offensive / defensive tooling (Windows bridges to Kali under WSL) |

### Languages

- [![PowerShell][powershell-shield]][powershell-url]

### Tools

- [![Windows Terminal][wt-shield]][wt-url]
- [![Scoop][scoop-shield]][scoop-url]
- [![WinGet][winget-shield]][winget-url]
- [![psmux][psmux-shield]][psmux-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- GETTING STARTED -->
## Getting Started

### Step 0 — provision a fresh box

Stock Windows ships **neither `git` nor PowerShell 7**, so the one-liner below
cannot run on a brand-new machine until you lay the foundation. Do that first:

```powershell
winget install Git.Git Microsoft.PowerShell
git clone https://github.com/dotgibson/dotfiles-Windows.git ~/dotfiles-Windows
cd ~/dotfiles-Windows
winget configure -f configuration.dsc.yaml --accept-configuration-agreements
```

`configuration.dsc.yaml` is idempotent and reconciling: it installs Windows
Terminal, PowerShell 7, WSL and Git, **and enables Developer Mode** — which is what
lets `install.ps1` create real symlinks instead of degrading to copies.

> Enable Developer Mode rather than running elevated. Scoop's installer refuses to
> run from an administrator shell, so elevating to win symlinks costs you the
> entire package phase.

Then **reopen PowerShell 7** (`pwsh`) and continue below.

### Prerequisites

**PowerShell 7** (`pwsh`), **`git`**, and **Developer Mode** — all provided by
Step 0. Already have them? Skip straight to the install.

### Installation

```powershell
irm https://raw.githubusercontent.com/dotgibson/dotfiles-Windows/main/bootstrap.ps1 | iex
```

The one-liner is **integrity-gated** — verify the script against its pinned
SHA-256 before piping to `iex` (the docs show the hash-checked form). Or, from the
clone you already made in Step 0, run the installer directly:

```powershell
cd ~/dotfiles-Windows
.\install.ps1                # packages + symlinks (idempotent)
.\install.ps1 -SkipPackages  # just re-wire links
.\install.ps1 -DryRun        # preview; -Help for the full option list
```

Then open a **new** PowerShell window, set your name/email in `~/.gitconfig.local`,
and review `~/.wslconfig` + `wsl --shutdown` to apply mirrored networking.

<!-- bootstrap.ps1 SHA-256 (LF-normalized): 09b31819217ce71a0ae241fa41ac206f48b148e49bb98b5adc1af0f6775745e5 -->

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- LAYOUT -->
## Layout

```text
dotfiles-Windows/
├── install.ps1                  bootstrap (env var, packages, symlinks)
├── uninstall.ps1                remove repo symlinks (optionally restore backups)
├── .githooks/pre-commit         runs tests/Invoke-Validation.ps1 before commits
├── powershell/
│   ├── profile.ps1              loader (core→os→local)
│   ├── core/                    aliases, shared lib, tool inits, functions, completions, help
│   │     00-aliases  05-lib  08-git-safety  10-tools  15-update  20-functions  25-television
│   │     40-op  45-crypto  50-completions  55-help  57-health-nudge
│   ├── os/                      windows helpers + wsl bridge + psmux + remote + maint + doctor
│   │     30-windows  31-wsl-bridge  32-psmux  33-psmux-pill  34-remote  40-maint  45-doctor  48-core
│   └── local.ps1.example        copy to local.ps1 (gitignored)
├── maint/Maintenance.ps1        unattended daily maint runner (Task Scheduler)
├── windows-terminal/settings.json
├── starship/starship.toml       same prompt as the fleet (tokyonight-storm)
├── git/ (.gitconfig, .gitignore_global)
├── ssh/config                   hardened (no ControlMaster on Win OpenSSH)
├── psmux/psmux.conf             native host tmux (psmux), symlinked to ~/.config/psmux/
│       psmux.reset.conf  scripts/   (keybinds split out + popup helper scripts)
├── desktop/                     opt-in tiling desktop (GlazeWM + Zebar), symlinked to ~/.glzr
├── nvim/                        symlinked to %LOCALAPPDATA%\nvim (mirrors Core)
├── wsl/windows.wslconfig.example  canonical host WSL2 config (mirrored net)
├── packages/ (scoopfile.json, winget.json, Install-Packages.ps1)
├── docs/ (TOOLS.md, PORTING-NOTES.md, ARCHITECTURE-AUDIT.md, PACKAGE-OWNERSHIP.md, REMOTE-ACCESS.md)
└── CONTRIBUTING.md  SECURITY.md  .github/ (workflows, CODEOWNERS, templates)
```

`powershell/core/` is native pwsh config (**not** a vendored subtree); `nvim/`,
`starship/` and `theme/` are the three assets mirrored from `dotfiles-core`. The deep detail — the
fragment loader and coverage gate, the supply-chain-gated bootstrap, and the WSL
bridge — is written up on the hub, alongside the **[Windows architecture audit][audit]**:

> **[→ dotfiles-Windows on the documentation hub][repo-docs]**

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- CONTRIBUTING -->
## Contributing

This repo owns the Windows host directly, so its contribution rules differ from
the vendored-Core OS repos:

1. **Host config lives here — edit it here.** There is no vendored `core/` to
   avoid; `powershell/core/` is native pwsh config authored in this repo.
2. **Don't hand-edit the mirrored assets.** `nvim/`, `starship/starship.toml` and
   `theme/palette.toml` are synced from `dotfiles-core` (`nvim-sync.ps1` /
   `starship-sync.ps1` / `theme-sync.ps1`) — fix drift **upstream**, then re-sync,
   so the parity gate stays green.
3. **Don't hand-edit a colour.** Every hex in `powershell/core/` and `psmux/` that
   sits inside a `# core:theme:gen` marker — and every colour in the `Tokyo Night`
   scheme in `windows-terminal/settings.json` — is rendered from `theme/palette.toml`
   by `gen-theme.ps1`; `gen-theme.ps1 -Check` fails the PR that edits one by hand.
   Picking a colour in Windows Terminal's Settings pane counts.
4. **Green the gate.** `tests/Invoke-Validation.ps1` is the fast, dependency-free
   check; `pwsh -NoProfile -File tests/Invoke-Tests.ps1` is the full gated suite
   (the exact command CI runs). `.githooks/pre-commit`
   and CI mirror both.

Full rules — including the ones that bite (ASCII-only `bootstrap.ps1`, the README
hash pin, `# provides:`/`# requires:` contracts, app-owned `settings.json`) — are in
[CONTRIBUTING.md](CONTRIBUTING.md).

Bugs and ideas: open an
[issue](https://github.com/dotgibson/dotfiles-Windows/issues). Security problems:
please report them **privately** — see [SECURITY.md](SECURITY.md).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- LICENSE -->
## License

Distributed under the MIT License. See [`LICENSE`](LICENSE) for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- CONTACT -->
## Contact

Garrett Allen - [@gerrrrt](https://x.com/gerrrrt) - <garrettallen2@gmail.com> - [LinkedIn](https://linkedin.com/in/garrettallen2)

Project Link: [dotgibson](https://github.com/dotgibson/)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- Markdown Links & Images -->
[repo-docs]: https://dotgibson.github.io/dotfiles-web/docs/repos/dotfiles-Windows
[audit]: https://dotgibson.github.io/dotfiles-web/docs/reference/windows-architecture-audit
[dotgibson-shield]: https://img.shields.io/github/v/release/dotgibson/dotfiles-core?style=plastic&label=dotgibson&labelColor=181717&logo=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAF1klEQVR4nLSWbUxT7RnHr9PT09MXSltaoC9QXkqR16Iwhb0Iw8VYYE7jPri5aBaZzpmFZbpolpn4QeMyM%2BM%2B7MVt0Q9LNJIlxCzqxGWS6aKAig51vBQKIi3QltpCS0%2Fbc879pD1N3%2Bnz4fG5Pl2977v%2F331d131f5%2BZrddWQZAgAgy9uCRlefICzT6GeIsP%2FXF15kahmu9JglGmLRQoRQdIQWgu77BuWGe%2Fo%2BOqym8odApaWomTT1%2Bl2HqirahaTuJ9kQMggkgYhDRGfRiQDZBi9fuf52%2BD7l1b3ZhRcmq%2FMnBHmibuO7fvWoTalVoDjQRwL8RGgEOtzB0MbtBDnkRjGR0AgTK%2BQfNukr1LKXlhXKZpJSxTKGoFSq9vf16tQ8%2FiEh094Vu0L449mLGMup20DRWuFYVCiFm%2BvU36nTbOlMB%2BnCDxIOBzhvv6nFpc3TS0dUKDRHzh1Jk9O8wlPYN326Oa%2FJobnN8shAOxqKjrdXa8WSnGKWPewR%2FuHLG5P8oKUFJHi%2FH19F6UKEQ%2BnbJap27%2B%2BtWR15VAHgLkV%2F%2F0xW6OuQCfNE4PgmyX6f0xZKYbJDuj43lmtoYqHU%2FaZdwNXr4eoUG51zqgw%2B%2FCtrbm0UCeRynBhqVj2YC4RNC%2FuqStbKkydAODzeO7%2B6QYTpnOIYgB729R729RY9DAGafb0wDOHLwAA5vKK1mJNFoCpsxeLLn%2Fy91uU359719%2FfVXL%2BSM35IzU9rcXciCcQujz0imOfbGhOB0jkGo2hFQBW7Quzr0Zzq6vyBT%2FuKY%2BHErfBmQWLK1Lhr6l1OkleCqC0poPb%2FuTwv3OrA8DPDhgkokgLmLX77o86kqcGJmaj5xjr1JWlAAr1Js75MDEGAAI%2B1mvWX%2F1JY29XmYDPS5ZoNsrM24si1xSh3%2FRbGBYlz%2F73g41ztqliqYv1onyVHgDocMjjXASAKycavlqnZBHa2ajcasjv%2B8MbAPhRV9nI5MezB41crIPPHWOW9Gtl9XhDDCMCokIqSwGQ4shvyucFhEQCnqlSdm9k%2BdKt6XM%2FqO7aof7t8YbIIW5SHdpVIhUTAOAP0L8bmM3MHgJwByidQCgnhSmAqOEYnQ8AgRBr%2FuUzKsgggIs3pyVCfkeTCgAmFtaNOgm39C%2F3511r2W8JYvIAJbIaAwQ3vKAEoVgRaTQIBYKxqxgMs6euvdUXiQDgeHd5rV7K1fb2kC2rOgaYghQBMJ5grI3HUGuuhQiNIOWq8sy%2FLTgCKplgT0ZtCyprWw7%2FvKCyNr6yQqYg8cim59a9KQDnwv84R1%2F99UwAzsMya4vxeOYLN7YePGG%2BcAPjxXS%2BoavknFfOlRTAh8nHKNqLa1v2ZwK6dxQZtHk5ahu3%2FcYmLsoh%2B%2FsUgN%2BztDQzEvkYFBurGnan%2FS1%2B1P98L1FbxLIPzh193X%2FtwbmjiGUBYHd5nVFRCABPlxdtfh%2B3LHGKxof%2Bqo90C6yj58yi9Tm1kWjr94ZXsGhTuDuynAx2z0245yY4X06Kf9HWFd0N%2BuPbsUR64%2B3a57Erig2qIoOIlJSUNE69GWTZRFufXvRNL%2Fo2ywyJE1fMP6xWqHBEP5yfvP7%2FbAAAsFufG01mkVCqkGvLyrbNTD2mw9kfDckmE0oudx9rUZfhiF5Zd%2F%2F00QDF0NkBTJhanB3e0riHJIRKhXarqWfdu%2Bx0WnOot1ftuNR90lhQzEO0L7B2YvCm3b%2BWNI%2ByffSLq757%2BPcquYaIvBtgdcXycuzO9MzTFdccd9IwDNMVlDaXbzPXtxsVhQRDEQzl8i6d%2Buf12Y%2BONDVMo6vOfHWJxHLz3l811u8WAEZABCNAAHSI8n8k2HABKRJjLJ8JECxFMAE%2BHXhiGb7yn35vcCNDKVsEcSuv%2BEpn%2B7Etla0CwAQIOBLBhrkt85kAnwm8mX95e%2FTOa9vUZiIxQI43r0Kura9uN5SYNMoyuVDGZ2nK73C65iy28Rezo44152bSKYAvz3ifVA1lDn0WAAD%2F%2F%2FWvXexgMwqgAAAAAElFTkSuQmCC
[dotgibson-url]: https://github.com/dotgibson/dotfiles-core/releases/latest
[ci-shield]: https://img.shields.io/github/check-runs/dotgibson/dotfiles-Windows/main?style=plastic&logo=githubactions&logoColor=white&label=CI
[ci-url]: https://github.com/dotgibson/dotfiles-Windows/actions/workflows/ci.yml
[lastcommit-shield]: https://img.shields.io/github/last-commit/dotgibson/dotfiles-Windows?branch=main&style=plastic&logo=git&logoColor=white
[contributors-shield]: https://img.shields.io/github/contributors/dotgibson/dotfiles-Windows.svg?style=plastic&logo=github
[contributors-url]: https://github.com/dotgibson/dotfiles-Windows/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/dotgibson/dotfiles-Windows.svg?style=plastic&logo=github
[forks-url]: https://github.com/dotgibson/dotfiles-Windows/network/members
[stars-shield]: https://img.shields.io/github/stars/dotgibson/dotfiles-Windows.svg?style=plastic&logo=github
[stars-url]: https://github.com/dotgibson/dotfiles-Windows/stargazers
[issues-shield]: https://img.shields.io/github/issues/dotgibson/dotfiles-Windows?style=plastic&logo=github
[issues-url]: https://github.com/dotgibson/dotfiles-Windows/issues
[license-shield]: https://img.shields.io/github/license/dotgibson/dotfiles-Windows.svg?style=plastic
[license-url]: https://github.com/dotgibson/dotfiles-Windows/blob/main/LICENSE
[docs]: https://dotgibson.github.io/dotfiles-web/docs
[powershell-shield]: https://img.shields.io/github/v/release/PowerShell/PowerShell?style=plastic&logo=powershell&logoColor=white&label=PowerShell&labelColor=5391FE&color=3D59A1
[powershell-url]: https://github.com/PowerShell/PowerShell
[wt-shield]: https://img.shields.io/github/v/release/microsoft/terminal?style=plastic&logo=windowsterminal&logoColor=white&label=Windows%20Terminal&labelColor=4D4D4D&color=3D59A1
[wt-url]: https://github.com/microsoft/terminal
[scoop-shield]: https://img.shields.io/badge/Scoop-555555?style=plastic
[scoop-url]: https://scoop.sh
[winget-shield]: https://img.shields.io/github/v/release/microsoft/winget-cli?style=plastic&logo=gnometerminal&logoColor=24283B&label=WinGet&labelColor=BB9AF7&color=3D59A1
[winget-url]: https://github.com/microsoft/winget-cli
[psmux-shield]: https://img.shields.io/github/v/release/psmux/psmux?style=plastic&logo=gnometerminal&logoColor=24283B&label=psmux&labelColor=BB9AF7&color=3D59A1
[psmux-url]: https://github.com/psmux
