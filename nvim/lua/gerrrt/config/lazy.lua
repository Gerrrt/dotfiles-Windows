-- ================================================================================================
-- TITLE : lazy.nvim Bootstrap & Plugin Setup
-- ABOUT :
--   bootstraps the 'lazy.nvim' plugin manager by cloning it if not present, prepends it to the
--   runtime path, and then loads core configuration files (globals, options, keymaps, autocmds).
--   Last, initialises 'lazy.nvim' with plugins.
-- LINKS :
--   > lazy.nvim github  : https://github.com/folke/lazy.nvim
--   > lazy.nvim website : https://lazy.folke.io/installation
-- ================================================================================================

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
---@diagnostic disable-next-line: undefined-field (fs_stat)
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	local lazyrepo = "https://github.com/folke/lazy.nvim.git"
	local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
	if vim.v.shell_error ~= 0 then
		vim.api.nvim_echo({
			{ "Failed to clone lazy.nvim:\n", "ErrorMsg" },
			{ out, "WarningMsg" },
			{ "\nPress any key to exit..." },
		}, true, {})
		vim.fn.getchar()
		os.exit(1)
	end
end
vim.opt.rtp:prepend(lazypath)

require("gerrrt.config.globals")
require("gerrrt.config.options")
require("gerrrt.config.keymaps")
require("gerrrt.config.autocmds")
require("gerrrt.config.clipboard")
require("gerrrt.config.providers")

-- ── the lockfile lives in STATE, not in the config tree ─────────────────────────────────
-- lazy.nvim REWRITES its lockfile in place on every plugin install/update, and an OS repo
-- bootstrap-symlinks ~/.config/nvim into the VENDORED core/nvim/ tree — the one tree that
-- must stay byte-for-byte upstream. So on any machine that runs nvim at all, a file inside
-- that tree was permanently dirty (#465).
--
-- Not a tidiness problem. Opening the editor ONCE was enough: a fresh openSUSE box repinned
-- 10 plugins and a fresh Gentoo box 2, with nobody running :Lazy update. Consumers gate the
-- vendoring contract — `make check-core`, a no-core-edits pre-commit hook, core-integrity at
-- PR time — and all of them correctly failed closed on it, so `make test` was red on any box
-- where nvim had been opened until someone ran `git checkout -- core/nvim/lazy-lock.json`.
-- Worse, a routine `git add -A` swept the drift into an unrelated commit on any box where
-- the guard was not installed. "Do not edit core/" is not a rule an operator can keep when
-- the writer is the very tool the file configures.
--
-- The fix is the move v4 already made for zsh history (15-history.zsh: HISTFILE under
-- $XDG_STATE_HOME because history is mutable STATE, not config), for the same reason:
--
--   · $XDG_STATE_HOME/nvim/lazy-lock.json  — the MUTABLE lockfile this machine writes.
--   · core/nvim/lazy-lock.json             — the read-only fleet SEED. Still the
--     reproducible plugin set every machine starts from; `make update-nvim-plugins`
--     upstream remains the only thing that changes it.
--
-- The seed copy below is what preserves reproducibility on a fresh machine: state absent
-- means first run, so start from the fleet's pins rather than resolving every plugin's
-- default branch afresh. stdpath("state") rather than expanding $XDG_STATE_HOME by hand —
-- it is defined even when the env var is not.
local lockfile = vim.fs.joinpath(vim.fn.stdpath("state"), "lazy-lock.json")
local seed = vim.fs.joinpath(vim.fn.stdpath("config"), "lazy-lock.json")
local uv = vim.uv or vim.loop
if not uv.fs_stat(lockfile) and uv.fs_stat(seed) then
	vim.fn.mkdir(vim.fn.stdpath("state"), "p")
	-- Best-effort: a failed seed means lazy resolves from the specs instead, which is a
	-- slower first run, not a broken one. Never abort startup over it.
	local ok, err = uv.fs_copyfile(seed, lockfile)
	if not ok then
		vim.notify("lazy: could not seed lockfile from Core (" .. tostring(err) .. ")", vim.log.levels.WARN)
	end
end

require("lazy").setup({
	spec = {
		{ import = "gerrrt.plugins" },
	},
	-- See the note above: mutable state, never the vendored config tree.
	lockfile = lockfile,
	install = {
		colorscheme = {
			"tokyonight",
		},
	},
	rocks = {
		enabled = false,
	},
	-- Invert lazy.nvim's default: a spec is lazy UNLESS it opts out with `lazy = false`. Today every
	-- spec here is already covered one of two ways, so this changes nothing at present:
	--   • most declare an event/ft/cmd/keys trigger;
	--   • the pure-data / dependency specs declare `lazy = true` explicitly and are pulled in by a
	--     `require` or by another spec's `dependencies` — webdev-icons.lua, schemastore.lua, and the
	--     luvit-meta entry in lazydev-nvim.lua.
	-- It is a REGRESSION NET: a future spec added with NEITHER a trigger nor an explicit `lazy` stays
	-- lazy instead of silently landing on the startup path. The one spec that must load eagerly
	-- (tokyonight, plugins/theme.lua) already says `lazy = false, priority = 1000` explicitly.
	-- Verified: the set of plugins loaded at startup and on first file open is identical before and
	-- after this line.
	defaults = { lazy = true },
	-- Auto-check for plugin updates, but don't spam notifications on every startup.
	-- Disabled when DOTFILES_OFFLINE=1 (engagement boxes) — the checker does background
	-- `git fetch` of plugin repos, which we don't want phoning home unattended. See globals.lua.
	checker = { enabled = not vim.g.dotfiles_offline, notify = false },
	change_detection = { notify = false },
	performance = {
		rtp = {
			-- Disable built-in runtime plugins we don't use so they're never sourced at startup.
			-- netrwPlugin is the belt-and-suspenders pair to the vim.g.loaded_netrw* globals set
			-- in config/globals.lua (nvim-tree owns file exploration). The rest — gzip/tar/zip
			-- (transparent in-place archive editing), tohtml, tutor — are unused here.
			--
			-- matchparen is the notable one: it is NOT merely unused, it is actively costly. It
			-- registers 10 autocmds, three of which (CursorMovedI, TextChangedI, TextChangedP) run
			-- on EVERY KEYSTROKE in insert mode to re-scan for a matching bracket. That is the
			-- classic Neovim insert-latency source. 'showmatch' used to double this up from the
			-- other side; it was removed in config/options.lua (see the note there).
			-- rplugin  : the remote-plugin manifest loader. perl/ruby providers are already off
			--            (config/providers.lua) and nothing here ships a remote plugin.
			-- spellfile: auto-downloads missing spellfiles over the network on demand — unwanted
			--            generally, and actively wrong on a DOTFILES_OFFLINE engagement box.
			--
			-- NOT disabled, deliberately: `matchit` (extended `%` between if/end, tags, etc. — a
			-- real feature) and `editorconfig` (vim-sleuth's counterpart for repos that ship one).
			-- NvChad disables 26 runtime plugins including matchit; that list is largely cargo-cult
			-- and costs you `%`. Each entry here is disabled for a stated reason.
			disabled_plugins = {
				"netrwPlugin",
				"gzip",
				"tarPlugin",
				"zipPlugin",
				"tohtml",
				"tutor",
				"matchparen",
				"rplugin",
				"spellfile",
			},
		},
	},
})
