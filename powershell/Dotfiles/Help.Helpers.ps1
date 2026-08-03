# ============================================================================
#  Help.Helpers.ps1  -  pure dothelp catalog + logic, owned by the Dotfiles
#  module (B7 stage 2c).
#
#  Extracted from core/55-help.ps1 so the host-INDEPENDENT pieces — the command
#  catalog (Get-DotfilesHelpData) and everything derived from it (filter tokens,
#  flat picker lines, primary-verb parsing, and the "did you mean?" edit-distance
#  matching) — live in the module (exported, unit-tested in tests/Help.Tests.ps1)
#  instead of as global: functions. The interactive `dothelp` verb and the
#  CommandNotFoundAction hook stay in the fragment and call these via the module
#  export; the completer in core/50-completions.ps1 likewise resolves
#  Get-DotHelpFilters lazily from here.
# ============================================================================

function Get-DotfilesHelpData {
    # Ordered groups -> rows of @{ Command; Desc }. Curated to mirror the README
    # cheatsheet; keep new user-facing verbs listed here so they stay discoverable.
    [System.Collections.Specialized.OrderedDictionary]$g = [ordered]@{}
    $g['Listing & files'] = @(
        @{ Command = 'll / la / lt'; Desc = 'eza listings (long / all+hidden / tree)' }
        @{ Command = 'cat / catp';   Desc = 'bat (no-pager / paged)' }
        @{ Command = 'gmd <file>';   Desc = 'render markdown in the terminal (glow)' }
        @{ Command = 'du / hex / loc'; Desc = 'dust disk-usage / hexyl / tokei LOC' }
        @{ Command = 'extract / compress'; Desc = 'archive in/out (ouch, with fallbacks)' }
        @{ Command = 'mkbak <f>';    Desc = 'timestamped backup copy of a file' }
    )
    $g['Navigation'] = @(
        @{ Command = 'z <dir>';      Desc = 'zoxide jump (cd is rebound to z)' }
        @{ Command = '.. / ... / ~'; Desc = 'up one/two dirs / home' }
        @{ Command = 'mkcd <dir>';   Desc = 'make a directory and cd into it' }
        @{ Command = 'dotfiles';     Desc = 'cd to the dotfiles repo' }
    )
    $g['Git'] = @(
        @{ Command = 'g / gs / gst';  Desc = 'git / status -sb / status' }
        @{ Command = 'gss / gsb';     Desc = 'status --short / --short --branch' }
        @{ Command = 'ga / gaa / gc / gcm'; Desc = 'add / add --all / commit -v / commit -m' }
        @{ Command = 'gco / gd / gp'; Desc = 'checkout / diff / push' }
        @{ Command = 'gl / glog';     Desc = 'pull / log graph' }
        @{ Command = 'lg';           Desc = 'lazygit' }
        @{ Command = 'fbr';          Desc = 'fuzzy git-branch checkout' }
        @{ Command = 'gaf / grf / grsf'; Desc = 'fuzzy git stage / restore / unstage' }
    )
    $g['Find / fuzzy'] = @(
        @{ Command = 'Ctrl+t / Ctrl+r'; Desc = 'fzf file picker / history search' }
        @{ Command = 'fif <term>';   Desc = 'find-in-files, open the hit in nvim' }
        @{ Command = 'tvim / ttext'; Desc = 'television: pick file / search contents' }
        @{ Command = 'tcd / trepo / tbranch'; Desc = 'television: dir / repo / branch' }
    )
    $g['Network / HTTP'] = @(
        @{ Command = 'http / https'; Desc = 'xh (Rust HTTPie)' }
        @{ Command = 'dns <name>';   Desc = 'doggo (modern dig)' }
        @{ Command = 'myip / localips'; Desc = 'public IP / local interface IPs' }
        @{ Command = 'serve [port]'; Desc = 'HTTP server in CWD, prints LAN URL' }
    )
    $g['Updates & maintenance'] = @(
        @{ Command = 'up [-y] / up -n'; Desc = 'apply scoop + winget updates (-n/-Preview: list only)' }
        @{ Command = 'update-check'; Desc = 'force the "updates available" check now' }
        @{ Command = 'maint-install [HH:MM]'; Desc = 'register the daily maint task' }
        @{ Command = 'maint-run / maint-log / maint-status'; Desc = 'run / tail / next-run' }
        @{ Command = 'shell-bench / prof-trace'; Desc = 'measure cold-start / trace load' }
        @{ Command = 'dotfiles-doctor [-Fix]'; Desc = 'health-check this setup (and auto-remediate)' }
        @{ Command = 'git-reap'; Desc = 'kill orphaned/stuck git processes so git can be updated' }
    )
    $g['Packages'] = @(
        @{ Command = 'scs / sci / scl / scu'; Desc = 'scoop search / install / list / update' }
        @{ Command = 'wgs / wgi / wgu'; Desc = 'winget search / install / upgrade-all' }
    )
    $g['Secrets & transfer'] = @(
        @{ Command = 'opsecret / optoken'; Desc = '1Password: read secret / copy TOTP' }
        @{ Command = 'openv / opssh'; Desc = '1Password: run with .env.op / list SSH keys' }
        @{ Command = 'age-enc / age-dec'; Desc = 'age file encrypt / decrypt' }
        @{ Command = 'send / recv';  Desc = 'croc peer-to-peer file transfer' }
    )
    $g['WSL bridge'] = @(
        @{ Command = 'kali'; Desc = 'jump into the Kali WSL distro' }
        @{ Command = 'cdwsl [distro]'; Desc = 'enter WSL at the current directory' }
        @{ Command = 'wsls / hostip'; Desc = 'distro status / host LAN IP' }
    )
    $g['psmux (multiplexer)'] = @(
        @{ Command = 'mux [session]'; Desc = 'attach-or-create a psmux session' }
        @{ Command = 'psmux-pill-enable / -disable'; Desc = 'status pills: operator/VPN IP + power' }
    )
    $g['Shell'] = @(
        @{ Command = 'core <verb>';  Desc = 'fleet front door: core doctor / help / version / update (matches Core on Unix)' }
        @{ Command = 'reload';       Desc = 'reload the PowerShell profile' }
        @{ Command = 'which <name>'; Desc = 'resolve a command (source / kind)' }
        @{ Command = 'tools';        Desc = 'open the host tool docs (docs/TOOLS.md)' }
        @{ Command = 'dothelp [filter]'; Desc = 'this index (-i for an fzf picker)' }
    )
    return $g
}

