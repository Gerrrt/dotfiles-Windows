-- ================================================================================================
-- TITLE : nil (Nix LSP Setup)
-- LINKS : https://github.com/oxalica/nil
-- ABOUT : Nix language server (oxalica) — completion, diagnostics, gotos for the Nix expression
--         language. cmd `{ "nil" }` and flake.nix/.git root_markers come from nvim-lspconfig's
--         lsp/nil_ls.lua (a table cmd, so the binary-availability guard reads it directly).
-- INSTALL: mason — "nil" (Rust binary). Formatter: alejandra (conform). Linter: statix
--         (anti-patterns) via nvim-lint — config-optional and fast. (deadnix isn't in the Mason
--         registry, so it's not wired here; add it to nvim-lint if you install it via nix/cargo.)
-- ================================================================================================
return {
	filetypes = { "nix" },
}
