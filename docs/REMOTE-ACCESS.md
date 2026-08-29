# Remote access: ssh into this host, and into the distros behind it

Standing OpenSSH Server up on a Windows box that also hosts WSL2 breaks two things
that have nothing obvious to do with sshd:

1. **The PowerShell profile stops loading over ssh** — reported as "untrusted
   source". It still loads fine in Windows Terminal.
2. **The Linux boxes stop answering** — and the ones that do only answer while a
   terminal happens to be open on the host.

Both are real. Neither is a WSL fault, and — importantly — neither is an
execution-policy or Mark-of-the-Web problem, which is where almost every guide
sends you first.

---

## 1. Why the profile is "untrusted" over ssh

**It is Redirection Guard, and it is not configurable.**

Windows enforces the process mitigation `ProcessRedirectionTrustPolicy`
(a.k.a. Redirection Guard) across the whole **service / session-0 lineage**. A
process with it enforced refuses to traverse a reparse point — a symlink or a
junction — whose target sits under a directory owned by a non-admin principal.
The failure is `ERROR_UNTRUSTED_MOUNT_POINT`, which surfaces as:

```
The path cannot be traversed because it contains an untrusted mount point.
```

Every config this repo wires used to be a symlink into a repo under
`C:\Users\<you>\...`, which is exactly the shape the mitigation blocks.

### Confirm it in one command

Run this **in the session that is broken** (over ssh, or from any
scheduled-task/service-launched shell):

```powershell
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class M {
  [DllImport("kernel32.dll")] public static extern bool GetProcessMitigationPolicy(IntPtr h,int p,out uint b,IntPtr s);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
}
'@
$v = 0
[M]::GetProcessMitigationPolicy([M]::GetCurrentProcess(), 15, [ref]$v, [IntPtr]4) | Out-Null
'0x{0:X}' -f $v      # bit 0 set (e.g. 0x105) = ENFORCED;  0x100 = not enforced
```

Measured on a real host, the split is clean and explains the symptom exactly:

| Process | Policy | |
| --- | --- | --- |
| `explorer`, `WindowsTerminal`, `glazewm` | `0x100` | not enforced — this is why the desktop always worked |
| `services.exe`, `wslservice`, Task Scheduler `svchost`, `sshd` | `0x105` | **enforced** — every ssh session inherits this |

### What does *not* fix it

These were each tried on a real host and each did nothing. Do not spend an
evening on them:

| Attempt | Result |
| --- | --- |
| `fsutil behavior set SymlinkEvaluation R2L:1` | no effect. This is a different mechanism (remote/UNC paths), not Redirection Guard |
| Deleting `MitigationOptions` from the `sshd.exe` IFEO key | no effect — the lineage default still applies |
| Setting IFEO `MitigationOptions` to `REDIRECTION_TRUST_ALWAYS_OFF` (`0x2 << 20`) | **ignored** — the policy is inherited and non-relaxable, which is the entire point of it |
| Changing the **symlink's** owner to `BUILTIN\Administrators` | no effect — the link's owner is not the discriminator |
| Running sshd as a real Windows service instead of a scheduled task | would not help: `services.exe` is `0x105` too |

The one thing that *is* a discriminator is the **target's** owner: a reparse
point whose target directory is owned by `BUILTIN\Administrators` traverses fine
even under enforcement. That is a lever for scoop (below), not for a repo you
need to be able to edit as yourself.

### What this repo does instead

Stop using reparse points for the configs that have to work over ssh. The three
that matter are wired as **real files** that pull in the repo copy through the
config format's own include mechanism — same single source of truth, no reparse
point. This is `Kind = 'Stub'` in `Get-DotfilesLinkPlan`
(`powershell/core/05-lib.ps1`), rendered by `Get-DotfilesStubContent`:

| Config | Mechanism |
| --- | --- |
| `$PROFILE` | a real `.ps1` that dot-sources `powershell/profile.ps1` |
| `~/.gitconfig` | `[include] path = <repo>/git/.gitconfig` |
| `~/.ssh/config` | `Include <repo>\ssh\config`, on the first line |

Everything else stays a symlink, either because the format has no include
directive (`.gitignore_global`) or because it is only ever used interactively
(Windows Terminal, GlazeWM, Zebar).

Two consequences worth knowing:

