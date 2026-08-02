-- nvim/lua/gerrrt/health.lua
-- ─────────────────────────────────────────────────────────────────────────────
-- `:checkhealth gerrrt` — a precise, actionable report for Core's Neovim bits that
-- otherwise fail with a generic message. Two sections:
--   • clipboard  — when no backend exists, `"+y` / `"+p` surface only Neovim's opaque
--     "clipboard provider" error. Here we run the SAME `clip` / `clip-paste` ladder the
--     provider uses and say exactly what's missing and how to fix it.
--   • LSP servers — the built-in `:checkhealth vim.lsp` only lists clients ATTACHED to the
--     current session, so from the dashboard it reads "No active clients" and tells you
--     nothing about whether your configured servers are installed. This section reports
--     every WANTED server (from gerrrt/servers) as installed/enabled/attached instead.
--
-- This module is loaded ONLY by :checkhealth (Neovim discovers lua/**/health.lua) —
-- it is never required at startup, so it adds nothing to load time.
-- ─────────────────────────────────────────────────────────────────────────────
local M = {}

local function check_clipboard(h)
  h.start("dotfiles-core: clipboard")

  -- Native Windows (NOT WSL — there has("win32") is false, it's Linux) never runs Core's
  -- bootstrap and has no clip/clip-paste scripts: dotfiles-Windows vendors only nvim/, so the
  -- unified Unix/WSL provider simply does not apply here. Worse, `clip` spuriously resolves to
  -- Windows' built-in clip.exe, so the generic ladder below reports "clip: found, clip-paste:
  -- missing" and warns about a probe the host was never meant to run. clipboard.lua instead wires
  -- an OS-appropriate provider on this host (the clip-windows provider — clip.exe copy + PowerShell
  -- paste — when clip.exe is present, else the OSC52 fallback). We deliberately do NOT re-derive
  -- which of those is live here: :checkhealth vim.provider is the single authority on the active
  -- backend. So just record that the Unix probe is inapplicable and defer to it.
  if vim.fn.has("win32") == 1 then
    h.ok("native Windows — Core's Unix/WSL clip/clip-paste probe does not apply here")
    h.info(
      "clipboard.lua wires the host provider instead (clip-windows via clip.exe + PowerShell, "
        .. "else OSC52). See :checkhealth vim.provider for the live clipboard backend."
    )
    return
  end

  local have_clip = vim.fn.executable("clip") == 1
  local have_paste = vim.fn.executable("clip-paste") == 1

  if not (have_clip and have_paste) then
    -- Core's bootstrap symlinks clip/clip-paste into ~/.local/bin; without them
    -- clipboard.lua leaves Neovim's own auto-detection in place (see its header).
    h.warn(
      ("Core's cross-OS clipboard scripts are not on PATH (clip: %s, clip-paste: %s)"):format(
        have_clip and "found" or "missing",
        have_paste and "found" or "missing"
      ),
      {
        "Neovim is using its built-in clipboard auto-detection instead.",
        "Run Core's bootstrap (it symlinks clip/clip-paste into ~/.local/bin),",
        "or add them to PATH, to get the unified WSL/macOS/Wayland/X11 provider.",
      }
    )
    return
  end

  h.ok("clip and clip-paste are on PATH")

  -- Probe a real backend by READING the clipboard (clip-paste mutates nothing). On a
  -- working box it exits 0; with no backend it exits 1 with the install hint, exactly
  -- the path that otherwise only shows up as an opaque yank/paste failure.
  local out = vim.fn.system({ "clip-paste" })
  if vim.v.shell_error == 0 then
    h.ok('a clipboard backend is reachable (clip-paste succeeded) — "+y / "+p will work')
  else
    h.error('no clipboard backend is reachable — "+y / "+p will fail', {
      "Install one for your session:",
      "  Wayland : wl-clipboard   (wl-copy / wl-paste)",
      "  X11     : xclip   or   xsel",
      "  macOS   : pbcopy/pbpaste ship with the OS",
      "  WSL     : clip.exe / powershell ship with Windows",
      vim.trim(out ~= "" and ("clip-paste said: " .. out) or ""),
    })
  end
end

local function check_lsp(h)
  h.start("dotfiles-core: LSP servers")

  -- READ-ONLY by construction: we peek `package.loaded` rather than require()-ing the registry.
  -- Requiring it here would REGISTER server configs and call vim.lsp.enable() as a side effect of
  -- running a health check — and, on the dashboard, it would do so BEFORE nvim-lspconfig's
  -- lsp/*.lua defaults are on the runtimepath (that plugin loads on `User FilePost`), caching an
  -- incomplete config for the rest of the session. So we only report once a code file has loaded
  -- the stack the normal way (correct order), and otherwise tell the user to open one.
  local servers = package.loaded["gerrrt.servers"]
  if type(servers) ~= "table" or type(servers.status) ~= "function" then
    h.info("LSP stack not loaded yet — open any code file (that loads it in the right order), then re-run :checkhealth gerrrt")
    return
  end

  local offline = vim.g.dotfiles_offline
  local attached, idle, pending, missing, broken = 0, 0, 0, 0, 0

  for _, s in ipairs(servers.status()) do
    if not s.registered then
      -- Our servers/<name>.lua override failed to load. The server may still run on nvim-lspconfig's
      -- upstream defaults, but our deliberate local overrides are silently lost — flag it.
      broken = broken + 1
      h.error(("%s — config override failed to load (running on lspconfig defaults, if any)"):format(s.name), {
        "See :messages for the gerrrt.servers error.",
      })
    elseif s.clients > 0 then
      attached = attached + 1
      h.ok(("%s — attached (%d client%s)"):format(s.name, s.clients, s.clients == 1 and "" or "s"))
    elseif s.enabled then
      idle = idle + 1
      h.ok(("%s — enabled (no client attached right now)"):format(s.name))
    elseif s.available then
      -- Binary is present but the enable pass never ran for it (installed after startup without
      -- firing the Mason re-enable hook, e.g. `uv tool install`). It can't attach until enabled.
      pending = pending + 1
      h.warn(("%s — binary present but not enabled yet"):format(s.name), {
        "Restart Neovim (or re-run the Mason install) to enable it; it won't attach until then.",
      })
    elseif offline then
      -- DOTFILES_OFFLINE boxes intentionally omit tooling; a missing binary is expected, not a
      -- defect — keep the section green (mirrors the startup-notify suppression in servers/init.lua).
      missing = missing + 1
      h.info(("%s — binary not found (DOTFILES_OFFLINE: expected)"):format(s.name))
    else
      missing = missing + 1
      h.warn(("%s — binary not found, server not enabled"):format(s.name), {
        "Install via :Mason (except ruff/ty via `uv tool install`, rust via rustup).",
      })
    end
  end

  h.info(
    ("%d attached · %d enabled-idle · %d pending-enable · %d missing · %d broken"):format(
      attached,
      idle,
      pending,
      missing,
      broken
    )
      .. "\n'attached' is a snapshot of THIS moment — servers attach per-filetype, so open a file of that"
      .. " language to watch its server start."
  )
end

local function sorted_keys(set)
  local t = {}
  for k in pairs(set) do
    t[#t + 1] = k
  end
  table.sort(t)
  return t
end

local function check_formatters(h)
  h.start("dotfiles-core: formatters (conform)")

  -- READ-ONLY: peek package.loaded, never require() (that would force-load conform from a health
  -- check). list_all_formatters() is conform's own public API — the exact one :ConformInfo renders
  -- — so there's no second formatter list here to drift from conform.lua.
  local conform = package.loaded["conform"]
  if type(conform) ~= "table" or type(conform.list_all_formatters) ~= "function" then
    h.info("conform.nvim not loaded yet — save a file or run :ConformInfo, then re-run :checkhealth gerrrt")
    return
  end

  local list = conform.list_all_formatters()
  table.sort(list, function(a, b)
    return a.name < b.name
  end)

  local offline = vim.g.dotfiles_offline
  local installed, missing = 0, 0
  for _, f in ipairs(list) do
    if f.available then
      installed = installed + 1
      h.ok(("%s — installed"):format(f.name))
    else
      missing = missing + 1
      local why = (f.available_msg and f.available_msg ~= "") and (" (" .. f.available_msg .. ")") or ""
      if offline then
        h.info(("%s — not found%s (DOTFILES_OFFLINE: expected)"):format(f.name, why))
      else
        h.warn(("%s — binary not found%s"):format(f.name, why), {
          "Install via :Mason; ruff via `uv tool install ruff`; forge_fmt/zigfmt/terraform_fmt need foundry/zig/terraform on PATH.",
        })
      end
    end
  end

  h.info(("%d installed · %d missing"):format(installed, missing)
    .. "\nconform silently skips a formatter whose binary is missing (that filetype just falls back to"
    .. " LSP formatting, or none) — a miss here is degraded formatting, never an error.")
end

local function check_linters(h)
  h.start("dotfiles-core: linters (nvim-lint)")

  -- READ-ONLY: peek package.loaded, never require() (that would force-load nvim-lint, whose config
  -- also runs an initial lint pass — a side effect a health check must not trigger).
  local lint = package.loaded["lint"]
  if type(lint) ~= "table" then
    h.info("nvim-lint not loaded yet — open any code file, then re-run :checkhealth gerrrt")
    return
  end

  -- Union of every linter wired per-filetype, plus semgrep (attached via the SAST filetype set in
  -- nvim-lint.lua, not linters_by_ft). We read the plugin's own registries, so the wanted set can't
  -- drift from the config. Each linter's REAL binary is its builtin `.cmd` (e.g. golangcilint→
  -- "golangci-lint"), which is more accurate than guessing from the map key.
  local set = { semgrep = true }
  for _, names in pairs(lint.linters_by_ft or {}) do
    for _, n in ipairs(names) do
      set[n] = true
    end
  end

  local offline = vim.g.dotfiles_offline
  local installed, missing, dynamic = 0, 0, 0
  for _, name in ipairs(sorted_keys(set)) do
    local okd, def = pcall(function()
      return lint.linters[name]
    end)
    local cmd = okd and type(def) == "table" and def.cmd or nil

    if type(cmd) == "function" then
      -- A few builtins compute cmd at runtime; probing it here would mean calling it out of context.
      dynamic = dynamic + 1
      h.info(("%s — dynamic command, not probed"):format(name))
    elseif type(cmd) == "string" then
      if vim.fn.executable(cmd) == 1 then
        installed = installed + 1
        h.ok(("%s — installed (%s)"):format(name, cmd))
      elseif offline then
        missing = missing + 1
        h.info(("%s — %s not found (DOTFILES_OFFLINE: expected)"):format(name, cmd))
      else
        missing = missing + 1
        h.warn(("%s — `%s` not found on PATH"):format(name, cmd), {
          "Install via :Mason; some (checkstyle/phpstan/rubocop/…) also need their language runtime present.",
        })
      end
    else
      h.info(("%s — could not resolve its command"):format(name))
    end
  end

  h.info(("%d installed · %d missing · %d dynamic"):format(installed, missing, dynamic)
    .. "\nseveral linters are config-gated — installed here, but they only run in a project that ships"
    .. " their config (see plugins/nvim-lint.lua). Python lint is ruff's LSP, not listed here.")
end

local function check_claude(h)
  h.start("dotfiles-core: Claude Code (claudecode.nvim)")

  -- plugins/claudecode-nvim.lua is `cond`-gated on this binary. Without the probe below, a box
  -- without the CLI just silently has no <leader>a maps and no :ClaudeCode* commands, which reads
  -- as a broken config rather than the deliberate default it is. Say so explicitly.
  if vim.fn.executable("claude") ~= 1 then
    h.ok("`claude` not on PATH — the plugin is gated off, as intended on a box without the CLI")
    h.info(
      "This is the expected state fleet-wide: the Claude Code CLI is in no OS repo's package list, "
        .. "so <leader>a and the :ClaudeCode* commands simply do not exist here. Install the CLI to "
        .. "enable them (it is an npm/brew install, not a Core concern)."
    )
    return
  end

  h.ok("`claude` found on PATH — the plugin is enabled")

  -- READ-ONLY: peek package.loaded, never require(). Requiring would force-load the plugin, which
  -- starts a WebSocket server and writes a lock file — side effects a health check must not cause.
  if type(package.loaded["claudecode"]) ~= "table" then
    h.info("not loaded yet — it is cmd/keys-lazy, so press <leader>ac (or run :ClaudeCodeStart) first")
    return
  end

  -- The plugin owns its own connection state and :ClaudeCodeStatus is its single authority; we
  -- report the lock file instead because it is the thing the CLI actually reads to find us, and
  -- it is observable without touching the plugin's internals.
  --
  -- ASK, don't re-derive: claudecode.lockfile resolves this once at load and is the authority on
  -- where it actually wrote. Re-deriving it here means two copies of the same rule drifting apart
  -- on the next plugin bump — and a health check that confidently reports the wrong directory is
  -- worse than no health check. READ-ONLY peek, same discipline as the package.loaded check above.
  local lockfile = package.loaded["claudecode.lockfile"]
  local lock_dir = type(lockfile) == "table" and lockfile.lock_dir or nil
  if type(lock_dir) ~= "string" then
    -- Fallback mirroring lockfile.get_lock_dir() exactly. Three details are load-bearing:
    --   • os.getenv, NOT vim.env — vim.env normalizes a set-but-EMPTY var to nil while os.getenv
    --     returns "", so the two disagree on `CLAUDE_CONFIG_DIR=`. Match the plugin's source.
    --   • the explicit `~= ""` guard, so that empty value falls back instead of yielding "/ide".
    --   • expand() on BOTH branches, so a `~` or `$VAR` in the override resolves the way the
    --     plugin resolved it (otherwise the glob searches a literal `~` and finds nothing).
    -- expand("~/.claude/ide") also avoids vim.env.HOME, which native Windows frequently leaves
    -- unset — concatenating nil there would throw and take the whole :checkhealth report down.
    local dir = os.getenv("CLAUDE_CONFIG_DIR")
    if dir and dir ~= "" then
      lock_dir = vim.fn.expand(dir .. "/ide")
    else
      lock_dir = vim.fn.expand("~/.claude/ide")
    end
  end
  local locks = vim.fn.glob(lock_dir .. "/*.lock", true, true)
  if #locks == 0 then
    h.warn(("loaded, but no lock file under %s"):format(lock_dir), {
      "The CLI discovers this Neovim via that file, so `claude` will not see it.",
      "Run :ClaudeCodeStatus for the server's own view, then :ClaudeCodeStart if it is stopped.",
    })
  else
    h.ok(("%d IDE lock file(s) under %s"):format(#locks, lock_dir))
    h.info(
      "A lock file only means SOME editor is advertising itself — it may be another Neovim. "
        .. ":ClaudeCodeStatus is the authority on this session's server and its connections."
    )
  end
end

function M.check()
  local h = vim.health
  check_clipboard(h)
  check_lsp(h)
  check_formatters(h)
  check_linters(h)
  check_claude(h)
end

return M
