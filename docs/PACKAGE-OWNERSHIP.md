# PACKAGE-OWNERSHIP.md — who owns what, and why

Written 2026-07-20 after retiring Chocolatey from the host. This is the rule
this repo's package layer assumes; `TOOLS.md` covers *which* tools and why,
this covers *which manager installs them*.

## The rule

| Manager     | Owns                                                | Manifest           |
| ----------- | --------------------------------------------------- | ------------------ |
| scoop       | CLI tools, language runtimes, fonts                  | `scoopfile.json`   |
| winget      | GUI apps, system components, shell-integrated things | `winget.json`      |
| chocolatey  | **nothing — retired, do not reintroduce**            | —                  |

Chocolatey was removed because all 40 of its packages duplicated scoop/winget,
its versions lagged (`ripgrep` 14.1.0 vs scoop's 15.2.0), and
`C:\ProgramData\chocolatey\bin` sat early enough on the machine PATH that its
**stale** shims won for `fd`, `julia`, `wget`, `make`, `7z`, and `tree-sitter`.

## Deliberate exceptions to "scoop owns CLI"

Three CLI tools live in winget on purpose. Do not "fix" these:

- **`Git.Git`** — the Program Files install provides Git Bash, Credential
  Manager, and shell integration. Scoop only needs *a* git on PATH.
- **`Microsoft.PowerShell`** — the daily-driver shell; wants the system install.
- **`GNU.Wget2`** — see below.

Python is winget-owned (at whatever prefix winget chose — `C:\Python314` on the
reference host) because the `py` launcher and `uv`
resolve to it. `scoopfile.json` deliberately does **not** declare `python` —
declaring it recreates a duplicate interpreter on every install run.

> **"Reference host" means one specific machine.** Some passages below record what
> was actually observed on the dev box (install prefixes, an AV registration GUID,
> which ruby was present) because the *reasoning* only makes sense with the
> evidence attached. Those are snapshots, not invariants — verify before relying on
> one on a different machine.

## `wget` is a shim, not a package

scoop's `wget` manifest downloads from `eternallybored.org`, which resolves to
a sinkhole on this host — a DNS-level filter, not a hosts entry (observed as
`127.250.0.1` here; that address is whatever the local resolver returns, so don't
treat it as a constant).
Rather than bypass it, `wget` is a shim at `~/bin/wget.cmd` forwarding to
winget's `GNU.Wget2`. If you rebuild the host, recreate it:

```bat
@echo off
"%LOCALAPPDATA%\Microsoft\WinGet\Links\wget2.exe" %*
```

## PATH is near its ceiling

Windows truncates the combined machine+user PATH at **2048 characters**. As of
this writing it sits at **1906**. Truncation is silent and looks exactly like a
missing package — entries at the tail simply stop resolving.

Before adding a PATH entry, check the budget:

```powershell
$m = [Environment]::GetEnvironmentVariable('Path','Machine')
$u = [Environment]::GetEnvironmentVariable('Path','User')
"$($m.Length + $u.Length + 1) / 2048"
```

`C:\Program Files\7-Zip` is prepended to the **machine** PATH on purpose: Lua for
Windows ships a 2010-era `7z.exe` at `C:\Program Files (x86)\Lua\5.1`, and since
machine PATH always precedes user PATH, scoop's shim can never win that race.

## Removing a "duplicate" version — read this first

Two registrations with different version strings **do not** imply two installs.
Both of these bit us on 2026-07-20:

- **Julia** — choco reported 1.12.0, winget 1.12.6. One install, two trackers.
  Removing choco's copy deleted the files winget still claimed.
- **7-Zip** — 24.07 and 26.02 both installed to `C:\Program Files\7-Zip`.
  Uninstalling the stale 24.07 registration ran its uninstaller and gutted
  26.02, which kept reporting as installed.

Verify the install directory before removing anything that looks like a stale
version:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  Where-Object DisplayName -match '<name>' |
  Select-Object DisplayName, DisplayVersion, InstallLocation
```

If two entries share an `InstallLocation`, they are one install. Deregister
rather than uninstall.

## A manager listing something is not proof it installed it

The corollary, and the one that took longest to see. **An absent ARP entry is as
informative as a shared one** — it tells you which manager can actually remove a
package, and therefore which manager's claim is real.

Julia is the worked example. Its installer is Inno Setup with
`CreateUninstallRegKey=no`: it writes `uninstall\unins000.exe` and registers
*nothing* in ARP. So the ARP entry that existed on 2026-07-20 was
**Chocolatey's**, describing a directory choco had installed into. winget had
been listing Julia the whole time on the strength of someone else's registration.

Two consequences follow, and both bit:

1. Removing choco's Julia deleted the files, because choco genuinely owned that
   install — winget's listing was never a second copy.
2. Afterwards `winget uninstall` failed with `0x800401f5 Application not found`
   **and could not be fixed by reinstalling**, because a fresh install still
   registers nothing for winget to correlate against.

The record was cleared by supplying the missing registration — a single HKCU key
with `UninstallString` pointing at the real `unins000.exe`, so winget could
correlate, run Julia's own uninstaller, and drop its tracking entry in one
supported operation. The key is not removed by Inno afterwards (it did not create
it), so delete it yourself once winget reports success.

Do **not** edit winget's tracking database to fix this class of problem — it
lives under the App Installer package data:

```text
%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\Microsoft.Winget.Source_8wekyb3d8bbwe\installed.db
```

It is held open by a running service, and corrupting it breaks winget entirely
rather than just the offending row.

Before removing anything, ask which manager can *uninstall* it:

```powershell
# No ARP entry => winget/choco cannot remove it, whatever `list` claims.
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  Where-Object { $_.DisplayName -match '<name>' -or $_.InstallLocation -match '<name>' } |
  Select-Object DisplayName, InstallLocation, UninstallString
```

## A directory is not an install: the .NET phantom runtimes

The same lie in a fourth place. ARP can misattribute an install, winget's tracking
db can outlive one — and `dotnet --list-runtimes` can invent one outright, because
it enumerates directory **names** under `shared\`, never their contents.

Found 2026-07-20 in `C:\Program Files\dotnet`:

| Path | Contents | Reported as installed |
| ---- | -------- | --------------------- |
| `shared\Microsoft.NETCore.App\9.0.6`        | 3 metadata files, 0 DLLs   | yes |
| `shared\Microsoft.WindowsDesktop.App\9.0.6` | 2 metadata files, 0 DLLs   | yes |
| `shared\Microsoft.AspNetCore.App\9.0.6`     | 4 metadata files, 0 DLLs   | yes |
| `sdk\9.0.301`                               | 863 metadata files, 0 DLLs | no — needs `dotnet.dll` |

No ARP entry claimed any of them: a .NET 9 uninstall had taken the binaries and the
registrations but left the version directories standing.

**An empty version directory is worse than no directory.** Because `9.0.6` existed,
the host *selected* it and then died:

```text
A fatal error was encountered. The library 'hostpolicy.dll' required to execute
the application was not found in '...\shared\Microsoft.NETCore.App\9.0.6'
```

Deleting the empty directories restores the correct, actionable failure:

```text
You must install or update .NET to run this application.
Framework: 'Microsoft.NETCore.App', version '9.0.0' (x64)
```

So `dotnet --list-runtimes` is a claim, not evidence. Verify with a DLL count
before trusting it, and before removing a runtime that looks redundant:

```powershell
Get-ChildItem 'C:\Program Files\dotnet\shared' -Directory | ForEach-Object {
  Get-ChildItem $_.FullName -Directory | ForEach-Object {
    '{0,-52} dlls={1}' -f $_.FullName.Replace('C:\Program Files\dotnet\shared\',''),
      (Get-ChildItem $_.FullName -Filter *.dll -File -EA SilentlyContinue).Count
  }
}
```

### Before removing a shared runtime, classify its consumers

`*.runtimeconfig.json` says which apps actually need a machine-wide runtime, and
the distinction is the whole answer:

- `"includedFrameworks"` — **self-contained**, ships its own runtime, unaffected by
  anything you do to `C:\Program Files\dotnet`.
- `"framework"` — **framework-dependent**, genuinely needs it. Check `rollForward`
  too: the default stays within the same major, so .NET 10 does not rescue a
  net9.0 app.

Of 12 net9.0 apps on this host, 9 were self-contained (ShareX among them — it is a
declared dependency in `winget.json` and bundles 9.0.17 internally). Only 3 were
framework-dependent, all Razer Cortex plugins, and all already broken by the
phantom.

.NET 6 was removed the same day by the same method: nothing outside
`C:\Program Files\dotnet` targeted it, and it had been out of support since
November 2024.

## The stale registration that must NOT be cleaned: BullGuard

There is a third registry of installed software besides ARP and winget's tracking
db — **Windows Security Center** — and it holds a ghost this repo deliberately
leaves alone.

`Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct`
reports **BullGuard Antivirus** as `enabled=ON, definitions=OUT-OF-DATE`. It is
entirely fictional: both executables it names are absent, and there is no
service, process, install directory, or ARP entry. BullGuard was discontinued
(folded into Norton) and its uninstaller never called
`WscUnRegisterSecurityProvider`. The leftover key is:

```text
HKLM\SOFTWARE\Microsoft\Security Center\Provider\Av\{0C5A09FB-657F-B94D-DF1B-BB843C6EE0E4}
```

**It cannot be deleted, and that is correct behaviour.** The ACL grants `Delete`
to exactly one identity, `NT SERVICE\wscsvc` — the Security Center service.
SYSTEM gets only `SetValue, CreateSubKey, ReadKey`; Administrators are not in the
ACL at all. Verified on 2026-07-20: `reg delete` fails as Administrator, fails as
`NT AUTHORITY\SYSTEM` (via `gsudo -s`), and restarting `wscsvc` does not purge it.

That protection exists so malware cannot silently deregister your antivirus.
Taking ownership to grant yourself `Delete` defeats it. Do not do that — "it is
only a stale entry" is exactly the reasoning the control is built to resist.

### The real risk, and the cheap mitigation

Nothing is wrong today: Malwarebytes is active with current definitions, and
Defender is correctly passive (`AMRunningMode: Not running`) because a third-party
AV owns protection.

The danger is conditional. Windows decides whether to re-enable Defender based on
whether any *other* product claims to be enabled — and this ghost claims exactly
that. **If Malwarebytes is ever removed or replaced, Defender may not turn itself
back on, leaving no antivirus at all while Security Center believes otherwise.**

So after any antivirus change, check explicitly rather than assuming:

```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled
```

If that reports `Not running` and no other AV is installed, re-enable Defender by
hand in Windows Security.

Two legitimate ways it could still disappear, neither worth doing for its own
sake: a Windows in-place upgrade/repair install rebuilds the Security Center
store, and Malwarebytes' own `mb-clean` support tool has historically cleared
stale WSC registrations (vendor tooling, running with the privileges intended for
the job).

A backup of the key was taken on the reference host at
`~\pkg-backup-2026-07-20\bullguard-av-registration.reg` — that path exists on that
machine only; export your own before touching the key.

## mise owns node, and only node

`mise` had been installed and activated (`powershell/core/10-tools.ps1`) since
before this cleanup while managing **zero** runtimes. It now owns exactly one:

```toml
# mise/config.toml, linked to ~/.config/mise/config.toml
[tools]
node = "24"
```

Node was previously winget's `OpenJS.NodeJS.LTS` and — like python and ruby — was
never declared in any manifest, so a rebuilt host would not have got it. Moving it
to a committed `mise/config.toml` brings it under version control for the first time.

Scope stops there deliberately:

- **python** stays winget-owned at winget's prefix (`C:\Python314` on the
  reference host). mise installs
  `python-build-standalone` builds, which register nothing under
  `HKLM\SOFTWARE\Python\PythonCore` and do not provide the `py` launcher (which is
  separately installed and would break). `uv` is already present and does
  per-project python on Windows better than mise would.
- **ruby** stays winget-owned. mise's `core:ruby` is built on `ruby-build`, a Unix
  shell toolchain; `mise ls-remote ruby` listing versions does not establish that
  installing one works. (On the reference host, as of 2026-07, ruby 4.0.6 was the
  only one present — a snapshot, not an invariant.)
- **php / java / julia / composer** stay scoop-owned, declared in
  `packages/scoopfile.json`.

### The two things that bite

**npm globals are per-node-version.** They no longer live in `%APPDATA%\npm`
(that directory and its PATH entry are gone). After a major node bump they must be
reinstalled, and one of them is load-bearing:

```powershell
npm install -g neovim obsidian-headless
nvim --headless "+checkhealth provider" +qa   # Node provider must report OK
```

`neovim@5.4.0` is nvim's **Node provider host**. If it goes missing, node-based
plugins fail — quietly.

**node is no longer on the system PATH.** It exists only inside a mise-activated
shell. Anything that shells out to `node` from a non-shell context — a scheduled
task, a service, a GUI app — will not find it. Interactive shells are fine because
`10-tools.ps1` activates mise. This also broke `yarn` until the orphaned corepack
shims left behind in `C:\Program Files\nodejs` were deleted; `yarn` and `pnpm` both
carry their own installs and work normally now.

## Undeclared on purpose

- `cacert`, `dark`, `innounp`, `mingw` — scoop auto-dependencies, pulled in as
  needed. Declaring them pins transitive deps for no benefit.
- `gzip`, `unzip` — installed only to replace choco shims. `7zip` and `ouch`
  cover archives; not worth manifest space.

## Overlap is intentional

`bottom`/`btop-lhm`/`procs`, `eza`/`lsd`, `delta`/`difftastic`, `fzf`/`television`,
`curl`/`xh` all coexist by design — the rationale for each is in `TOOLS.md`
(e.g. btop-lhm reads hardware sensors; television is deliberately denied Ctrl+R
because atuin owns it). Do not "deduplicate" these without reading that table.

`fastfetch` is declared but referenced nowhere in config — that is correct, it is
a run-by-hand tool.
