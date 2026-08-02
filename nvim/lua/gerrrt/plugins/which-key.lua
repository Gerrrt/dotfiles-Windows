-- ================================================================================================
-- TITLE : which-key | shows your keybindings as you type the leader
-- LINKS : https://github.com/folke/which-key.nvim
-- ================================================================================================
return {
	"folke/which-key.nvim",
	event = "VeryLazy",
	opts = {
		-- NvChad-flavored popup: the classic bottom prompt, but a minimal rounded float with a bit of
		-- breathing room and a clean left-aligned column layout — the colors (blue keys, red
		-- descriptions, green groups) are set palette-aware in utils/ui-highlights.lua so they track
		-- the theme instead of being hardcoded here.
		preset = "classic",
		win = {
			border = "rounded",
			padding = { 1, 2 }, -- one row / two cols of inner padding, so entries don't kiss the border
			title = true,
			title_pos = "center",
		},
		layout = {
			spacing = 4, -- gap between the key and its description column
			align = "left",
		},
		spec = {
			-- Only present when the `claude` binary is — the plugin spec is `cond`-gated, so on a box
			-- without the CLI this group renders empty. Declared anyway so the prefix has a name
			-- wherever it does appear, same reasoning as <leader>t below.
			{ "<leader>a", group = "ai / claude" },
			{ "<leader>b", group = "buffer" },
			{ "<leader>c", group = "code / LSP" },
			{ "<leader>d", group = "debug (dap)" },
			{ "<leader>f", group = "find (fzf)" },
			{ "<leader>g", group = "git" },
			{ "<leader>h", group = "harpoon" },
			{ "<leader>n", group = "npm (package.json)" },
			{ "<leader>q", group = "session" },
			{ "<leader>s", group = "split / window" },
			-- normal mode only, and only really populated on python buffers (buffer-local pytest maps
			-- attached on FileType python — config/autocmds.lua). Declared globally so the prefix has a
			-- name wherever it appears rather than rendering as a bare unnamed group.
			{ "<leader>t", group = "test", mode = "n" },
			{ "<leader>u", group = "ui / toggles" },
			{ "<leader>w", group = "which-key" },
			{ "<leader>x", group = "trouble / lists" },
			{ "<leader><tab>", group = "tabs" },
			-- These three had real children but no group entry, so which-key rendered them as bare
			-- unnamed prefixes: <leader>r (rc = edit config, rn = rename symbol), <leader>o
			-- (oi = organize imports), <leader>p (pa = copy file path).
			{ "<leader>r", group = "rename / config" },
			{ "<leader>o", group = "organize" },
			-- normal mode only: in visual, <leader>p is itself a mapping (paste-without-yank,
			-- config/keymaps.lua), not a prefix — declaring a group there would misdescribe it.
			{ "<leader>p", group = "path", mode = "n" },
			-- non-leader: mini.surround moved here off `s` so flash owns `s` (see mini-nvim.lua)
			{ "gs", group = "surround", mode = { "n", "x" } },
		},
	},
	keys = {
		-- `<leader>?` now opens the full cheatsheet (config/keymaps.lua) — the whole map, not the
		-- live prompt. which-key's buffer-local-keys popup moves to `<leader>wk` so both survive.
		{
			"<leader>wk",
			function()
				require("which-key").show({ global = false })
			end,
			desc = "Buffer Local Keymaps (which-key)",
		},
	},
}
