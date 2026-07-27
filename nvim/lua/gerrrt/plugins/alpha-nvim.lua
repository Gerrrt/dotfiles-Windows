-- ================================================================================================
-- TITLE : alpha-nvim | minimalist start screen / dashboard
-- LINKS : https://github.com/goolord/alpha-nvim
-- ABOUT : The greeter you don't currently have. Shows ONLY when you launch `nvim` with no file
--         arguments (argc == 0) via event = VimEnter, so it never fights nvim-tree's directory
--         hijack (`nvim .` / `nvim ~/proj` has argc == 1 → tree opens, alpha stays out of the way).
--         Buttons route to tools you already use: fzf-lua finders, persistence session-restore,
--         your `<leader>rc` config edit, and :Lazy.
-- ICONS : button glyphs are \u{XXXX} escapes (Nerd Font codepoints) so they survive transfer.
-- ================================================================================================
return {
	"goolord/alpha-nvim",
	dependencies = { "nvim-tree/nvim-web-devicons" },
	event = "VimEnter",
	config = function()
		local startify = require("alpha.themes.startify")

		-- N9: palette-aware accents so the greeter colors from tokyonight-storm
		local ok, c = pcall(function()
			return require("gerrrt.utils.palette").colors()
		end)
		if ok and type(c) == "table" then
			vim.api.nvim_set_hl(0, "AlphaHeader", { fg = c.blue, bold = true })
			vim.api.nvim_set_hl(0, "AlphaFooter", { fg = c.comment, italic = true })
		end

		startify.section.header.val = {
			"                                            ",
			"  ███╗   ██╗██╗   ██╗██╗███╗   ███╗         ",
			"  ████╗  ██║██║   ██║██║████╗ ████║         ",
			"  ██╔██╗ ██║██║   ██║██║██╔████╔██║         ",
			"  ██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║         ",
			"  ██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║         ",
			"  ╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝         ",
			"                                            ",
		}

		startify.section.header.opts.hl = "AlphaHeader"

		startify.section.top_buttons.val = {
			startify.button("f", "\u{f002}  Find file", "<cmd>FzfLua files<cr>"), -- f002 search
			startify.button("g", "\u{f002}  Live grep", "<cmd>FzfLua live_grep<cr>"),
			startify.button("r", "\u{f1da}  Recent files", "<cmd>FzfLua oldfiles<cr>"), -- f1da history
			startify.button("s", "\u{f021}  Restore session", "<cmd>lua require('persistence').load()<cr>"), -- f021 refresh
			startify.button("c", "\u{f013}  Config", "<cmd>lua vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(vim.fn.stdpath('config'), 'init.lua')))<cr>"), -- f013 gear
			startify.button("l", "\u{f1b3}  Lazy", "<cmd>Lazy<cr>"), -- f1b3 cubes
			startify.button("q", "\u{f057}  Quit", "<cmd>qa<cr>"), -- f057 times-circle
		}

		-- N9: quiet footer (plugin count + nvim version)
		local ok2, lazy = pcall(require, "lazy")
		local pcount = ok2 and lazy.stats().count or 0
		local ver = vim.version()
		startify.section.footer.val = {
			("\u{f0e7} %d plugins   \u{f419} nvim %d.%d.%d"):format(pcount, ver.major, ver.minor, ver.patch), -- f0e7 bolt, f419 nvim
		}
		startify.section.footer.opts = { position = "center", hl = "AlphaFooter" }

		require("alpha").setup(startify.config)
	end,
}