# --- Get-DotHelpFilters -------------------------------------------------------
# The set of useful `dothelp <filter>` arguments: every group name plus every
# individual command verb (so "ll / la / lt" yields ll, la, lt). Pure, so the
# tab-completer in core/50-completions.ps1 can offer them and it's unit-tested.
function Get-DotHelpFilters {
    $data = Get-DotfilesHelpData
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($group in $data.Keys) {
        $out.Add($group)
        foreach ($row in $data[$group]) {
            foreach ($tok in ($row.Command -split '[\s/]+')) {
                # skip placeholders like <dir>, [filter], <name>
                if ($tok -and $tok -notmatch '^[<\[]') { $out.Add($tok) }
            }
        }
    }
    $out | Sort-Object -Unique
}

# --- Get-DotHelpFlatLines -----------------------------------------------------
# One picker-ready line per command for the interactive (fzf) picker, tab-delimited
# as "<display>`t<command>":
#   <display> — the human column fzf shows: "command   description   [group]",
#               the command padded to a common width so the columns line up.
#   <command> — the bare token the caller extracts on pick (split on TAB, take the
#               LAST field), so display padding never leaks onto the prompt.
# The whole row is rendered HERE, in PowerShell, and shown verbatim by fzf — it is
# never handed to a preview SHELL. That's deliberate: command cells like `mkbak <f>`
# and group names like `Listing & files` contain cmd.exe metacharacters (`< > &`)
# that a `--preview 'echo {..}'` would mis-parse (U9). Pure, so it's unit-tested.
function Get-DotHelpFlatLines {
    $data = Get-DotfilesHelpData
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $data.Keys) {
        foreach ($row in $data[$group]) {
            $rows.Add([pscustomobject]@{ Command = $row.Command; Desc = $row.Desc; Group = $group })
        }
    }
    $width = ($rows.Command | Measure-Object -Maximum -Property Length).Maximum
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rows) {
        $display = '{0}   {1}   [{2}]' -f $r.Command.PadRight($width), $r.Desc, $r.Group
        $out.Add(("{0}`t{1}" -f $display, $r.Command))
    }
    return $out
}

