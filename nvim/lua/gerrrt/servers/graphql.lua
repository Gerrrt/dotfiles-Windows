-- ================================================================================================
-- TITLE : graphql (GraphQL LSP Setup)
-- LINKS : https://github.com/graphql/graphiql/tree/main/packages/graphql-language-service-cli
-- ABOUT : GraphQL language server — schema-aware completion, diagnostics, gotos. cmd
--         `{ "graphql-lsp", "server", "-m", "stream" }` comes from nvim-lspconfig's lsp/graphql.lua
--         (a table cmd, so the binary-availability guard reads cmd[1] directly). Its root_dir is
--         gated on a GraphQL config (.graphqlrc*/graphql.config.*), so it only attaches in a real
--         GraphQL project — including the typescriptreact/javascriptreact filetypes it also claims
--         for gql`` template literals, which is why those are left in place.
-- INSTALL: mason — "graphql-language-service-cli" (node-based). Formatting is prettierd (conform).
-- ================================================================================================
return {
	filetypes = { "graphql", "typescriptreact", "javascriptreact" },
}
