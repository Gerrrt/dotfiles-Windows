# ============================================================================
#  tests/StarshipSync.Tests.ps1  -  starship-sync.ps1 pure ref resolver
#  (library-only). Covers the reproducible-pin option (-Ref) without cloning.
#  Mirror of NvimSync.Tests.ps1.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $env:DOTFILES_STARSHIPSYNC_LIBONLY = '1'
    . (Join-Path $RepoRoot 'starship-sync.ps1')
}

Describe 'Get-StarshipSyncPin' {
    # The bug: starship/.core-ref recorded `pinned = v4.9.0`, but the scheduled
    # workflow invokes starship-sync.ps1 BARE. Without this resolver the next run
    # silently syncs the branch tip and rewrites the pin away, with nothing in the
    # diff to say a deliberate decision was reverted.
    It 'carries a recorded pin forward when no -Ref is given' {
        $p = Get-StarshipSyncPin -RecordedPin 'v4.9.0'
        $p.Ref    | Should -Be 'v4.9.0'
        $p.Source | Should -Be 'recorded'
    }
    It 'lets an explicit -Ref win over the recorded pin' {
        $p = Get-StarshipSyncPin -Ref 'v5.0.0' -RecordedPin 'v4.9.0'
        $p.Ref    | Should -Be 'v5.0.0'
        $p.Source | Should -Be 'explicit'
    }
    It 'abandons the pin when -Force is passed' {
        $p = Get-StarshipSyncPin -RecordedPin 'v4.9.0' -Force
        $p.Ref    | Should -BeNullOrEmpty
        $p.Source | Should -Be 'forced-branch'
    }
    It 'treats the (branch tip) sentinel as NOT a pin' {
        $p = Get-StarshipSyncPin -RecordedPin '(branch tip)'
        $p.Ref    | Should -BeNullOrEmpty
        $p.Source | Should -Be 'branch'
    }
    It 'tracks the branch when nothing is recorded' {
        (Get-StarshipSyncPin).Source                     | Should -Be 'branch'
        (Get-StarshipSyncPin -RecordedPin '').Source     | Should -Be 'branch'
    }
    It 'cannot honour a pin under -CoreLocal (there is no ref to fetch)' {
        $p = Get-StarshipSyncPin -RecordedPin 'v4.9.0' -CoreLocalUsed
        $p.Ref    | Should -BeNullOrEmpty
        $p.Source | Should -Be 'core-local'
    }
    It 'produces a pin the ref planner accepts' {
        # The two resolvers must compose: a carried-forward pin has to survive
        # Get-StarshipSyncRefPlan, not trip its option-injection guard.
        $p    = Get-StarshipSyncPin -RecordedPin 'v4.9.0'
        $plan = Get-StarshipSyncRefPlan -Ref $p.Ref -Branch 'main'
        $plan.Mode   | Should -Be 'ref'
        $plan.Target | Should -Be 'v4.9.0'
    }
}
AfterAll { Remove-Item Env:DOTFILES_STARSHIPSYNC_LIBONLY -ErrorAction SilentlyContinue }

Describe 'Get-StarshipSyncRefPlan' {
    It 'syncs the branch tip when no ref is given' {
        $p = Get-StarshipSyncRefPlan -Branch 'main'
        $p.Mode   | Should -Be 'branch'
        $p.Target | Should -Be 'main'
    }
    It 'pins an exact ref, which wins over -Branch' {
        $p = Get-StarshipSyncRefPlan -Ref 'v2.1.0' -Branch 'main'
        $p.Mode   | Should -Be 'ref'
        $p.Target | Should -Be 'v2.1.0'
    }
    It 'rejects a ref that starts with a dash (option injection)' {
        { Get-StarshipSyncRefPlan -Ref '--upload-pack=evil' } | Should -Throw
    }
    It 'rejects -Ref combined with -CoreLocal' {
        { Get-StarshipSyncRefPlan -Ref 'abc1234' -CoreLocal 'C:\src\dotfiles-core' } | Should -Throw
    }
}
