# ============================================================================
#  tests/Doctor.Tests.ps1  -  dotfiles-doctor result model + aggregation.
#  (Host-specific probes are not exercised; the pure logic is.)
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    # The doctor result model + pure logic now live in the Dotfiles module (B7
    # stage 2b); import it rather than dot-sourcing the fragment (whose probes and
    # the dotfiles-doctor verb are host-specific and not exercised here).
    $script:Module = Import-Module (Join-Path $RepoRoot 'powershell/Dotfiles/Dotfiles.psd1') -Force -DisableNameChecking -PassThru
}
AfterAll { if ($script:Module) { Remove-Module $script:Module -Force -ErrorAction SilentlyContinue } }

Describe 'New-DoctorResult' {
    It 'builds a result with the expected shape' {
        $r = New-DoctorResult -Name 'thing' -Status 'ok' -Detail 'd' -Hint 'h'
        $r.Name | Should -Be 'thing'
        $r.Status | Should -Be 'ok'
    }
    It 'rejects an invalid status' {
        { New-DoctorResult -Name 'x' -Status 'bogus' } | Should -Throw
    }
}

Describe 'Get-FragmentHealthResult' {
    It 'warns when the profile never loaded (null)' {
        (Get-FragmentHealthResult $null).Status | Should -Be 'warn'
    }
    It 'is ok for an empty error list' {
        (Get-FragmentHealthResult @()).Status | Should -Be 'ok'
    }
    It 'fails and reports the count + first failure' {
        $res = Get-FragmentHealthResult @('core/10-tools.ps1: boom', 'os/40-maint.ps1: nope')
        $res.Status | Should -Be 'fail'
        $res.Detail | Should -Match '2 failed'
        $res.Detail | Should -Match '10-tools'
    }
}

Describe 'Get-DoctorFixPlan' {
    It 'is empty when everything is ok' {
        (Get-DoctorFixPlan @((New-DoctorResult 'Execution policy' 'ok'))) | Should -BeNullOrEmpty
    }
    It 'maps known failing checks to deduped actions' {
        $plan = Get-DoctorFixPlan @(
            (New-DoctorResult 'Execution policy' 'fail'),
            (New-DoctorResult 'Profile link' 'warn'),
            (New-DoctorResult 'link: .gitconfig' 'warn'),
            (New-DoctorResult 'Modules off OneDrive' 'warn'),
            (New-DoctorResult 'Core toolchain' 'warn')
        )
        $plan | Should -Contain 'execpolicy'
        $plan | Should -Contain 'rewire'
        $plan | Should -Contain 'localize-modules'
        $plan | Should -Contain 'install-packages'
        # 'Profile link' + 'link: .gitconfig' both collapse to a single rewire.
        ($plan | Where-Object { $_ -eq 'rewire' }).Count | Should -Be 1
    }
    It 'ignores checks it has no remedy for' {
        (Get-DoctorFixPlan @((New-DoctorResult 'git identity' 'warn'))) | Should -BeNullOrEmpty
    }
}

Describe 'Get-DotRepoVersionDetail' {
    It 'formats sha + date + dirty marker' {
        $d = Get-DotRepoVersionDetail -Sha 'abc1234' -IsDirty $true -When '2026-06-16'
        $d | Should -Match 'abc1234'
        $d | Should -Match '2026-06-16'
        $d | Should -Match '\[dirty\]'
    }
    It 'omits the dirty marker on a clean tree' {
        (Get-DotRepoVersionDetail -Sha 'abc1234' -IsDirty $false) | Should -Not -Match '\[dirty\]'
    }
    It 'reports unknown when there is no sha' {
        (Get-DotRepoVersionDetail -Sha '' -IsDirty $false) | Should -Match 'unknown'
    }
}

Describe 'Get-NvimVendorDetail' {
    It 'formats the short sha + commit date' {
        $d = Get-NvimVendorDetail -Sha 'abcdef1234567' -When '2026-06-16'
        $d | Should -Match 'core@abcdef1'
        $d | Should -Match '2026-06-16'
    }
    It 'omits the date when it is unknown' {
        (Get-NvimVendorDetail -Sha 'abcdef1' -When 'unknown') | Should -Not -Match '\('
    }
    It 'reports a missing ref when there is no sha' {
        (Get-NvimVendorDetail -Sha '' -When '') | Should -Match 'no vendor ref'
    }
}

Describe 'Get-StarshipVendorDetail' {
    It 'formats the short sha + commit date' {
        $d = Get-StarshipVendorDetail -Sha '23822156e0a81cc' -When '2026-08-05'
        $d | Should -Match 'core@2382215'
        $d | Should -Match '2026-08-05'
    }
    It 'surfaces an explicit pin — the drift worth seeing' {
        # starship is the asset that carries a pin, and a silently dropped pin is
        # exactly what this row exists to make visible on the host.
        (Get-StarshipVendorDetail -Sha 'abcdef1' -When '2026-08-05' -Pinned 'v4.9.0') |
            Should -Match 'pinned v4\.9\.0'
    }
    It 'does not render the (branch tip) sentinel as a pin' {
        (Get-StarshipVendorDetail -Sha 'abcdef1' -When '2026-08-05' -Pinned '(branch tip)') |
            Should -Not -Match 'pinned'
    }
    It 'omits the date when it is unknown' {
        (Get-StarshipVendorDetail -Sha 'abcdef1' -When 'unknown') | Should -Not -Match '\('
    }
    It 'reports a missing ref when there is no sha' {
        (Get-StarshipVendorDetail -Sha '' -When '') | Should -Match 'no vendor ref'
        (Get-StarshipVendorDetail -Sha '' -When '') | Should -Match 'starship-sync'
    }
}

