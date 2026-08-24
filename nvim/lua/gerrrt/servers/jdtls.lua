-- ================================================================================================
-- TITLE : jdtls (Eclipse JDT — Java LSP Setup)
-- LINKS : https://projects.eclipse.org/projects/eclipse.jdt.ls
-- ABOUT : Java language server — diagnostics, completion, imports, gotos, formatting, code actions.
--         (For the full jdtls experience nvim-jdtls is the richer path; this is the lightweight
--         vim.lsp.enable route.) cmd (a launcher that manages a per-project data dir) and the
--         Maven/Gradle/Ant root_markers come from nvim-lspconfig's lsp/jdtls.lua.
-- GUARD : lspconfig ships `cmd` as a FUNCTION, so this server is registered in servers/init.lua's
--         `fn_cmd_binaries` (binary "jdtls") for the binary-availability guard.
-- INSTALL: mason — "jdtls" (needs a JDK/JRE; mise pins temurin-21 — on the UNIX FLEET. On
--         dotfiles-Windows, the one host that vendors this tree without that pin, the JDK is
--         scoop-owned openjdk25. Either satisfies jdtls; only the owner and the major differ.)
--         Formatter: google-java-format (conform). Linter: checkstyle (nvim-lint, gated on a
--         checkstyle config).
-- ================================================================================================
return {
	filetypes = { "java" },
}
