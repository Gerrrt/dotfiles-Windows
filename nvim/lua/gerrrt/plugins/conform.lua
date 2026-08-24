-- ================================================================================================
-- TITLE : conform.nvim | formatter runner
-- LINKS : https://github.com/stevearc/conform.nvim
-- ABOUT : Maps filetypes to formatters and runs them. Format-on-save is wired in
--         config/autocmds.lua (trailing whitespace trimmed first); <leader>cf formats on demand.
-- ASTRAL: Python formatting uses ruff (format + import-sort). ruff + ty are installed via uv
--         (the Astral way), NOT mason — run once:
--             uv tool install ruff
--             uv tool install ty
--         The NON-Python tools (formatters + linters + servers) are installed by the central Mason
--         manifest in plugins/mason-tool-installer.lua. Prefer mason for ruff? add "ruff" there.
-- ================================================================================================
return {
	"stevearc/conform.nvim",
	event = { "BufWritePre" },
	cmd = { "ConformInfo" },
	keys = {
		{
			"<leader>cf",
			function()
				require("conform").format({ async = true, lsp_format = "fallback" })
			end,
			mode = { "n", "v" },
			desc = "Format buffer / range",
		},
	},
	opts = {
		formatters_by_ft = {
			lua = { "stylua" },
			python = { "ruff_format", "ruff_organize_imports" },
			sh = { "shfmt" },
			bash = { "shfmt" },
			go = { "gofumpt" },
			c = { "clang_format" },
			cpp = { "clang_format" },
			json = { "prettierd" },
			jsonc = { "prettierd" },
			css = { "prettierd" },
			scss = { "prettierd" }, -- SCSS/LESS were already in the stylelint map (nvim-lint); prettierd formats them too
			less = { "prettierd" },
			html = { "prettierd" },
			markdown = { "prettierd" },
			yaml = { "prettierd" },
			javascript = { "prettierd" },
			javascriptreact = { "prettierd" },
			typescript = { "prettierd" },
			typescriptreact = { "prettierd" },
			svelte = { "prettierd" },
			vue = { "prettierd" },
			toml = { "taplo" }, -- taplo formats TOML; the same binary also serves as its LSP (servers/taplo.lua)
			-- ── added-language formatters ──────────────────────────────────────────────
			-- Each is a conform BUILTIN; conform auto-skips a formatter whose binary isn't on
			-- PATH (shown as "not ready" in :ConformInfo, never an error), so these are self-gating
			-- on a box that lacks the tool — matching servers/init.lua's binary-guard philosophy.
			solidity = { "forge_fmt" }, -- `forge fmt` (Foundry, already root-detected via taplo) — the one prior formatter gap
			ruby = { "rubocop" }, -- rubocop's --fix; also its linter (nvim-lint), gated there on .rubocop.yml
			java = { "google-java-format" },
			kotlin = { "ktlint" }, -- ktlint formats AND lints (nvim-lint)
			php = { "php_cs_fixer" },
			zig = { "zigfmt" }, -- `zig fmt` (needs zig on PATH)
			sql = { "sql_formatter" },
			proto = { "buf" }, -- `buf format`
			graphql = { "prettierd" }, -- prettier speaks graphql natively
			terraform = { "terraform_fmt" }, -- `terraform fmt` (needs terraform/tofu on PATH)
			hcl = { "terraform_fmt" }, -- terraform fmt also formats generic HCL
			-- NOTE: zsh is intentionally absent. shfmt is a POSIX/bash/mksh formatter and does
			-- NOT understand zsh — it mangles zsh-only syntax (glob qualifiers (#qN), ${(%):-%x},
			-- $+widgets[name-with-hyphens], &|, ...). There is no safe zsh formatter, so zsh files
			-- are never auto-formatted. (autocmds.lua also hard-skips formatting for ft=zsh, and
			-- utils/lsp.lua disables bashls's LSP formatting so the "fallback" path can't shfmt it.)
		},
		-- Per-formatter overrides layered on conform's builtins (conform merges these over the
		-- builtin spec, so `command`/`stdin`/`exit_codes` are inherited — only `args` is replaced).
		formatters = {
			-- rubocop --server is a SILENT NO-OP on Windows (#646), exactly as in
			-- plugins/nvim-lint.lua. Server mode needs fork/UNIX sockets; a native-Windows ruby
			-- prints "RuboCop server is not supported by this Ruby.", writes NOTHING to stdout, and
			-- exits 0 — so conform sees an empty result, leaves the buffer untouched, and reports
			-- no error. :ConformInfo still shows rubocop `available` (the binary really is there),
			-- which is what makes this so quiet: format-on-save simply does nothing on ruby files.
			--
			-- Resolved lazily and FILTERED from the upstream args, so this can't drift if conform
			-- changes them, and requiring the builtin module is deferred to format time rather than
			-- lazy-spec evaluation. Unix keeps --server — there it is a real speedup.
			rubocop = {
				args = function(self, ctx)
					local base = require("conform.formatters.rubocop").args
					if type(base) == "function" then
						base = base(self, ctx)
					end
					if vim.fn.has("win32") == 0 then
						return base
					end
					local kept = {}
					for _, a in ipairs(base or {}) do
						if a ~= "--server" then
							kept[#kept + 1] = a
						end
					end
					return kept
				end,
			},
		},
	},
	-- No `config` function: `config = function(_, opts) require("conform").setup(opts) end` is
	-- byte-for-byte what lazy.nvim does by default for a spec that has `opts` and a main module,
	-- so writing it out only invited drift.
}