- **`~/.gitignore_global` stays a symlink on purpose.** A `.gitignore` has
  nothing to include, so the `.gitconfig` stub instead overrides
  `core.excludesfile` to point straight at the repo copy — *after* the include,
  because last value wins for a single-valued key.
- **`~/.ssh/config` bites twice.** As a symlink it also stalls the ssh **client**
  on the host itself, because `ssh.exe` reads it at startup and inherits the same
  enforcement. Symptom: a plain `ssh` hangs while `ssh -F NUL` returns instantly.

Re-wire an existing box with:

```powershell
.\install.ps1 -SkipPackages
```

`dotfiles-doctor` reports a stub row as `stub -> repo`, and flags a stub-kind row
that is still a symlink as *"will not resolve over ssh"*.

### What is still broken: scoop

`scoop` points every app at its current version with a **junction**
(`scoop\apps\<app>\current`), and those junctions have the same problem. On a box
with 78 scoop apps, 77 were unreachable over ssh — no `starship`, no `mise`, no
`jj`. The one that worked differed only in that its target version directory was
owned by `BUILTIN\Administrators`.

There is no stub trick for a junction. The options are to leave scoop tools out
of ssh sessions, or to take ownership of the app directories:

```powershell
icacls "$env:USERPROFILE\scoop\apps\<app>\<version>" /setowner "BUILTIN\Administrators"
```

Ownership does not revoke your ACLs, so scoop keeps working — but scoop creates a
fresh, user-owned directory on every update, so this needs re-applying (a job for
`maint/Maintenance.ps1`, not a one-off).

### The things people usually blame, and how to rule them out fast

None of these caused the failure above, but they are real and cheap to check:

```powershell
whoami                      # is the ssh session even the account you think?
$PROFILE; Test-Path $PROFILE
Get-ExecutionPolicy -List   # NB: Process scope does NOT reach an ssh session
Get-Item -LiteralPath $PROFILE -Stream Zone.Identifier -ErrorAction SilentlyContinue
```

- `Test-Path $PROFILE` false → the ssh session resolved a *different* `$PROFILE`
  (different account, or a `Documents` redirect that only exists interactively).
- `CurrentUser` is `Undefined` while `Process` is `Bypass` → your terminal
  shortcut launches pwsh with `-ExecutionPolicy Bypass`, and **a Process-scope
  policy is not inherited by an ssh session**. Fix with
  `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`.
- A `Zone.Identifier` stream exists → Mark-of-the-Web; the repo arrived as a
  download, not a clone. `Get-ChildItem $env:DOTFILES_WIN -Recurse -File | Unblock-File`.

### `ssh host <command>` hangs

Not a trust problem, and easy to mistake for one. Windows OpenSSH's default shell
is `cmd.exe` unless `HKLM:\SOFTWARE\OpenSSH\DefaultShell` says otherwise — and if
`DefaultShell` points at `pwsh.exe` but **`DefaultShellCommandOption` is unset**,
then `ssh host <command>` launches pwsh interactively and waits on stdin forever.
Interactive `ssh host` works; every scripted command hangs.

```powershell
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellCommandOption -Value '-Command' -PropertyType String -Force
```

### The key that isn't read

If your account is in the local **Administrators** group, the stock `sshd_config`
contains:

