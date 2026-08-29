# ============================================================================
#  windows/Enable-RemoteAccess.ps1  -  make this host reachable over ssh, and
#  keep the WSL distros reachable once it is.
#
#      pwsh -File windows/Enable-RemoteAccess.ps1                 # report only (default)
#      pwsh -File windows/Enable-RemoteAccess.ps1 -ProbeDistros   # ...also ask each distro
#      pwsh -File windows/Enable-RemoteAccess.ps1 -Apply          # fix it (needs admin)
#      pwsh -File windows/Enable-RemoteAccess.ps1 -StartDistros   # start sshd in each distro
#      pwsh -File windows/Enable-RemoteAccess.ps1 -Help
#
#  Standing OpenSSH Server up on a Windows box that also hosts WSL2 breaks two
#  things that look unrelated to it, so this script exists to name both:
#
#    * The profile stops loading over ssh. An ssh session is not the shell you
#      tested in: it inherits no Process-scope execution policy, no interactive
#      session, and — if you sign in as a different account — a different
#      $PROFILE. Any of the four causes reads as "untrusted source".
#
#    * The Linux boxes stop answering. The Windows sshd service takes 0.0.0.0:22
#      at boot; with networkingMode=mirrored the distros share those interfaces,
#      so a distro sshd that also wants :22 never binds. And a distro only runs
#      while it has a live process — which is why it worked whenever a terminal
#      happened to be open on the host and never when it wasn't.
#
#  -Check is read-only. -ProbeDistros additionally STARTS each distro (that is
#  the only way to read its sshd config). -Apply is the only mode that writes.
#
#  Deliberately NOT done here: configuring sshd inside a distro. Which port a
#  distro listens on is that distro's own repo's business (dotfiles-Debian for
#  the Kali/Debian/Ubuntu family) — this script reports the mismatch and prints
#  the one-liner to fix it there.
# ============================================================================
[CmdletBinding()]
param(
    # Report only. The default when no mode switch is passed.
    [switch]$Check,
    # Apply the host-side fixes. Needs an elevated shell.
    [switch]$Apply,
    # Start sshd inside each distro and leave it running (no admin needed). This
    # is what the boot task runs.
    [switch]$StartDistros,
    # First port of the per-distro map. The Windows sshd keeps 22.
    [int]$BasePort = 2222,
    # Enter each distro to read its sshd port. Starts the distro — not read-only.
    [switch]$ProbeDistros,
    # -Apply only: open the per-distro ports to the LAN. Off by default: the safer
    # shape is one open port (22) with ProxyJump through it.
    [switch]$OpenDistroPorts,
    # -Apply only: stop the box sleeping on AC. A sleeping host answers nothing,
    # and this is the setting that makes "it works while I'm at the desk" true.
    [switch]$DisableSleepOnAC,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $here

# The rendering helpers, the doctor result model and the remote planners all come
# from the repo's own module. Unlike windows/defaults.ps1 there is no shim
# fallback: this script's whole job is the pure logic in Remote.Helpers.ps1, so a
# checkout missing it should say so rather than half-run.
$Manifest = Join-Path $RepoRoot 'powershell/Dotfiles/Dotfiles.psd1'
if (-not (Test-Path $Manifest)) {
    Write-Error "Dotfiles module not found at $Manifest — run this from a full checkout."
    exit 1
}
Import-Module $Manifest -Force -DisableNameChecking

$TaskName = 'dotfiles-wsl-keepalive'

function Get-RemoteUsage {
    @(
        'Enable-RemoteAccess.ps1 - reach this host (and its WSL distros) over ssh'
        ''
        'USAGE'
        '  pwsh -File windows/Enable-RemoteAccess.ps1 [-Check] [-ProbeDistros]'
        '  pwsh -File windows/Enable-RemoteAccess.ps1 -Apply [-OpenDistroPorts] [-DisableSleepOnAC]'
        '  pwsh -File windows/Enable-RemoteAccess.ps1 -StartDistros'
        ''
        'MODES'
        '  -Check            report what an ssh session would get (default, read-only)'
        '  -ProbeDistros     also enter each distro to read its sshd port (starts it)'
        '  -Apply            fix the host side: sshd service, shell, firewall, boot task'
        '  -StartDistros     start sshd inside each distro now (no admin)'
        ''
        'OPTIONS'
        '  -BasePort <n>       first port of the per-distro map (default 2222)'
        '  -OpenDistroPorts    -Apply: expose the distro ports to the LAN (default: no)'
        '  -DisableSleepOnAC   -Apply: stop the host sleeping while on AC power'
    )
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- the distro list ----------------------------------------------------------
# WSL_UTF8=1 because `wsl --list --quiet` otherwise emits UTF-16LE, which arrives
# here as a string with a NUL between every character; the strip covers builds
# that ignore the variable.
function Get-DistroNames {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    $prev = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try { $raw = & wsl.exe --list --quiet 2>$null }
    catch { return @() }
    finally {
        if ($null -eq $prev) { Remove-Item Env:WSL_UTF8 -ErrorAction SilentlyContinue }
        else { $env:WSL_UTF8 = $prev }
    }
    return @($raw | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
}

# --- probes -------------------------------------------------------------------
function Get-RemoteResults {
    param([switch]$Deep)
    $r = [System.Collections.Generic.List[object]]::new()

    # --- the service ----------------------------------------------------------
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        $r.Add((New-DoctorResult 'sshd service' 'fail' 'OpenSSH Server not installed' `
            'Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0'))
    } elseif ($svc.Status -ne 'Running') {
        $r.Add((New-DoctorResult 'sshd service' 'fail' "installed but $($svc.Status)" 'Start-Service sshd'))
    } else {
        $r.Add((New-DoctorResult 'sshd service' 'ok' 'running'))
    }
    if ($svc) {
        # A Manual start type is the classic "it worked until I rebooted": the
        # service is fine, it simply never came back.
        $start = (Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue).StartMode
        if ($start -eq 'Auto') { $r.Add((New-DoctorResult 'sshd startup' 'ok' 'Automatic')) }
        else { $r.Add((New-DoctorResult 'sshd startup' 'fail' "$start — will not survive a reboot" 'Set-Service sshd -StartupType Automatic')) }
    }

    # --- the login shell ------------------------------------------------------
    # No DefaultShell means an ssh login lands in cmd.exe, which loads no profile
    # at all — a failure that looks exactly like a blocked profile.
    $shell = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
    if (-not $shell) {
        $r.Add((New-DoctorResult 'sshd default shell' 'fail' 'unset — ssh logins get cmd.exe (no profile)' `
            'set HKLM:\SOFTWARE\OpenSSH DefaultShell to your pwsh.exe (this script -Apply does it)'))
    } elseif ($shell -notmatch 'pwsh\.exe$') {
        $r.Add((New-DoctorResult 'sshd default shell' 'warn' $shell 'point DefaultShell at pwsh.exe — the profile targets PowerShell 7'))
    } else {
        $r.Add((New-DoctorResult 'sshd default shell' 'ok' $shell))
    }

    # --- where sshd actually looks for your key -------------------------------
    $keyTarget = Get-DotSshKeyFileTarget -IsAdmin (Test-IsAdmin)
    if (Test-Path $keyTarget.Path) {
        $r.Add((New-DoctorResult 'authorized_keys' 'ok' $keyTarget.Path))
    } else {
        $r.Add((New-DoctorResult 'authorized_keys' 'warn' "missing: $($keyTarget.Path)" $keyTarget.Note))
    }

    # --- firewall -------------------------------------------------------------
    $fw = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($fw -and $fw.Enabled -eq 'True') { $r.Add((New-DoctorResult 'firewall: 22/tcp' 'ok' 'inbound rule enabled')) }
    elseif ($fw) { $r.Add((New-DoctorResult 'firewall: 22/tcp' 'fail' 'rule present but disabled' 'Enable-NetFirewallRule -Name OpenSSH-Server-In-TCP')) }
    else { $r.Add((New-DoctorResult 'firewall: 22/tcp' 'fail' 'no inbound rule' 'this script -Apply adds it')) }

    # --- what an ssh session would do with the profile ------------------------
    # $PROFILE is populated even under -NoProfile, so this is measurable from
    # here. Resolve the symlink first: install.ps1 links $PROFILE into the repo,
    # and it is the TARGET's zone and Mark-of-the-Web that the policy judges.
    $profilePath = $PROFILE
    $exists = [bool]($profilePath -and (Test-Path -LiteralPath $profilePath))
    $target = $profilePath
    if ($exists) {
        $item = Get-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType -eq 'SymbolicLink' -and $item.Target) { $target = @($item.Target)[0] }
    }
    $motw = $false
    if ($exists -and (Test-Path -LiteralPath $target)) {
        $motw = [bool](Get-Item -LiteralPath $target -Stream Zone.Identifier -ErrorAction SilentlyContinue)
    }
    # A UNC path is not the local zone, and RemoteSigned judges by zone — so an
    # unsigned profile on \\server\share or \\wsl.localhost\ is refused no matter
    # how local it feels.
    $remotePath = $false
    foreach ($p in @($profilePath, $target)) {
        if ($p -and $p.StartsWith('\\')) { $remotePath = $true }
    }
    # NOT Get-ExecutionPolicy: that reports THIS shell's effective policy, and a
    # terminal launched with -ExecutionPolicy Bypass would make the probe report
    # health that no ssh session gets. Get-DotSshExecutionPolicy drops Process
    # scope, which is precisely the scope an ssh session does not inherit.
    $sshPolicy = Get-DotSshExecutionPolicy -ScopeList (Get-ExecutionPolicy -List)
    $r.Add((Get-DotProfileTrustResult -Policy $sshPolicy -ProfilePath $profilePath `
        -ProfileExists $exists -HasMotw $motw -IsRemotePath $remotePath))

    # --- WSL: the host-side settings that decide whether a distro is reachable -
    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path $wslConfig) {
        $conf = Get-Content $wslConfig -Raw
        if ($conf -match '(?m)^\s*networkingMode\s*=\s*mirrored') {
            $r.Add((New-DoctorResult 'wsl: networking' 'ok' 'mirrored'))
        } else {
            $r.Add((New-DoctorResult 'wsl: networking' 'warn' 'not mirrored — inbound needs portproxy' `
                "copy wsl/windows.wslconfig.example to $wslConfig, then: wsl --shutdown"))
        }
        # vmIdleTimeout=-1 is what stops the utility VM winding down when you are
        # not at the keyboard. Without it the distros are reachable only while
        # something on the host happens to be using WSL.
        if ($conf -match '(?m)^\s*vmIdleTimeout\s*=\s*-1') {
            $r.Add((New-DoctorResult 'wsl: idle timeout' 'ok' 'vmIdleTimeout=-1 (VM stays up)'))
        } else {
            $r.Add((New-DoctorResult 'wsl: idle timeout' 'warn' 'VM winds down when idle' `
                'add vmIdleTimeout=-1 under [wsl2] in .wslconfig, then: wsl --shutdown'))
        }
    } else {
        $r.Add((New-DoctorResult 'wsl: .wslconfig' 'warn' 'absent' `
            "copy wsl/windows.wslconfig.example to $wslConfig"))
    }

    # --- the boot task --------------------------------------------------------
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { $r.Add((New-DoctorResult 'wsl: boot task' 'ok' "$TaskName registered ($($task.State))")) }
    else { $r.Add((New-DoctorResult 'wsl: boot task' 'warn' 'not registered — distros start only when you open a terminal' 'this script -Apply registers it')) }

    # --- sleep ----------------------------------------------------------------
    # A sleeping host serves nothing. Report the AC standby timeout rather than
    # guessing at Modern Standby: 0 means never.
    try {
        $ac = & powercfg.exe /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null
        $acLine = @($ac | Select-String 'Current AC Power Setting Index') | Select-Object -First 1
        if ($acLine -and $acLine.Line -match '0x([0-9a-fA-F]+)') {
            $secs = [Convert]::ToInt32($Matches[1], 16)
            if ($secs -eq 0) { $r.Add((New-DoctorResult 'host sleep (AC)' 'ok' 'never sleeps on AC')) }
            else { $r.Add((New-DoctorResult 'host sleep (AC)' 'warn' "sleeps after $([int]($secs / 60)) min on AC" 'a sleeping host answers no ssh — re-run with -Apply -DisableSleepOnAC (or set up Wake-on-LAN)')) }
        }
    } catch {
        $r.Add((New-DoctorResult 'host sleep (AC)' 'warn' 'could not read the power scheme' ''))
    }

    # --- the distros ----------------------------------------------------------
    $names = Get-DistroNames
    if (-not $names.Count) {
        $r.Add((New-DoctorResult 'wsl: distros' 'warn' 'none found' 'wsl --list --verbose'))
        return $r
    }
    $plan = Get-DotWslSshPlan -Distro $names -BasePort $BasePort
    foreach ($row in $plan) {
        $listening = @(Get-NetTCPConnection -State Listen -LocalPort $row.Port -ErrorAction SilentlyContinue)
        if ($listening.Count) {
            $r.Add((New-DoctorResult "distro: $($row.Distro)" 'ok' "answering on $($row.Port)"))
        } else {
            $r.Add((New-DoctorResult "distro: $($row.Distro)" 'warn' "nothing listening on $($row.Port)" `
                "inside the distro: set 'Port $($row.Port)' in /etc/ssh/sshd_config, then sudo systemctl enable --now ssh"))
        }
        if ($Deep) {
            # The collision that started all this: a distro still configured for 22
            # cannot bind it while the Windows sshd holds it.
            $conf = & wsl.exe -d $row.Distro -u root -- sh -c 'grep -E "^[[:space:]]*Port[[:space:]]" /etc/ssh/sshd_config 2>/dev/null' 2>$null
            $ports = @($conf | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
            if (-not $ports.Count) {
                $r.Add((New-DoctorResult "distro: $($row.Distro) sshd_config" 'warn' 'no explicit Port (defaults to 22)' `
                    "22 belongs to the Windows sshd now — set 'Port $($row.Port)' in the distro"))
            } elseif ($ports -join ' ' -match '\b22\b') {
                $r.Add((New-DoctorResult "distro: $($row.Distro) sshd_config" 'fail' "$($ports -join ', ') — collides with the Windows sshd" `
                    "set 'Port $($row.Port)' in the distro's /etc/ssh/sshd_config"))
            } else {
                $r.Add((New-DoctorResult "distro: $($row.Distro) sshd_config" 'ok' ($ports -join ', ')))
            }
        }
    }
    return $r
}

function Write-RemoteReport {
    param([object[]]$Results)
    $ok = Get-DotGlyph ok; $warn = Get-DotGlyph warn; $fail = Get-DotGlyph fail
    Write-DotBanner 'remote access'
    foreach ($row in $Results) {
        $glyph = switch ($row.Status) { 'ok' { $ok } 'warn' { $warn } default { $fail } }
        $color = switch ($row.Status) { 'ok' { 'Green' } 'warn' { 'Yellow' } default { 'Red' } }
        Write-DotHost ("  {0} {1,-28} {2}" -f $glyph, $row.Name, $row.Detail) -Color $color
        if ($row.Hint -and $row.Status -ne 'ok') { Write-DotHost "      -> $($row.Hint)" -Color DarkGray }
    }
    $s = Get-DoctorSummary -Results $Results
    Write-DotHost ''
    Write-DotHost ("  {0} ok, {1} warn, {2} fail" -f $s.Ok, $s.Warn, $s.Fail) -Color DarkGray
    return $s
}

# --- apply --------------------------------------------------------------------
$script:ExitCode = 0

function Invoke-RemoteApply {
    if (-not (Test-IsAdmin)) {
        Write-DotErr 'this needs an elevated shell' 'run remote-setup from the profile, or start pwsh as administrator'
        $script:ExitCode = 1
        return
    }

    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        Write-DotHost 'installing OpenSSH Server...' -Color Cyan
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    Write-DotOk 'sshd running, starts automatically'

    # An ssh login should land in the same shell as a local one, or none of the
    # profile work applies to remote sessions.
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ($pwshPath) {
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $pwshPath -PropertyType String -Force | Out-Null
        # -Command (not -c) is what pwsh expects for `ssh host <cmd>`; without it
        # non-interactive ssh commands fail in ways that look like a broken profile.
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellCommandOption -Value '-Command' -PropertyType String -Force | Out-Null
        Write-DotOk "ssh logins land in $pwshPath"
    } else {
        Write-DotErr 'pwsh not found — leaving DefaultShell alone' 'scoop install pwsh, then re-run'
    }

    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    } else {
        Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
    }
    Write-DotOk 'firewall: 22/tcp inbound allowed'

    # The admin trap: for an account in Administrators, sshd reads this file and
    # ignores ~/.ssh/authorized_keys — and ignores THIS one too unless its ACL is
    # limited to Administrators + SYSTEM. Create it correctly now so adding a key
    # later is a one-liner that actually takes effect. SIDs, not names, so a
    # non-English Windows works.
    $adminKeys = (Get-DotSshKeyFileTarget -IsAdmin $true).Path
    if (-not (Test-Path $adminKeys)) {
        New-Item -ItemType File -Path $adminKeys -Force | Out-Null
        & icacls.exe $adminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
        Write-DotOk "created $adminKeys (Administrators + SYSTEM only)"
    }

    # Keep the distros up without a terminal open. sshd inside a distro is itself
    # a live process, so starting it is what stops WSL tearing the distro down —
    # the task just makes that happen at logon instead of when you open a shell.
    $pwshForTask = if ($pwshPath) { $pwshPath } else { 'powershell.exe' }
    $runner = Join-Path $PSScriptRoot 'Enable-RemoteAccess.ps1'
    $action = New-ScheduledTaskAction -Execute $pwshForTask `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -StartDistros' -f $runner)
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Description 'dotfiles: start sshd in each WSL distro so they stay reachable' -Force | Out-Null
    Write-DotOk "$TaskName registered (at logon)"
    Write-DotHost '      note: this fires at LOGON. A box rebooted with nobody signed in' -Color DarkGray
    Write-DotHost '      needs auto-logon (or a distro-side service) before ssh answers.' -Color DarkGray

    if ($OpenDistroPorts) {
        $names = Get-DistroNames
        $plan = Get-DotWslSshPlan -Distro $names -BasePort $BasePort
        foreach ($row in $plan) {
            $ruleName = "dotfiles-wsl-$($row.Alias)"
            if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
                Set-NetFirewallRule -Name $ruleName -Enabled True | Out-Null
            } else {
                New-NetFirewallRule -Name $ruleName -DisplayName "WSL $($row.Distro) (sshd)" `
                    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $row.Port | Out-Null
            }
            Write-DotOk "firewall: $($row.Port)/tcp -> $($row.Distro)"
        }
        Write-DotHost '      these ports now face the LAN. ProxyJump through 22 exposes less.' -Color DarkGray
    }

    if ($DisableSleepOnAC) {
        & powercfg.exe /change standby-timeout-ac 0 | Out-Null
        & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
        Write-DotOk 'host will not sleep or hibernate on AC power'
    }

    Restart-Service sshd
}

# --- start the distros --------------------------------------------------------
function Invoke-StartDistros {
    $names = Get-DistroNames
    if (-not $names.Count) { Write-DotErr 'no WSL distros found'; $script:ExitCode = 1; return }
    foreach ($n in $names) {
        # `service` works with or without systemd and is a no-op if ssh is up.
        & wsl.exe -d $n -u root -- /usr/sbin/service ssh start 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-DotOk "$n : sshd started" }
        else {
            Write-DotErr "$n : could not start sshd" 'install it in the distro: sudo apt install openssh-server'
            $script:ExitCode = 1
        }
    }
}

# --- entry --------------------------------------------------------------------
if ($Help) { Get-RemoteUsage | ForEach-Object { Write-DotHost $_ }; exit 0 }

if ($Apply -and $Check) {
    Write-DotErr '-Check and -Apply are different modes' 'run -Check first, then -Apply'
    exit 2
}

if ($StartDistros) {
    Invoke-StartDistros
    exit $script:ExitCode
}

if ($Apply) {
    Invoke-RemoteApply
    if ($script:ExitCode -eq 0) {
        Write-DotHost ''
        Write-DotHost 'now re-checking...' -Color Cyan
        $null = Write-RemoteReport -Results (Get-RemoteResults)
    }
    exit $script:ExitCode
}

# Default: report. Exit non-zero on a hard failure so a caller can gate on it;
# warnings are informational and do not fail the run.
$results = Get-RemoteResults -Deep:$ProbeDistros
$summary = Write-RemoteReport -Results $results
if ($summary.Fail -gt 0) { exit 1 }
exit 0
