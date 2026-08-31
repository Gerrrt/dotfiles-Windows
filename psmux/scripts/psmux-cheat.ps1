# psmux-cheat.ps1 — prefix+? searchable cheatsheet (host port of core/tmux-cheat.sh).
# fzf-searchable list of THIS host's psmux keys, pwsh functions, aliases, and git
# aliases. Enter copies the selected key/command to the clipboard (Set-Clipboard).
# Invoked via:
#   bind ? display-popup -w 78% -h 80% "pwsh ... -File ~/.config/psmux/scripts/psmux-cheat.ps1"
# (prefix ? matches Core's tmux `prefix + ?`; was `prefix D` before the parity pass.)
#
# This DOCUMENTS the config; it doesn't read it — keep it in sync by hand. Data is
# tuned to the psmux host: prefix C-a, no vim-tmux-navigator (host), copy via
# clip.exe, and the PowerShell command surface (not the zsh one).

$ErrorActionPreference = 'SilentlyContinue'

# group, key/command, description
# NOTE: each row carries a LEADING COMMA (`,@(...)`). Without it, PowerShell emits
# each inner array as a separate pipeline statement and the collecting `@()` unrolls
# them into one flat string array — then `$_[0..2]` below indexes single CHARACTERS
# ('psmux'[0]='p'), rendering the cheatsheet as 3 columns of ~1 char each. The comma
# wraps each row in a 1-element array so unrolling yields the row intact. Keep it.
$rows = @(
    # ── psmux · prefix is C-a ────────────────────────────────────────────────
    ,@('psmux', 'C-a',              'PREFIX  (double-tap C-a C-a -> last window)')
    ,@('psmux', 'prefix r',         'reload psmux.conf')
    ,@('psmux', 'prefix c',         'new window (keeps path)')
    ,@('psmux', 'prefix ,',         'rename window')
    ,@('psmux', 'prefix &',         'kill window')
    ,@('psmux', 'M-H / M-L',        'previous / next window (Alt+Shift+H/L, no prefix)')
    ,@('psmux', 'prefix n / p',     'next / previous window')
    ,@('psmux', 'prefix 0-9',       'select window by number')
    ,@('psmux', 'prefix S',         'choose session')
    ,@('psmux', 'prefix d',         'detach')
    ,@('psmux', 'prefix R',         'refresh client')
    ,@('psmux', 'prefix :',         'command prompt')
    ,@('psmux', 'prefix q',         'show pane numbers (type one to jump)')
    # ── pane ─────────────────────────────────────────────────────────────────
    ,@('pane', 'C-h/j/k/l',       'select pane L/D/U/R (no prefix)')
    ,@('pane', 'prefix |',        'split vertical (keeps path)')
    ,@('pane', 'prefix -',        'split horizontal (keeps path)')
    ,@('pane', 'prefix \',        'full-height vertical split')
    ,@('pane', 'prefix _',        'full-width horizontal split')
    ,@('pane', 'prefix H/J/K/L',  'resize pane (re-press prefix per step)')
    ,@('pane', 'prefix m',        'zoom / maximize pane toggle')
    ,@('pane', 'prefix x',        'kill pane')
    ,@('pane', 'prefix X',        'swap pane down')
    ,@('pane', 'prefix P',        'toggle per-pane titles')
    ,@('pane', 'prefix *',        'synchronize-panes toggle (type into all)')
    ,@('pane', 'prefix F',        'floating popup shell (host equivalent of new-pane)')
    # NOTE: C-h/j/k/l pane-select is bound at root (no prefix) to mirror the
    # fleet's vim-tmux-navigator muscle memory. The host has no is_vim guard, so
    # it's plain pane navigation — it won't pass through into nvim splits.
    # ── popups ─────────────────────────────────────────────────────────────────
    ,@('popup', 'prefix w', 'session/window switcher')
    ,@('popup', 'prefix T', 'scratch terminal')
    ,@('popup', 'prefix g', 'lazygit')
    ,@('popup', 'prefix f', 'sessionizer (dir -> session)')
    ,@('popup', 'prefix u', 'URL picker (scrape pane -> fzf -> clipboard)')
    ,@('popup', 'prefix ?', 'this cheatsheet')
    # ── copy-mode (vi) ─────────────────────────────────────────────────────────
    ,@('copy', 'prefix Enter', 'enter copy-mode')
    ,@('copy', 'v',            'begin selection')
    ,@('copy', 'C-v',          'rectangle/block toggle')
    ,@('copy', 'y',            'copy selection -> Windows clipboard (clip.exe)')
    ,@('copy', '/ ? n N',      'search fwd / back / next / prev')
    ,@('copy', 'Escape',       'cancel copy-mode')
    # ── shell · PSReadLine / PSFzf ─────────────────────────────────────────────
    ,@('key', 'Ctrl-t',     'fzf file picker -> insert path')
    ,@('key', 'Ctrl-r',     'fzf history search')
    ,@('key', 'Up / Down',  'prefix history search')
    # ── shell · pwsh functions (host) ──────────────────────────────────────────
    ,@('cmd', 'up',                  'apply scoop + winget updates  (up -y = auto-confirm winget)')
    ,@('cmd', 'update-check',        'force the update check now')
    ,@('cmd', 'mux [session]',       'attach-or-create a psmux session (default: Gerrrt)')
    ,@('cmd', 'serve [port]',        'HTTP server in cwd; prints the LAN URL')
    ,@('cmd', 'fif <text>',          'find text inside files (rg + fzf -> nvim)')
    ,@('cmd', 'fbr',                 'fuzzy git-branch checkout')
    ,@('cmd', 'mkbak <file>',        'timestamped backup of a file')
    ,@('cmd', 'extract <file>',      'extract any archive type')
    ,@('cmd', 'sha256 <file>',       'SHA-256 of a file (also sha1 / md5)')
    ,@('cmd', 'kali / cdwsl',        'jump into Kali / into Kali at the current dir')
    ,@('cmd', 'wsls / hostip',       'WSL distro status / host LAN IP')
    ,@('cmd', 'maint-install [HH:MM]', 'schedule daily maintenance (default 13:00)')
    ,@('cmd', 'maint-run / maint-log -f', 'run maintenance now / follow the log')
    ,@('cmd', 'opsecret / optoken',  '1Password: read a secret / copy a TOTP')
    # ── aliases ─────────────────────────────────────────────────────────────────
    ,@('alias', 'll / la / lt', 'eza listings (long / all / tree)')
    ,@('alias', 'cat / catp',   'bat (no-pager / paged)')
    ,@('alias', 'z <dir>',      'zoxide jump (cd is rebound to z)')
    ,@('alias', 'http / dns / md', 'xh / doggo / glow')
    ,@('alias', 'lg',           'lazygit')
    ,@('alias', 'g / gs / gst', 'git / status -sb / status')
    ,@('alias', 'ga / gaa / gc / gcm', 'add / add --all / commit -v / commit -m')
    ,@('alias', 'gco / gcb / gsw', 'checkout / checkout -b / switch')
    ,@('alias', 'gd / gds / glog', 'diff / diff --staged / log-graph')
    ,@('alias', 'gl / gp / gpf', 'pull / push / push --force-with-lease')
    ,@('alias', 'gsta / gstp / grbm', 'stash push / pop / rebase onto trunk')
    # ── git aliases (run as: git <x>) ───────────────────────────────────────────
    ,@('git', 'git st',        'status -sb')
    ,@('git', 'git lg',        'pretty graph log (all branches)')
    ,@('git', 'git co / br',   'checkout / branch -vv')
    ,@('git', 'git cm / ca',   'commit -m / amend')
    ,@('git', 'git fix',       'commit --fixup (pairs with autosquash)')
    ,@('git', 'git wip / unwip', 'quick WIP commit / undo it')
    ,@('git', 'git undo',      'soft-reset last commit (keep changes)')
    ,@('git', 'git pushf',     'push --force-with-lease')
    ,@('git', 'git sl / sp',   'stash list / pop')
    ,@('git', 'git aliases',   'list every git alias')
)

if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    $rows | ForEach-Object { '{0,-6} {1,-26} {2}' -f $_[0], $_[1], $_[2] }
    return
}

# tokyonight: accent group, muted description (ANSI 24-bit). The two SGR lines are
# GENERATED from theme/palette.toml by gen-theme.ps1 - the twin of Core's
# emit_cheat_sgr for tmux/scripts/tmux-cheat.sh. Do not hand-edit.
$e   = [char]27
# core:theme:gen cheat-sgr
$gc  = "$e[38;2;122;162;247m"   # blue
$dim = "$e[38;2;86;95;137m"     # comment
# core:theme:end cheat-sgr
$rst = "$e[0m"

# emit "<pretty display><TAB><copy token>"
$lines = $rows | ForEach-Object {
    ('{0}{1,-6}{2} {3,-26} {4}{5}{6}{7}{8}' -f $gc, $_[0], $rst, $_[1], $dim, $_[2], $rst, "`t", $_[1])
}

$sel = $lines | fzf --ansi --delimiter "`t" --with-nth 1 --no-sort --reverse `
    --prompt 'cheat > ' --header 'Enter: copy to clipboard   ·   Esc: close'
if (-not $sel) { return }

$token = ($sel -split "`t")[-1]
Set-Clipboard -Value $token
