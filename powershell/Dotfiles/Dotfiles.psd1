@{
    RootModule        = 'Dotfiles.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '30e4fff9-3034-48d1-a718-851d57c8f80a'
    Author            = 'dotgibson'
    Description       = 'dotfiles-Windows shared, non-interactive helper surface (pure rendering + logic). Imported by the PowerShell profile; the interactive layer stays global.'
    PowerShellVersion = '7.0'

    # The curated public surface (single source of truth for what the module
    # exposes). Internal-only helpers are simply omitted here as later stages add
    # them, so they stay module-scoped instead of polluting the session.
    FunctionsToExport = @(
        # rendering / colour / glyphs
        'Write-DotHost'
        'Write-DotBanner'
        'Write-DotRule'
        'Write-DotErr'
        'Write-DotOk'
        'Write-DotWarn'
        'Get-DotGlyph'
        'Test-DotColor'
        'Test-DotTrueColor'
        'Get-DotAnsiSgr'
        'Test-DotUnicode'
        'Get-DotConsoleWidth'
        'Format-DotWrap'
        # prompts / input
        'Read-DotConfirm'
        'Get-DotConfirmAnswer'
        'Read-DotInput'
        'Get-DotInputResult'
        'Test-DotGum'
        'Test-DotEmailish'
        # progress
        'Get-DotSpinnerFrame'
        'Format-DotSpinnerLine'
        'Invoke-DotSpinner'
        # pure logic / data
        'Test-SensitiveHistoryLine'
        'Get-DotStringSha256'
        'Get-DotToolNudge'
        'Test-DotNonInteractiveArg'
        'Test-InteractiveShell'
        'Test-InMux'
        'Get-DotfilesLinkPlan'
        'Get-DotfilesStubContent'
        'Test-StubIntoRepo'
        'ConvertTo-WslPath'
        # remote access: ssh into this host and the distros behind it
        'ConvertTo-DotSshAlias'
        'Get-DotWslSshPlan'
        'Format-DotWslSshConfig'
        'Get-DotRemoteWiringResult'
        # doctor: result model, aggregation + pure logic (host probes stay in the fragment)
        'New-DoctorResult'
        'Get-DoctorSummary'
        'Get-DoctorGroup'
        'Get-FragmentHealthResult'
        'Get-DotRepoVersionDetail'
        'Get-NvimVendorDetail'
        'Get-StarshipVendorDetail'
        'Get-ScoopBucketHealthResult'
        'Get-DoctorFixPlan'
        # help: command catalog + pure derivations (the dothelp verb stays in the fragment)
        'Get-DotfilesHelpData'
        'Get-DotHelpFilters'
        'Get-DotHelpFlatLines'
        'Get-DotHelpPrimaryVerb'
        'Get-DotLevenshtein'
        'Get-DotDidYouMean'
        # modules: local module-dir reconcile (the modules-localize verb stays in the fragment)
        'Get-DotModulePrunePlan'
        # serve: bind/url plan (the serve verb + LAN-IP lookup stay in the fragment)
        'Get-DotServePlan'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