```text
Match Group administrators
    AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

so a key appended to `~/.ssh/authorized_keys` is read by **nobody**. If that block
is commented out (as it is on a hand-tuned host), `~/.ssh/authorized_keys` is used
and everything works — but restoring a stock config would silently break key auth.
The machine-level file is also ignored unless its ACL grants only Administrators
and SYSTEM.

---

## 2. Why the Linux boxes stopped answering

### It is usually not a port collision

The common advice is that the Windows sshd binds `0.0.0.0:22` at boot and starves
a distro sshd that wants the same port. That is only true if you actually left the
Windows host on 22 — check before assuming:

```powershell
Get-Content C:\ProgramData\ssh\sshd_config | Select-String '^Port'
```

Give one port per box either way. A distro's port is set **inside the distro**, in
`/etc/ssh/sshd_config`, which belongs to that distro's own repo
(`dotfiles-Debian` for the Kali/Debian/Ubuntu family) — not to this one:

```bash
# inside the distro
sudo sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
sudo systemctl enable --now ssh
```

To see what is actually listening, grab the banners from the host — this
identifies each daemon rather than guessing from config:

```powershell
foreach ($p in 22,2220,2222,2223,2224,2225,2226) {
  $c = New-Object Net.Sockets.TcpClient
  if ($c.ConnectAsync('127.0.0.1',$p).Wait(1200) -and $c.Connected) {
    $c.ReceiveTimeout = 1200
    '{0}  {1}' -f $p, (New-Object IO.StreamReader($c.GetStream())).ReadLine()
  }
  $c.Close()
}
```

The Debian-family banners (`OpenSSH_10.3p1 Debian-4`) distinguish a Kali distro
from an Arch or Fedora one at a glance.

### The distro isn't running

This is the real cause of "it only works when I have a terminal open".

WSL2 tears a distro down once its **last process exits**, and the utility VM
follows after `vmIdleTimeout`. A distro running real **systemd** stays up once
started, because PID 1 never exits — one without it (Alpine, or any distro whose
`/etc/wsl.conf` says `systemd=true` but whose PID 1 is not systemd) does not.

The host-side fix is a **boot task that starts each distro you want reachable**.
A task that runs bare `wsl.exe --exec true` starts only the *default* distro,
which is a common and confusing half-fix:

```powershell
# one action per distro, not one action total
wsl.exe -d <distro> --exec /bin/true
```

Optionally add `vmIdleTimeout=-1` under `[wsl2]` in `%USERPROFILE%\.wslconfig` so
the VM stops winding down while you are away. It needs `wsl --shutdown` to apply,
which kills every running distro and any session inside them — so do it
deliberately.

Check what is up, and who is connected to what, without guessing:

```powershell
wsl -l -v                                     # which distros are running
wsl -d <distro> --exec who                    # who is logged in, and from where
```

> With `networkingMode=mirrored`, `ss` inside any distro shows the **host's**
> whole peer list, so it cannot tell you which distro a connection belongs to.
> Use `who` for per-distro attribution.

### Restarting the host sshd does not drop your distro sessions

Worth knowing before you hesitate over a restart. If you reach the distros
directly (MacBook → distro port), those connections are served by each distro's
own sshd *inside* the distro, and the Windows sshd is not in the path. Restarting
it drops only what is connected to the host's own port — and even then, existing
sshd session processes survive, because each session is an independent process
tree. Check first:

```powershell
Get-NetTCPConnection -LocalPort <hostport> -State Established
```

Sessions reached via `ProxyJump` through the Windows host **are** in the path and
will drop.

---

## 3. "It used to work while the machine was asleep"

It didn't, and this is worth being blunt about: **a sleeping Windows box serves no
ssh.** What changed is almost certainly that the box now actually sleeps.

- **Don't sleep on AC:** `powercfg /change standby-timeout-ac 0`. Check what you
  already have with
  `powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE` — an index of `0` means
  it never sleeps on AC and this is not your problem.
- **Wake-on-LAN**, if you must: enable it on the NIC and in firmware, then send a
  magic packet before connecting. Unreliable on Modern Standby (S0) laptops, and
  **fast startup** must be off or a shut-down box will not wake at all.

---

## 4. What to expose

The default shape is **one open port** to the Windows host, with the distros
reached through it:

```sshconfig
# on the machine you ssh FROM
Host winbox
    HostName 192.168.1.50
    Port 2220
    User you
    IdentityFile ~/.ssh/id_ed25519

Host kali
    HostName 127.0.0.1        # loopback from winbox's point of view
    Port 2222
    ProxyJump winbox
```

The distro half of that is generated, not hand-written. Run this **on the Windows
host** and paste the output into the client's `~/.ssh/config`:

```powershell
wsl-ssh-config -JumpHost winbox
```

It allocates a stable port per distro from the *sorted* distro list, so the map
does not shuffle when you install, unregister or re-default one — a port that
moves is worse than no port, because it is already baked into ssh_config,
firewall rules and muscle memory. It also refuses to hand out the port the
Windows sshd itself answers on; pass `-HostPort` if that is not 22. Without
`-JumpHost` it emits the direct shape instead, dialling this box's LAN address.

It prints and never writes — the file this belongs in is on the other machine.
The `winbox` entry stays hand-written for the same reason: it carries your key
and account, which this repo does not know.

The alternative — a LAN firewall rule per distro — is one hop less and one more
network-facing listener per distro. Prefer the jump host for anything reachable
from outside the house.

Whatever you expose, `sshd_config` should have `PasswordAuthentication no` once
your key works. Verify the key **first**, in a second session, with the first one
still open.
