-- ================================================================================================
-- TITLE : render-markdown.nvim | render Markdown in the buffer as you edit
-- LINKS : https://github.com/MeanderingProgrammer/render-markdown.nvim
-- ABOUT : Pretty headings, bullets, code blocks, tables, callouts and checkboxes drawn inline —
--         no separate preview window/browser. You spellcheck en+de and have a dedicated markdown
--         autocmd (wrap/conceal), so prose is a real part of this config; this makes notes and
--         READMEs legible while staying plain text. Uses the markdown + markdown_inline treesitter
--         parsers you already install (nvim-treesitter.lua).
-- LAZY  : ft = markdown (+ codecompanion/Avante-style chats if you ever add them). Toggle live
--         with `<leader>um` (the new ui/toggles group). Anti-conceal reveals raw markup on the
--         cursor line, matching your markdown autocmd's concealcursor="" behaviour.
-- ================================================================================================
return {
	"MeanderingProgrammer/render-markdown.nvim",
	dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" },
	ft = { "markdown" },
	keys = {
		{ "<leader>um", "<cmd>RenderMarkdown toggle<cr>", desc = "Toggle Markdown render" },
	},
	---@module 'render-markdown'
	---@type render.md.UserConfig
	opts = {
		completions = { lsp = { enabled = true } },
		anti_conceal = { enabled = true }, -- show raw markup on the cursor line
		code = { sign = false, width = "block", right_pad = 1 },
		heading = { sign = false },
		-- No LaTeX math rendering. Left enabled, render-markdown's healthcheck probes for the
		-- `latex` treesitter parser and the latex2text/utftex CLIs (pylatexenc) — none installed
		-- across the fleet — surfacing three :checkhealth warnings for a feature unused here.
		latex = { enabled = false },
	},
}
