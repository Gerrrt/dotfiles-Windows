# ============================================================================
#  tests/Maint.Tests.ps1  -  the maintenance runner's own docs, and the policy
#  behind the scheduled tasks that carry it.
#
#  Three subjects, one feature:
#
#  1. Maintenance.ps1 states its step list in THREE places — the file header, the
#     -Help block, and the actual Step calls. Nothing kept them honest, so both
#     prose copies silently lost the scoop junction step (and the header lost navi
#     as well). The gate below discovers the steps from the AST and fails when a
#     step is not documented in both.
#
#  2. Get-DotStablePwshPath — which pwsh a task is registered against. Task
#     Scheduler stores an absolute path forever, and a Store pwsh resolves to a
#     version-pinned package dir that vanishes on update, taking the daily run and
#     the junction sweep with it (0x80070002, silently: a task that never launches
#     writes nothing to maint.log).
#
#  3. Get-DotMaintTaskHealth — whether a registered task can still run.
#
#  2 and 3 are pure, so both are tested with hand-built rows: no real task is
#  registered, no admin token is needed, and no particular pwsh install is assumed.
# ============================================================================

BeforeDiscovery {
    $RepoRoot = Split-Path -Parent $PSScriptRoot

    # One distinctive keyword (or several, ALL required) per Step label. A derived
    # keyword cannot work here: the natural derivation (the text before ':') maps
    # 'scoop: re-create junctions (admin-trusted)' to 'scoop', which already appears
    # in the help text — so the one genuinely undocumented step would have passed.
    # And an exact substring match fails everywhere, because the labels are terse
    # command names ('scoop update (buckets)') and the prose is a sentence.
    $keyword = @{
        'scoop update (buckets)'                     = @('buckets')
        'scoop upgrade (apps)'                       = @('upgrade apps')
        'scoop cleanup'                              = @('cleanup')
        'scoop: re-create junctions (admin-trusted)' = @('junction')
        'mise plugins update'                        = @('mise')
        'mise upgrade'                               = @('mise')
        'neovim: Lazy sync / TSUpdate / MasonUpdate' = @('neovim', 'Lazy')
        'navi repo update'                           = @('navi')
        'module update: $m'                          = @('PowerShell modules')
        'winget upgrade --all'                       = @('winget')
    }

    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RepoRoot 'maint/Maintenance.ps1'), [ref]$null, [ref]$null)

    # CommandElements[0] is the command name itself ('Step'), so the label is [1].
    # Both string AST types have to be accepted: `Step "module update: $m"` is an
    # ExpandableStringExpressionAst, which is a SIBLING of StringConstantExpressionAst,
    # not a subclass — matching only the latter silently drops that step from the
    # checked set. .Value on the expandable one is the literal 'module update: $m',
    # which is a perfectly stable map key.
    $script:StepLabel = @(
        $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Step'
        }, $true) | ForEach-Object {
            $e = $_.CommandElements[1]
            if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $e -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $e.Value }
            else { '' }
        })

    $script:MapKey    = @($keyword.Keys)
    $script:StepCases = @($script:StepLabel | Where-Object { $_ } | ForEach-Object {
        @{ Label = $_; Keyword = @($keyword[$_]) }
    })
}

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Module = Import-Module (Join-Path $RepoRoot 'powershell/Dotfiles/Dotfiles.psd1') -Force -DisableNameChecking -PassThru

    $maint = Join-Path $RepoRoot 'maint/Maintenance.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($maint, [ref]$null, [ref]$null)

    # The -Help block by AST rather than by regex over the source: it survives the
    # array literal being re-wrapped or reordered, which a line-anchored regex does not.
    $helpIf = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] }, $true) |
        Where-Object { $_.Clauses[0].Item1.Extent.Text -eq '$Help' } | Select-Object -First 1

    # The header is the leading run of comment lines; the file opens with the banner
    # and its first non-comment line is `[CmdletBinding()] param(...)`.
    $lines  = Get-Content $maint
    $header = @(); foreach ($l in $lines) { if ($l -match '^\s*#') { $header += $l } else { break } }

    # Both sides normalized: the help text is a wrapped array literal, so a keyword
    # can otherwise fall across an element boundary.
    function script:Flatten { param([string]$Text) ($Text -replace '\s+', ' ').Trim() }
    $script:HelpText   = script:Flatten ([string]$helpIf.Extent.Text)
    $script:HeaderText = script:Flatten ($header -join ' ')

    $script:MaintSrc = Get-Content (Join-Path $RepoRoot 'powershell/os/40-maint.ps1') -Raw

    # Every key present, so the module's Set-StrictMode -Version Latest cannot turn a
    # forgotten property into a silent $null.
    function script:Row {
        param([string]$Path, [string]$Kind, [bool]$Stable, [bool]$UserScoped, [bool]$Exists)
        @{ Path = $Path; Kind = $Kind; Stable = $Stable; UserScoped = $UserScoped; Exists = $Exists }
    }
}
AfterAll {
    if ($script:Module) { Remove-Module $script:Module -Force -ErrorAction SilentlyContinue }
}

