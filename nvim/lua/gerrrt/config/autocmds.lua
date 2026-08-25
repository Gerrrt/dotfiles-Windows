-- ================================================================================================
-- TITLE : auto-commands
-- ABOUT : automatically run code on defined events (e.g. save, yank)
-- ================================================================================================
local on_attach = require("gerrrt.utils.lsp").on_attach

-- ================================================================================================
-- User FilePost — "a real file is open AND the UI has painted"
-- ================================================================================================
-- WHY : BufReadPre/BufReadPost fire BEFORE the first UI paint, so every plugin hung off them sits
--       between launching nvim and SEEING your file. Measured on this config, that was ~125ms of
--       nvim-lspconfig + gitsigns + nvim-lint + todo-comments on the critical path. This event
--       re-hangs that work AFTER the first paint, so the file appears immediately and the machinery
--       arrives a frame later. (The idea is NvChad's `User FilePost`; the implementation is ours.)
--
-- CONTRACT : fires exactly ONCE per session, only when
--              • the buffer is a real file (non-empty name), and
--              • it isn't a utility buffer (buftype ~= "" / "help"), and
--              • the UI has attached (UIEnter has run).
--            The augroup deletes itself on the first successful fire, so there is zero ongoing cost
--            — no lingering autocmd re-checking these conditions on every later buffer.
--
-- MEASURED on this config (`nvim file.lua`, real TTY): BufReadPre 43ms, BufReadPost 44ms,
--            VimEnter 126ms, UIEnter 131ms. So the plugins below moved from ~44ms to ~131ms —
--            ~87ms of work lifted out of the window before the UI is ready.
--
-- WHY BOTH UIEnter AND VimEnter — AND WHY THEY ARE NOT INTERCHANGEABLE : UIEnter is the precise
--            "a UI attached" signal and is the one we want interactively, but it NEVER FIRES under
--            `nvim --headless` — which is how scripts, CI, and this repo's own audit
--            (scripts/test-core.sh) run Neovim. Gating on UIEnter alone silently meant no LSP, no
--            gitsigns and no linting in every headless session.
--
--            But VimEnter must NOT be accepted as readiness when a UI exists. Per the timings above
--            it lands ~5ms BEFORE UIEnter, and with `nvim file.lua` the buffer is already named by
--            then — so treating it as ready would fire FilePost at ~126ms instead of ~131ms, pulling
--            all four plugins back in front of the first paint and giving away part of the win this
--            whole change exists to get. VimEnter is therefore accepted ONLY when there is genuinely
--            no UI to wait for (`nvim_list_uis()` is empty), i.e. real headless. In a TTY a UI is
--            already attached well before VimEnter (uis == 1 as early as BufReadPre), so the check
--            reliably distinguishes the two.
--            (NvChad gates on UIEnter only; they don't run headless LSP tests, so they never hit it.)
--
-- BOTH ORDERS ARE HANDLED : with `nvim file.lua`, BufReadPost fires long before VimEnter/UIEnter;
--            with a bare `nvim` it's the reverse (and the empty buffer has no name, so nothing fires
--            until you actually open something). Whichever event arrives LAST finds the conditions
--            satisfied and does the work — which is why the startup events only set a flag rather
--            than firing FilePost directly.
--
-- NO FileType REPLAY NEEDED : plugins loading here have missed this buffer's FileType. NvChad
--            compensates with a blunt global `nvim_exec_autocmds("FileType", {})` re-fire, which on
--            this config would re-run every FileType handler across 285 registered autocmds. We
--            deliberately do NOT do that — each migrated plugin already self-attaches to open
--            buffers, verified individually:
--              • vim.lsp.enable() re-runs `doautoall nvim.lsp.enable FileType` whenever it's called
--                after startup (neovim runtime lua/vim/lsp.lua — the `vim_did_enter` branch),
--              • gitsigns iterates nvim_list_bufs() in its setup,
--              • todo-comments attaches to all bufs in visible windows,
--              • nvim-lint replays the triggering buffer ITSELF at the end of its config()
--                (plugins/nvim-lint.lua) — so it needs no help from this event either, but it
--                DOES need mason.nvim loaded before that replay spawns a Mason-installed
--                linter. Load order within one dispatch does not supply that; nvim-lint's own
--                `dependencies` does, which is why the spec declares mason there (#652).
--            A plugin that needs options set AT READ TIME (vim-sleuth) must NOT be moved here, and
--            one that is already `ft`-gated (nvim-colorizer) is better off staying that way.
local filepost_group = vim.api.nvim_create_augroup("GerrrtFilePost", { clear = true })
vim.api.nvim_create_autocmd({ "UIEnter", "VimEnter", "BufReadPost", "BufNewFile" }, {
  group = filepost_group,
  callback = function(args)
    -- UIEnter always means ready. VimEnter only counts when no UI will ever attach (headless) —
    -- see the "WHY THEY ARE NOT INTERCHANGEABLE" note above; accepting it in a TTY would fire
    -- FilePost ~5ms early, back in front of the first paint.
    if args.event == "UIEnter" or (args.event == "VimEnter" and #vim.api.nvim_list_uis() == 0) then
      vim.g.startup_done = true
    end
    if not vim.g.startup_done then
      return
    end
    if vim.api.nvim_buf_get_name(args.buf) == "" then
      return -- scratch / unnamed (e.g. the empty buffer of a bare `nvim`)
    end
    local buftype = vim.bo[args.buf].buftype
    if buftype ~= "" and buftype ~= "help" then
      return -- terminal, quickfix, prompt, nofile, ...
    end
    -- Delete FIRST, then fire on the next event-loop tick — both halves are load-bearing.
    --
    -- WHY THE FIRE IS DEFERRED (vim.schedule) : firing FilePost synchronously here runs the whole
    -- deferred-plugin load INSIDE this buffer's BufReadPost chain whenever the first real file
    -- arrives AFTER startup (bare `nvim` → dashboard/:e/picker — i.e. most sessions). Loading
    -- nvim-lspconfig calls vim.lsp.enable(), which post-startup replays `doautoall nvim.lsp.enable
    -- FileType`; that nested, group-scoped FileType trigger sets Vim's global did_filetype flag for
    -- the STILL-RUNNING BufReadPost sequence. The runtime's filetypedetect handler — registered at
    -- end of startup, so AFTER this one — then calls `:setf lua`, and setf is a documented no-op
    -- once did_filetype() is true. Net effect: the FIRST file opened in a bare session got NO
    -- filetype at all — no syntax/treesitter highlighting, no LSP attach, no linter — while every
    -- later buffer worked (this augroup had deleted itself, so nothing poisoned their chains).
    -- Scheduling moves the plugin burst to after the chain completes, so setf runs unpoisoned —
    -- and the file paints one tick sooner, which is this event's whole purpose anyway. The
    -- self-attach contract is unchanged: vim.lsp.enable's replay picks the buffer up a tick later.
    --
    -- WHY THE DELETE COMES BEFORE THE FIRE : exactly-once must hold even if a second BufReadPost
    -- lands in the window between scheduling and the tick running (e.g. two quick :edits) — the
    -- group must already be gone by then, not merely doomed.
    vim.api.nvim_del_augroup_by_name("GerrrtFilePost")
    vim.schedule(function()
      vim.api.nvim_exec_autocmds("User", { pattern = "FilePost", modeline = false })
    end)
  end,
})

-- Restore last cursor position when reopening a file
local last_cursor_group = vim.api.nvim_create_augroup("LastCursorGroup", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", {
  group = last_cursor_group,
  callback = function()
    -- Commit/rebase buffers should open at the top (you're writing a new message / editing the
    -- todo list), not wherever the cursor last sat in a previous commit — skip the restore there.
    local ft = vim.bo.filetype
    if ft == "gitcommit" or ft == "gitrebase" then
      return
    end
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    local lcount = vim.api.nvim_buf_line_count(0)
    if mark[1] > 0 and mark[1] <= lcount then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Highlight the yanked text for 200ms
local highlight_yank_group = vim.api.nvim_create_augroup("HighlightYank", { clear = true })
vim.api.nvim_create_autocmd("TextYankPost", {
  group = highlight_yank_group,
  pattern = "*",
  callback = function()
    -- TextYankPost fires on yanks AND deletes, so a bad call here throws E5108 on every such
    -- edit — the op still runs, but a red error trails it. Hence the capability probe rather
    -- than a hard-coded name.
    --
    -- VERSION-GATED, NOT SWAPPED. `vim.hl.on_yank` is correct on 0.12 and is what this config
    -- has always called. On Neovim HEAD (0.13-dev) it is deprecated in favour of `vim.hl.hl_op`
    -- (runtime lua/vim/hl.lua: `vim.deprecate('vim.hl.on_yank', 'vim.hl.hl_op', '0.14')`), which
    -- also serves the new TextPutPost event. But hl_op does NOT exist on 0.12.4 — verified — so
    -- a straight rename would break every machine still on stable. Core is vendored to a
    -- ten-repo fleet that will not upgrade in lockstep, so probe for the new name and fall back.
    -- When the whole fleet is on 0.13+, collapse this to a bare vim.hl.hl_op call.
    local hl = vim.hl.hl_op or vim.hl.on_yank
    hl({
      higroup = "IncSearch",
      timeout = 200,
    })
  end,
})

-- Format on save: trim trailing whitespace, then run conform.
-- lsp_format = "fallback" means filetypes without a conform formatter still get
-- formatted by their LSP (e.g. gopls), and filetypes with neither are left alone.
local lsp_fmt_group = vim.api.nvim_create_augroup("FormatOnSaveGroup", { clear = true })
vim.api.nvim_create_autocmd("BufWritePre", {
  group = lsp_fmt_group,
  callback = function(args)
    -- pcall-guarded: on a fresh box (or if mini failed to load) a bare require().trim() would
    -- throw here and abort the whole BufWritePre before conform ever runs, breaking `:w`. mini
    -- loads on VeryLazy so this is rare, but the rest of Core guards cross-plugin calls the same way.
    pcall(function()
      require("mini.trailspace").trim()
    end)
    -- Never auto-format zsh. shfmt (whether reached through conform OR through the
    -- lsp_format="fallback" path via bash-language-server, which shells out to shfmt)
    -- parses zsh as bash and silently corrupts zsh-only syntax. Skipping by FILETYPE
    -- (not a single filename) protects every zsh file in Core, not just plugins.zsh.
    -- Trailing-whitespace trim above already ran, so zsh still gets that.
    if vim.bo[args.buf].filetype == "zsh" then
      return
    end
    require("conform").format({ bufnr = args.buf, lsp_format = "fallback", timeout_ms = 1500 })
  end,
})

-- Python: buffer-local pytest runners via uv. Plugin-free ON PURPOSE — this config avoids the
-- heavy test-runner stack (no neotest, matching the no-dap-ui/no-toggleterm stance elsewhere); a
-- split terminal running `uv run pytest` covers the daily "run this" loop and complements the DAP
-- "debug test method" (<leader>dm, plugins/nvim-dap.lua). BUFFER-LOCAL (attached on FileType
-- python) so the <leader>t prefix stays free for every other filetype.
--
-- GATED on `uv` being present — like the uvr/uvs zsh aliases (HAVE_UV). Without it the maps would
-- only ever advertise a command that opens a failed terminal, so we simply don't create them.
-- Re-probed per attach, so installing uv mid-session takes effect on the next Python buffer.
local py_test_group = vim.api.nvim_create_augroup("PyTestRunner", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = py_test_group,
  pattern = "python",
  callback = function(args)
    if vim.fn.executable("uv") ~= 1 then
      return
    end
    local function pytest(target)
      vim.cmd("update") -- write a modified buffer first (like vim-test) so pytest sees latest edits
      -- Run in the uv PROJECT ROOT, not Neovim's cwd. autochdir is off (config/options.lua), so a
      -- file opened from elsewhere would otherwise make uv resolve the wrong project. Same root
      -- markers the lualine venv component uses (plugins/lualine-nvim.lua).
      local root = vim.fs.root(args.buf, { { "uv.lock", "pyproject.toml" }, ".git" }) or vim.fn.getcwd()
      -- argv FORM, never a shell string: a filename with spaces or shell metacharacters (`;`, `&`,
      -- …) is passed as one literal argument and cannot be re-parsed or injected — which
      -- fnameescape() (Ex-syntax only) would NOT have prevented through `:terminal`'s shell.
      local argv = { "uv", "run", "pytest" }
      if target then
        argv[#argv + 1] = target
      end
      -- Fresh scratch buffer in a bottom split, then attach the terminal job to it.
      vim.cmd("botright split | enew | resize 15")
      local jid = vim.fn.jobstart(argv, { cwd = root, term = true })
      if jid <= 0 then
        vim.notify("Test: failed to start `uv run pytest`", vim.log.levels.ERROR, { title = "Test" })
        return
      end
      -- The startinsert below leaves you in terminal mode, where this split swallows Core's
      -- <C-h/j/k/l> exactly as Claude's does — and since `:q` needs normal mode, even CLOSING it
      -- requires <C-\><C-n> first. Give it the same escape hatch; see utils/term.lua for why the
      -- maps ride <M-…> rather than widening the navigator's own keys. jobstart(term=true) leaves
      -- the terminal buffer current, so this is the buffer we just created.
      require("gerrrt.utils.term").map_navigation(vim.api.nvim_get_current_buf(), "test output")
      vim.cmd("startinsert") -- so output scrolls live
    end
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = args.buf, silent = true, desc = desc })
    end
    map("<leader>tt", function()
      pytest(nil)
    end, "Test: pytest (whole suite)")
    map("<leader>tf", function()
      -- Resolve the path NOW, before the split changes the current buffer.
      pytest(vim.fn.expand("%:p"))
    end, "Test: pytest (current file)")
  end,
})

-- on attach function shortcuts
local lsp_on_attach_group = vim.api.nvim_create_augroup("LspMappings", { clear = true })
vim.api.nvim_create_autocmd("LspAttach", {
  group = lsp_on_attach_group,
  callback = on_attach,
})

-- Teach Neovim the `buf-config` filetype that buf_ls advertises (servers/buf_ls.lua lists
-- `filetypes = { "proto", "buf-config" }`). Nothing in stock Neovim maps buf's own config files to
-- that name, so two things were true at once: `:checkhealth vim.lsp` flagged `buf-config` as an
-- "Unknown filetype" (its known-set comes from vim.filetype._get_known_filetypes(), which DOES read
-- vim.filetype.add() registrations), AND buf_ls never attached to buf.yaml / buf.gen.yaml because
-- they stayed `yaml`. Mapping the buf-specific filenames fixes both: the ft becomes known (the
-- health warning is gone) and buf_ls now serves these files with buf-aware completion/diagnostics —
-- the language server's intended job. The set is buf's full v2 config surface (buf.yaml,
-- buf.gen.yaml, buf.work.yaml, buf.policy.yaml) plus the buf.lock dependency lock. They no longer
-- load as `yaml`, so yamlls steps aside here (buf_ls is the better fit for buf config).
vim.filetype.add({
  filename = {
    ["buf.yaml"] = "buf-config",
    ["buf.gen.yaml"] = "buf-config",
    ["buf.work.yaml"] = "buf-config",
    ["buf.policy.yaml"] = "buf-config",
    ["buf.lock"] = "buf-config",
  },
})
-- Highlighting: these are all YAML, so alias the buf-config filetype to the yaml PARSER rather than
-- starting treesitter ourselves. plugins/nvim-treesitter.lua (main branch) drives highlighting from
-- its OWN FileType handler via `vim.treesitter.language.get_lang(ft)` → start-if-installed; with
-- this register call get_lang resolves buf-config→yaml, so that existing install/start lifecycle
-- lights these buffers up — including its already-loaded-buffer sweep and a yaml parser that only
-- lands after a fresh-box ensure_installed pass. Starting the parser here on FileType instead would
-- miss the not-yet-installed case (FileType fires before the parser arrives, and never retries).
vim.treesitter.language.register("yaml", "buf-config")

-- custom options for text/markdown files
local markdown_options = vim.api.nvim_create_augroup("MarkdownOptions", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = markdown_options,
  pattern = { "markdown", "text", "gitcommit" },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
    vim.opt_local.relativenumber = false
    vim.opt_local.number = false
    vim.opt_local.cursorline = false
    -- Mark this buffer as opting out of cursorline so the ActiveCursorline toggle (below) won't
    -- re-enable it on a later BufEnter — FileType only fires once, but BufEnter fires on every
    -- revisit, and without this flag switching back to a markdown/text/gitcommit buffer would
    -- clobber the `cursorline = false` set here.
    vim.b.disable_cursorline = true
    vim.opt_local.colorcolumn = ""
    vim.opt_local.signcolumn = "no"
    vim.opt_local.conceallevel = 2 -- conceal markup (link/bold markers); moved here from global options
    vim.opt_local.concealcursor = "" -- still show markup on the cursor line
  end,
})

-- Notify when the tracked upstream is ahead of HEAD, so you know to rebase/pull before starting.
-- Async `git fetch` on VimEnter so startup never blocks. Gated on dotfiles_offline (engagement
-- boxes) — same switch that already silences lazy's checker and mason, so this never emits
-- unattended network traffic on a Kali/Defense box. Routes through vim.notify -> mini.notify,
-- so the toast matches the rest of the UI for free.
if not vim.g.dotfiles_offline then
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("GitRemoteAhead", { clear = true }),
    callback = function()
      -- Capture the startup cwd ONCE. Every git call below runs pinned to it (cwd = repo), so a
      -- later `:cd` can't silently point the fetch/rev-list at a different repository or report
      -- stale data. vim.system uses argv (no shell) — portable to the Windows host in this config,
      -- which cmd/pwsh `> /dev/null 2>&1` redirection was not.
      local repo = vim.fn.getcwd()
      local function git(args, on_done)
        vim.system(vim.list_extend({ "git" }, args), { cwd = repo, text = true }, on_done)
      end
      -- Chain on SUCCESS only: not-a-repo, a failed fetch (offline/no remote), or no upstream
      -- configured each short-circuit BEFORE we trust a commit count — so we never toast a number
      -- derived from a fetch that didn't actually happen.
      git({ "rev-parse", "--is-inside-work-tree" }, function(inside)
        if inside.code ~= 0 then
          return -- not a git repo
        end
        git({ "fetch" }, function(fetched)
          if fetched.code ~= 0 then
            return -- fetch failed (no network / no remote) — don't report a stale count
          end
          git({ "rev-list", "--count", "HEAD..@{u}" }, function(rev)
            if rev.code ~= 0 then
              return -- no upstream tracking branch configured
            end
            local count = (rev.stdout or ""):gsub("%s+", "")
            if count ~= "" and tonumber(count) and tonumber(count) > 0 then
              vim.schedule(function()
                -- \u{f0662} nf-md-source_branch_sync, written as an escape so the glyph survives
                -- transfer (house convention, matches lualine.lua / diagnostics.lua).
                vim.notify("\u{f0662} " .. count .. " new commit(s) on remote", vim.log.levels.INFO, { title = "Git" })
              end)
            end
          end)
        end)
      end)
    end,
  })
end

-- Show cursorline only in the active window. Pairs with vimade (plugins/vimade.lua): vimade fades
-- inactive splits, this drops their cursorline, together giving a clear "which split is live" cue
-- for the globalstatus + split-heavy workflow. cursorline defaults ON globally (options.lua); this
-- just suppresses it on the windows you're not in.
local active_cursorline_group = vim.api.nvim_create_augroup("ActiveCursorline", { clear = true })
vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  group = active_cursorline_group,
  callback = function()
    -- Respect a buffer's opt-out (set by MarkdownOptions above); everything else lights up.
    vim.opt_local.cursorline = not vim.b.disable_cursorline
  end,
})
vim.api.nvim_create_autocmd("WinLeave", {
  group = active_cursorline_group,
  callback = function()
    vim.opt_local.cursorline = false
  end,
})
