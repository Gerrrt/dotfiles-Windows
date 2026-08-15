# ============================================================================
#  tests/Module.Tests.ps1  -  the Dotfiles module's manifest + public surface.
#
#  Pins the curated export surface (B7) so a helper can't silently drop out of
#  the module — or leak in — as later stages migrate command verbs. Behavioral
#  assertions on the helpers themselves live in Lib.Tests.ps1 (which dot-sources
#  the same source file directly); this file only checks the MODULE boundary.
# ============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Manifest = Join-Path $script:RepoRoot 'powershell/Dotfiles/Dotfiles.psd1'
    # -PassThru so AfterAll removes THIS module instance, not every loaded module
    # named "Dotfiles" (a dev could have an unrelated one in their session).
    $script:Module = Import-Module $script:Manifest -Force -DisableNameChecking -PassThru
}
AfterAll { if ($script:Module) { Remove-Module $script:Module -Force -ErrorAction SilentlyContinue } }

Describe 'Dotfiles module manifest' {
    It 'is a valid module manifest' {
        { Test-ModuleManifest -Path $script:Manifest } | Should -Not -Throw
    }
    It 'exports only an explicit function list (no wildcard surface)' {
        $data = Import-PowerShellDataFile -Path $script:Manifest
        $data.FunctionsToExport | Should -Not -Contain '*'
        $data.FunctionsToExport.Count | Should -BeGreaterThan 0
        # nothing leaks via cmdlet/alias/variable exports
        $data.CmdletsToExport   | Should -BeNullOrEmpty
        $data.AliasesToExport   | Should -BeNullOrEmpty
        $data.VariablesToExport | Should -BeNullOrEmpty
    }
}

Describe 'Dotfiles module exports' {
    It 'exports the curated public helper surface' {
        $exported = (Get-Module Dotfiles).ExportedFunctions.Keys
        foreach ($fn in @(
            'Write-DotHost', 'Write-DotErr', 'Write-DotOk', 'Write-DotWarn',
            'Write-DotBanner', 'Write-DotRule', 'Get-DotGlyph', 'Test-DotColor',
            'Test-DotTrueColor', 'Get-DotAnsiSgr',
            'Test-DotUnicode', 'Get-DotConsoleWidth', 'Format-DotWrap',
            'Read-DotConfirm', 'Get-DotConfirmAnswer', 'Read-DotInput', 'Get-DotInputResult',
            'Test-DotGum', 'Test-DotEmailish',
            'Get-DotSpinnerFrame', 'Format-DotSpinnerLine', 'Invoke-DotSpinner', 'Test-SensitiveHistoryLine',
            'Get-DotStringSha256', 'Get-DotToolNudge', 'Get-DotfilesLinkPlan',
            'Test-DotNonInteractiveArg', 'Test-InteractiveShell', 'Test-InMux',
            'ConvertTo-WslPath',
            'New-DoctorResult', 'Get-DoctorSummary', 'Get-DoctorGroup',
            'Get-FragmentHealthResult', 'Get-DotRepoVersionDetail',
            'Get-NvimVendorDetail', 'Get-StarshipVendorDetail', 'Get-DoctorFixPlan',
            'Get-DotfilesHelpData', 'Get-DotHelpFilters', 'Get-DotHelpFlatLines',
            'Get-DotHelpPrimaryVerb', 'Get-DotLevenshtein', 'Get-DotDidYouMean'
        )) {
            $exported | Should -Contain $fn
        }
    }
    It 'makes an exported helper callable after import' {
        Get-DotStringSha256 'abc' | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
    It 'declares the manifest list and the live exports identically (no drift)' {
        $declared = (Import-PowerShellDataFile -Path $script:Manifest).FunctionsToExport | Sort-Object
        $live      = (Get-Module Dotfiles).ExportedFunctions.Keys | Sort-Object
        $live | Should -Be $declared
    }
}
