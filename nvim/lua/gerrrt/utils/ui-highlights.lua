-- ================================================================================================
-- TITLE : ui-highlights | NvChad-flavored highlight overrides
-- ABOUT : The "clean up the chrome" layer of the NvChad look — hairline window splits, minimal
--         rounded floating windows, and a finder/completion palette that reads as one system.
--         This is deliberately a FLAT table of `nvim_set_hl`-style overrides, not a helper
--         framework: one function, one pass, no nested state.
-- WHY HERE (not a ColorScheme autocmd): tokyonight calls `on_highlights(hl, c)` on every
--         `:colorscheme`, so routing through it (see plugins/theme.lua) makes these overrides
--         RELOAD-SAFE and PALETTE-AWARE for free — `c` is tokyonight's already-resolved palette,
--         so swapping `style`/theme recolors everything below without touching this file.
--         Mutating the `hl` table is exactly how tokyonight wants overrides applied; any key
--         added here (incl. plugin groups like FzfLua*/BlinkCmp*) is passed to nvim_set_hl.
-- TRANSPARENCY: theme.lua runs `transparent = true`, so backgrounds are `NONE` throughout —
--         borders are TINTED, never boxed, which is the core of NvChad's minimal float look.
-- ================================================================================================
local M = {}

-- hl : tokyonight's highlights table (mutate in place)
-- c  : tokyonight's resolved color palette (bg_visual, border, blue, ...)
function M.apply(hl, c)
	local none = "NONE"

	-- ── carried over from the previous inline on_highlights ─────────────────────────────────
	hl.Visual = { bg = c.bg_visual }
	hl.Comment = { fg = c.comment, italic = true }

	-- ── window splits: one soft hairline instead of a heavy divider ──────────────────────────
	hl.WinSeparator = { fg = c.border, bg = none }
	hl.VertSplit = { fg = c.border, bg = none }

	-- ── floating windows: minimal, rounded, border-tinted (LSP hover, diagnostics, :help) ────
	hl.NormalFloat = { bg = none }
	hl.FloatBorder = { fg = c.border_highlight, bg = none }
	hl.FloatTitle = { fg = c.blue, bg = none, bold = true }

	-- ── fzf-lua: NvChad's minimal finder — border tint = accent, titles = accents, no boxes ──
	hl.FzfLuaNormal = { bg = none }
	hl.FzfLuaBorder = { fg = c.border_highlight, bg = none }
	hl.FzfLuaTitle = { fg = c.blue, bg = none, bold = true }
	hl.FzfLuaPreviewNormal = { bg = none }
	hl.FzfLuaPreviewBorder = { fg = c.border_highlight, bg = none }
	hl.FzfLuaPreviewTitle = { fg = c.purple, bg = none, bold = true }
	hl.FzfLuaCursorLine = { bg = c.bg_highlight, bold = true }
	hl.FzfLuaCursorLineNr = { fg = c.blue }
	hl.FzfLuaHeaderText = { fg = c.red }
	hl.FzfLuaHeaderBind = { fg = c.yellow }
	hl.FzfLuaScrollBorderFull = { fg = c.border_highlight }
	hl.FzfLuaScrollBorderEmpty = { fg = c.fg_gutter }

	-- ── blink.cmp: rounded menu + docs float that match the floats above ─────────────────────
	hl.BlinkCmpMenu = { bg = none }
	hl.BlinkCmpMenuBorder = { fg = c.border_highlight, bg = none }
	hl.BlinkCmpDoc = { bg = none }
	hl.BlinkCmpDocBorder = { fg = c.border_highlight, bg = none }
	hl.BlinkCmpSignatureHelp = { bg = none }
	hl.BlinkCmpSignatureHelpBorder = { fg = c.border_highlight, bg = none }
	hl.BlinkCmpLabelMatch = { fg = c.blue, bold = true }

	-- ── blink.cmp kind icons: NvChad's colored-kind look. blink draws each item's kind icon (and the
	-- trailing kind text column) with the group `BlinkCmpKind<Kind>`; coloring those by semantic role
	-- gives the menu NvChad's rainbow kind column. Grouped so related kinds share a palette accent
	-- (func=blue, var=magenta, type=yellow, keyword=purple, const/value=orange, text=green, misc=cyan).
	local kind_palette = {
		{ c.blue, { "Function", "Method", "Constructor" } },
		{ c.magenta, { "Variable", "Field", "Property" } },
		{ c.yellow, { "Class", "Struct", "Interface", "Enum", "EnumMember", "TypeParameter", "Event" } },
		{ c.purple, { "Keyword", "Operator" } },
		{ c.orange, { "Constant", "Value", "Unit" } },
		{ c.green, { "Text", "String", "Snippet" } },
		{ c.cyan, { "Module", "File", "Folder", "Reference", "Color" } },
	}
	for _, spec in ipairs(kind_palette) do
		local color, kinds = spec[1], spec[2]
		for _, kind in ipairs(kinds) do
			hl["BlinkCmpKind" .. kind] = { fg = color }
		end
	end

	-- ── LSP renamer float (utils/renamer.lua): NvChad tints the rename prompt's border git-red as a
	-- "this edits everything" cue, with a matching bold red title. Border/title only; the body uses the
	-- normal float bg so the input text stays readable.
	hl.GerrrtRenamerBorder = { fg = c.red, bg = none }
	hl.GerrrtRenamerTitle = { fg = c.red, bg = none, bold = true }

	-- ── which-key: NvChad's palette on the minimal rounded float — blue keys, red descriptions, ──
	-- green groups, dim separators. Border/title tint match the LSP + finder floats above so every
	-- popup in the config reads as one system. (Layout/border geometry is set in plugins/which-key.lua.)
	hl.WhichKey = { fg = c.blue } -- the key itself
	hl.WhichKeyGroup = { fg = c.green } -- a +prefix group (e.g. "+git")
	hl.WhichKeyDesc = { fg = c.red } -- the action description
	hl.WhichKeySeparator = { fg = c.comment } -- the → between key and desc
	hl.WhichKeyValue = { fg = c.green }
	hl.WhichKeyNormal = { bg = none }
	hl.WhichKeyBorder = { fg = c.border_highlight, bg = none }
	hl.WhichKeyTitle = { fg = c.blue, bg = none, bold = true }


	-- noice.nvim (plugins/noice-nvim.lua): the floating command-line popup + wildmenu, tinted +
	-- transparent to match the other floats above. (Only these two views are enabled.)
	hl.NoiceCmdlinePopup = { bg = none }
	hl.NoiceCmdlinePopupBorder = { fg = c.border_highlight, bg = none }
	hl.NoiceCmdlinePopupTitle = { fg = c.blue, bg = none, bold = true }
	hl.NoiceCmdlineIcon = { fg = c.blue }
	hl.NoiceCmdlineIconSearch = { fg = c.yellow }
	hl.NoicePopupmenu = { bg = none }
	hl.NoicePopupmenuBorder = { fg = c.border_highlight, bg = none }
	hl.NoicePopupmenuSelected = { bg = c.bg_highlight, fg = c.blue, bold = true }

	-- ── nvim-dap (plugins/nvim-dap.lua): breakpoint + stopped-line gutter signs ──────────────
	-- Breakpoints are git-red like the renamer border (both mean "this is consequential"), the
	-- conditional variant is amber to read as "sometimes", and the stopped frame is green with a
	-- tinted line so the current execution point is unmistakable against the cursorline.
	hl.DapBreakpoint = { fg = c.red }
	hl.DapBreakpointCondition = { fg = c.yellow }
	hl.DapLogPoint = { fg = c.blue }
	hl.DapStopped = { fg = c.green }
	hl.DapStoppedLine = { bg = c.bg_visual }

	-- ── gutter: NvChad's dim line numbers with a bright, obvious current line ────────────────
	hl.LineNr = { fg = c.fg_gutter }
	hl.CursorLineNr = { fg = c.orange, bold = true }
end

return M
