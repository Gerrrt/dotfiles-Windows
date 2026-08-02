-- nvim/lua/gerrrt/utils/term.lua
-- ─────────────────────────────────────────────────────────────────────────────
-- Terminal-buffer ergonomics — the one place the "how do I get OUT of here" rule lives.
--
-- THE PROBLEM: a Neovim terminal buffer forwards EVERY keystroke to the program inside it,
-- and both of Core's terminals call startinsert, so you land in terminal mode. Core's
-- <C-h/j/k/l> (vim-tmux-navigator) are normal-mode only, so they never reach Neovim — the
-- program eats them and the split reads as a trap. Neovim's <C-\><C-n> is the one reserved
-- way out, and before this module nothing in the config said so: `mode = "t"` appeared
-- nowhere under nvim/. That was the actual defect — discoverability, not behavior.
--
-- WHY <M-…> AND NOT THE NAVIGATOR'S OWN KEYS: widening <C-h/j/k/l> into terminal mode is the
-- obvious fix and it is wrong. <C-h> is ASCII 8 (backspace), <C-j> is ASCII 10 (newline), and
-- <C-w> is delete-word-backward — claiming any of them breaks editing at an interactive
-- prompt. <M-…> is unclaimed by the TUIs we run here. mini.move owns <A-h/j/k/l> in
-- normal/visual only (a different mode, so no real collision), and the overload reads the
-- same way regardless: "move in that direction".
--
-- Callers: plugins/claudecode-nvim.lua (Claude's split) and config/autocmds.lua (the pytest
-- split). Documented as one "Terminal buffers" card in cheatsheet.lua — keep them in step.
-- ─────────────────────────────────────────────────────────────────────────────
local M = {}

local DIRECTIONS = {
	{ "h", "Left" },
	{ "j", "Down" },
	{ "k", "Up" },
	{ "l", "Right" },
}

--- Give a terminal buffer buffer-local <M-h/j/k/l> that leave terminal mode and navigate in one
--- keystroke. Buffer-local on purpose: a terminal you did not open (`:terminal`, a plugin's own)
--- keeps its keys untouched, so this never silently changes a surface it does not own.
---@param buf integer Buffer handle of the terminal buffer.
---@param label string? What to call it in the keymap `desc` (e.g. "Claude"); defaults to "terminal".
function M.map_navigation(buf, label)
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	for _, nav in ipairs(DIRECTIONS) do
		local key, dir = nav[1], nav[2]
		vim.keymap.set("t", ("<M-%s>"):format(key), ([[<C-\><C-n><cmd>TmuxNavigate%s<cr>]]):format(dir), {
			buffer = buf,
			desc = ("Leave %s, window/pane %s"):format(label or "terminal", dir:lower()),
		})
	end
end

return M