# --- Get-DotHelpPrimaryVerb ---------------------------------------------------
# The first runnable token of a catalog Command cell ("g / gs / gl" -> "g",
# "mkbak <f>" -> "mkbak"), skipping placeholders. Pure, so the interactive picker
# can drop it on the edit line and it's unit-tested.
function Get-DotHelpPrimaryVerb {
    [OutputType([string])]
    param([string]$Command)
    if (-not $Command) { return '' }
    foreach ($tok in ($Command -split '[\s/]+')) {
        if ($tok -and $tok -notmatch '^[<\[]') { return $tok }
    }
    return ''
}

# --- "did you mean?" matching (pure) ------------------------------------------
# Get-DotLevenshtein: classic edit distance, used to rank near-misses. Get-DotDid
# YouMean ranks the catalog verbs against a mistyped name (exact-prefix and
# substring beat edit distance) and returns the best few. Both pure, unit-tested;
# the CommandNotFoundAction hook (in the fragment) wires them to the shell.
function Get-DotLevenshtein {
    [OutputType([int])]
    param([string]$A, [string]$B)
    $a = "$A"; $b = "$B"
    if ($a -eq $b) { return 0 }
    if (-not $a) { return $b.Length }
    if (-not $b) { return $a.Length }
    $prev = 0..$b.Length
    for ($i = 1; $i -le $a.Length; $i++) {
        $cur = @($i) + (1..$b.Length | ForEach-Object { 0 })
        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $cur[$j] = [Math]::Min([Math]::Min($cur[$j - 1] + 1, $prev[$j] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    return $prev[$b.Length]
}

function Get-DotDidYouMean {
    [OutputType([string[]])]
    param([string]$Name, [string[]]$Candidates, [int]$Max = 3)
    if ([string]::IsNullOrWhiteSpace($Name) -or -not $Candidates) { return @() }
    $n = $Name.ToLowerInvariant()
    # Only word-like verbs of length >= 2 make good suggestions: drop one-char
    # aliases (z/g/l), flags (-n), and symbol verbs (~, .., Ctrl+t) that would
    # otherwise "match" as substrings of a long typo and add noise.
    $usable = $Candidates | Where-Object { $_ -match '^[A-Za-z][A-Za-z0-9_-]{1,}$' }
    $scored = foreach ($c in ($usable | Sort-Object -Unique)) {
        if (-not $c) { continue }
        $cl = $c.ToLowerInvariant()
        if ($cl -eq $n) { continue }
        $score = $null
        if ($cl.StartsWith($n) -or $n.StartsWith($cl)) { $score = 0 }
        # substring only counts when the candidate is long enough to be meaningful
        elseif (($cl.Length -ge 4 -and $n.Contains($cl)) -or ($n.Length -ge 4 -and $cl.Contains($n))) { $score = 1 }
        else {
            $d = Get-DotLevenshtein $n $cl
            # only suggest genuinely close names (scaled to the shorter length)
            if ($d -le [Math]::Max(1, [Math]::Min(2, [int]($n.Length / 3)))) { $score = 2 + $d }
        }
        if ($null -ne $score) { [pscustomobject]@{ Name = $c; Score = $score } }
    }
    @($scored | Sort-Object Score, Name | Select-Object -First $Max -ExpandProperty Name)
}
