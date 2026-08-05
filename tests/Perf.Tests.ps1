# ============================================================================
#  tests/Perf.Tests.ps1  -  cold-start performance regression gate.
#
#  A wall-clock budget on a shared CI runner is flaky, and the external tools
#  aren't installed there anyway, so this gates the STRUCTURAL invariants that
#  keep shell start fast — the things a careless change would quietly break:
#    1. the FAST_START escape hatch short-circuits the heavy fragment;
#    2. every spawn-on-load tool init goes through the cached Get-InitCache path
#       (no raw `Invoke-Expression (tool init)` paying a subprocess every shell);
#  plus a deliberately generous load-time safety net over the cheap, tool-
#  independent fragments, to catch someone doing real work at load time.
# ============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Tools    = Get-Content (Join-Path $script:RepoRoot 'powershell/core/10-tools.ps1') -Raw
}

Describe 'cold-start invariants' {
    It 'short-circuits the heavy fragment under FAST_START' {
        $script:Tools | Should -Match "if \(\`$env:FAST_START -eq '1'\) \{ return \}"
    }

    It 'caches every spawn-on-load tool init via Get-InitCache' {
        # starship/zoxide/mise/atuin/carapace each shell out to print their init
        # script; all must resolve it through the cache, or a cold shell pays a
        # subprocess spawn per tool again. (navi no longer has a shell init — its
        # Ctrl+G widget was replaced by the Ctrl+G sessionizer in 10-tools.ps1, so
        # navi is now a plain command with nothing to cache.)
        foreach ($tool in 'starship', 'zoxide', 'mise', 'atuin', 'carapace') {
            $script:Tools | Should -Match "Get-InitCache -Name $tool"
        }
    }

    It 'gives each cached init a non-cached fallback (never loses the integration)' {
        # The pattern is: $cf = Get-InitCache ...; if ($cf) { . $cf } else { <fallback> }
        ([regex]::Matches($script:Tools, 'if \(\$cf\) \{ \. \$cf \}')).Count | Should -BeGreaterOrEqual 5
    }
}

Describe 'cheap fragments load well under budget' {
    It 'dot-sources the tool-independent fragments quickly' {
        # These define functions / register completers and must NOT do heavy work at
        # load. Real cost is tens of ms; the 3s budget only trips on an egregious
        # regression (e.g. a network/subprocess call added to a load-time path).
        #
        # Measured ONCE COLD, though, this asserted the wrong thing: the first
        # dot-source in a fresh session also pays PowerShell's parse/compile and any
        # module autoload, none of which is load-time work these fragments do. On a
        # shared GitHub runner that noise is unbounded, and on 2026-08-05 it put a run
        # at 3012ms against the 3000ms budget — a 0.4% overshoot, on a body whose real
        # cost is ~100x under the gate. A red CI that means "the runner was busy" is
        # worse than no gate, because it trains you to re-run instead of read.
        #
        # So: one untimed warm-up to pay the one-time costs, then take the FASTEST of
        # three timed runs. Noise only ever ADDS time, so the minimum is the closest
        # estimate of true load cost — and the regression this exists to catch (a
        # network or subprocess call on a load path) is slow on every run, so it still
        # trips. Re-sourcing is safe: the only aliasing here is `Set-Alias`, which
        # overwrites, and nothing in these three files is append-only.
        $global:DOTFILES = $script:RepoRoot
        $load = {
            . (Join-Path $script:RepoRoot 'powershell/core/05-lib.ps1')
            . (Join-Path $script:RepoRoot 'powershell/core/55-help.ps1')
            . (Join-Path $script:RepoRoot 'powershell/core/00-aliases.ps1')
        }
        $null = Measure-Command $load   # warm-up — discarded
        $fastest = (1..3 |
                ForEach-Object { (Measure-Command $load).TotalMilliseconds } |
                Measure-Object -Minimum).Minimum
        $fastest | Should -BeLessThan 3000
    }
}
