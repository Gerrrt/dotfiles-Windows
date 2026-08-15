# ============================================================================
#  tests/Packages.Tests.ps1  -  Install-Packages helpers (library-only).
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $env:DOTFILES_PKG_LIBONLY = '1'
    . (Join-Path $RepoRoot 'packages/Install-Packages.ps1')
}
AfterAll { Remove-Item Env:DOTFILES_PKG_LIBONLY -ErrorAction SilentlyContinue }

Describe 'Get-WingetInstalledIds' {
    It 'extracts PackageIdentifiers from export JSON' {
        $json = '{ "Sources": [ { "Packages": [ {"PackageIdentifier":"Git.Git"}, {"PackageIdentifier":"Mozilla.Firefox"} ] } ] }'
        $ids = Get-WingetInstalledIds $json
        $ids | Should -HaveCount 2
        $ids | Should -Contain 'Git.Git'
    }
    It 'returns empty for blank input' {
        Get-WingetInstalledIds '' | Should -BeNullOrEmpty
    }
    It 'returns empty for malformed JSON (no throw)' {
        { Get-WingetInstalledIds 'not json {{' } | Should -Not -Throw
        Get-WingetInstalledIds 'not json {{' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ScoopInstallToken' {
    It 'returns the bare name when unpinned' {
        Get-ScoopInstallToken ([pscustomobject]@{ Name = 'fzf'; Source = 'main' }) | Should -Be 'fzf'
    }
    It 'returns name@version when pinned' {
        Get-ScoopInstallToken ([pscustomobject]@{ Name = 'fzf'; Version = '0.54.0' }) | Should -Be 'fzf@0.54.0'
    }
}

Describe 'ConvertTo-DotWingetSpec' {
    It 'treats a bare string as an unpinned, ungrouped id' {
        $s = ConvertTo-DotWingetSpec 'Git.Git'
        $s.Id | Should -Be 'Git.Git'; $s.Version | Should -BeNullOrEmpty; $s.Group | Should -BeNullOrEmpty
    }
    It 'reads id + version from an object entry' {
        $s = ConvertTo-DotWingetSpec ([pscustomobject]@{ id = 'Git.Git'; version = '2.45.0' })
        $s.Id | Should -Be 'Git.Git'; $s.Version | Should -Be '2.45.0'
    }
    It 'reads an optional group tag (U3)' {
        $s = ConvertTo-DotWingetSpec ([pscustomobject]@{ id = 'Mozilla.Firefox'; group = 'gui' })
        $s.Id | Should -Be 'Mozilla.Firefox'; $s.Group | Should -Be 'gui'
    }
}

Describe 'Get-DotInstallProgress' {
    It 'reports 0% and an unknown ETA before anything finishes' {
        $p = Get-DotInstallProgress -Completed 0 -Total 10 -ElapsedSeconds 0
        $p.Percent | Should -Be 0
        $p.EtaSeconds | Should -Be -1
    }
    It 'extrapolates the ETA from the average pace so far' {
        # 4 of 20 done in 20s -> 5s/item, 16 left -> 80s.
        $p = Get-DotInstallProgress -Completed 4 -Total 20 -ElapsedSeconds 20
        $p.Percent | Should -Be 20
        $p.EtaSeconds | Should -Be 80
    }
    It 'never reaches 100% until the last item finishes (floors, e.g. 199/200 -> 99)' {
        (Get-DotInstallProgress -Completed 199 -Total 200 -ElapsedSeconds 199).Percent | Should -Be 99
    }
    It 'is 100% with a zero ETA once complete' {
        $p = Get-DotInstallProgress -Completed 20 -Total 20 -ElapsedSeconds 100
        $p.Percent | Should -Be 100
        $p.EtaSeconds | Should -Be 0
    }
    It 'is inert for a zero/empty total (no divide-by-zero)' {
        $p = Get-DotInstallProgress -Completed 0 -Total 0 -ElapsedSeconds 5
        $p.Percent | Should -Be 0
        $p.EtaSeconds | Should -Be -1
    }
}

Describe 'Format-DotDuration' {
    It 'renders sub-minute durations as seconds' {
        Format-DotDuration 0  | Should -Be '0s'
        Format-DotDuration 45 | Should -Be '45s'
    }
    It 'renders minute+ durations as MmSSs with zero-padded seconds' {
        Format-DotDuration 65  | Should -Be '1m05s'
        Format-DotDuration 600 | Should -Be '10m00s'
    }
    It 'renders an unknown (negative) duration as ?' {
        Format-DotDuration -1 | Should -Be '?'
    }
}

Describe 'Get-PackagesUsage' {
    It 'documents every public switch' {
        $u = (Get-PackagesUsage) -join "`n"
        foreach ($flag in '-SkipScoop', '-SkipWinget', '-Frozen', '-NonInteractive', '-Help') {
            $u | Should -Match ([regex]::Escape($flag))
        }
    }
}

# --- optional package groups (U3): pure policy helpers ------------------------
Describe 'Get-DotOptionalGroups' {
    It 'returns the distinct, sorted group tags present' {
        $entries = @(
            [pscustomobject]@{ Id = 'a'; Group = 'gui' }
            [pscustomobject]@{ Id = 'b'; Group = $null }
            [pscustomobject]@{ Id = 'c'; Group = 'gui' }
            [pscustomobject]@{ Id = 'd'; Group = 'sec' }
        )
        Get-DotOptionalGroups $entries | Should -Be @('gui', 'sec')
    }
    It 'returns empty when nothing is tagged' {
        Get-DotOptionalGroups @([pscustomobject]@{ Id = 'a'; Group = $null }) | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-DotGroupList / ConvertTo-DotGroupList' {
    It 'parses space- or comma-separated lists (lowercased, de-duped, sorted)' {
        ConvertFrom-DotGroupList 'GUI sec gui'  | Should -Be @('gui', 'sec')
        ConvertFrom-DotGroupList 'gui,sec'      | Should -Be @('gui', 'sec')
    }
    It 'treats blank and the "none" marker (any case) as an empty selection' {
        ConvertFrom-DotGroupList ''     | Should -BeNullOrEmpty
        ConvertFrom-DotGroupList 'none' | Should -BeNullOrEmpty
        ConvertFrom-DotGroupList 'NONE' | Should -BeNullOrEmpty
        ConvertFrom-DotGroupList 'None' | Should -BeNullOrEmpty
    }
    It 'formats a selection, emitting "none" when empty' {
        ConvertTo-DotGroupList @('sec', 'gui') | Should -Be 'gui sec'
        ConvertTo-DotGroupList @()             | Should -Be 'none'
    }
    It 'round-trips through both helpers' {
        ConvertFrom-DotGroupList (ConvertTo-DotGroupList @('gui')) | Should -Be @('gui')
        ConvertTo-DotGroupList (ConvertFrom-DotGroupList 'none')   | Should -Be 'none'
    }
}

Describe 'Test-DotGroupSelected' {
    It 'always installs a core (untagged) entry' {
        Test-DotGroupSelected -Group ''    -Selected @()      | Should -BeTrue
        Test-DotGroupSelected -Group $null -Selected @('gui') | Should -BeTrue
    }
    It 'installs a tagged entry only when its group is selected' {
        Test-DotGroupSelected -Group 'gui' -Selected @('gui') | Should -BeTrue
        Test-DotGroupSelected -Group 'gui' -Selected @('sec') | Should -BeFalse
        Test-DotGroupSelected -Group 'gui' -Selected @()      | Should -BeFalse
    }
    It 'installs a tagged entry when the selection is unknown ($null = opt-out default)' {
        Test-DotGroupSelected -Group 'gui' -Selected $null | Should -BeTrue
    }
}

Describe 'Set-DotGroupLine' {
    It 'appends a managed line to content that lacks one' {
        $out = Set-DotGroupLine -Content "# header`n" -Value 'gui'
        $out | Should -Match "(?m)^\`$env:DOTFILES_PKG_GROUPS = 'gui'"
        $out | Should -Match '# header'
    }
    It 'replaces an existing managed line instead of duplicating it' {
        $first  = Set-DotGroupLine -Content '' -Value 'gui'
        $second = Set-DotGroupLine -Content $first -Value 'none'
        @($second -split "`n" | Where-Object { $_ -match 'DOTFILES_PKG_GROUPS' }).Count | Should -Be 1
        $second | Should -Match "DOTFILES_PKG_GROUPS = 'none'"
    }
}

Describe 'Resolve-DotPackageGroupSelection' {
    AfterEach { Remove-Item Env:DOTFILES_PKG_GROUPS -ErrorAction SilentlyContinue }

    It 'returns empty when no optional groups exist' {
        Resolve-DotPackageGroupSelection -Available @() -NonInteractive $true -LocalPs1Path 'x' | Should -BeNullOrEmpty
    }
    It 'installs every group non-interactively (opt-out default)' {
        Resolve-DotPackageGroupSelection -Available @('gui', 'sec') -NonInteractive $true -LocalPs1Path 'x' |
            Should -Be @('gui', 'sec')
    }
    It 'honours a persisted selection, clamped to what exists' {
        $env:DOTFILES_PKG_GROUPS = 'gui gone'
        Resolve-DotPackageGroupSelection -Available @('gui', 'sec') -NonInteractive $false -LocalPs1Path 'x' |
            Should -Be @('gui')
    }
    It 'honours a persisted "none" as an empty selection' {
        $env:DOTFILES_PKG_GROUPS = 'none'
        Resolve-DotPackageGroupSelection -Available @('gui') -NonInteractive $false -LocalPs1Path 'x' |
            Should -BeNullOrEmpty
    }
}

# --- packages/PackageLock.ps1 (B4): pure lockfile helpers --------------------
# Dot-sourced transitively by Install-Packages.ps1 above, so the functions are in
# scope here.
Describe 'Read-PackageLock' {
    It 'parses scoop and winget version maps' {
        # generatedAt is a non-date sentinel on purpose: ConvertFrom-Json coerces an
        # ISO-8601 string into a [datetime] (which round-trips as 2026-...0000000Z),
        # and generatedAt is informational only. The version VALUES are explicitly
        # string-coerced in the helper, so they stay exact.
        $lock = Read-PackageLock '{ "generatedAt": "lock-stamp", "scoop": { "fzf": "0.54.0" }, "winget": { "Git.Git": "2.47.1" } }'
        $lock.Scoop['fzf']      | Should -Be '0.54.0'
        $lock.Winget['Git.Git'] | Should -Be '2.47.1'
        $lock.GeneratedAt       | Should -Be 'lock-stamp'
    }
    It 'is case-insensitive on lookups' {
        (Read-PackageLock '{ "scoop": { "FZF": "1.0" } }').Scoop['fzf'] | Should -Be '1.0'
    }
    It 'returns empty maps for blank or malformed input (no throw)' {
        (Read-PackageLock '').Scoop          | Should -BeNullOrEmpty
        { Read-PackageLock 'not json {{' }   | Should -Not -Throw
        (Read-PackageLock 'not json {{').Winget | Should -BeNullOrEmpty
    }
}

Describe 'Get-LockedVersion' {
    It 'returns the version when present (case-insensitive)' {
        Get-LockedVersion -Map @{ 'Git.Git' = '2.47.1' } -Name 'git.git' | Should -Be '2.47.1'
    }
    It 'returns $null for a miss, a null map, or an empty name' {
        Get-LockedVersion -Map @{ a = '1' } -Name 'b' | Should -BeNullOrEmpty
        Get-LockedVersion -Map $null -Name 'a'        | Should -BeNullOrEmpty
        Get-LockedVersion -Map @{ a = '1' } -Name ''   | Should -BeNullOrEmpty
    }
}

Describe 'Test-PackageVersionMatch' {
    It 'treats trailing-zero padding as the same release (the #140 false positives)' {
        Test-PackageVersionMatch '2026.1.0.0' '2026.1'  | Should -BeTrue
        Test-PackageVersionMatch '2.7.10.0'   '2.7.10'  | Should -BeTrue
        Test-PackageVersionMatch '4.5.0.0'    '4.5.0'   | Should -BeTrue
        Test-PackageVersionMatch '1.0'        '1.0.0.0' | Should -BeTrue
    }
    It 'is symmetric regardless of which side carries more components' {
        Test-PackageVersionMatch '2.7.10' '2.7.10.0' | Should -BeTrue
    }
    It 'still reports a genuine bump as different' {
        # The one real update in #140.
        Test-PackageVersionMatch '2026.7.11' '2026.7.7' | Should -BeFalse
        Test-PackageVersionMatch '1.2.3'     '1.2.4'    | Should -BeFalse
        Test-PackageVersionMatch '2.0'       '1.0.0.0'  | Should -BeFalse
    }
    It 'does not mistake a nonzero trailing component for padding' {
        Test-PackageVersionMatch '1.2.3.1' '1.2.3' | Should -BeFalse
    }
    It 'falls back to exact string compare when either side is not numeric-dotted' {
        Test-PackageVersionMatch '0.5.0-beta' '0.5.0'      | Should -BeFalse
        Test-PackageVersionMatch '0.5.0-beta' '0.5.0-beta' | Should -BeTrue
        Test-PackageVersionMatch 'nightly'    'nightly'    | Should -BeTrue
        Test-PackageVersionMatch 'nightly'    '1.0'        | Should -BeFalse
    }
    It 'handles empty/absent versions without throwing' {
        { Test-PackageVersionMatch '' '' } | Should -Not -Throw
        Test-PackageVersionMatch '' ''    | Should -BeTrue
        Test-PackageVersionMatch '1.0' '' | Should -BeFalse
    }
    It 'compares components numerically, not lexically' {
        # A string compare would call these equal-length-but-different; a lexical
        # one would order 9 after 10. Both must read as a real difference.
        Test-PackageVersionMatch '1.10' '1.9'  | Should -BeFalse
        Test-PackageVersionMatch '1.010' '1.10' | Should -BeTrue
    }
}

Describe 'ConvertFrom-ScoopExport' {
    It 'reads name/version from the modern { apps: [...] } shape' {
        $m = ConvertFrom-ScoopExport '{ "apps": [ { "Name": "fzf", "Version": "0.54.0" }, { "Name": "bat", "Version": "0.24.0" } ] }'
        $m['fzf'] | Should -Be '0.54.0'; $m['bat'] | Should -Be '0.24.0'
    }
    It 'reads the legacy bare-array shape' {
        (ConvertFrom-ScoopExport '[ { "Name": "jq", "Version": "1.7" } ]')['jq'] | Should -Be '1.7'
    }
    It 'skips entries without a version, and tolerates junk' {
        (ConvertFrom-ScoopExport '{ "apps": [ { "Name": "x" } ] }').Count | Should -Be 0
        { ConvertFrom-ScoopExport 'nope' } | Should -Not -Throw
    }
}

Describe 'ConvertFrom-WingetExport' {
    It 'reads id/version from the Sources/Packages shape' {
        $json = '{ "Sources": [ { "Packages": [ { "PackageIdentifier": "Git.Git", "Version": "2.47.1" } ] } ] }'
        (ConvertFrom-WingetExport $json)['Git.Git'] | Should -Be '2.47.1'
    }
    It 'skips non-version placeholders and empty versions' {
        $json = '{ "Sources": [ { "Packages": [ { "PackageIdentifier": "A", "Version": "Unknown" }, { "PackageIdentifier": "B", "Version": "" }, { "PackageIdentifier": "C", "Version": "Latest" } ] } ] }'
        (ConvertFrom-WingetExport $json).Count | Should -Be 0
    }
}

Describe 'Get-PackageLockDrift' {
    It 'reports nothing when the manifest and lock agree' {
        $d = Get-PackageLockDrift -DesiredNames @('a', 'b') -LockMap @{ a = '1'; b = '2' }
        $d.InSync | Should -BeTrue
    }
    It 'flags a desired-but-unlocked name as Missing' {
        $d = Get-PackageLockDrift -DesiredNames @('a', 'b') -LockMap @{ a = '1' }
        $d.Missing | Should -Contain 'b'; $d.InSync | Should -BeFalse
    }
    It 'flags a locked-but-undesired name as Orphan' {
        $d = Get-PackageLockDrift -DesiredNames @('a') -LockMap @{ a = '1'; old = '9' }
        $d.Orphan | Should -Contain 'old'; $d.InSync | Should -BeFalse
    }
    It 'does not flag an ignored name as Missing when it is absent from the lock' {
        $d = Get-PackageLockDrift -DesiredNames @('a', 'selfup') -LockMap @{ a = '1' } -Ignore @('selfup')
        $d.Missing | Should -BeNullOrEmpty; $d.InSync | Should -BeTrue
    }
    It 'does not flag an ignored name as Orphan when a stale lock still carries it' {
        $d = Get-PackageLockDrift -DesiredNames @('a') -LockMap @{ a = '1'; selfup = '9' } -Ignore @('selfup')
        $d.Orphan | Should -BeNullOrEmpty; $d.InSync | Should -BeTrue
    }
    It 'still flags genuinely missing names when an ignore list is supplied' {
        $d = Get-PackageLockDrift -DesiredNames @('a', 'b') -LockMap @{ a = '1' } -Ignore @('selfup')
        $d.Missing | Should -Contain 'b'; $d.InSync | Should -BeFalse
    }
}

Describe 'Get-UnpinnableWingetId' {
    It 'lists 1Password, whose version winget can only report as a constraint' {
        Get-UnpinnableWingetId | Should -Contain 'AgileBits.1Password'
    }
    It 'stays short - every entry costs -Frozen reproducibility' {
        @(Get-UnpinnableWingetId).Count | Should -BeLessOrEqual 5
    }
    It 'returns ids the version parser genuinely rejects' {
        # Guards the pairing: if ConvertFrom-WingetExport ever started accepting
        # "> 1.2.3", the allowlist would be silently masking a real drift.
        $json = '{"Sources":[{"Packages":[{"PackageIdentifier":"AgileBits.1Password","Version":"> 8.12.28.25"}]}]}'
        (ConvertFrom-WingetExport $json).ContainsKey('AgileBits.1Password') | Should -BeFalse
    }
}

Describe 'New-PackageLockObject' {
    It 'sorts keys and carries the injected timestamp' {
        $o = New-PackageLockObject -Scoop @{ zoxide = '1'; bat = '2' } -Winget @{} -GeneratedAt 'TS'
        $o.generatedAt | Should -Be 'TS'
        @($o.scoop.Keys) | Should -Be @('bat', 'zoxide')   # sorted
    }
    It 'treats a $null section as an empty map (no throw)' {
        { New-PackageLockObject -Scoop $null -Winget $null -GeneratedAt 'TS' } | Should -Not -Throw
        $o = New-PackageLockObject -Scoop $null -Winget $null -GeneratedAt 'TS'
        @($o.scoop.Keys).Count | Should -Be 0
    }
}

# --- drift gate: enforced once packages.lock.json is committed (B4) -----------
Describe 'packages.lock.json drift' {
    It 'covers exactly the managed manifest set (skipped until the lock exists)' {
        $lockPath = Join-Path $RepoRoot 'packages/packages.lock.json'
        if (-not (Test-Path $lockPath)) {
            Set-ItResult -Skipped -Because 'no packages.lock.json yet — run Update-PackageLock.ps1 on Windows and commit it'
            return
        }
        $lock = Read-PackageLock (Get-Content $lockPath -Raw)
        $scoop  = Get-Content (Join-Path $RepoRoot 'packages/scoopfile.json') -Raw | ConvertFrom-Json
        $winget = Get-Content (Join-Path $RepoRoot 'packages/winget.json')  -Raw | ConvertFrom-Json
        $scoopNames = @($scoop.apps | ForEach-Object { $_.Name })
        $wingetIds  = @($winget.packages | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.id } })

        # Self-updating packages can never be locked (winget reports "> <ver>",
        # which ConvertFrom-WingetExport rejects on purpose) — exclude them so a
        # permanent, by-design gap doesn't read as "you forgot to re-lock".
        $sd = Get-PackageLockDrift -DesiredNames $scoopNames -LockMap $lock.Scoop
        $wd = Get-PackageLockDrift -DesiredNames $wingetIds  -LockMap $lock.Winget -Ignore (Get-UnpinnableWingetId)
        $sd.Missing | Should -BeNullOrEmpty -Because "scoop apps added without re-locking: $($sd.Missing -join ', ')"
        $sd.Orphan  | Should -BeNullOrEmpty -Because "scoop apps removed from the manifest but still locked: $($sd.Orphan -join ', ')"
        $wd.Missing | Should -BeNullOrEmpty -Because "winget ids added without re-locking: $($wd.Missing -join ', ')"
        $wd.Orphan  | Should -BeNullOrEmpty -Because "winget ids removed from the manifest but still locked: $($wd.Orphan -join ', ')"
    }
}

