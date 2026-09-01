# ============================================================================
#  tests/Core.Tests.ps1  -  the `core` front door (os/48-core.ps1) dispatch.
#
#  The front door is thin routing over host verbs (dotfiles-doctor / dothelp /
#  up / update-check / maint-*), which are host-specific and NOT exercised here. We stub those leaves,
#  dot-source the fragment, and assert `core <verb>` routes + passes args
#  through, that a bare `core` shows the index, and that an unknown verb
#  suggests the nearest instead of dispatching.
#
#  Scope note: the stubs are `global:` functions, so they must record into a
#  `$global:` list — a `$script:` var set in BeforeAll resolves to a different
#  scope inside a global function than the It blocks read, and the routing
#  asserts would silently see an empty list.
# ============================================================================

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    # Module provides the pure helpers the fragment calls (Get-DotLevenshtein,
    # Get-DotRepoVersionDetail, Write-DotErr, Write-DotHost).
    $script:Module = Import-Module (Join-Path $RepoRoot 'powershell/Dotfiles/Dotfiles.psd1') -Force -DisableNameChecking -PassThru

    # Test-Cmd is a load-time FRAGMENT function (core/05-lib.ps1), not a module
    # export, so it's absent in this unit context — stub it with equivalent
    # behaviour so core-version's git-metadata guard resolves.
    function global:Test-Cmd { param([string]$Name) [bool](Get-Command $Name -ErrorAction Ignore) }

    # Get-DotRepoRevision is likewise a fragment function — it lives in the
    # earlier-loading os/45-doctor.ps1 (which core-version now shares to avoid the
    # duplicated git block, C3). It's absent when 48-core is dot-sourced alone, so
    # stub it with a fixed revision record; core-version's job here is only to FORMAT
    # and print it, so a canned object exercises that path without spawning git.
    function global:Get-DotRepoRevision { param([string]$Root) [pscustomobject]@{ Sha = 'abc1234'; When = '2026-01-01'; IsDirty = $false } }

    # Point the layer root at this checkout (core-version resolves $root from it
    # before handing off to Get-DotRepoRevision).
    $script:prevDotfilesWin = $env:DOTFILES_WIN
    $env:DOTFILES_WIN = $RepoRoot

    # Record which leaf each route lands on (+ the args it forwarded). Global so
    # the global stubs and the It blocks share one list (see scope note above).
    $global:DotCoreCalls = [System.Collections.Generic.List[string]]::new()
    function global:dotfiles-doctor { $global:DotCoreCalls.Add("doctor:$($args -join ',')") }
    function global:dothelp         { $global:DotCoreCalls.Add("help:$($args -join ',')") }
    function global:up              { $global:DotCoreCalls.Add("up:$($args -join ',')") }
    function global:update-check    { $global:DotCoreCalls.Add("update-check:$($args -join ',')") }
    function global:maint-install   { $global:DotCoreCalls.Add("maint-install:$($args -join ',')") }
    function global:maint-run       { $global:DotCoreCalls.Add("maint-run:$($args -join ',')") }
    function global:maint-log       { $global:DotCoreCalls.Add("maint-log:$($args -join ',')") }
    function global:maint-status    { $global:DotCoreCalls.Add("maint-status:$($args -join ',')") }
    function global:maint-uninstall { $global:DotCoreCalls.Add("maint-uninstall:$($args -join ',')") }

    . (Join-Path $RepoRoot 'powershell/os/48-core.ps1')
}

AfterAll {
    $env:DOTFILES_WIN = $script:prevDotfilesWin
    Remove-Variable -Name DotCoreCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Item function:core, function:core-doctor, function:core-help, function:core-version -ErrorAction SilentlyContinue
    Remove-Item function:dotfiles-doctor, function:dothelp, function:up, function:update-check -ErrorAction SilentlyContinue
    Remove-Item function:maint-install, function:maint-run, function:maint-log, function:maint-status, function:maint-uninstall -ErrorAction SilentlyContinue
    Remove-Item function:Test-Cmd, function:Get-DotRepoRevision -ErrorAction SilentlyContinue
    if ($script:Module) { Remove-Module $script:Module -Force -ErrorAction SilentlyContinue }
}

