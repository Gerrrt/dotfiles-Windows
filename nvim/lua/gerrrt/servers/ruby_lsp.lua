-- ================================================================================================
-- TITLE : ruby-lsp (Ruby LSP Setup)
-- LINKS : https://github.com/Shopify/ruby-lsp
-- ABOUT : Shopify's Ruby language server — completion, go-to, diagnostics, and (via init_options
--         formatter="auto") formatting/linting through rubocop/syntax_tree when present. cmd,
--         root_markers, and the root-cwd handling come from nvim-lspconfig's lsp/ruby_lsp.lua.
-- GUARD : lspconfig ships `cmd` as a FUNCTION (sets cwd to the project root), so this server is
--         registered in servers/init.lua's `fn_cmd_binaries` (binary "ruby-lsp") — otherwise the
--         binary-availability guard couldn't tell whether ruby-lsp is installed.
-- INSTALL: mason — "ruby-lsp" (needs a Ruby runtime; mise pins ruby — on the UNIX FLEET. The one
--         host that vendors this nvim/ tree without that pin is dotfiles-Windows, where ruby is
--         winget-owned and ships no MSYS2 DevKit, so C-extension gems (prism) fail to build and
--         mason's install dies on an error naming neither ruby nor the devkit. Fix there is one
--         elevated `ridk install 1 3`.) Formatter/linter: rubocop (conform + nvim-lint, gated on
--         .rubocop.yml).
-- ================================================================================================
return {
	filetypes = { "ruby", "eruby" },
}
