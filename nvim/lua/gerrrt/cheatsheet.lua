-- ================================================================================================
-- TITLE : cheatsheet | a full-screen, NVChad-style keybinding reference
-- ABOUT : which-key answers "I've started typing <leader>, what's next?" — great for discovery,
--         useless for "what do I even have?". This is the other half: one floating panel that
--         lays out EVERY curated binding in the config at once, grouped by task, so you can
--         eyeball the whole surface area and rediscover the features you're under-using.
-- WHY HAND-CURATED : the mappings live across ~30 lazy specs, most bound lazily and not registered
--         until their plugin loads — so scraping `nvim_get_keymap()` at open time would show a
--         half-empty, load-order-dependent list. This table is the intentional picture; when you
--         add a binding to a plugin spec, add its row here too (they sit next to each other in
--         review). Descriptions mirror the `desc =` on the real keymaps.
-- SCOPE  : "every curated binding" means every GLOBAL, user-facing one. Deliberately excluded, so
--         the panel stays a map rather than a dump: keys that only exist inside a transient UI
--         (the rename float, oil buffers, alpha's dashboard buttons, this panel's own q/<Esc>) and
--         plain Vim motions that aren't config-specific. An audit found the panel had drifted —
--         mini.move's <A-hjkl> and the entire blink.cmp completion set were missing — so if you
--         are adding a card, prefer over-inclusion to a silent gap.
-- ENTRY : `:Cheatsheet` (alias `:Cheat`) and `<leader>?` (see config/keymaps.lua). `q`/`<Esc>`
--         close; the panel is a throwaway scratch buffer, nothing to save.
-- DEPS  : none — pure Neovim API, so it survives on a bare box the same as the rest of Core.
-- ================================================================================================

local M = {}