Describe 'core front door' {
    BeforeEach { $global:DotCoreCalls.Clear() }

    It 'routes `core doctor` to dotfiles-doctor and forwards args' {
        core doctor -Quiet
        $global:DotCoreCalls | Should -Contain 'doctor:-Quiet'
    }
    It 'routes `core help <filter>` to dothelp' {
        core help git
        $global:DotCoreCalls | Should -Contain 'help:git'
    }
    It 'treats a bare `core` as the help index' {
        core
        ($global:DotCoreCalls | Where-Object { $_ -like 'help:*' }) | Should -Not -BeNullOrEmpty
    }
    It 'routes `core update` to up and forwards args' {
        core update -y
        $global:DotCoreCalls | Should -Contain 'up:-y'
    }
    It '`core version` prints the layer name' {
        (core version *>&1 | Out-String) | Should -Match 'dotfiles-Windows'
    }
    It 'suggests the nearest verb on a typo and does NOT dispatch' {
        $out = core doctr *>&1 | Out-String
        $out | Should -Match 'did you mean: core doctor'
        $global:DotCoreCalls | Should -BeNullOrEmpty
    }
}

# The second family (dotfiles-core#684): `core update check` -> update-check, and
# `core maint <verb>` -> maint-*. Additive — the bare names keep working, and
# `core update -y` still belongs to `up` (only the literal word `check` is intercepted).
Describe 'core front door — update check + maint family' {
    BeforeEach { $global:DotCoreCalls.Clear() }

    It 'routes `core update check` to update-check, not up' {
        core update check
        $global:DotCoreCalls | Should -Contain 'update-check:'
        ($global:DotCoreCalls | Where-Object { $_ -like 'up:*' }) | Should -BeNullOrEmpty
    }
    It 'still routes `core update -y` to up (only the word check is intercepted)' {
        core update -y
        $global:DotCoreCalls | Should -Contain 'up:-y'
    }
    It 'routes `core maint install <HH:MM>` to maint-install and forwards the time' {
        core maint install 09:00
        $global:DotCoreCalls | Should -Contain 'maint-install:09:00'
    }
    It 'routes `core maint log -f` to maint-log and forwards -f' {
        core maint log -f
        $global:DotCoreCalls | Should -Contain 'maint-log:-f'
    }
    It 'routes `core maint run` to maint-run' {
        core maint run
        $global:DotCoreCalls | Should -Contain 'maint-run:'
    }
    It 'routes `core maint status` to maint-status' {
        core maint status
        $global:DotCoreCalls | Should -Contain 'maint-status:'
    }
    It 'routes `core maint uninstall` to maint-uninstall' {
        core maint uninstall
        $global:DotCoreCalls | Should -Contain 'maint-uninstall:'
    }
    It 'treats a bare `core maint` as usage (a namespace is help) and dispatches nothing' {
        $out = core maint *>&1 | Out-String
        $out | Should -Match 'usage: core maint <install\|run\|log\|status\|uninstall>'
        $global:DotCoreCalls | Should -BeNullOrEmpty
    }
    It 'suggests the nearest maint sub-verb on a typo and does NOT dispatch' {
        $out = core maint stauts *>&1 | Out-String
        $out | Should -Match 'did you mean: core maint status'
        $global:DotCoreCalls | Should -BeNullOrEmpty
    }
    It 'suggests `core maint` for `core mant`' {
        $out = core mant *>&1 | Out-String
        $out | Should -Match 'did you mean: core maint'
        $global:DotCoreCalls | Should -BeNullOrEmpty
    }
}

Describe 'core-* standalone twins' {
    BeforeEach { $global:DotCoreCalls.Clear() }

    It 'core-doctor forwards to dotfiles-doctor' {
        core-doctor -Quiet
        $global:DotCoreCalls | Should -Contain 'doctor:-Quiet'
    }
    It 'core-help forwards to dothelp' {
        core-help
        ($global:DotCoreCalls | Where-Object { $_ -like 'help:*' }) | Should -Not -BeNullOrEmpty
    }
    It 'core-version prints dotfiles-Windows + a revision detail' {
        (core-version *>&1 | Out-String) | Should -Match 'dotfiles-Windows'
    }
}
