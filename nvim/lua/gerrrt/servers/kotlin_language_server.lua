-- ================================================================================================
-- TITLE : kotlin-language-server (Kotlin LSP Setup)
-- LINKS : https://github.com/fwcd/kotlin-language-server
-- ABOUT : Kotlin language server (fwcd) — completion, diagnostics, gotos over Gradle/Maven/Ant
--         projects. cmd `{ "kotlin-language-server" }`, Gradle/Maven root_markers, and the cache
--         storagePath init_option come from nvim-lspconfig's lsp/kotlin_language_server.lua (a
--         table cmd, so the binary-availability guard reads it directly — no fn_cmd_binaries entry).
-- INSTALL: mason — "kotlin-language-server" (needs a JRE; mise pins temurin-21 — on the UNIX
--         FLEET; scoop-owned openjdk25 on dotfiles-Windows, which vendors this tree without that
--         pin. Either satisfies it.) Formatter+linter: ktlint (conform + nvim-lint).
-- ================================================================================================
return {
	filetypes = { "kotlin" },
}