-- ── the content ──────────────────────────────────────────────────────────────────────────────
-- Ordered list of cards. Each card = { title, { "keys", "description" }, ... }. Order here is the
-- order they get packed into the masonry columns (shortest-column-first), so keep related cards
-- adjacent and roughly grouped essentials → editing → navigation → git → lang → tools.
M.sections = {
	{
		"Essentials",
		{ "<leader>?", "Open this cheatsheet" },
		{ "<leader>wk", "Buffer-local keys" },
		{ "<leader>rc", "Edit config" },
		{ "<Esc>", "Clear search highlight" },
		{ "<leader>pa", "Copy full file path" },
		{ "<leader>p", "Paste over, keep yank (x)" },
		{ "<leader>D", "Delete to black hole" },
		{ "gc / gcc", "Comment motion / line" },
	},
	{
		"Motion & Search",
		{ "j / k", "Down / up (wrap-aware)" },
		{ "n / N", "Next / prev match (centered)" },
		{ "<C-d> / <C-u>", "Half page down / up (centered)" },
		{ "J", "Join lines, keep cursor" },
		{ "< / >", "Indent, keep selection (v)" },
		{ "[c", "Jump to context (upwards)" },
	},
	{
		"Flash (jump)",
		{ "s", "Flash jump" },
		{ "S", "Flash Treesitter" },
		{ "r", "Remote Flash (o)" },
		{ "R", "Treesitter search (o/x)" },
		{ "<C-s>", "Toggle Flash in / search (c)" },
	},
	{
		"Windows & Splits",
		{ "<C-h/j/k/l>", "Move (crosses tmux panes)" },
		{ "<leader>sv", "Split vertically" },
		{ "<leader>sh", "Split horizontally" },
		{ "<leader>se", "Equalize sizes" },
		{ "<leader>sw", "Cycle to next split" },
		{ "<leader>sx", "Swap positions" },
		{ "<leader>sq", "Close split" },
		{ "<leader>so", "Close all OTHER splits" },
		{ "<C-arrows>", "Resize height / width" },
	},
	{
		"Buffers",
		{ "]b / [b", "Next / previous" },
		{ "<leader>bn / bp", "Next / previous (leader alias)" },
		{ "<leader>bj", "Pick (jump to letter)" },
		{ "<leader>bd", "Delete, keep layout" },
		{ "<leader>bP", "Pin / unpin" },
		{ "<leader>bo/br/bh", "Close others / right / left" },
		{ "<leader>b, / b.", "Move left / right" },
	},
	{
		"Tabs (workspaces)",
		{ "<leader><tab>n", "New tab" },
		{ "<leader><tab>d", "Close tab" },
		{ "<leader><tab>o", "Close other tabs" },
		{ "]<tab> / [<tab>", "Next / previous" },
		{ "gt / gT", "Cycle (native)" },
	},
	{
		"Harpoon",
		{ "<leader>ha", "Add file" },
		{ "<leader>hh", "Toggle menu" },
		{ "<leader>hn / hN", "Next / previous file" },
		{ "<leader>1..4", "Jump to pinned file" },
	},
	{
		"Find (fzf-lua)",
		{ "<leader>ff", "Files" },
		{ "<leader>fg", "Live grep" },
		{ "<leader>fb", "Buffers" },
		{ "<leader>fr", "Recent files" },
		{ "<leader>fh", "Help tags" },
		{ "<leader>fk", "Keymaps" },
		{ "<leader>ft", "Todo comments" },
		{ "]t / [t", "Next / prev todo comment" },
		{ "<leader>fx / fX", "Diagnostics doc / workspace" },
		{ "<leader>fs / fw", "Symbols doc / workspace" },
		-- Inside the picker. <Tab>/<A-a> are fzf's own multi-select; <C-y> is ours
		-- (plugins/fzf-lua.lua) and needs the `claude` CLI, otherwise it just says so.
		{ "<Tab> / <A-a>", "Mark one / toggle all" },
		{ "<C-y>", "Send marked to Claude" },
	},
	{
		"LSP & Code",
		{ "K", "Hover docs" },
		{ "gd / gD", "Definition / declaration" },
		{ "gr", "References" },
		{ "gi", "Implementations" },
		{ "gy", "Type definitions" },
		{ "<leader>ca", "Code action (n/v)" },
		{ "<leader>rn", "Rename symbol" },
		{ "<leader>cd", "Line diagnostics" },
		{ "[d / ]d", "Prev / next diagnostic" },
		{ "<C-s>", "Signature help (i)" },
		{ "<leader>oi", "Organize imports" },
		{ "<leader>cf", "Format buffer / range" },
		{ "<leader>cL", "Run CodeLens" },
		{ "<leader>cs", "Symbols (Trouble)" },
		{ "<leader>cl", "LSP refs/defs (Trouble)" },
		{ "<leader>cn", "Annotation (Neogen)" },
		{ "<leader>;", "Breadcrumb pick (dropbar)" },
	},
	{
		"Debug (nvim-dap)",
		{ "<leader>db", "Toggle breakpoint" },
		{ "<leader>dB", "Conditional breakpoint" },
		{ "<leader>dc", "Continue / start session" },
		{ "<leader>di / do", "Step into / over" },
		{ "<leader>dO", "Step out" },
		{ "<leader>ds / df", "Scopes / frames (float)" },
		{ "<leader>dw", "Hover value (n/v)" },
		{ "<leader>dr", "Toggle REPL" },
		{ "<leader>dl", "Run last configuration" },
		{ "<leader>dt", "Terminate session" },
		{ "<leader>dm", "Debug test method (python)" },
		{ "<leader>dR", "Rust debuggables (start)" },
	},
	{
		"Test (python)",
		{ "<leader>tt", "pytest: whole suite (uv run)" },
		{ "<leader>tf", "pytest: current file (uv run)" },
		{ "<leader>dm", "Debug test method (dap)" },
	},
	{
		"Trouble & Lists",
		{ "<leader>xx", "Workspace diagnostics" },
		{ "<leader>xX", "Buffer diagnostics" },
		{ "<leader>xL", "Location list" },
		{ "<leader>xQ", "Quickfix list" },
		{ "<leader>xt / xT", "Todos / Todo-Fix-Fixme" },
	},
	{
		"Git — hunks (gitsigns)",
		{ "]h / [h", "Next / prev hunk" },
		{ "<leader>gs", "Stage / unstage hunk" },
		{ "<leader>gS", "Stage whole buffer" },
		{ "<leader>gr", "Reset hunk" },
		{ "<leader>gp", "Preview hunk" },
		{ "<leader>gb", "Blame line" },
		{ "<leader>gd", "Diff this" },
		{ "ih", "Hunk text object (dih/vih)" },
	},
	{
		"Git — tools",
		{ "<leader>gg", "Status (fugitive)" },
		{ "<leader>gc", "Commit" },
		{ "<leader>gP", "Push" },
		{ "<leader>gl", "LazyGit (float)" },
		{ "<leader>gv / gV", "Diffview open / close" },
		{ "<leader>gH / gL", "History: file / repo" },
		{ "<leader>gy / gY", "Permalink: yank / open" },
	},
	{
		-- claudecode.nvim (plugins/claudecode-nvim.lua). The whole spec is gated on the `claude`
		-- binary, so on a box without the CLI these keys do not exist — this card documents the
		-- surface you get once it does. `<leader>as` is deliberately overloaded: visual = send
		-- selection, nvim-tree/oil buffer = add that file.
		"AI (Claude Code)",
		{ "<leader>ac", "Toggle Claude" },
		{ "<leader>af", "Focus Claude" },
		{ "<leader>ar / aC", "Resume / continue session" },
		{ "<leader>ab", "Add buffer to context" },
		{ "<leader>as", "Send selection (v) / add file" },
		{ "<leader>aa / ad", "Accept / deny diff" },
		{ "<leader>am", "Select model" },
		{ "<leader>aS", "Server status" },
		-- Getting OUT of Claude's split is the "Terminal buffers" card below, not here: it is the
		-- same answer for the pytest split, and the whole panel is visible at once so a second copy
		-- would only be a thing to keep in step.
	},
	{
		-- utils/term.lua. Applies to BOTH terminals Core opens — Claude's split
		-- (plugins/claudecode-nvim.lua) and the pytest split (config/autocmds.lua). Terminal mode
		-- forwards every key to the program inside, so Core's <C-h/j/k/l> never reach Neovim;
		-- <C-\><C-n> is Neovim's one reserved way out and <M-h/j/k/l> does that and navigates in one
		-- go. Note `:q` needs normal mode too, so closing one also starts with <C-\><C-n>.
		"Terminal buffers",
		{ "<C-\\><C-n>", "Exit terminal mode" },
		{ "<M-h/j/k/l>", "Exit + navigate" },
		{ "i / a", "Back to typing" },
	},
	{
		"Folds (ufo)",
		{ "zR / zM", "Open / close all folds" },
		{ "zK", "Peek fold / hover" },
		{ "za / zc", "Toggle / close (native)" },
	},
	{
		"Text objects & Surround",
		{ "a/i + w b q p", "word / bracket / quote / para" },
		{ "a/i + f c o", "func / class / block (TS)" },
		{ "gsa / gsd / gsr", "Surround add / del / replace" },
		{ "gsf / gsF", "Find surround right / left" },
		{ "gsh", "Highlight surround" },
		{ "gsn", "Update surround search range" },
		{ "]f / [f", "Next / prev function" },
		{ "]a / [a", "Next / prev argument" },
		{ "<leader>j", "Split / join block (treesj)" },
	},
	{
		-- mini.move (plugins/mini-nvim.lua). Normal mode moves the current LINE; visual mode moves
		-- the SELECTION and keeps it selected. h/l also re-indent, which is why they earn a row.
		"Move lines (mini.move)",
		{ "<A-j> / <A-k>", "Move line/selection down / up" },
		{ "<A-h> / <A-l>", "Move line/selection left / right" },
	},
	{
		-- blink.cmp (plugins/blink-cmp.lua). preset = "none", so every key here is set explicitly
		-- in that spec — this card and that keymap block must be edited together.
		"Completion (blink.cmp)",
		{ "<C-Space>", "Show menu / toggle docs" },
		{ "<C-k> / <C-j>", "Select previous / next item" },
		{ "<CR>", "Accept selected item" },
		{ "<C-e>", "Hide menu" },
		{ "<C-b> / <C-f>", "Scroll docs up / down" },
		{ "<Tab> / <S-Tab>", "Snippet: next / prev placeholder" },
		-- NOT <C-s>: that is signature help, mapped in utils/lsp.lua (LSP & Code card above), not by
		-- blink. blink's signature window is automatic (signature.enabled) with no key of its own.
	},
	{
		"Sessions",
		{ "<leader>qs", "Restore (this dir)" },
		{ "<leader>ql", "Restore last session" },
		{ "<leader>qd", "Stop saving session" },
	},
	{
		"UI & Toggles",
		{ "<leader>e", "File tree (closes Zen if active)" },
		{ "-", "Parent dir (oil)" },
		{ "<leader>z", "Zen mode" },
		{ "<leader>U", "Undotree" },
		{ "<leader>um", "Markdown render" },
	},
	{
		"Packages",
		{ "<leader>ns", "npm: show versions" },
		{ "<leader>nu / nd", "npm: update / delete" },
		{ "<leader>ni / nc", "npm: install / change ver" },
		{ "Cargo.toml", "crates.nvim inline versions" },
	},
}

