-- ================================================================================================
-- TITLE : nvim-lint | standalone linter runner
-- LINKS : https://github.com/mfussenegger/nvim-lint
-- ABOUT : Runs a filetype's linter on write / leaving insert mode, surfacing results as
--         normal diagnostics (Trouble, <leader>cd, [d/]d all work). Binaries installed by
--         mason-tool-installer in plugins/mason-tool-installer.lua.
-- ASTRAL: Python is intentionally NOT here — the ruff language server (servers/ruff.lua)
--         provides Python lint diagnostics AND code actions. Listing ruff here too would
--         double-report.
-- ================================================================================================
return {
	"mfussenegger/nvim-lint",
	-- `User FilePost` (config/autocmds.lua). Nothing to replay: linting is driven entirely by the
	-- BufWritePost/InsertLeave autocmds registered below, both of which fire long after load.
	event = "User FilePost",
	config = function()
		local lint = require("lint")

		-- semgrep is NOT a nvim-lint builtin, so define it here. It runs `semgrep scan --json` on the
		-- single file with the project's config (found upward — the same config the gating below keys
		-- on, so `--config` is always resolvable when this actually runs) and maps the stable JSON
		-- result schema to diagnostics. Guarded end-to-end: gated on a project semgrep config, marked
		-- heavy (save-only), and the parser pcall-decodes so a bad/empty run degrades to no diagnostics.
		lint.linters.semgrep = {
			cmd = "semgrep",
			stdin = false,
			append_fname = true,
			ignore_exitcode = true, -- semgrep exits non-zero when it finds something; that's not an error
			args = function()
				local cfg = vim.fs.find({ ".semgrep.yml", ".semgrep.yaml", "semgrep.yml", "semgrep.yaml" }, {
					upward = true,
					path = vim.fs.dirname(vim.api.nvim_buf_get_name(0)),
					type = "file",
				})[1]
				local a = { "scan", "--json", "--quiet", "--disable-version-check" }
				if cfg then
					a[#a + 1] = "--config=" .. cfg
				end
				return a
			end,
			parser = function(output, _)
				local diags = {}
				local ok, decoded = pcall(vim.json.decode, output)
				if not ok or type(decoded) ~= "table" or type(decoded.results) ~= "table" then
					return diags
				end
				local sev = {
					ERROR = vim.diagnostic.severity.ERROR,
					WARNING = vim.diagnostic.severity.WARN,
					INFO = vim.diagnostic.severity.INFO,
				}
				for _, r in ipairs(decoded.results) do
					local s, e, extra = r.start or {}, r["end"] or {}, r.extra or {}
					diags[#diags + 1] = {
						lnum = math.max((s.line or 1) - 1, 0),
						col = math.max((s.col or 1) - 1, 0),
						end_lnum = math.max((e.line or 1) - 1, 0),
						end_col = math.max((e.col or 1) - 1, 0),
						severity = sev[extra.severity] or vim.diagnostic.severity.WARN,
						source = "semgrep",
						code = r.check_id,
						message = extra.message or r.check_id or "semgrep finding",
					}
				end
				return diags
			end,
		}

		lint.linters_by_ft = {
			lua = { "luacheck" },
			sh = { "shellcheck" },
			bash = { "shellcheck" },
			go = { "golangcilint" }, -- meta-linter; richer than revive but heavier (runs the whole package on save)
			c = { "cpplint" },
			cpp = { "cpplint" },
			javascript = { "eslint_d" },
			javascriptreact = { "eslint_d" },
			typescript = { "eslint_d" },
			typescriptreact = { "eslint_d" },
			svelte = { "eslint_d" },
			vue = { "eslint_d" },
			dockerfile = { "hadolint" },
			solidity = { "solhint" },
			-- CSS family: cssls (servers/cssls.lua) validates syntax; stylelint adds style/lint rules.
			-- Gated below to only run when a project stylelint config exists (mirrors the eslint guard).
			css = { "stylelint" },
			scss = { "stylelint" },
			less = { "stylelint" },
			markdown = { "markdownlint-cli2" }, -- mirrors this repo's markdown gate; formatting stays prettierd (conform)
			yaml = { "yamllint" }, -- schema validation is yamlls' job; yamllint adds style/lint rules
			-- ── added-language linters ─────────────────────────────────────────────────
			-- gated ones (rubocop/checkstyle/phpstan/sqlfluff/tflint) only run when a project
			-- config is present — see `gated` below — so a bare buffer never eats a hard error.
			ruby = { "rubocop" }, -- also the ruby formatter (conform); gated on .rubocop.yml
			kotlin = { "ktlint" }, -- fast, config-optional; also the kotlin formatter (conform)
			java = { "checkstyle" },
			php = { "phpstan" },
			sql = { "sqlfluff" }, -- needs a dialect → gated on .sqlfluff
			proto = { "protolint" },
			terraform = { "tflint" },
			nix = { "statix" }, -- anti-patterns; config-optional & fast. (deadnix — dead code — isn't Mason-installable, so it's left out; add it here if you install it via nix/cargo.)
			-- NOTE: no zsh entry. shellcheck only supports sh/bash/dash/ksh and emits SC1071
			-- ("ShellCheck only supports sh/bash/dash/ksh scripts") on a zsh file — i.e. a useless
			-- error diagnostic on every zsh buffer. Nothing reliably lints zsh, so we don't.
			-- NOTE: no zig/graphql entry — their LSPs (zls, graphql) carry the diagnostics.
		}

		-- SAST (security static analysis): semgrep, run ONLY where a project opts in with a semgrep
		-- config (see `gated` below). It is not a per-filetype linter in the map above; instead it is
		-- appended as a candidate for the security-relevant filetypes here, so one entry covers many
		-- languages without editing each list. Gating is essential: config-less semgrep would
		-- otherwise fall back to a network `--config auto` fetch on every save.
		local sast_fts = {
			python = true,
			javascript = true,
			javascriptreact = true,
			typescript = true,
			typescriptreact = true,
			go = true,
			ruby = true,
			java = true,
			php = true,
			c = true,
			cpp = true,
			solidity = true,
		}

		-- CONFIG-GATED linters: each hard-errors, does unwanted whole-repo/network work, or needs a
		-- dialect when no project config exists — so it runs only when one of its config files is
		-- found upward from the buffer. (Generalises the old per-linter eslint/stylelint guards.)
		local gated = {
			eslint_d = {
				".eslintrc",
				".eslintrc.js",
				".eslintrc.cjs",
				".eslintrc.json",
				".eslintrc.yaml",
				".eslintrc.yml",
				"eslint.config.js",
				"eslint.config.mjs",
				"eslint.config.cjs",
				"eslint.config.ts",
				"eslint.config.mts",
				"eslint.config.cts",
			},
			stylelint = {
				".stylelintrc",
				".stylelintrc.json",
				".stylelintrc.yaml",
				".stylelintrc.yml",
				".stylelintrc.js",
				".stylelintrc.cjs",
				".stylelintrc.mjs",
				"stylelint.config.js",
				"stylelint.config.cjs",
				"stylelint.config.mjs",
			},
			rubocop = { ".rubocop.yml", ".rubocop.yaml" },
			checkstyle = { "checkstyle.xml", ".checkstyle.xml", "google_checks.xml", "sun_checks.xml" },
			phpstan = { "phpstan.neon", "phpstan.neon.dist", "phpstan.dist.neon" },
			sqlfluff = { ".sqlfluff", "setup.cfg", "tox.ini", "pyproject.toml" },
			tflint = { ".tflint.hcl", "tflint.hcl" },
			semgrep = { ".semgrep.yml", ".semgrep.yaml", "semgrep.yml", "semgrep.yaml" },
		}
		-- Cache config lookups per (linter, buffer-dir): the find walks the tree upward and this
		-- callback fires on every save/InsertLeave. Keyed by dir so a :cd or different buffer re-checks.
		local function has_config(linter, dir)
			return vim.fs.find(gated[linter], { upward = true, path = dir, type = "file" })[1] ~= nil
		end

		-- HEAVY linters that scan the WHOLE package/translation-unit/repo per run are too costly to
		-- fire on every InsertLeave — async, but invocations pile up while you edit. Restrict them to
		-- BufWritePost (save-only); the fast per-file linters keep the snappier cadence.
		local heavy = {
			golangcilint = true,
			cpplint = true,
			checkstyle = true,
			phpstan = true,
			sqlfluff = true,
			tflint = true,
			semgrep = true,
		}

		local grp = vim.api.nvim_create_augroup("NvimLint", { clear = true })
		vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave" }, {
			group = grp,
			callback = function(args)
				-- Resolve linters across EVERY component of a (possibly compound) filetype. nvim-lint's
				-- own try_lint() matches the exact `vim.bo.filetype` string, so a dotted ft like
				-- `yaml.ansible` or a Helm `yaml.gotmpl` never matched `yaml` and went unlinted — even
				-- though conform (which splits on ".") still formatted it. Splitting here fixes that.
				local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(args.buf))
				local names, seen = {}, {}
				local function add(name)
					if not seen[name] then
						seen[name] = true
						names[#names + 1] = name
					end
				end
				for _, part in ipairs(vim.split(vim.bo[args.buf].filetype, ".", { plain = true })) do
					for _, l in ipairs(lint.linters_by_ft[part] or {}) do
						add(l)
					end
					if sast_fts[part] then
						add("semgrep")
					end
				end

				-- Drop linters that shouldn't run this pass: heavy ones on InsertLeave (whole
				-- package/repo scanners — save-only), and config-gated ones with no project config
				-- upward from the buffer (avoids hard errors / network / wrong dialect).
				local run = {}
				for _, name in ipairs(names) do
					local skip = (args.event == "InsertLeave" and heavy[name])
						or (gated[name] and not has_config(name, dir))
					if not skip then
						run[#run + 1] = name
					end
				end
				if #run > 0 then
					require("lint").try_lint(run)
				end
			end,
		})
	end,
}
