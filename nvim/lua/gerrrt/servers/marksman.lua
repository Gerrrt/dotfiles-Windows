-- ================================================================================================
-- TITLE : marksman (Markdown language server) LSP Setup
-- LINKS : https://github.com/artempyanykh/marksman
-- ABOUT : Cross-file Markdown intelligence — wiki-links/`[ref]` completion, heading & link
--         go-to-definition, rename-across-files, and document/workspace symbols. You write a lot
--         of Markdown (en+de spell, the dedicated markdown autocmd, render-markdown.nvim), so this
--         turns a docs tree into something navigable. Pairs with markdownlint (diagnostics, via
--         nvim-lint) and prettierd (formatting, via conform) — marksman does neither, no overlap.
-- INSTALL: mason — package name "marksman" (added to ensure_installed in plugins/mason-tool-installer.lua).
-- ================================================================================================
return {
	cmd = { "marksman", "server" },
	-- `markdown.mdx` was dropped: it is not a registered filetype in this config (no mdx detection,
	-- no mdx usage), so `vim.lsp`'s healthcheck flagged it as an unknown filetype. Re-add it only
	-- alongside real mdx filetype detection if .mdx editing becomes a thing.
	filetypes = { "markdown" },
	root_markers = { ".marksman.toml", ".git" },
}
