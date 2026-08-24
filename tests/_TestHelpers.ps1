# ============================================================================
#  tests/_TestHelpers.ps1  -  shared fixtures for the Pester suites (B14).
#
#  NOT a *.Tests.ps1 file, so Pester never discovers it as a suite and the CI
#  test-file-count gate (issue #29) doesn't count it. Dot-source it from a
#  suite's BeforeAll — functions defined here then resolve in that suite's
#  nested BeforeAll/It blocks, the same way the dot-sourced install/uninstall
#  helpers already do.
# ============================================================================

# New-DotTestTempDir — a fresh, unique scratch directory created on disk.
# Hoisted from the identical `Join-Path GetTempPath (prefix + guid)` +
# `New-Item -ItemType Directory` boilerplate that Install/Integration/Uninstall/
# Completions each repeated. Returns the directory path; callers create any
# sub-tree they need under it and remove it in their own AfterAll.
function New-DotTestTempDir {
    [OutputType([string])]
    param([string]$Prefix = 'dottest')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("$Prefix-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dir
}

# New-DotCoreTagFixture — a throwaway git repo shaped like dotfiles-core AT a release:
# one commit carrying the SPECIFIC release tag vX.Y.Z and then the MOVING major alias
# vX, with $Past commits stacked on top. This is the exact shape that made
# nvim/.core-ref record `tag = v4-19-g10ad221` (#202). Returns the repo path; the
# caller removes it.
#
# BOTH tags are ANNOTATED and the alias is created SECOND, because that is what Core's
# scripts/tag-release.sh actually does (`git tag -fa "$TAG"`, then `git tag -fa
# "$MAJOR"`). git describe breaks a same-commit tie by tag priority, then depth, then
# TAGGER TIME — so annotated-and-newer is precisely what makes the alias win. A fixture
# using two lightweight tags would tie on all three and fall into describe's final,
# arbitrary tie-break: a test that reproduces the bug only by luck.
#
# The tagger dates are pinned a DAY apart for the same reason — two `git tag -a` calls
# in the same wall-clock second carry identical tagger times and land in that arbitrary
# branch. GIT_COMMITTER_DATE is what git stamps as the tagger date.
function New-DotCoreTagFixture {
    [OutputType([string])]
    param(
        [string]$Release = 'v9.9.9',
        [string]$Alias   = 'v9',
        [int]$Past       = 2,
        # Only the moving alias exists — Core before it ever cut a vX.Y.Z release.
        [switch]$AliasOnly
    )
    $repo = New-DotTestTempDir -Prefix 'coretag'
    git -C $repo init --quiet 2>&1 | Out-Null
    git -C $repo config user.email 'test@example.invalid' 2>&1 | Out-Null
    git -C $repo config user.name  'test' 2>&1 | Out-Null
    Set-Content -Path (Join-Path $repo 'core.version') -Value '9.9.9' -Encoding UTF8
    git -C $repo add -A 2>&1 | Out-Null
    git -C $repo commit -m 'release' --quiet 2>&1 | Out-Null

    $prev = $env:GIT_COMMITTER_DATE
    try {
        if (-not $AliasOnly) {
            $env:GIT_COMMITTER_DATE = '2020-01-01T00:00:00 +0000'
            git -C $repo tag -a $Release -m $Release 2>&1 | Out-Null
        }
        $env:GIT_COMMITTER_DATE = '2020-01-02T00:00:00 +0000'   # the alias is NEWER
        git -C $repo tag -a $Alias -m $Alias 2>&1 | Out-Null
    }
    finally {
        if ($null -eq $prev) { Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
        else { $env:GIT_COMMITTER_DATE = $prev }
    }

    for ($i = 1; $i -le $Past; $i++) {
        Set-Content -Path (Join-Path $repo "past$i.txt") -Value "$i" -Encoding UTF8
        git -C $repo add -A 2>&1 | Out-Null
        git -C $repo commit -m "past $i" --quiet 2>&1 | Out-Null
    }
    $repo
}
