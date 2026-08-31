# ============================================================================
#  tests/Integration.Tests.ps1  -  install -> uninstall round-trip on a real
#  (temp) filesystem. The other suites unit-test pure functions; this one wires
#  actual symlinks from the shared link plan and tears them back down, exercising
#  the real predicates (Test-SymlinkCurrent, Test-LinkIntoRepo) end-to-end so a
#  wiring/teardown regression can't pass on green unit tests alone.
#
#  Needs symlink creation privileges; the GitHub windows-latest runner (and Linux)
#  both allow it — the same New-Item -SymbolicLink the Uninstall suite already uses.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $env:DOTFILES_INSTALL_LIBONLY   = '1'
    $env:DOTFILES_UNINSTALL_LIBONLY = '1'
    . (Join-Path $RepoRoot 'powershell/core/05-lib.ps1')   # Get-DotfilesLinkPlan
    . (Join-Path $RepoRoot 'install.ps1')                  # Test-SymlinkCurrent
    . (Join-Path $RepoRoot 'uninstall.ps1')                # Test-LinkIntoRepo
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')         # New-DotTestTempDir

    # A self-contained fake world: a fake repo with the target files, and fake
    # HOME / LOCALAPPDATA / Documents roots the plan links into.
    $script:World = New-DotTestTempDir -Prefix 'rt'
    $script:Repo  = Join-Path $script:World 'repo'
    $script:HomeDir  = Join-Path $script:World 'home'
    $script:Local = Join-Path $script:World 'local'
    $script:Roaming = Join-Path $script:World 'roaming'
    $script:Docs  = Join-Path $script:World 'docs'
    foreach ($d in $script:Repo, $script:HomeDir, $script:Local, $script:Roaming, $script:Docs) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }

    $script:Plan = Get-DotfilesLinkPlan -RepoRoot $script:Repo -HomeDir $script:HomeDir `
        -LocalAppData $script:Local -RoamingAppData $script:Roaming -Documents $script:Docs

    # Materialize each target inside the fake repo so the links have something to
    # point at (a file for file-targets, a dir for the nvim/scripts dir-targets).
    foreach ($row in $script:Plan) {
        $parent = Split-Path -Parent $row.Target
        if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if ($row.Target -match '\.(ps1|json|conf|gitconfig|gitignore_global|toml|lua)$' -or (Split-Path -Leaf $row.Target) -eq 'config') {
            'target' | Set-Content -LiteralPath $row.Target
        } else {
            New-Item -ItemType Directory -Force -Path $row.Target | Out-Null
        }
    }
}

AfterAll {
    if ($script:World -and (Test-Path $script:World)) { Remove-Item $script:World -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:DOTFILES_INSTALL_LIBONLY, Env:DOTFILES_UNINSTALL_LIBONLY -ErrorAction SilentlyContinue
}

Describe 'install -> uninstall round-trip' {
    It 'wires every planned row the way its Kind says, and both predicates agree' {
        foreach ($row in $script:Plan) {
            $parent = Split-Path -Parent $row.Link
            if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

            if ($row.Kind -eq 'Stub') {
                # A stub is a REAL file that includes the repo copy - a symlink here is
                # unreadable from an ssh session (docs/REMOTE-ACCESS.md).
                Set-Content -LiteralPath $row.Link -Value (Get-DotfilesStubContent -Name $row.Name -Target $row.Target)
                Test-StubIntoRepo -Link $row.Link -Root $script:Repo | Should -BeTrue
                # ...and it must NOT read as a symlink, or uninstall would try to treat it as one.
                Test-LinkIntoRepo -Link $row.Link -Root $script:Repo | Should -BeFalse
            } else {
                New-Item -ItemType SymbolicLink -Path $row.Link -Target $row.Target -Force | Out-Null

                # install's idempotency predicate must see the freshly-made link as current,
                # and uninstall's safety predicate must recognise it as one of ours.
                Test-SymlinkCurrent -Link $row.Link -Target $row.Target | Should -BeTrue
                Test-LinkIntoRepo  -Link $row.Link -Root   $script:Repo | Should -BeTrue
                # a symlink is never a stub
                Test-StubIntoRepo  -Link $row.Link -Root   $script:Repo | Should -BeFalse
            }
        }
    }

    It 'leaves a real user file alone (neither predicate claims it)' {
        # .gitconfig is a Stub row, so this doubles as the check that a user's OWN
        # config is not mistaken for our stub just because it sits at the stub's path.
        $real = (Join-Path $script:HomeDir '.gitconfig')
        Remove-Item -LiteralPath $real -Force -ErrorAction SilentlyContinue
        'my own config' | Set-Content -LiteralPath $real
        Test-LinkIntoRepo -Link $real -Root $script:Repo | Should -BeFalse
        Test-StubIntoRepo -Link $real -Root $script:Repo | Should -BeFalse
        # restore the stub so the teardown step below has something to remove again
        Set-Content -LiteralPath $real -Value (Get-DotfilesStubContent -Name '.gitconfig' -Target (Join-Path $script:Repo 'git\.gitconfig'))
    }

    It 'removes exactly the rows that point into the repo, links and stubs alike' {
        $removed = 0
        foreach ($link in (Get-DotfilesLinkMap -HomeDir $script:HomeDir -LocalAppData $script:Local -RoamingAppData $script:Roaming -Documents $script:Docs)) {
            # Mirrors uninstall.ps1's guard exactly: either shape counts as ours.
            if ((Test-LinkIntoRepo -Link $link -Root $script:Repo) -or (Test-StubIntoRepo -Link $link -Root $script:Repo)) {
                Remove-Item -LiteralPath $link -Force -Recurse -ErrorAction SilentlyContinue
                $removed++
            }
        }
        $removed | Should -Be $script:Plan.Count
        foreach ($row in $script:Plan) { Test-Path -LiteralPath $row.Link | Should -BeFalse }
    }
}

# ---------------------------------------------------------------------------
# The nvim migration, driven through the REAL Write-StubItem.
#
# This is the one place install.ps1 can destroy repo content. %LOCALAPPDATA%\nvim
# was a directory symlink onto <repo>\nvim, so before Clear-StubParent existed every
# path operation on %LOCALAPPDATA%\nvim\init.lua resolved THROUGH it: the "existing
# file" that got backed up was the repo's own init.lua, and the shim was written into
# the Core-mirrored tree. Silent, and it dirties the one directory in this repo that
# must stay byte-for-byte upstream. So this exercises the real function, not a
# simulation of it.
# ---------------------------------------------------------------------------
Describe 'Write-StubItem over the legacy nvim directory symlink' {
    BeforeEach {
        $script:Box  = New-DotTestTempDir -Prefix 'nvimmig'
        $script:BRepo = Join-Path $script:Box 'repo'
        $script:BLocal = Join-Path $script:Box 'local'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:BRepo 'nvim\lua\gerrrt') | Out-Null
        New-Item -ItemType Directory -Force -Path $script:BLocal | Out-Null
        'require("gerrrt")' | Set-Content -LiteralPath (Join-Path $script:BRepo 'nvim\init.lua') -NoNewline
        '{}'                | Set-Content -LiteralPath (Join-Path $script:BRepo 'nvim\lazy-lock.json') -NoNewline

        # Write-StubItem reads these from its enclosing scope, exactly as install.ps1
        # sets them up: RepoRoot for the idempotency check, DryRun/LinkStats for
        # reporting, Yes so Confirm-Overwrite doesn't prompt in a test host.
        # $RepoRoot is set UNSCOPED as well: install.ps1 reads it unqualified, and
        # dot-sourcing the installer in BeforeAll left its own $RepoRoot (this repo)
        # in a scope that a bare $script: assignment does not reach.
        $RepoRoot          = $script:BRepo
        $script:RepoRoot   = $script:BRepo
        $script:DryRun     = $false
        $script:Yes        = $true
        $script:LinkStats  = @{ linked = 0; copied = 0; stubbed = 0; skipped = 0; backedup = 0 }

        $script:BPlan = Get-DotfilesLinkPlan -RepoRoot $script:BRepo -HomeDir (Join-Path $script:Box 'home') `
            -LocalAppData $script:BLocal -RoamingAppData (Join-Path $script:Box 'roaming') -Documents (Join-Path $script:Box 'docs')
        $script:BNvim = $script:BPlan | Where-Object Name -eq 'nvim config'
    }
    AfterEach {
        if ($script:Box -and (Test-Path $script:Box)) { Remove-Item $script:Box -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'retires the symlink and leaves the repo tree byte-identical' {
        $repoInit = Join-Path $script:BRepo 'nvim\init.lua'
        $before   = (Get-FileHash -LiteralPath $repoInit).Hash
        New-Item -ItemType SymbolicLink -Path $script:BNvim.LegacyLink -Target (Join-Path $script:BRepo 'nvim') | Out-Null

        Write-StubItem -Name $script:BNvim.Name -Target $script:BNvim.Target -Link $script:BNvim.Link -LegacyLink $script:BNvim.LegacyLink

        # The repo is untouched: same bytes, no .bak dropped beside it, nothing added.
        (Get-FileHash -LiteralPath $repoInit).Hash | Should -Be $before
        @(Get-ChildItem -LiteralPath (Join-Path $script:BRepo 'nvim') -Filter '*.bak' -Recurse).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:BRepo 'nvim') | ForEach-Object Name | Sort-Object) |
            Should -Be @('init.lua', 'lazy-lock.json', 'lua')

        # And %LOCALAPPDATA%\nvim is now a REAL directory holding the shim.
        $dir = Get-Item -LiteralPath $script:BNvim.LegacyLink -Force
        $dir.LinkType | Should -BeNullOrEmpty
        Test-StubIntoRepo -Link $script:BNvim.Link -Root $script:BRepo | Should -BeTrue
        $script:LinkStats.stubbed | Should -Be 1
    }

    It 'keeps the retired symlink as a .bak rather than deleting it' {
        New-Item -ItemType SymbolicLink -Path $script:BNvim.LegacyLink -Target (Join-Path $script:BRepo 'nvim') | Out-Null
        Write-StubItem -Name $script:BNvim.Name -Target $script:BNvim.Target -Link $script:BNvim.Link -LegacyLink $script:BNvim.LegacyLink
        @(Get-ChildItem -LiteralPath $script:BLocal -Force | Where-Object Name -like 'nvim.*.bak').Count | Should -Be 1
        $script:LinkStats.backedup | Should -Be 1
    }

    It 'retires a copy-mode leftover too, so no stale lua\ shadows the repo on rtp' {
        # No Developer Mode => Link-Item copied the tree instead of linking it.
        New-Item -ItemType Directory -Force -Path (Join-Path $script:BNvim.LegacyLink 'lua') | Out-Null
        'stale' | Set-Content -LiteralPath $script:BNvim.Link

        Write-StubItem -Name $script:BNvim.Name -Target $script:BNvim.Target -Link $script:BNvim.Link -LegacyLink $script:BNvim.LegacyLink

        Test-Path -LiteralPath (Join-Path $script:BNvim.LegacyLink 'lua') | Should -BeFalse
        Test-StubIntoRepo -Link $script:BNvim.Link -Root $script:BRepo | Should -BeTrue
    }

    It 'is idempotent: a second run leaves the stub alone and drops no .bak' {
        New-Item -ItemType SymbolicLink -Path $script:BNvim.LegacyLink -Target (Join-Path $script:BRepo 'nvim') | Out-Null
        Write-StubItem -Name $script:BNvim.Name -Target $script:BNvim.Target -Link $script:BNvim.Link -LegacyLink $script:BNvim.LegacyLink
        $first = Get-Content -LiteralPath $script:BNvim.Link -Raw

        Write-StubItem -Name $script:BNvim.Name -Target $script:BNvim.Target -Link $script:BNvim.Link -LegacyLink $script:BNvim.LegacyLink

        Get-Content -LiteralPath $script:BNvim.Link -Raw | Should -Be $first
        @(Get-ChildItem -LiteralPath $script:BLocal -Force | Where-Object Name -like 'nvim.*.bak').Count | Should -Be 1
        $script:LinkStats.skipped | Should -Be 1
    }

    It 'writes one forwarder per script, retiring the directory symlink first' {
        $src = Join-Path $script:BRepo 'psmux\scripts'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        foreach ($n in 'psmux-menu.ps1', 'psmux-url.ps1') { "'real $n'" | Set-Content -LiteralPath (Join-Path $src $n) }
        $row = $script:BPlan | Where-Object Name -eq 'psmux scripts'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $row.Link) | Out-Null
        New-Item -ItemType SymbolicLink -Path $row.Link -Target $src | Out-Null

        Write-StubDirItem -Name $row.Name -Target $row.Target -Link $row.Link

        # The repo keeps exactly its two scripts - no forwarder was written INTO it
        # through the old link, and nothing was backed up there.
        @(Get-ChildItem -LiteralPath $src | ForEach-Object Name | Sort-Object) |
            Should -Be @('psmux-menu.ps1', 'psmux-url.ps1')
        (Get-Item -LiteralPath $row.Link -Force).LinkType | Should -BeNullOrEmpty
        Test-StubDirIntoRepo -Link $row.Link -Target $row.Target -Root $script:BRepo | Should -BeTrue
    }

    It 'runs the repo script through the forwarder, arguments and all' {
        # The point of the whole row: psmux.conf still names ~/.config/psmux/scripts,
        # so the forwarder has to behave like the real script when invoked.
        $src = Join-Path $script:BRepo 'psmux\scripts'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        'param($Who) "hello $Who from $(Split-Path -Leaf $PSScriptRoot)"' |
            Set-Content -LiteralPath (Join-Path $src 'psmux-menu.ps1')
        $row = $script:BPlan | Where-Object Name -eq 'psmux scripts'
        Write-StubDirItem -Name $row.Name -Target $row.Target -Link $row.Link

        $out = & (Join-Path $row.Link 'psmux-menu.ps1') -Who 'world'
        # 'scripts' proves $PSScriptRoot resolved to the REPO copy, not ~/.config.
        $out | Should -Be 'hello world from scripts'
    }

    It 'sweeps a forwarder whose script was deleted upstream' {
        $src = Join-Path $script:BRepo 'psmux\scripts'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        foreach ($n in 'keep.ps1', 'gone.ps1') { "'x'" | Set-Content -LiteralPath (Join-Path $src $n) }
        $row = $script:BPlan | Where-Object Name -eq 'psmux scripts'
        Write-StubDirItem -Name $row.Name -Target $row.Target -Link $row.Link
        Remove-Item -LiteralPath (Join-Path $src 'gone.ps1') -Force

        Write-StubDirItem -Name $row.Name -Target $row.Target -Link $row.Link

        Test-Path -LiteralPath (Join-Path $row.Link 'gone.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $row.Link 'keep.ps1') | Should -BeTrue
    }

    It 'leaves a file of the user''s own in the scripts directory alone' {
        $src = Join-Path $script:BRepo 'psmux\scripts'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        "'x'" | Set-Content -LiteralPath (Join-Path $src 'psmux-menu.ps1')
        $row = $script:BPlan | Where-Object Name -eq 'psmux scripts'
        New-Item -ItemType Directory -Force -Path $row.Link | Out-Null
        'my own helper' | Set-Content -LiteralPath (Join-Path $row.Link 'mine.ps1')

        Write-StubDirItem -Name $row.Name -Target $row.Target -Link $row.Link

        Get-Content -LiteralPath (Join-Path $row.Link 'mine.ps1') -Raw | Should -Match 'my own helper'
    }

    It 'never retires a stub parent the plan does not name as legacy' {
        # The guard that stops ~/.gitconfig offering to retire $HOME: the home dir
        # holds .gitignore_global, a real sibling of that row's target in the repo.
        New-Item -ItemType Directory -Force -Path (Join-Path $script:BRepo 'git') | Out-Null
        'gitconfig'       | Set-Content -LiteralPath (Join-Path $script:BRepo 'git\.gitconfig')
        'gitignore'       | Set-Content -LiteralPath (Join-Path $script:BRepo 'git\.gitignore_global')
        $git      = $script:BPlan | Where-Object Name -eq '.gitconfig'
        $fakeHome = Split-Path -Parent $git.Link
        New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
        'mine' | Set-Content -LiteralPath (Join-Path $fakeHome '.gitignore_global')

        Write-StubItem -Name $git.Name -Target $git.Target -Link $git.Link -LegacyLink $git.LegacyLink

        Test-Path -LiteralPath $fakeHome | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $fakeHome) -Force | Where-Object Name -like 'home.*.bak').Count | Should -Be 0
    }
}
