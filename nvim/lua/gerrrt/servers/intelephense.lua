-- ================================================================================================
-- TITLE : intelephense (PHP LSP Setup)
-- LINKS : https://intelephense.com/
-- ABOUT : PHP language server — completion, diagnostics, gotos, refactors. cmd
--         `{ "intelephense", "--stdio" }`, composer.json/.git root_markers, and telemetry-off
--         settings come from nvim-lspconfig's lsp/intelephense.lua (a table cmd, so the
--         binary-availability guard reads it directly).
-- INSTALL: mason — "intelephense" (node-based). Formatter: php-cs-fixer (conform). Linter: phpstan
--         (nvim-lint, gated on phpstan.neon). NOTE: php-cs-fixer/phpstan need a PHP runtime, which
--         mise does NOT pin — install php on a box that edits PHP.
-- ================================================================================================
return {
	filetypes = { "php" },
}
