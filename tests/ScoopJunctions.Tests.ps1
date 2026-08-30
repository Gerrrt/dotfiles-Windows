# ============================================================================
#  tests/ScoopJunctions.Tests.ps1  -  the policy behind maint's scoop junction
#  re-creation, and the two scheduled tasks that carry it.
#
#  Redirection Guard refuses a junction CREATED by a non-admin, and NTFS stamps
#  that trust at creation from the creator's token — so re-creating the junction
#  from an elevated process is the only lever (docs/REMOTE-ACCESS.md).
#
#  Get-DotScoopJunctionPlan decides WHICH reparse points that applies to. The walk
#  and the rmdir/mklink live in maint/Repair-ScoopJunctions.ps1 and are not
#  exercised here — they need a scoop install and an admin token. The
#  classification is pure, so all of it is tested with hand-built rows.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Module = Import-Module (Join-Path $RepoRoot 'powershell/Dotfiles/Dotfiles.psd1') -Force -DisableNameChecking -PassThru

    function script:Row {
        param([string]$Link, [string]$Target, $LinkType)
        @{ Link = $Link; Target = $Target; LinkType = $LinkType }
    }
}
AfterAll {
    if ($script:Module) { Remove-Module $script:Module -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-DotScoopJunctionPlan' {

    Context 'classification, elevated' {
        It 'queues a junction for re-creation' {
            $p = Get-DotScoopJunctionPlan -Candidate @((Row 'a\current' 'a\1.0' 'Junction')) -IsElevated $true
            $p.Rows[0].Action | Should -Be 'recreate'
            $p.ToRecreate     | Should -Be 1
        }

        # A hardlink is a second NAME for the same file, not a reparse point —
        # nothing is traversed and Redirection Guard never looks at it. scoop leaves
        # several in the app dirs (bat\current\config, btop-lhm\current\btop.conf).
        It 'skips a hardlink' {
            $p = Get-DotScoopJunctionPlan -Candidate @((Row 'b\cfg' 'p\b\cfg' 'HardLink')) -IsElevated $true
            $p.Rows[0].Action | Should -Be 'skip-not-junction'
            $p.NotJunction    | Should -Be 1
            $p.ToRecreate     | Should -Be 0
        }

        # scoop's own app dir has a real `current` directory, not a junction.
        It 'skips a plain directory with no link type' {
            $p = Get-DotScoopJunctionPlan -Candidate @((Row 'scoop\current' 'scoop\current' $null)) -IsElevated $true
            $p.Rows[0].Action | Should -Be 'skip-not-junction'
        }

        # Re-making a symlink is mklink /D, a different operation with different
        # semantics. scoop does not create them, so they are left alone rather than
        # silently converted.
        It 'skips a symlink rather than converting it to a junction' {
            $p = Get-DotScoopJunctionPlan -Candidate @((Row 'c\link' 'c\real' 'SymbolicLink')) -IsElevated $true
            $p.Rows[0].Action | Should -Be 'skip-not-junction'
        }

        # A half-finished scoop update can leave a junction pointing at nothing;
        # mklink with an empty target would only manufacture an error.
        It 'skips a junction whose target could not be resolved' {
            $p = Get-DotScoopJunctionPlan -Candidate @((Row 'd\current' '' 'Junction')) -IsElevated $true
            $p.Rows[0].Action | Should -Be 'skip-unresolved'
            $p.Unresolved     | Should -Be 1
        }
    }

    Context 'unelevated' {
        # Re-creating as a non-admin would just re-stamp the junction untrusted, so
        # there is nothing useful to do. Reporting one Blocked count is what lets the
        # maint step log ONE honest line instead of one failure per app.
        It 'blocks the junctions and leaves the rest classified' {
            $rows = @(
                (Row 'a\current' 'a\1.0' 'Junction')
                (Row 'b\current' 'b\2.0' 'Junction')
                (Row 'b\cfg'     'p\b'   'HardLink')
            )
            $p = Get-DotScoopJunctionPlan -Candidate $rows -IsElevated $false
            $p.Blocked     | Should -Be 2
            $p.ToRecreate  | Should -Be 0
            $p.NotJunction | Should -Be 1
            ($p.Rows | Where-Object { $_.Action -eq 'blocked-not-elevated' }).Count | Should -Be 2
        }

        It 'blocks nothing when there are no junctions at all' {
            $p = Get-DotScoopJunctionPlan -Candidate @((Row 'b\cfg' 'p\b' 'HardLink')) -IsElevated $false
            $p.Blocked | Should -Be 0
        }
    }

    Context 'the tallies' {
        It 'accounts for every candidate exactly once' {
            $rows = @(
                (Row 'a\current' 'a\1.0' 'Junction')
                (Row 'b\cfg'     'p\b'   'HardLink')
                (Row 'c\link'    'c\r'   'SymbolicLink')
                (Row 'd\current' ''      'Junction')
                (Row 'e\dir'     'e\dir' $null)
            )
            $p = Get-DotScoopJunctionPlan -Candidate $rows -IsElevated $true
            $p.Total | Should -Be 5
            ($p.ToRecreate + $p.NotJunction + $p.Unresolved + $p.Blocked) | Should -Be $p.Total
        }

        It 'returns an empty plan for an empty candidate set rather than throwing' {
            $p = Get-DotScoopJunctionPlan -Candidate @() -IsElevated $true
            $p.Total      | Should -Be 0
            $p.ToRecreate | Should -Be 0
            $p.Rows       | Should -HaveCount 0
        }
    }
}

Describe 'maint/Repair-ScoopJunctions.ps1' {
    BeforeAll {
        $RepoRoot   = Split-Path -Parent $PSScriptRoot
        $script:Src = Get-Content (Join-Path $RepoRoot 'maint/Repair-ScoopJunctions.ps1') -Raw
    }

    # apps\<app>\current is not the only junction scoop makes. It wires persisted
    # state back out of an app dir into scoop\persist\<app>\..., and
    # scoop\modules\gsudoModule sits outside apps\ entirely — 15 further junctions
    # on a real host. Re-stamp only `current` and bat still cannot read its themes
    # over ssh, so the walk must be the whole root, not a tour of the app dirs.
    It 'walks every directory reparse point under the scoop root' {
        $script:Src | Should -Match '-Recurse -Directory -Force'
        $script:Src | Should -Match '-Attributes ReparsePoint'
        # not a hand-written descent into apps\<app>\current
        $script:Src | Should -Not -Match "Join-Path \`$_\.FullName 'current'"
    }

    # rmdir on a junction must drop the LINK and never recurse into the target —
    # otherwise re-creating bat\themes would delete persist\bat\themes.
    It 'drops the link with rmdir and re-makes it with mklink /J' {
        $script:Src | Should -Match 'cmd /c rmdir'
        $script:Src | Should -Match 'cmd /c mklink /J'
    }

    # scoop sets ReadOnly on `current`, and rmdir refuses a read-only directory.
    It "clears scoop's ReadOnly bit before removing" {
        $script:Src | Should -Match 'FileAttributes\]::ReadOnly'
    }

    # An app whose files are in use (pwsh running the runner) fails its rmdir. That
    # is expected and must not be reported as a failure, nor leave a missing link.
    It 'treats an in-use junction as skipped, not failed' {
        $script:Src | Should -Match '\$inUse\+\+'
    }

    # Step runs its body as `& $Body *>> $Log` under $ErrorActionPreference =
    # 'Continue', so a native exe's exit code is swallowed — only a terminating
    # error is ever reported as FAIL.
    It 'throws on real failures so Maintenance.ps1 Step reports FAIL' {
        $script:Src | Should -Match 'if \(\$failed -gt 0\) \{ throw'
    }

    It 'is wired into Maintenance.ps1 after the scoop upgrade' {
        $m = Get-Content (Join-Path $RepoRoot 'maint/Maintenance.ps1') -Raw
        $m | Should -Match 'Repair-ScoopJunctions\.ps1'
        $upgrade = $m.IndexOf("Step 'scoop upgrade (apps)'")
        $reown   = $m.IndexOf("Step 'scoop: re-create junctions (admin-trusted)'")
        $upgrade | Should -BeGreaterThan 0
        $reown   | Should -BeGreaterThan $upgrade
    }
}

Describe 'the two maint scheduled tasks (os/40-maint.ps1)' {
    BeforeAll {
        $RepoRoot   = Split-Path -Parent $PSScriptRoot
        $script:Src = Get-Content (Join-Path $RepoRoot 'powershell/os/40-maint.ps1') -Raw
    }

    # The daily runner must NEVER gain a principal: scoop explicitly discourages
    # running `scoop update` as admin (packages/Install-Packages.ps1 warns about it).
    # Only the junction task is elevated.
    It 'leaves the daily task unelevated — exactly one principal, in the scoop path' {
        ([regex]::Matches($script:Src, 'New-ScheduledTaskPrincipal')).Count | Should -Be 1
        $script:Src | Should -Match "New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest"
    }

    # SYSTEM's profile paths are not the user's, so neither may be inferred there.
    It 'bakes the user-resolved scoop root and log path into the task action' {
        $script:Src | Should -Match '-ScoopRoot "\{1\}" -LogPath "\{2\}"'
    }

    # It has to run after `scoop update *`, which is what re-creates the junctions
    # untrusted. The daily task's ExecutionTimeLimit is 1h, so +1h cannot overlap.
    It 'schedules the junction repair an hour after the daily run' {
        $script:Src | Should -Match '\(\[datetime\]\$When\)\.AddHours\(1\)'
        $script:Src | Should -Match 'ExecutionTimeLimit \(New-TimeSpan -Hours 1\)'
    }

    # The task list has one definition, Get-DotMaintTaskName, and both the reporting
    # and the removal verbs iterate it — so neither can drift into handling only one
    # of the two tasks. (45-doctor.ps1 consumes the same provider rather than
    # hardcoding the names.)
    It 'registers, reports and removes both tasks' {
        $script:Src | Should -Match "\`$script:ScoopTaskName = 'dotfiles-maint-scoop-junctions'"
        ([regex]::Matches($script:Src, '@\(\$script:MaintTaskName, \$script:ScoopTaskName\)')).Count | Should -Be 1
        ([regex]::Matches($script:Src, 'foreach \(\$name in \(Get-DotMaintTaskName\)\)')).Count | Should -Be 2
    }

    # Registering an elevated task needs an elevated shell. That must degrade to one
    # warning with the daily task still installed, not fail the whole command.
    It 'degrades to a single warning when not elevated' {
        $script:Src | Should -Match 'if \(-not \$isAdmin\) \{'
        $script:Src | Should -Match 'Write-DotWarn "scoop junction task'
    }
}