# --- the one manifest overlap that had no gate --------------------------------
# scoop<->lock, winget<->lock and winget.json<->winget-import.json are all already
# guarded above. configuration.dsc.yaml was not, and it matters more now that the
# README makes `winget configure -f configuration.dsc.yaml` the documented Step 0
# for a fresh box: the DSC baseline and the manifest the installer actually reads
# could diverge silently, so Step 0 would provision a different set than
# Install-Packages.ps1 expects.
#
# The invariant comes from configuration.dsc.yaml's own header: it "carries the
# CORE, untagged baseline only — the opt-in gui/desktop groups live in
# winget-import.json / winget.json". So every winget id it declares must (a) exist
# in winget.json and (b) be an UNTAGGED core entry there.
Describe 'configuration.dsc.yaml and winget.json' {
    # Dependency-free parse, matching Invoke-Validation.ps1's house style (no YAML
    # module on the runner). A winget id is Publisher.Package -- at least one dot and
    # no whitespace -- which cleanly separates the `settings: id:` values from the DSC
    # *resource* ids (os-version, developer-mode, windows-terminal), none of which
    # contain a dot. Resolved inside each It, like the other Describes in this file.
    It 'finds the DSC winget ids (guards the parser itself)' {
        # If the parse silently returned nothing, every assertion below would pass
        # vacuously. Pin that it actually found something.
        $ids = Get-DscWingetId (Join-Path $RepoRoot 'configuration.dsc.yaml')
        $ids.Count | Should -BeGreaterThan 0
        $ids | Should -Contain 'Microsoft.PowerShell'
        $ids | Should -Contain 'Git.Git'
    }

    It 'declares every DSC package in winget.json too' {
        $ids = Get-DscWingetId (Join-Path $RepoRoot 'configuration.dsc.yaml')
        $wg  = Get-Content (Join-Path $RepoRoot 'packages/winget.json') -Raw | ConvertFrom-Json
        $known = @($wg.packages | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.id } })
        foreach ($id in $ids) {
            $known | Should -Contain $id -Because "configuration.dsc.yaml installs '$id' but packages/winget.json does not list it -- Step 0 and Install-Packages.ps1 would provision different sets"
        }
    }

    It 'keeps the DSC baseline to UNTAGGED core entries' {
        $ids = Get-DscWingetId (Join-Path $RepoRoot 'configuration.dsc.yaml')
        $wg  = Get-Content (Join-Path $RepoRoot 'packages/winget.json') -Raw | ConvertFrom-Json
        foreach ($id in $ids) {
            # Check EVERY matching entry, not just the first: a duplicate id whose
            # second occurrence carried a group tag would otherwise slip through.
            # (Invoke-Validation.ps1 rejects duplicate winget ids too, but this test
            # should not depend on another gate to be correct.)
            $entries = @($wg.packages | Where-Object { $_ -isnot [string] -and $_.id -eq $id })
            foreach ($entry in $entries) {
                $entry.group | Should -BeNullOrEmpty -Because "'$id' is in an opt-in group, but configuration.dsc.yaml carries the core baseline only -- an opt-in package would be force-installed on every fresh box"
            }
        }
    }

    It 'installs the two prerequisites bootstrap.ps1 cannot provide itself' {
        # bootstrap.ps1 hard-returns without these, and its failure message points the
        # user at configuration.dsc.yaml -- so the DSC file has to actually deliver
        # them or that advice is a dead end.
        $ids = Get-DscWingetId (Join-Path $RepoRoot 'configuration.dsc.yaml')
        $ids | Should -Contain 'Git.Git'
        $ids | Should -Contain 'Microsoft.PowerShell'
    }

    It 'enables Developer Mode, which is what makes symlinks work without admin' {
        # install.ps1's Test-CanSymlink requires pwsh 7 OR admin; Developer Mode is the
        # non-elevated path, and elevating instead makes scoop refuse to install.
        $raw = Get-Content (Join-Path $RepoRoot 'configuration.dsc.yaml') -Raw
        $raw | Should -Match 'Microsoft\.Windows\.Developer/DeveloperMode'
        # Scope `Ensure: Present` to the DeveloperMode resource's OWN block. A bare
        # file-wide match would still pass if DeveloperMode stopped ensuring Present
        # while some other resource happened to carry the same setting. The tempered
        # token `(?:(?!- resource:).)*?` refuses to cross into the next resource.
        $raw | Should -Match '(?s)Microsoft\.Windows\.Developer/DeveloperMode(?:(?!- resource:).)*?Ensure:\s*Present'
    }
}

