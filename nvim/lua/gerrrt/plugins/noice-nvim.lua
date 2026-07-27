-- ================================================================================================
-- TITLE : noice.nvim | floating command line (tamed)
-- LINKS : https://github.com/folke/noice.nvim
-- ABOUT : ONLY the floating command line + its popupmenu — the part worth having. Everything else
--         is deliberately left on Neovim's NATIVE path, which is what avoids the two bugs the full
--         setup caused:
--           • messages.enabled = false → no message takeover, so no stray "mini" view / scrollbar
--             (that was the purple bar on the right), AND the classic command line keeps its row,
--             so a `:` / `:!` command with lots of output can't overrun a reclaimed line and push
--             the cursor off-screen (noice's cmdheight=0 was the culprit there).
--           • notify off → vim.notify untouched (no nvim-notify dependency).
--           • lsp hover/signature/progress off → native floats (styled by utils/ui-highlights.lua)
--             and fidget-nvim keeps the LSP progress spinner.
-- DEPS  : nui.nvim only.
-- ================================================================================================
return {
	"folke/noice.nvim",
	event = "VeryLazy",
	dependencies = { "MunifTanjim/nui.nvim" },
	opts = {
		cmdline = { enabled = true, view = "cmdline_popup" }, -- floating, centered `:` input
		popupmenu = { enabled = true, backend = "nui" }, -- floating wildmenu alongside the cmdline
		messages = { enabled = false }, -- keep native messages → real cmdline row, no output overrun
		notify = { enabled = false }, -- leave vim.notify alone
		lsp = {
			progress = { enabled = false }, -- fidget-nvim owns the LSP progress spinner
			hover = { enabled = false }, -- native hover (already styled by ui-highlights borders)
			signature = { enabled = false }, -- native signature
		},
	},
}
