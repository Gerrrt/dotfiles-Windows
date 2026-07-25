-- ================================================================================================
-- TITLE : buf_ls (Protobuf LSP Setup)
-- LINKS : https://github.com/bufbuild/buf
-- ABOUT : The Protobuf language server bundled in the `buf` CLI — Buf-module/workspace aware
--         completion, diagnostics, gotos. cmd `{ "buf", "lsp", "serve", ... }` and buf.yaml/.git
--         root_markers come from nvim-lspconfig's lsp/buf_ls.lua (a table cmd, so the
--         binary-availability guard reads cmd[1] = "buf" directly).
-- INSTALL: mason — "buf" (Go binary; the same binary formats via `buf format` in conform). Linter:
--         protolint (nvim-lint) — a dedicated proto linter alongside buf's own lint.
-- ================================================================================================
return {
	filetypes = { "proto", "buf-config" },
}