Describe 'Get-ThemeVendorDetail' {
    It 'formats the short sha + commit date' {
        $d = Get-ThemeVendorDetail -Sha 'a85622e9ec439d4' -When '2026-08-31'
        $d | Should -Match 'core@a85622e'
        $d | Should -Match '2026-08-31'
    }
    It 'surfaces an explicit pin' {
        (Get-ThemeVendorDetail -Sha 'abcdef1' -When '2026-08-31' -Pinned 'v5.5.0') |
            Should -Match 'pinned v5\.5\.0'
    }
    It 'does not render the (branch tip) sentinel as a pin' {
        (Get-ThemeVendorDetail -Sha 'abcdef1' -When '2026-08-31' -Pinned '(branch tip)') |
            Should -Not -Match 'pinned'
    }
    It 'names theme-sync.ps1 when no ref is recorded' {
        # The remedy has to name the RIGHT script - pointing a stale palette at
        # nvim-sync or starship-sync would send someone to re-vendor the wrong asset.
        (Get-ThemeVendorDetail -Sha '' -When '') | Should -Match 'theme-sync\.ps1'
    }
}

Describe 'Get-DoctorGroup' {
    It 'buckets shell/environment probes' {
        Get-DoctorGroup 'PowerShell 7 (pwsh)' | Should -Be 'Shell & environment'
        Get-DoctorGroup 'Execution policy'    | Should -Be 'Shell & environment'
        Get-DoctorGroup 'Symlink capability'  | Should -Be 'Shell & environment'
    }
    It 'buckets repo/link probes (including nvim vendor and link: rows)' {
        Get-DoctorGroup 'Repo root'        | Should -Be 'Repo & links'
        Get-DoctorGroup 'Profile link'     | Should -Be 'Repo & links'
        Get-DoctorGroup 'link: .gitconfig' | Should -Be 'Repo & links'
        Get-DoctorGroup 'nvim vendor'      | Should -Be 'Repo & links'
    }
    It 'groups the scoop bucket probe with health, not Other' {
        Get-DoctorGroup 'Scoop buckets' | Should -Be 'Health & toolchain'
    }
    It 'groups the maint task probe with health, not Other' {
        Get-DoctorGroup 'Maint tasks' | Should -Be 'Health & toolchain'
    }
    It 'keeps Profile fragments and Core toolchain in health (not repo)' {
        Get-DoctorGroup 'Profile fragments' | Should -Be 'Health & toolchain'
        Get-DoctorGroup 'Core toolchain'    | Should -Be 'Health & toolchain'
    }
    It 'puts an unknown probe in Other so it still renders' {
        Get-DoctorGroup 'Some Future Probe' | Should -Be 'Other'
    }
}

Describe 'Get-DoctorSummary' {
    It 'counts ok/warn/fail correctly' {
        $s = Get-DoctorSummary @(
            (New-DoctorResult a ok), (New-DoctorResult b warn),
            (New-DoctorResult c fail), (New-DoctorResult d ok)
        )
        $s.Ok | Should -Be 2; $s.Warn | Should -Be 1; $s.Fail | Should -Be 1
    }
    It 'overall is fail if any fail' {
        (Get-DoctorSummary @((New-DoctorResult a ok), (New-DoctorResult b fail))).Overall | Should -Be 'fail'
    }
    It 'overall is warn if warns but no fails' {
        (Get-DoctorSummary @((New-DoctorResult a ok), (New-DoctorResult b warn))).Overall | Should -Be 'warn'
    }
    It 'overall is ok if all ok' {
        (Get-DoctorSummary @((New-DoctorResult a ok))).Overall | Should -Be 'ok'
    }
}

Describe 'Get-ScoopBucketHealthResult' {
    # The wording IS the check here: a wedged bucket makes `scoop status` report
    # stale packages as current, so the row has to say why the box can't be
    # trusted and give the exact unwedge. See the 2026-08-04 `extras` incident.
    It 'is ok when nothing is faulted, and says how many it cleared' {
        $res = Get-ScoopBucketHealthResult -Faults @() -Checked 6
        $res.Status | Should -Be 'ok'
        $res.Name   | Should -Be 'Scoop buckets'
        $res.Detail | Should -Match '6 bucket'
    }
    It 'is ok, not a false pass, when there are no buckets at all' {
        $res = Get-ScoopBucketHealthResult -Faults @() -Checked 0
        $res.Status | Should -Be 'ok'
        $res.Detail | Should -Match 'no scoop buckets'
    }
    It 'warns (not fails) on a fault — nothing is broken, it just cannot be trusted' {
        $res = Get-ScoopBucketHealthResult -Faults @('extras — stuck mid-merge (MERGE_HEAD)') -Checked 6
        $res.Status | Should -Be 'warn'
    }
    It 'names every faulted bucket in the detail' {
        $res = Get-ScoopBucketHealthResult -Faults @('extras — stuck mid-merge', 'java — dirty') -Checked 6
        $res.Detail | Should -Match 'extras'
        $res.Detail | Should -Match 'java'
    }
    It 'hints the actual unwedge, not just "something is wrong"' {
        $res = Get-ScoopBucketHealthResult -Faults @('extras — stuck mid-merge') -Checked 6
        $res.Hint | Should -Match 'reset --hard'
        $res.Hint | Should -Match 'scoop update'
    }
    It 'explains the stale-reporting risk in the hint (why a warn matters)' {
        $res = Get-ScoopBucketHealthResult -Faults @('extras — stuck mid-merge') -Checked 6
        $res.Hint | Should -Match 'stale'
    }
    It 'treats $null faults like none' {
        (Get-ScoopBucketHealthResult -Faults $null -Checked 3).Status | Should -Be 'ok'
    }
}
