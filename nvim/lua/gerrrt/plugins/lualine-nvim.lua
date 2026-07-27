-- ================================================================================================
-- TITLE : lualine.nvim | statusline (NvChad-styled)
-- LINKS : https://github.com/nvim-lualine/lualine.nvim
-- ABOUT : NvChad's block statusline, rebuilt as a STANDARD lualine config — no NvChad backend,
--         no statusline caching, no managed toggle state. Just lualine's own theming with
--         NvChad's rounded "bubble" separators and section layout:
--           left  : mode (rounded bubble) · git branch · git diff (+~-)
--           center: filename (relative) with modified/readonly markers
--           right : search count · attached LSP servers · diagnostics · filetype · cwd ·
--                   scroll-percentage + location (one rounded bubble)
-- LOOK  : the signature NvChad move is the ROUNDED block — half-circle caps  (U+E0B6) and
--          (U+E0B4) instead of powerline arrows, with NO inner component separators so each
--         half reads as one clean run of blocks. Colors come from a HAND-BUILT theme derived from
--         tokyonight's resolved palette (build_theme below) — not lualine's bundled tokyonight
--         theme — so the blocks map onto NvChad's structure (accent mode/location PILLS at both
--         ends, a lighter git/cwd block, a base filename run) and each section keeps a solid bg,
--         which is what makes the pills read as opaque islands on the transparent bar. Because it
--         pulls from the same palette tokyonight hands `on_highlights` (utils/ui-highlights.lua),
--         it stays theme- and transparency-aware; the tokyonight `style` is resolved once in
--         utils/palette.lua (mirror it in plugins/theme.lua) — both default to "storm".
-- ICONS : All glyphs are written as \u{XXXX} escapes (Nerd Font private-use codepoints),
--         NOT raw glyphs. Raw glyphs get silently stripped when text passes through tools
--         that don't preserve the private-use area; escapes are plain ASCII in the file and
--         decode to the glyph at runtime, so they survive copy/paste/transfer intact.
--         Each escape is named in a trailing comment. Requires a Nerd Font in your terminal.
--         If any single glyph shows as a box (tofu), your font lacks it — swap that codepoint.
--         Diagnostic glyphs are kept IDENTICAL to utils/diagnostics.lua + bufferline so the
--         gutter, tabline and statusline never disagree (this matters more than matching
--         NvChad's exact glyphs — the NvChad look here is the block styling, not the icons).
-- ================================================================================================
return {
	"nvim-lualine/lualine.nvim",
	event = "VeryLazy",
	dependencies = { "nvim-tree/nvim-web-devicons" },
	config = function()
		-- Build a lualine theme from tokyonight's resolved palette so the statusline mirrors NvChad's
		-- St_* block structure: a/z = accent PILLS (mode on the left, cursor location on the right —
		-- lualine feeds theme `a` to both), b/y = a lighter git/cwd block, c/x = the base filename
		-- run. Mode → accent follows NvChad (Normal=blue, Insert=purple, Visual=cyan, Replace=orange,
		-- Command/Terminal=green). Dark text (bg_dark) on the bright accents keeps the pills legible.
		-- pcall so a fresh box where tokyonight hasn't loaded falls back to lualine's bundled theme
		-- rather than aborting the whole statusline.
		local function build_theme()
			-- palette resolved once in utils/palette.lua (single source of the tokyonight `style`);
			-- nil on a fresh box where tokyonight hasn't loaded → fall back to lualine's bundled theme.
			local c = require("gerrrt.utils.palette").colors()
			if type(c) ~= "table" then
				return "tokyonight"
			end
			local base, block = c.bg_dark, c.bg_highlight
			local function mk(accent)
				return {
					a = { fg = c.bg_dark, bg = accent, gui = "bold" },
					b = { fg = c.fg_dark, bg = block },
					c = { fg = c.fg, bg = base },
				}
			end
			return {
				normal = mk(c.blue),
				insert = mk(c.magenta), -- NvChad Insert pill = purple
				visual = mk(c.cyan),
				replace = mk(c.orange),
				command = mk(c.green),
				terminal = mk(c.green),
				inactive = {
					a = { fg = c.comment, bg = base },
					b = { fg = c.comment, bg = base },
					c = { fg = c.comment, bg = base },
				},
			}
		end

		-- The buffer the STATUSLINE is describing — not necessarily the current one.
		-- Neovim sets vim.g.statusline_winid while evaluating a statusline; with globalstatus=true
		-- (set below) there is one bar shared by every window, so reading `0`/current buffer is
		-- subtly wrong whenever the bar is redrawn for a window you aren't in. This is the one
		-- discipline worth taking from NvChad's statusline modules (nvchad/stl/utils.lua does the
		-- same via its stbufnr()). Falls back to the current buffer when the global isn't set.
		local function stbuf()
			local win = vim.g.statusline_winid
			if win and vim.api.nvim_win_is_valid(win) then
				return vim.api.nvim_win_get_buf(win)
			end
			return vim.api.nvim_get_current_buf()
		end

		-- Show the language servers attached to the statusline's buffer.
		-- Width-gated like NvChad does: on a narrow window the server list is the first thing worth
		-- dropping, since the diagnostics counts next to it carry the actionable information.
		local function lsp_servers()
			if vim.o.columns < 100 then
				return ""
			end
			local clients = vim.lsp.get_clients({ bufnr = stbuf() })
			if #clients == 0 then
				return ""
			end
			local names = {}
			for _, client in ipairs(clients) do
				names[#names + 1] = client.name
			end
			return "\u{f085} " .. table.concat(names, ", ") -- f085 nf-fa-cogs
		end

		-- Active Python virtual environment (uv / venv), shown only in Python buffers.
		--
		-- DISPLAY ONLY: this does not configure ty or ruff. ty already discovers <root>/.venv on its
		-- own, so nothing here needs to feed it — this block just answers "which env am I actually
		-- in?" at a glance, which is the thing that silently differs between projects.
		--
		-- CACHED PER BUFFER (vim.b): a statusline component is re-evaluated on every redraw, so the
		-- filesystem walk below must never run inline. It runs once per buffer and the answer is
		-- memoised in vim.b[buf]; everything after that is a table read. Resolution order matches
		-- uv's own: an activated VIRTUAL_ENV wins, then UV_PROJECT_ENVIRONMENT (absolute as-is,
		-- relative to the project root), then <root>/.venv. Presence is probed via pyvenv.cfg rather
		-- than bin/python because that file exists on every platform and cannot be faked by a stray
		-- directory that happens to be named `venv`.
		local function venv_name()
			local buf = stbuf()
			if vim.bo[buf].filetype ~= "python" or vim.o.columns < 90 then
				return ""
			end
			local cached = vim.b[buf].gerrrt_venv
			if cached == nil then
				local resolved = ""
				local ok = pcall(function()
					local active = vim.env.VIRTUAL_ENV
					if active and active ~= "" then
						resolved = active
						return
					end
					local root = vim.fs.root(buf, { { "uv.lock", "pyproject.toml" }, ".git" })
					if not root then
						return
					end
					local candidates = {}
					local upe = vim.env.UV_PROJECT_ENVIRONMENT
					if upe and upe ~= "" then
						-- uv treats an absolute UV_PROJECT_ENVIRONMENT as-is and a relative one as
						-- relative to the project root. Detecting "absolute" with a leading-"/" test
						-- is POSIX-only: on Windows it would misread a drive-qualified path
						-- (C:\envs\proj) or a UNC path (\\server\share) as RELATIVE, join it onto the
						-- root, miss the pyvenv.cfg probe, and silently fall back to .venv — i.e.
						-- report the wrong environment. Accept all three forms.
						local is_abs = upe:sub(1, 1) == "/"
							or upe:match("^%a:[/\\]") ~= nil -- C:\... or C:/...
							or upe:match("^[/\\][/\\]") ~= nil -- \\server\share (UNC)
						candidates[#candidates + 1] = is_abs and upe or vim.fs.joinpath(root, upe)
					end
					candidates[#candidates + 1] = vim.fs.joinpath(root, ".venv")
					for _, dir in ipairs(candidates) do
						if vim.uv.fs_stat(vim.fs.joinpath(dir, "pyvenv.cfg")) then
							resolved = dir
							return
						end
					end
				end)
				cached = ok and resolved or ""
				vim.b[buf].gerrrt_venv = cached
			end
			if cached == "" then
				return ""
			end
			return "\u{f0320} " .. vim.fn.fnamemodify(cached, ":t") -- f0320 nf-md-language_python
		end

		-- (N1: cwd removed — tmux shows the project dir when a pane runs nvim)

		require("lualine").setup({
			options = {
				theme = build_theme(),
				icons_enabled = true,
				globalstatus = true,
				-- NvChad's rounded blocks: half-circle section caps, and NO component separators
				-- (an empty string) so each half is one clean run instead of arrow-chevroned.
				section_separators = { left = "\u{e0b4}", right = "\u{e0b6}" }, -- e0b4  / e0b6
				component_separators = "",
				-- NO `disabled_filetypes = { statusline = { "NvimTree" } }` — it is actively harmful
				-- with globalstatus. lualine checks disabled_filetypes and `return nil`s BEFORE it
				-- consults extensions (lualine.nvim/lua/lualine.lua:298-306), so listing NvimTree
				-- there did two bad things at once: it made the "nvim-tree" entry in `extensions`
				-- (below) permanently unreachable, and — because globalstatus = true means ONE shared
				-- bar — it blanked the statusline for EVERY window whenever the tree held focus.
				-- Verified: with ft=NvimTree focused, lualine.statusline() returned nil.
				-- The extension is the thing that renders a sensible bar for the tree, so keep that
				-- and drop the disable. If you ever do want the bar to vanish over the tree, remove
				-- "nvim-tree" from `extensions` too — but do not set both.
			},
			sections = {
				lualine_a = {
					-- the outer half-circle cap (e0b6) turns the mode block into NvChad's bubble
					{ "mode", separator = { left = "\u{e0b6}" } }, -- e62b nf-custom-vim, e0b6
					-- Macro recording indicator. showmode=false (options.lua) means the cmdline is the
					-- only native cue that you're recording; this surfaces it in the block instead.
					-- Empty string when not recording, so the component collapses and adds no width.
					{
						function()
							local reg = vim.fn.reg_recording()
							return reg == "" and "" or "\u{f111} REC " .. reg:upper() -- f111 nf-fa-circle
						end,
					},
				},
				lualine_b = {
					{ "branch", icon = "\u{e0a0}" }, -- e0a0 powerline branch
					{
						"diff",
						symbols = {
							added = "\u{f067} ", -- f067 nf-fa-plus
							modified = "\u{f111} ", -- f111 nf-fa-circle
							removed = "\u{f068} ", -- f068 nf-fa-minus
						},
					},
				},
				lualine_c = {
					{
						"filename",
						path = 0, -- N2: filename only (dropbar + tmux cwd carry the path)
						symbols = {
							modified = " \u{f111}", -- f111 nf-fa-circle (●-style "unsaved" dot)
							readonly = " \u{f023}", -- f023 nf-fa-lock
							unnamed = "[No Name]",
						},
					},
				},
				lualine_x = {
					{ "searchcount" },
					-- venv sits immediately left of the server list: both answer "what is analysing
					-- this buffer", and in a Python buffer the environment is the more surprising of
					-- the two. Collapses to nothing outside Python, so no width is spent elsewhere.
					{ venv_name, color = { gui = "italic" } },
					{
						lsp_servers,
						color = { gui = "italic" },
					},
					{
						"diagnostics",
						symbols = {
							error = "\u{f057} ", -- f057 nf-fa-times_circle
							warn = "\u{f071} ", -- f071 nf-fa-exclamation_triangle
							info = "\u{f05a} ", -- f05a nf-fa-info_circle
							hint = "\u{f0eb} ", -- f0eb nf-fa-lightbulb
						},
					},
					{ "filetype" },
				},
				lualine_y = {},
				lualine_z = {
					-- Scroll PERCENTAGE through the file — the "how far in am I" cue. lualine's
					-- `progress` renders Top / Bot / NN% (NvChad itself shows line/col here; this is the
					-- one deliberate divergence). The outer half-circle cap (e0b6) opens the right
					-- bubble, mirroring how the mode block opens the left one.
					{ "progress", icon = "\u{f0d7}", separator = { left = "\u{e0b6}" } }, -- f0d7 caret-down, e0b6
					-- location closes the right bubble with e0b4 — progress + location read as one pill.
					{ "location", icon = "\u{e0a1}", separator = { right = "\u{e0b4}" } }, -- e0a1 line-number, e0b4
				},
			},
			inactive_sections = {
				lualine_c = { { "filename", path = 1 } },
				lualine_x = { "location" },
			},
			extensions = { "nvim-tree", "lazy", "quickfix", "trouble", "mason" },
		})
	end,
}
