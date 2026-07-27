-- ================================================================================================
-- TITLE : rustaceanvim | batteries-included Rust (LSP + DAP via rust-analyzer)
-- LINKS : https://github.com/mrcjkb/rustaceanvim
-- ================================================================================================
-- NOTE: no on_attach is passed to rustaceanvim's server below. Buffer-local LSP keymaps
-- (K, gd, gr, <leader>ca, ...) are applied globally by the LspAttach autocmd in
-- config/autocmds.lua, which fires for rust-analyzer like every other server — so Rust gets
-- the same maps for free. (Passing utils/lsp.on_attach here used to be a no-op: rustaceanvim
-- calls server.on_attach with the classic (client, bufnr) signature, but that function expects
-- an LspAttach *event* table and early-returns on anything else.)
local config = function()
	-- Rust's debug entry point. Since dap.autoload_configurations is off (see the note below), this
	-- is what materialises rust-analyzer's debuggables — it replaces <leader>dc as the way to START
	-- a Rust session; everything after (breakpoints, stepping, scopes) is the normal <leader>d* set
	-- from plugins/nvim-dap.lua.
	--
	-- Bound HERE rather than in a lazy `keys` entry: this spec already loads on `ft = "rust"`, and a
	-- lazy `keys` entry is a LOAD TRIGGER — once the plugin is loaded by a different trigger,
	-- lazy.nvim drops the stub and expects the plugin to own the mapping, which rustaceanvim does
	-- not. Defining it in config means it exists exactly when rustaceanvim is active (verified: the
	-- keys-entry version silently never mapped).
	vim.keymap.set("n", "<leader>dR", "<cmd>RustLsp debuggables<cr>", { desc = "Rust debuggables (start)" })

	vim.g.rustaceanvim = {
		tools = { hover_actions = { auto_focus = true } },
		server = {
			default_settings = {
				["rust-analyzer"] = { cargo = { allFeatures = true } },
			},
		},
		dap = {
			-- Do NOT materialise Rust debug configurations on LSP attach.
			--
			-- rustaceanvim defaults this to true (config/internal.lua), and on rust-analyzer attach
			-- lsp/init.lua calls add_dap_debuggables(), which `require('dap')`. Under lazy.nvim that
			-- module access AUTOLOADS nvim-dap and its dependency — so merely opening a Rust file
			-- pulled in the whole DAP stack, and the debuggables request can kick off background
			-- `cargo` work to enumerate targets. Measured before this line: opening a .rs file
			-- reported `nvim-dap loaded = true, nvim-dap-python loaded = true`.
			--
			-- That silently contradicted the "loads only on debug keymaps" contract in
			-- plugins/nvim-dap.lua.
			--
			-- TRADEOFF, stated plainly: with autoload off, a bare `<leader>dc` (dap.continue) does
			-- NOT see rust-analyzer's debuggables, because nothing has asked for them yet. Rust
			-- debugging therefore goes through rustaceanvim's own entry points, which load the
			-- configurations on demand — `<leader>dR` below (:RustLsp debuggables) to pick a target,
			-- or :RustLsp debug. Once loaded, the normal dap keymaps (step/breakpoint/scopes) apply
			-- as usual. Prefer the old behaviour? Set this back to true and accept that opening any
			-- .rs file loads the DAP stack and may trigger background cargo work.
			autoload_configurations = false,
			adapter = {
				type = "executable",
				-- Prefer lldb-dap on PATH. Only consult `xcrun -f lldb-dap` on macOS (and only if
				-- xcrun actually exists) — on Linux/Kali xcrun is absent and its error text would
				-- otherwise become the adapter command. Final fallback is the bare name so the
				-- failure is a clean "not found" rather than executing garbage.
				command = (function()
					if vim.fn.exepath("lldb-dap") ~= "" then
						return "lldb-dap"
					end
					if vim.fn.has("mac") == 1 and vim.fn.executable("xcrun") == 1 then
						local p = vim.fn.trim(vim.fn.system({ "xcrun", "-f", "lldb-dap" }))
						if vim.v.shell_error == 0 and p ~= "" then
							return p
						end
					end
					return "lldb-dap"
				end)(),
				name = "rt_lldb",
			},
		},
	}
end

return {
	"mrcjkb/rustaceanvim",
	-- ^8, bumped from ^6: the v6 line calls vim.lsp.get_buffers_by_client_id() (deprecated,
	-- removed in Nvim 0.13) in server_status.lua — v6.9.7 still has it, so :Lazy would keep
	-- reverting a lockfile bump back into the warning. The fix ("update function call deprecated
	-- in nightly") landed in v7.0.0. Pinned to ^8 rather than ^9 deliberately: v9's ONLY breaking
	-- change is dropping Neovim 0.11 support, and Core vendors to a fleet that may not all be on
	-- 0.12 yet — v8 keeps the fix AND `neovim >= 0.11`. The v7/v8 breaking changes (ra-multiplex →
	-- lspmux; drop .vscode/settings.json) don't touch this config (no ra-multiplex; settings come
	-- from server.default_settings below). Move to ^9 once the whole fleet is on Neovim >= 0.12.
	version = "^8",
	ft = "rust",
	config = config,
}
