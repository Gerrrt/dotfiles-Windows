-- ================================================================================================
-- TITLE : nvim-treesitter (main branch — new API)
-- LINKS : https://github.com/nvim-treesitter/nvim-treesitter
-- NOTE  : Dropped lazy=false so the BufReadPost/BufNewFile event actually governs loading
--         (the two were fighting before).
-- ================================================================================================
return {
	"nvim-treesitter/nvim-treesitter",
	branch = "main",
	build = ":TSUpdate",
	event = { "BufReadPost", "BufNewFile" },
	config = function()
		local treesitter = require("nvim-treesitter")
		treesitter.setup({})
		local ensure_installed = {
			"bash",
			"c",
			"cpp",
			"css",
			"go",
			"html",
			"javascript",
			"json",
			"lua",
			"markdown",
			"markdown_inline",
			"python",
			"rust",
			"svelte",
			"solidity",
			"typescript",
			"vue",
			"yaml",
			"toml", -- pyproject/Cargo/foundry/starship/mise + taplo LSP
			"dockerfile", -- Dockerfile highlighting (dockerls attaches; this colours it)
			"diff", -- diffview.nvim + git diff buffers
			"gitcommit", -- commit message buffers (you write these via fugitive/lazygit)
			"vimdoc", -- :help and plugin docs
			"regex", -- noice.nvim floating cmdline: highlights the regex in :s/… and searches
			-- ── added-language parsers (LSP + formatter + linter wired in the other manifests) ──
			"ruby",
			"java",
			"kotlin",
			"php",
			"zig",
			"sql",
			"proto", -- Protobuf
			"graphql",
			"terraform", -- .tf
			"hcl", -- generic HCL (Packer/Nomad/Vault) — no LSP, but highlighting + terraform fmt
		}

		local group = vim.api.nvim_create_augroup("TreeSitterConfig", { clear = true })

		-- Installed-parser lookup, cached as a SET with lazy rebuild.
		--
		-- get_installed() is not a cheap accessor — it reads two directories off disk
		-- (nvim-treesitter/config.lua walks the `queries/` and `parser/` install dirs with
		-- vim.fs.dir) and returns a fresh list every call, measured at ~0.19ms. The old code called
		-- it inside the FileType callback and then did a LINEAR scan of the result, so every buffer
		-- you opened paid a directory walk plus an O(n) search just to answer "is this parser here?".
		--
		-- `installed == nil` means DIRTY: the next lookup rebuilds. Cheap hash lookup in the steady
		-- state, and never stale against what is actually on disk.
		local installed ---@type table<string, true>|nil
		local function installed_set()
			if not installed then
				local set = {}
				for _, lang in ipairs(treesitter.get_installed()) do
					set[lang] = true
				end
				installed = set
			end
			return installed
		end

		-- Invalidate on EVERY parser mutation, not just the ensure_installed pass below.
		-- nvim-treesitter emits `User TSUpdate` from reload_parsers() (so :TSInstall and :TSUpdate)
		-- and from M.uninstall() — the paths that call require("nvim-treesitter.install") directly
		-- and would otherwise bypass us entirely, leaving manually-installed parsers invisible and
		-- uninstalled ones still "present" (which would make a later vim.treesitter.start() fail).
		--
		-- Marked DIRTY rather than rebuilt in place, deliberately: uninstall fires this event BEFORE
		-- it removes the files, so rebuilding synchronously here would just re-cache the pre-removal
		-- state. Deferring the rebuild to the next lookup sidesteps the ordering entirely.
		vim.api.nvim_create_autocmd("User", {
			pattern = "TSUpdate",
			group = group,
			callback = function()
				installed = nil
			end,
		})

		-- Reuse the set we just built rather than calling config.get_installed() again — that would
		-- be a second identical directory walk at startup, which is the exact cost this cache exists
		-- to remove.
		local have = installed_set()
		local parsers_to_install = {}
		for _, parser in ipairs(ensure_installed) do
			if not have[parser] then
				table.insert(parsers_to_install, parser)
			end
		end
		if #parsers_to_install > 0 then
			-- Completion fires `User TSUpdate`, which invalidates the set above — so a parser
			-- installed during this session becomes visible without any await/callback plumbing.
			pcall(treesitter.install, parsers_to_install)
		end

		-- Start treesitter for a buffer when its filetype's language has an installed parser.
		local function start_ts(buf, ft)
			local lang = vim.treesitter.language.get_lang(ft)
			if lang and installed_set()[lang] then
				vim.treesitter.start(buf)
			end
		end
		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			callback = function(args)
				start_ts(args.buf, args.match)
			end,
		})
		-- This plugin lazy-loads on BufReadPost/BufNewFile, which fire AFTER FileType — so the
		-- buffer that TRIGGERED loading already missed the FileType autocmd above (and lazy.nvim
		-- only replays the triggering event, not FileType). Without this, the very FIRST file you
		-- open gets no highlighting/folds until re-edited. Start TS for every already-loaded
		-- buffer to cover that initial buffer.
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) then
				start_ts(buf, vim.bo[buf].filetype)
			end
		end
	end,
}
