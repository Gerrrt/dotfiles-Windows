-- ================================================================================================
-- TITLE : claudecode.nvim | Claude Code as an IDE peer, not a pane you paste into
-- LINKS : https://github.com/coder/claudecode.nvim
-- ABOUT : Implements the same WebSocket/MCP protocol Anthropic's VS Code and JetBrains extensions
--         speak, in pure Lua. Neovim runs the server and writes ~/.claude/ide/<port>.lock; the
--         `claude` CLI discovers that lock and attaches. What you get over a bare terminal pane:
--           • Claude's edits arrive as a native :diffsplit — `:w` accepts, `:q` rejects, and you
--             can edit the suggestion BEFORE accepting it.
--           • Visual selections send with their real file + line range attached.
--           • Claude reads this session's LSP diagnostics over MCP, so it sees the same errors
--             you do without re-running a build (we wire ~30 servers — that's the whole point).
--           • `<leader>as` in an nvim-tree or oil buffer @-mentions that file into context.
-- LAZY  : cmd + keys. Nothing loads, and no server binds a port, until you actually reach for it.
-- NOTE  : Two deliberate departures from upstream's README spec.
--         1. NO `dependencies = { "folke/snacks.nvim" }`. Upstream defaults its terminal to snacks,
--            which we don't ship and which would overlap fzf-lua / mini.notify / alpha. We set
--            `provider = "native"` — plain `:terminal` in a split. That also keeps faith with the
--            no-dap-ui / no-toggleterm stance stated in config/autocmds.lua. If the in-editor
--            terminal ever grates (paste handling, <C-\><C-n> mode juggling), `provider = "none"`
--            runs the server ONLY: drive `claude` from a tmux pane and attach it with `/ide`.
--         2. `cond` gates the whole spec on the `claude` binary. Core vendors into eight OS repos
--            and `claude` is in no package list on any of them, so on most boxes this plugin must
--            be completely inert — the same reasoning as the `uv` gate in config/autocmds.lua:
--            maps that only ever advertise a command that opens a failed terminal are worse than
--            no maps. `:checkhealth gerrrt` reports the gate so its absence is never a mystery.
-- ================================================================================================
return {
	"coder/claudecode.nvim",
	-- Re-probed at startup only. Installing the CLI mid-session takes effect on the next launch;
	-- unlike the per-buffer uv probe there is no cheaper seam here, and it isn't worth one.
	cond = function()
		return vim.fn.executable("claude") == 1
	end,
	cmd = {
		"ClaudeCode",
		"ClaudeCodeFocus",
		"ClaudeCodeSelectModel",
		"ClaudeCodeAdd",
		"ClaudeCodeSend",
		"ClaudeCodeTreeAdd",
		"ClaudeCodeStatus",
		"ClaudeCodeStart",
		"ClaudeCodeStop",
		"ClaudeCodeOpen",
		"ClaudeCodeClose",
		"ClaudeCodeDiffAccept",
		"ClaudeCodeDiffDeny",
		"ClaudeCodeCloseAllDiffs",
	},
	keys = {
		{ "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
		{ "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
		{ "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude session" },
		{ "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude session" },
		{ "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
		{ "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer to context" },
		{ "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send selection to Claude" },
		-- Same key, different surface: in a file explorer it @-mentions the entry under the cursor.
		-- Only the two explorers we actually ship are listed — upstream also names neo-tree,
		-- minifiles and snacks_picker_list (not installed), and netrw (disabled in config/globals.lua).
		{
			"<leader>as",
			"<cmd>ClaudeCodeTreeAdd<cr>",
			ft = { "NvimTree", "oil" },
			desc = "Add file to Claude context",
		},
		{ "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept Claude diff" },
		{ "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny Claude diff" },
		{ "<leader>aS", "<cmd>ClaudeCodeStatus<cr>", desc = "Claude server status" },
	},
	opts = {
		-- log_level "info" narrates routine protocol traffic through vim.notify, which mini.notify
		-- renders as popups — noisy enough to be a reason to uninstall. "warn" keeps the signal.
		log_level = "warn",
		terminal = {
			provider = "native",
			split_side = "right",
			split_width_percentage = 0.35,
		},
		diff_opts = {
			-- Vertical matches how the rest of the config reviews changes (diffview, fugitive).
			layout = "vertical",
			-- Land the cursor in the diff, not the terminal — the diff is the thing to act on.
			keep_terminal_focus = false,
		},
	},
	config = function(_, opts)
		require("claudecode").setup(opts)

		-- ── terminal-mode escape hatch ─────────────────────────────────────────────────────────
		-- auto_insert drops you into terminal mode, where Claude swallows Core's <C-h/j/k/l> and the
		-- split reads as a trap. utils/term.lua owns the rule and the reasoning (why <M-…> and not
		-- the navigator's own keys); this just applies it to the buffer the plugin opened.
		vim.api.nvim_create_autocmd("TermOpen", {
			group = vim.api.nvim_create_augroup("gerrrt_claudecode_term", { clear = true }),
			callback = function(ev)
				-- Deferred on purpose: TermOpen fires DURING termopen(), before the provider records
				-- the new buffer as its active one, so asking now returns the PREVIOUS terminal (or
				-- nil). One tick later the assignment has landed.
				vim.schedule(function()
					if not vim.api.nvim_buf_is_valid(ev.buf) then
						return
					end
					-- Ask the plugin which buffer is Claude's rather than pattern-matching the
					-- `term://…` name: TermOpen also fires for the pytest split in config/autocmds.lua
					-- and for any :terminal you open, and a name match on "claude" would also hit a
					-- plain shell started in a directory that happens to contain that word.
					local ok, terminal = pcall(require, "claudecode.terminal")
					if not ok or terminal.get_active_terminal_bufnr() ~= ev.buf then
						return
					end
					require("gerrrt.utils.term").map_navigation(ev.buf, "Claude")
				end)
			end,
		})
	end,
}
