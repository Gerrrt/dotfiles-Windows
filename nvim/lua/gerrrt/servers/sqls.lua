-- ================================================================================================
-- TITLE : sqls (SQL LSP Setup)
-- LINKS : https://github.com/sqls-server/sqls
-- ABOUT : SQL language server — completion, formatting, and (with a config.yml naming your DBs)
--         live schema-aware completion + query execution. cmd `{ "sqls" }` and config.yml
--         root_marker come from nvim-lspconfig's lsp/sqls.lua (a table cmd, so the
--         binary-availability guard reads it directly).
-- INSTALL: mason — "sqls" (Go binary). Formatter: sql-formatter (conform). Linter: sqlfluff
--         (nvim-lint, gated on .sqlfluff — it needs a dialect).
-- ================================================================================================
return {
	filetypes = { "sql", "mysql" },
}
