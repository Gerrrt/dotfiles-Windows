-- ================================================================================================
-- TITLE : mason-tool-installer | the central Mason install manifest
-- LINKS : https://github.com/WhoIsSethDaniel/mason-tool-installer.nvim
-- ABOUT : ONE manifest for EVERYTHING Mason owns — LSP servers, formatters (conform), linters
--         (nvim-lint). This is the install pass a fresh machine relies on to end up with a working
--         toolchain after a start.
-- WHY ITS OWN SPEC (not inside conform): this used to live in conform.nvim's `config`, but conform
--         is lazy (`event = BufWritePre`), so `run_on_start = true` really meant "run on the first
--         :w". Meanwhile servers enable earlier at `User FilePost` and `vim.lsp.enable` silently
--         skips a server whose binary isn't on PATH yet (servers/init.lua's binary_available guard) —
--         so on a fresh box the LSP stack stayed dark until a save AND a restart. Loading on VeryLazy
--         runs the install pass near startup on EVERY launch.
-- SAME-SESSION LSP : the install is async, so the `User FilePost` enable pass has already run (and
--         skipped the not-yet-installed servers) by the time it finishes. The
--         `MasonToolsUpdateCompleted` handler below re-runs servers/init.lua's enable pass when
--         installs complete —
--         `vim.lsp.enable` attaches the freshly-installed servers to the already-open buffer, so a
--         fresh box gets a working LSP stack WITHIN the first session, no restart required.
-- DELIBERATELY NOT here (installed by other channels — listing them would double-install):
--   • ruff, ty ......... uv tool install (Astral; see plugins/conform.lua header + servers/ruff.lua)
--   • rust-analyzer .... rustaceanvim / rustup (plugins/rustaceanvim.lua)
--   • nomicfoundation-solidity-language-server — npm i -g @nomicfoundation/solidity-language-server
--     (not carried in the Mason registry under a stable name; servers/solidity_*.lua expects the
--      binary on PATH). solhint (its linter) IS mason-managed, below.
-- ================================================================================================
return {
	"WhoIsSethDaniel/mason-tool-installer.nvim",
	event = "VeryLazy",
	dependencies = { "mason-org/mason.nvim" },
	config = function()
		require("mason-tool-installer").setup({
			ensure_installed = {
				-- ── LSP servers (mason package names; enabled in servers/init.lua) ──────────
				"lua-language-server",
				"gopls",
				"json-lsp",
				"typescript-language-server",
				"bash-language-server",
				"clangd",
				"dockerfile-language-server",
				"emmet-ls",
				"yaml-language-server",
				"tailwindcss-language-server",
				"taplo", -- TOML (also the conform formatter for toml)
				"marksman", -- Markdown
				"html-lsp", -- HTML validation
				"css-lsp", -- CSS/SCSS/LESS validation
				"svelte-language-server", -- Svelte component LSP (you already format/lint svelte)
				"vue-language-server", -- Vue/Volar LSP (also ships @vue/typescript-plugin for ts_ls)
				-- ── formatters (conform) ───────────────────────────────────────────────────
				"stylua",
				"shfmt",
				"gofumpt",
				"clang-format",
				"prettierd",
				-- ── linters (nvim-lint) ────────────────────────────────────────────────────
				"shellcheck",
				"golangci-lint", -- Go meta-linter (supersedes revive; richer diagnostics)
				"eslint_d",
				"hadolint",
				"cpplint",
				"luacheck",
				"solhint",
				-- NOTE: debugpy is deliberately NOT listed here. Mason's PyPI installer always runs
				-- `python -m venv` then pip, which needs python3-venv on Debian/Kali and py3-pip on
				-- Alpine — the exact per-distro dependency plugins/nvim-dap.lua avoids by preferring
				-- `uv`. Listing it would make the install fail on EVERY startup on those hosts, even
				-- though uv could run debugpy there perfectly well. Resolution order (Mason's copy if
				-- you install it by hand with :Mason, else uv, else python3) lives in nvim-dap.lua.
				"stylelint", -- CSS/SCSS/LESS lint (only runs when a project stylelint config exists)
				"markdownlint-cli2", -- markdown lint (mirrors the repo's markdown gate)
				"yamllint", -- yaml lint
				-- ── added languages: Ruby / Java / Kotlin / PHP / Zig / SQL / Protobuf / GraphQL /
				--    Terraform. Grouped here (rather than split across the sections above) so
				--    the whole new surface is legible in one place. Servers are enabled in
				--    servers/init.lua; formatters live in conform.lua; linters (all gated) in
				--    nvim-lint.lua; parsers in nvim-treesitter.lua.
				--
				-- RUNTIME CAVEAT (same shape as the debugpy note above): Mason installs several of
				-- these through a language runtime, so they only succeed where that runtime exists —
				-- Ruby (ruby-lsp, rubocop), the JVM (jdtls, kotlin-language-server, ktlint,
				-- checkstyle, google-java-format), and PHP (php-cs-fixer, phpstan). mise pins
				-- python/ruby/java/lua, so those resolve on a normal box; PHP is NOT pinned — install
				-- php where you edit PHP. A failed install logs an error but never breaks nvim, and
				-- servers/init.lua's binary-guard keeps an un-installed server dark instead of
				-- spawn-erroring. Tools needing a NON-Mason binary on PATH: zigfmt→zig,
				-- terraform_fmt→terraform/tofu, forge_fmt→foundry (as with the existing rust note).
				-- ── LSP servers ──
				"ruby-lsp",
				"jdtls",
				"kotlin-language-server",
				"intelephense",
				"zls",
				"sqls",
				"buf", -- Protobuf: buf CLI provides the LSP (buf lsp) AND the formatter (buf format)
				"graphql-language-service-cli",
				"terraform-ls",
				-- ── formatters (conform) ──
				"rubocop", -- Ruby: formats AND lints (also the nvim-lint entry)
				"google-java-format",
				"ktlint", -- Kotlin: formats AND lints
				"php-cs-fixer",
				"sql-formatter",
				-- ── linters (nvim-lint, gated) ──
				"checkstyle", -- Java
				"phpstan", -- PHP
				"sqlfluff", -- SQL (needs a dialect → gated on .sqlfluff)
				"protolint", -- Protobuf
				"tflint", -- Terraform
				-- ── SAST (nvim-lint, gated on a project semgrep config) ──
				"semgrep",
			},
			-- Skip the startup install/update pass on engagement boxes (DOTFILES_OFFLINE=1),
			-- which would otherwise hit the mason registry and download tools. See globals.lua.
			run_on_start = not vim.g.dotfiles_offline,
		})

		-- When installs finish, re-run the server enable pass so servers whose binaries the initial
		-- `User FilePost` pass skipped (fresh box) get enabled + attached to the open buffer this session.
		vim.api.nvim_create_autocmd("User", {
			pattern = "MasonToolsUpdateCompleted",
			callback = function()
				pcall(function()
					require("gerrrt.servers").enable_available()
				end)
			end,
		})
	end,
}
