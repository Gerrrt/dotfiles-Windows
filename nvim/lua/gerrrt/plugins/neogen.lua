-- ================================================================================================
-- TITLE : neogen | generate annotations / docstrings from the symbol under the cursor
-- LINKS : https://github.com/danymat/neogen
-- ABOUT : Put the cursor on a function/class and `<leader>cn` writes the doc skeleton in that
--         language's convention — LuaCATS for Lua, docstrings for Python, JSDoc for TS/JS, godoc
--         for Go, Doxygen for C/C++. Genuinely multi-language (it reads treesitter, which you
--         already run) and it understands LuaSnip placeholders, so it tab-jumps through fields
--         using your existing blink.cmp snippet engine.
-- LAZY  : cmd + keys. Sits under your `<leader>c` (code) group next to code-action/format.
-- ================================================================================================
return {
	"danymat/neogen",
	dependencies = { "nvim-treesitter/nvim-treesitter" },
	cmd = "Neogen",
	keys = {
		{
			"<leader>cn",
			function()
				require("neogen").generate()
			end,
			desc = "Generate annotation / docstring",
		},
	},
	opts = {
		snippet_engine = "luasnip", -- reuse the engine blink.cmp already drives
		-- neogen already generates docs for EVERY language it has a template for, off treesitter,
		-- with no config — so this table only pins the CONVENTION where a language has more than one
		-- (python: google vs numpy/rest; ruby: yard vs rdoc) or where being explicit documents the
		-- house choice. The rust/go/java/php/c/cpp entries mirror neogen's own defaults; they are
		-- listed so `<leader>cn` coverage for the languages this config now targets is legible here.
		languages = {
			python = { template = { annotation_convention = "google_docstrings" } },
			typescript = { template = { annotation_convention = "jsdoc" } },
			typescriptreact = { template = { annotation_convention = "jsdoc" } },
			javascript = { template = { annotation_convention = "jsdoc" } },
			lua = { template = { annotation_convention = "emmylua" } }, -- LuaCATS
			rust = { template = { annotation_convention = "rustdoc" } },
			go = { template = { annotation_convention = "godoc" } },
			java = { template = { annotation_convention = "javadoc" } },
			php = { template = { annotation_convention = "phpdoc" } },
			ruby = { template = { annotation_convention = "yard" } },
			c = { template = { annotation_convention = "doxygen" } },
			cpp = { template = { annotation_convention = "doxygen" } },
		},
	},
}
