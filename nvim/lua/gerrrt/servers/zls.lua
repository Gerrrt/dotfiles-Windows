-- ================================================================================================
-- TITLE : zls (Zig LSP Setup)
-- LINKS : https://github.com/zigtools/zls
-- ABOUT : Zig language server — completion, diagnostics, gotos. cmd `{ "zls" }`, build.zig/zls.json
--         root_markers, and workspace_required=false come from nvim-lspconfig's lsp/zls.lua (a
--         table cmd, so the binary-availability guard reads it directly).
-- INSTALL: mason — "zls" (standalone binary). Formatter: `zig fmt` via conform's zigfmt — needs the
--         `zig` compiler on PATH (not Mason-managed), same pattern as forge/terraform.
-- ================================================================================================
return {
	filetypes = { "zig", "zir" },
}
