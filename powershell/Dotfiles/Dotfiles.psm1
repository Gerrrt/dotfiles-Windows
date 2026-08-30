# ============================================================================
#  Dotfiles.psm1  -  the dotfiles-Windows module (B7, hybrid migration).
#
#  Owns the profile's NON-INTERACTIVE surface so its helpers stop leaking into
#  the global session as a flat pile of global: functions. STAGE 1 re-homes the
#  pure helper library (core/05-lib.ps1); later stages migrate the command verbs.
#
#  The interactive layer stays dot-sourced at GLOBAL scope by profile.ps1 and is
#  deliberately NOT moved here: a module-scoped `prompt` function is ignored by
#  the host (so starship's prompt would silently revert), and the tool inits /
#  PSReadLine keybinds / argument completers / CommandNotFoundAction all expect
#  to register against the global session.
#
#  The pure-helper FILE stays at core/05-lib.ps1 — the test suite, install.ps1,
#  uninstall.ps1 and Install-Packages.ps1 dot-source it directly, which still
#  works because dot-sourcing defines the functions in the CALLER's scope. This
#  module simply dot-sources the same file and re-exports the curated surface
#  declared in Dotfiles.psd1 (FunctionsToExport), the single source of truth.
# ============================================================================

# Run the module surface under StrictMode so an unbound variable, a missing
# property, or a bad array index surfaces as an error instead of a silent $null.
# Scoped to the MODULE: even under `Import-Module -Global` (how profile.ps1 loads
# it) this does NOT touch the interactive session, which stays lenient. The pure
# helpers dot-sourced below inherit it because they execute in this module's scope.
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '../core/05-lib.ps1')
. (Join-Path $PSScriptRoot 'Wsl.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Doctor.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Help.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Modules.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Serve.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Remote.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Maint.Helpers.ps1')