Describe 'winget-import.json drift' {
    # The committed packages/winget-import.json is a GENERATED projection of
    # winget.json (Export-WingetImport.ps1). It went stale silently before — a winget
    # id was added to the manifest but the import file wasn't regenerated. This gate
    # regenerates it to a temp path and asserts byte-for-byte equality with the copy on
    # disk. The generator is deterministic (no CreationDate/WinGetVersion stamp), so a
    # clean tree round-trips exactly; the default (floating) form matches the committed
    # ids-only artifact and needs neither winget nor the lockfile — so it runs anywhere.
    It 'is byte-identical to a fresh Export-WingetImport regeneration' {
        $generator = Join-Path $RepoRoot 'packages/Export-WingetImport.ps1'
        $committed  = Join-Path $RepoRoot 'packages/winget-import.json'
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("winget-import-drift-{0}.json" -f ([guid]::NewGuid().ToString('N')))
        try {
            & $generator -OutPath $tmp *> $null
            (Test-Path $tmp) | Should -BeTrue -Because 'the generator should have written the import file'
            # Base64 of the raw bytes so a BOM / CRLF / trailing-newline drift is caught,
            # not just the JSON text.
            $fresh  = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($tmp))
            $onDisk = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($committed))
            $fresh | Should -Be $onDisk `
                -Because 'packages/winget-import.json is stale — regenerate it: .\packages\Export-WingetImport.ps1'
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-ScoopBucketFault (Check-PackageFreshness)' {
    # A scoop bucket is a git clone, and a wedged clone keeps serving manifests from
    # whatever commit it froze at -- so stale versions compare as MATCHING and the
    # freshness check goes green on bad data. These cover the shapes that actually
    # produced that false green (see the 2026-08-04 `extras` mid-merge wedge).
    BeforeAll {
        $script:PkgRepoRoot = Split-Path -Parent $PSScriptRoot
        $env:DOTFILES_PKGFRESH_LIBONLY = '1'
        . (Join-Path $script:PkgRepoRoot 'packages/Check-PackageFreshness.ps1')

        # A scriptblock, not a `function` -- Pester 6 runs each It in its own scope, so
        # a function declared in the Describe body is not visible inside them.
        $script:NewCleanBucketClone = {
            param([string]$Path)
            git -C $Path init --quiet 2>&1 | Out-Null
            git -C $Path config user.email 'test@example.invalid' 2>&1 | Out-Null
            git -C $Path config user.name 'test' 2>&1 | Out-Null
            Set-Content -Path (Join-Path $Path 'app.json') -Value '{"version":"1.0.0"}' -Encoding UTF8
            git -C $Path add -A 2>&1 | Out-Null
            git -C $Path commit -m init --quiet 2>&1 | Out-Null
        }
    }
    AfterAll { Remove-Item Env:DOTFILES_PKGFRESH_LIBONLY -ErrorAction SilentlyContinue }

    BeforeEach {
        $script:Bucket = Join-Path ([System.IO.Path]::GetTempPath()) ("bucket-{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:Bucket -Force | Out-Null
    }
    AfterEach { Remove-Item $script:Bucket -Recurse -Force -ErrorAction SilentlyContinue }

    It 'passes a clean clone' {
        & $script:NewCleanBucketClone $script:Bucket
        Get-ScoopBucketFault $script:Bucket | Should -BeNullOrEmpty
    }

    It 'flags a missing bucket directory' {
        $gone = Join-Path $script:Bucket 'nope'
        Get-ScoopBucketFault $gone | Should -Match 'missing'
    }

    It 'flags a directory that is not a git clone' {
        Get-ScoopBucketFault $script:Bucket | Should -Match 'not a git clone'
    }

    It 'flags an interrupted merge -- the wedge that caused the false green' {
        & $script:NewCleanBucketClone $script:Bucket
        # MERGE_HEAD is what git leaves behind when a merge stops on conflict; while it
        # exists every `git pull` refuses, so the bucket silently stops advancing.
        Set-Content -Path (Join-Path $script:Bucket '.git/MERGE_HEAD') -Value ('0' * 40) -Encoding UTF8
        Get-ScoopBucketFault $script:Bucket | Should -Match 'stuck mid-'
    }

    It 'flags an interrupted rebase' {
        & $script:NewCleanBucketClone $script:Bucket
        New-Item -ItemType Directory -Path (Join-Path $script:Bucket '.git/rebase-merge') -Force | Out-Null
        Get-ScoopBucketFault $script:Bucket | Should -Match 'stuck mid-'
    }

    It 'flags a dirty working tree and names the offending paths' {
        & $script:NewCleanBucketClone $script:Bucket
        Set-Content -Path (Join-Path $script:Bucket 'app.json') -Value '{"version":"9.9.9"}' -Encoding UTF8
        $fault = Get-ScoopBucketFault $script:Bucket
        $fault | Should -Match 'dirty'
        $fault | Should -Match 'app\.json'
    }
}