-- ── rendering ────────────────────────────────────────────────────────────────────────────────
-- Layout is a simple masonry: cards are packed one at a time into whichever column is currently
-- shortest, so the panel stays roughly rectangular regardless of how many cards / how tall each is.

local CARD_W = 32 -- inner text width of a card, in display cells
local GUTTER = 3 -- blank cells between columns
local MARGIN = 2 -- blank cells inside the window border, left/right

local HL = {
	normal = "GerrrtCheatNormal",
	title = "GerrrtCheatTitle",
	rule = "GerrrtCheatRule",
	key = "GerrrtCheatKey",
	sep = "GerrrtCheatSep",
	footer = "GerrrtCheatFooter",
}

-- Number of accent "pill" highlight groups; cards cycle through them by index so adjacent headings
-- get different colors — NvChad's grid look (black text on a vivid accent bar). Populated by
-- define_highlights when the palette is available; 0 on a bare box (headings fall back to plain).
local NPILL = 0

local function define_highlights()
	local set = vim.api.nvim_set_hl
	-- Prefer the resolved tokyonight palette (one source of truth in utils/palette.lua) so the panel
	-- reads as NvChad's grid: heading bars in cycling accents, blue keys, dim rules/footer. nil on a
	-- fresh box (tokyonight not loaded) → degrade to the semantic links below instead of erroring —
	-- the cheatsheet stays deps-free by design.
	local c = require("gerrrt.utils.palette").colors()
	if type(c) == "table" then
		local accents = { c.blue, c.green, c.magenta, c.cyan, c.orange, c.yellow, c.red, c.teal, c.purple }
		for i, accent in ipairs(accents) do
			-- black (bg_dark) bold text on a vivid accent → the pill heading
			set(0, "GerrrtCheatPill" .. i, { fg = c.bg_dark, bg = accent, bold = true })
		end
		NPILL = #accents
		-- Solid panel background (NvChad's cheatsheet is an opaque card, not transparent) — the one
		-- place the hybrid look goes solid inside a float. bg_dark is the darkest surface so the accent
		-- pills and blue keys pop off it.
		set(0, HL.normal, { bg = c.bg_dark })
		set(0, HL.title, { fg = c.blue, bold = true }) -- heading fallback (unused when NPILL>0)
		set(0, HL.key, { fg = c.blue, bold = true })
		set(0, HL.rule, { fg = c.fg_gutter })
		set(0, HL.sep, { fg = c.comment })
		set(0, HL.footer, { fg = c.comment, italic = true })
	else
		-- bare-box fallback: link to semantic groups every colorscheme defines (previous behavior).
		NPILL = 0
		set(0, HL.normal, { link = "NormalFloat", default = true })
		set(0, HL.title, { link = "Title", default = true })
		set(0, HL.key, { link = "Constant", default = true })
		set(0, HL.rule, { link = "Comment", default = true })
		set(0, HL.sep, { link = "Comment", default = true })
		set(0, HL.footer, { link = "Comment", default = true })
	end
end

-- Build one card into an array of "rich lines" ({ text = str, hls = { {s,e,hl}, ... } }) where s/e
-- are BYTE offsets local to that line. Multibyte (the ─ rule) is fine because everything downstream
-- measures with #str (bytes) for offsets and strdisplaywidth() for padding.
local function build_card(section, idx)
	local lines = {}
	local function rich(text, hls)
		table.insert(lines, { text = text, hls = hls or {} })
	end

	-- widest key column, so descriptions align within the card
	local keyw = 0
	for i = 2, #section do
		keyw = math.max(keyw, vim.fn.strdisplaywidth(section[i][1]))
	end
	keyw = math.min(keyw, CARD_W - 6) -- never let keys eat the whole card

	-- Heading as a full-width PILL: one leading space, title, padded to the card width, and the whole
	-- run painted with a cycling accent group (black bold text on a vivid bar) — NvChad's grid look.
	-- Falls back to the plain HL.title span on a bare box where no pill groups were defined.
	local head = " " .. section[1]
	local pad = CARD_W - vim.fn.strdisplaywidth(head)
	if pad > 0 then
		head = head .. string.rep(" ", pad)
	end
	local head_hl = NPILL > 0 and ("GerrrtCheatPill" .. ((idx - 1) % NPILL + 1)) or HL.title
	rich(head, { { s = 0, e = #head, hl = head_hl } })

	for i = 2, #section do
		local key, desc = section[i][1], section[i][2]
		local kw = vim.fn.strdisplaywidth(key)
		local keycell = key .. string.rep(" ", math.max(1, keyw - kw + 2))
		-- truncate desc so key + desc never overflows the card
		local avail = CARD_W - vim.fn.strdisplaywidth(keycell)
		if vim.fn.strdisplaywidth(desc) > avail and avail > 1 then
			desc = vim.fn.strcharpart(desc, 0, avail - 1) .. "…"
		end
		local text = keycell .. desc
		rich(text, { { s = 0, e = #keycell, hl = HL.key } })
	end

	rich("", {}) -- trailing spacer row between stacked cards
	return lines
end

-- Pack cards into `ncol` columns, shortest-first. Returns the columns (each a list of rich lines)
-- and the tallest column height.
local function pack(cards, ncol)
	local cols, heights = {}, {}
	for c = 1, ncol do
		cols[c], heights[c] = {}, 0
	end
	for _, card in ipairs(cards) do
		-- pick the currently shortest column (ties → leftmost, so reading order stays natural)
		local target = 1
		for c = 2, ncol do
			if heights[c] < heights[target] then
				target = c
			end
		end
		for _, line in ipairs(card) do
			table.insert(cols[target], line)
		end
		heights[target] = heights[target] + #card
	end
	local tallest = 0
	for c = 1, ncol do
		tallest = math.max(tallest, heights[c])
	end
	return cols, tallest
end

-- Merge the packed columns into flat buffer lines + a flat highlight list (0-indexed rows, byte
-- cols) ready for nvim_buf_set_lines / nvim_buf_set_extmark.
local function compose(cols, height)
	local ncol = #cols
	local out_lines, out_hls = {}, {}
	for row = 1, height do
		local line = { text = "", hls = {} }
		local function padto(dispcol)
			local cur = vim.fn.strdisplaywidth(line.text)
			if cur < dispcol then
				line.text = line.text .. string.rep(" ", dispcol - cur)
			end
		end
		for c = 1, ncol do
			padto(MARGIN + (c - 1) * (CARD_W + GUTTER))
			local cell = cols[c][row]
			if cell then
				local base = #line.text -- byte offset where this cell starts
				for _, h in ipairs(cell.hls) do
					table.insert(line.hls, { s = base + h.s, e = base + h.e, hl = h.hl })
				end
				line.text = line.text .. cell.text
			end
		end
		table.insert(out_lines, line.text)
		for _, h in ipairs(line.hls) do
			table.insert(out_hls, { row = row - 1, s = h.s, e = h.e, hl = h.hl })
		end
	end
	return out_lines, out_hls
end

function M.open()
	define_highlights()

	-- decide column count from available width
	local max_w = math.floor(vim.o.columns * 0.92)
	local ncol = math.max(1, math.floor((max_w - MARGIN * 2 + GUTTER) / (CARD_W + GUTTER)))
	ncol = math.min(ncol, #M.sections)

	local cards = {}
	for i, s in ipairs(M.sections) do
		table.insert(cards, build_card(s, i))
	end

	local cols, tallest = pack(cards, ncol)
	local lines, hls = compose(cols, tallest)

	local content_w = MARGIN * 2 + ncol * CARD_W + (ncol - 1) * GUTTER
	local footer = "q / <Esc> close   •   <C-d> / <C-u> scroll"
	table.insert(lines, "")
	table.insert(lines, string.rep(" ", MARGIN) .. footer)
	table.insert(hls, { row = #lines - 1, s = MARGIN, e = MARGIN + #footer, hl = HL.footer })

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	local ns = vim.api.nvim_create_namespace("gerrrt_cheatsheet")
	for _, h in ipairs(hls) do
		-- nvim_buf_add_highlight is deprecated (0.11+); set_extmark is the exact equivalent
		vim.api.nvim_buf_set_extmark(buf, ns, h.row, h.s, { end_col = h.e, hl_group = h.hl })
	end
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "cheatsheet"
	vim.bo[buf].bufhidden = "wipe"

	-- The rounded border adds a cell on every side, so the *outer* window is width+2 × height+2.
	-- Clamp the inner size to columns-4 / lines-4 (border + a 1-cell margin) so nvim_open_win can
	-- never be asked for a float larger than the grid — which would error on a very small terminal.
	local width = math.max(1, math.min(content_w, vim.o.columns - 4))
	local height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.9), vim.o.lines - 4))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = "  gerrrt • cheatsheet ",
		title_pos = "center",
	})
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = false
	-- Paint the panel as a solid card (NvChad's cheatsheet is opaque). Only NormalFloat is
	-- remapped; the border/title keep the config-wide FloatBorder/FloatTitle tint.
	vim.wo[win].winhighlight = "NormalFloat:" .. HL.normal

	-- close keys — the buffer wipes on hide, so just close the window
	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end, { buffer = buf, nowait = true, silent = true })
	end
end

return M
