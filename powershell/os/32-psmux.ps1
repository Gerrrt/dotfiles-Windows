# ============================================================================
#  os/32-psmux.ps1  -  psmux (native Windows tmux) convenience
#
#  psmux is installed via scoop (packages/scoopfile.json, psmux bucket) and puts
#  `psmux`, `pmux`, and a `tmux` shim on PATH — all reading ~/.config/psmux/psmux.conf,
#  which install.ps1 symlinks from this repo's psmux/psmux.conf. So `tmux` already
#  "just works" on the host; this fragment only adds the one ergonomic verb the
#  rest of the fleet has muscle memory for.
#
#  Loads automatically (profile.ps1 globs os/ in name order). No-op if psmux
#  isn't installed yet, same guard style as the other fragments.
# ============================================================================

# --- load contract (checked by tests/LoadContract.Tests.ps1) ------------------
# provides: mux
# requires: Test-Cmd

if (-not (Test-Cmd psmux)) { return }

# mux — attach to the running session, or create it if it doesn't exist. One
# word to get into your persistent multiplexer (parity with `up`, `serve`, ...).
#   mux            # attach-or-create the default 'Gerrrt' session
#   mux scan       # attach-or-create a session named 'scan' (e.g. per engagement)
function mux {
    param([string]$Session = 'Gerrrt')
    psmux new-session -A -s $Session
}