# Labels and map keys are discovered at DISCOVERY time, so they reach the run
# phase as case data rather than as $script: state — a BeforeDiscovery variable
# read inside an It is empty.
Describe 'maint/Maintenance.ps1 documents every step it runs' -ForEach @(
    @{ Labels = $script:StepLabel; Keys = $script:MapKey }
) {

    It 'gives every Step call a literal label' {
        # A `Step $someVariable { }` would yield '' here. Failing loudly beats
        # quietly shrinking the set of steps this suite checks.
        $Labels | Should -Not -Contain ''
        $Labels.Count | Should -BeGreaterThan 0
    }

    # THE RATCHET. A new step has no map entry -> fail. A removed or renamed step
    # leaves a stale key -> fail, so the map cannot rot into a permanent pass. And
    # if the AST query above ever breaks and finds nothing, the keys match nothing
    # and this fails too — no magic count constant to keep up to date.
    It 'has a keyword for exactly the steps that exist' {
        (@($Labels | Sort-Object) -join ' | ') |
            Should -Be (@($Keys | Sort-Object) -join ' | ') `
            -Because 'a step was added, removed or renamed — update $keyword in this file, and both prose blocks in Maintenance.ps1'
    }

    It "'<Label>' is named in the -Help output" -ForEach $script:StepCases {
        foreach ($kw in $Keyword) {
            $script:HelpText | Should -BeLike "*$kw*" -Because "-Help does not mention '$kw' — the step list users see has drifted"
        }
    }

    It "'<Label>' is named in the file header" -ForEach $script:StepCases {
        foreach ($kw in $Keyword) {
            $script:HeaderText | Should -BeLike "*$kw*" -Because "the header comment does not mention '$kw'"
        }
    }
}

Describe 'Get-DotStablePwshPath' {

    It 'prefers the first stable candidate that exists' {
        $p = Get-DotStablePwshPath -Candidate @(
            (Row 'C:\pf\PowerShell\7\pwsh.exe' 'msi'        $true  $false $true)
            (Row 'C:\u\WindowsApps\pwsh.exe'   'user-alias' $true  $true  $true)
            (Row 'C:\wa\pkg_1.2.3\pwsh.exe'    'resolved'   $false $false $true)
        )
        $p.Kind     | Should -Be 'msi'
        $p.IsStable | Should -BeTrue
        $p.Warning  | Should -BeNullOrEmpty
    }

    It 'skips candidates that do not exist, whatever their order' {
        $p = Get-DotStablePwshPath -Candidate @(
            (Row 'C:\pf\PowerShell\7\pwsh.exe' 'msi'        $true $false $false)
            (Row 'C:\u\WindowsApps\pwsh.exe'   'user-alias' $true $true  $true)
        )
        $p.Kind | Should -Be 'user-alias'
        $p.Rejected[0].Reason | Should -Be 'not present'
    }

    # The asymmetry this function exists for. SYSTEM's LOCALAPPDATA is
    # C:\Windows\System32\config\systemprofile\AppData\Local — a per-user app
    # alias is not merely unstable there, it is not present at all.
    It 'rejects a user-scoped candidate for the SYSTEM task' {
        $p = Get-DotStablePwshPath -RunAs System -Candidate @(
            (Row 'C:\u\WindowsApps\pwsh.exe' 'user-alias' $true  $true  $true)
            (Row 'C:\wa\pkg_1.2.3\pwsh.exe'  'resolved'   $false $false $true)
        )
        $p.Kind | Should -Be 'resolved'
        $p.Rejected[0].Reason | Should -BeLike '*does not run in your profile*'
    }

    It 'accepts that same candidate for the user task' {
        $p = Get-DotStablePwshPath -RunAs User -Candidate @(
            (Row 'C:\u\WindowsApps\pwsh.exe' 'user-alias' $true  $true  $true)
            (Row 'C:\wa\pkg_1.2.3\pwsh.exe'  'resolved'   $false $false $true)
        )
        $p.Kind     | Should -Be 'user-alias'
        $p.IsStable | Should -BeTrue
    }

    # This host's actual situation: Store-only pwsh, no MSI, no scoop shim. The
    # task still gets registered — a warned-about task beats no task — but the
    # warning has to name the failure mode, because the symptom is silence.
    It 'falls back to the version-pinned path and warns' {
        $p = Get-DotStablePwshPath -RunAs System -Candidate @(
            (Row 'C:\pf\PowerShell\7\pwsh.exe' 'msi'      $true  $false $false)
            (Row 'C:\wa\pkg_1.2.3\pwsh.exe'    'resolved' $false $false $true)
        )
        $p.Path     | Should -Be 'C:\wa\pkg_1.2.3\pwsh.exe'
        $p.IsStable | Should -BeFalse
        $p.Warning  | Should -BeLike '*0x80070002*'
    }

    It 'returns no path, and says so, when nothing is usable' {
        $p = Get-DotStablePwshPath -Candidate @()
        $p.Path     | Should -BeNullOrEmpty
        $p.Kind     | Should -Be 'none'
        $p.IsStable | Should -BeFalse
        $p.Warning  | Should -Not -BeNullOrEmpty
    }

    It 'accounts for every candidate, as either the pick or a rejection' {
        $rows = @(
            (Row 'a' 'msi'        $true  $false $false)
            (Row 'b' 'user-alias' $true  $true  $true)
            (Row 'c' 'resolved'   $false $false $true)
        )
        $p = Get-DotStablePwshPath -RunAs System -Candidate $rows
        ($p.Rejected.Count + 1) | Should -Be $rows.Count
    }
}

Describe 'Get-DotMaintTaskHealth' {

    It 'reports an unregistered optional task as missing, naming the elevated shell' {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $false -Optional $true -Elevated $true
        $h.Status | Should -Be 'missing'
        $h.Hint   | Should -BeLike '*elevated shell*'
    }

    # Measured: Task Scheduler ACLs a SYSTEM-principal registration to SYSTEM +
    # BUILTIN\Administrators with NO entry for the interactive user, so unelevated
    # Get-ScheduledTask returns nothing for a task that is present and healthy.
    # Calling that "not installed" is a confident lie, and a check built on it
    # reports a false fault on every single unelevated run.
    It 'will not call an invisible SYSTEM task missing when unelevated' {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $false -Optional $true -Elevated $false
        $h.Status | Should -Be 'unknown'
        $h.Detail | Should -BeLike '*not visible*'
    }

    # The required daily task runs as you and IS readable unelevated, so its absence
    # is a real finding either way — elevation must not soften it.
    It 'still reports the required task missing when unelevated' {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $false -Optional $false -Elevated $false
        $h.Status | Should -Be 'missing'
    }

    It 'reports an unregistered required task as missing' {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $false -Optional $false -Elevated $true
        $h.Status | Should -Be 'missing'
        $h.Hint   | Should -Be 'run maint-install'
    }

    # The state the SYSTEM task lands in right after a package update: the last run
    # succeeded, and the next one cannot possibly launch. A check that only looked
    # at LastResult would call this healthy.
    It 'fails a task whose executable is gone, even when the last run succeeded' {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $true `
                -Execute 'C:\gone\pwsh.exe' -ExecuteExists $false -LastResult 0
        $h.Status | Should -Be 'fail'
        $h.Detail | Should -BeLike '*0x80070002*'
    }

    It 'fails a task whose last run could not launch' {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $true `
                -Execute 'C:\pwsh.exe' -ExecuteExists $true -LastResult 0x80070002
        $h.Status | Should -Be 'fail'
        $h.Detail | Should -BeLike '*could not launch*'
    }

    It 'passes a healthy task' {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $true `
                -Execute 'C:\pwsh.exe' -ExecuteExists $true -LastResult 0
        $h.Status | Should -Be 'ok'
    }

    # 0x41303 is SCHED_S_TASK_HAS_NOT_RUN — informational, not a failure. Guards the
    # obvious over-eager implementation of "any non-zero result is bad".
    It 'treats the informational SCHED_S_* codes as ok' -ForEach @(
        @{ Code = 0x41300 }, @{ Code = 0x41301 }, @{ Code = 0x41303 }
    ) {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $true `
                -Execute 'C:\pwsh.exe' -ExecuteExists $true -LastResult $Code
        $h.Status | Should -Be 'ok'
    }

    It 'treats a task that has never run as ok' {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $true `
                -Execute 'C:\pwsh.exe' -ExecuteExists $true -LastResult $null
        $h.Status | Should -Be 'ok'
    }

    # 0x41306 is SCHED_S_TASK_TERMINATED — ExecutionTimeLimit was hit. Worth
    # seeing, but the registration is fine, so it must not read as broken.
    It 'warns, not fails, on any other non-zero result' {
        $h = Get-DotMaintTaskHealth -TaskName 't' -Registered $true `
                -Execute 'C:\pwsh.exe' -ExecuteExists $true -LastResult 0x41306
        $h.Status | Should -Be 'warn'
        $h.Hint   | Should -BeLike '*maint-log*'
    }
}

Describe 'os/40-maint.ps1 registers its tasks against a stable pwsh' {

    It 'resolves a task path for both tasks, user and SYSTEM' {
        ([regex]::Matches($script:MaintSrc, 'Get-DotPwshPathForTask')).Count | Should -BeGreaterThan 2
        $script:MaintSrc | Should -Match 'Get-DotPwshPathForTask -RunAs System'
        $script:MaintSrc | Should -Match 'Get-DotPwshPathForTask -RunAs User'
    }

    # maint-run is a foreground, one-shot invocation — it resolves and launches in
    # the same breath, so a version-pinned path is correct there and Get-PwshPath
    # is deliberately left alone. Pins "we did not change the interactive path".
    It 'leaves maint-run on the plain Get-PwshPath' {
        $script:MaintSrc | Should -Match '(?s)function maint-run.*?Get-PwshPath'
    }

    It 'checks the action executable still exists before reporting a task healthy' {
        $script:MaintSrc | Should -Match 'Get-DotMaintTaskHealth'
        $script:MaintSrc | Should -Match 'ExpandEnvironmentVariables'
    }
}
