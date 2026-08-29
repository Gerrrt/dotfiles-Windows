# Remote access: ssh into this host, and into the distros behind it

Standing OpenSSH Server up on a Windows box that also hosts WSL2 breaks two
things that have nothing obvious to do with sshd:

1. **The PowerShell profile stops loading over ssh** — usually reported as
   "untrusted source". It still loads fine in Windows Terminal.
2. **The Linux boxes stop answering** — and the ones that do only answer while a
   terminal happens to be open on the host.

Both are real, both are caused by the install, and neither is a WSL fault. This
page is the diagnosis and the fix; `remote-doctor` is the same thing as a check
you can run.

```powershell
remote-doctor                 # what an ssh session would actually get
remote-doctor -ProbeDistros   # ...and what each distro's sshd is configured for
remote-setup                  # apply the host-side fixes (elevates)
```

---

## 1. Why the profile is "untrusted" over ssh

An ssh session is **not the shell you tested in**. Four different things produce
the same symptom, so check which one you have before fixing anything:

```powershell
# run this over ssh, not in a local terminal
whoami
$PROFILE
Test-Path $PROFILE
Get-ExecutionPolicy -List
Get-Item -LiteralPath $PROFILE -Force | Select-Object LinkType, Target
Get-Item -LiteralPath $PROFILE -Stream Zone.Identifier -ErrorAction SilentlyContinue
```

| What you see | What it means | Fix |
| --- | --- | --- |
| `Test-Path $PROFILE` is `False` | the ssh session resolved a **different** `$PROFILE` than your desktop session — a different account, or a `Documents` redirect that only exists interactively | compare `whoami` and `$PROFILE` in both sessions, then run `install.ps1 -SkipPackages` **as the account you ssh in as** |
| `CurrentUser` is `Undefined` and `Process` is `Bypass` locally | your terminal shortcut launches pwsh with `-ExecutionPolicy Bypass`. **A Process-scope policy does not reach an ssh session**, so the profile is refused there and nowhere else | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` |
| `CurrentUser` is `Restricted` / `AllSigned` | the policy refuses the profile outright | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` |
| a `Zone.Identifier` stream exists | Mark-of-the-Web: the repo arrived as a **download**, not a clone, so `RemoteSigned` treats it as internet content | `Get-ChildItem $env:DOTFILES_WIN -Recurse -File \| Unblock-File` |
| `$PROFILE` or its symlink `Target` starts with `\\` | `RemoteSigned` judges by **zone**, and a UNC path (`\\server\share`, `\\wsl.localhost\…`) is not the local zone. An unsigned script there is refused however local it feels | move the repo to a local path, point `DOTFILES_WIN` at it, re-run `install.ps1 -SkipPackages` |

`remote-doctor` reads that table for you, and it deliberately ignores **Process**
scope when it does: `Get-ExecutionPolicy` reports the effective policy of the
shell you run it from, so a terminal launched with `-ExecutionPolicy Bypass`
would make the probe report health that no ssh session ever gets. It walks the
scope precedence with Process removed — which is exactly the scope an ssh session
does not inherit.

There is also a fifth case that isn't about trust at all, and it is the most
common of the lot:

> **`ssh you@host` drops you in `cmd.exe`.** Windows OpenSSH's default shell is
> `cmd.exe` unless `HKLM:\SOFTWARE\OpenSSH\DefaultShell` says otherwise. No
> profile is *blocked* — none was ever going to load. `remote-setup` points it
> at your `pwsh.exe` (and sets `DefaultShellCommandOption` to `-Command`, which
> is what makes `ssh host <command>` work).

### The key that isn't read

Not a profile problem, but it costs everyone the same evening. If your account
is in the local **Administrators** group, the stock `sshd_config` contains:

```text
Match Group administrators
    AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

so a key appended to `~/.ssh/authorized_keys` is read by **nobody**, and you
silently fall back to a password prompt. The machine-level file is also ignored
unless its ACL grants only Administrators and SYSTEM. `remote-setup` creates it
with the right ACL; put your public key there.

---

## 2. Why the Linux boxes stopped answering

Two independent causes, and it is worth separating them because the symptoms
overlap.

### The port collision

The Windows sshd service binds `0.0.0.0:22` **at boot**. With
`networkingMode=mirrored` (which `wsl/windows.wslconfig.example` recommends, and
which you want) the distros share the host's interfaces — so a distro sshd that
also wants port 22 has nothing to bind to. It doesn't warn you from the Windows
side; it just isn't there.

The fix is one port per box. The Windows host keeps 22; each distro gets its own
port, assigned from the **sorted distro name list** so the map doesn't shuffle
when you install or unregister a distro:

```powershell
wsl-ssh-config                    # the ssh_config blocks, ports already assigned
wsl-ssh-config -JumpHost winbox   # ...routed through the Windows host instead
```

The port has to be set **inside the distro**, in `/etc/ssh/sshd_config` — that
file belongs to that distro's own repo (`dotfiles-Debian` for the
Kali/Debian/Ubuntu family), not to this one:

```bash
# inside the distro
sudo sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
sudo systemctl enable --now ssh
```

`remote-doctor -ProbeDistros` reads that file for every distro and tells you
which ones are still on 22.

### The distro isn't running

WSL2 tears a distro down once its **last process exits**, and the utility VM
follows after `vmIdleTimeout`. That is the whole of "it only works when I have a
terminal open on Windows": with no terminal, nothing is running, so nothing is
listening.

Two host-side settings fix it, and `remote-setup` does both:

- `vmIdleTimeout=-1` under `[wsl2]` in `%USERPROFILE%\.wslconfig` — the VM stops
  winding down when you are away from the keyboard (`wsl --shutdown` to apply).
- A **logon task** (`dotfiles-wsl-keepalive`) that runs `wslup`, which starts
  sshd in each distro. sshd is itself a live process, so a started distro stays
  up — the daemon is the keepalive.

```powershell
wslup                # start sshd in every distro right now
wsls                 # which distros are actually running
```

---

## 3. "It used to work while the machine was asleep"

It didn't, and this is worth being blunt about: **a sleeping Windows box serves
no ssh.** What changed is almost certainly that the box now actually sleeps —
or that it always did, and you were reaching the distros during the window when
it was awake.

Pick one:

- **Don't sleep on AC.** `remote-setup -DisableSleepOnAC`, or
  `powercfg /change standby-timeout-ac 0`. This is the honest fix for a
  desk machine that hosts things.
- **Wake-on-LAN.** Enable it on the NIC (Device Manager → the adapter →
  Power Management → *Allow this device to wake the computer*), plus WoL in
  firmware, then send a magic packet before connecting. Note that on a Modern
  Standby (S0) laptop this is unreliable, and **fast startup** must be off or a
  shut-down box will not wake at all.

`remote-doctor` reports the AC standby timeout so you can see which situation
you are in.

---

## 4. What to expose

The default shape this repo sets up is **one open port**: 22, to the Windows
host, with the distros reached through it.

```sshconfig
# on the machine you ssh FROM
Host winbox
    HostName 192.168.1.50
    User you
    IdentityFile ~/.ssh/id_ed25519

Host kali
    HostName 127.0.0.1        # loopback from winbox's point of view
    Port 2222
    ProxyJump winbox
```

`wsl-ssh-config -JumpHost winbox` prints exactly this, filled in for the distros
you have. The alternative — `remote-setup -OpenDistroPorts` — opens a LAN
firewall rule per distro. It is one hop less, and one more listener facing the
network per distro; prefer the jump host, especially for anything reachable from
outside the house.

Whatever you expose, `sshd_config` on the host should have
`PasswordAuthentication no` once your key works. Verify the key **first** — in a
second session, with the first one still open.
