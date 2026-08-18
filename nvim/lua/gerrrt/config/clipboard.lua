-- nvim/lua/gerrrt/config/clipboard.lua
-- ─────────────────────────────────────────────────────────────────────────────
-- Cross-OS system-clipboard provider for Neovim.
--
-- Routes the "+ and "* registers through Core's `clip` / `clip-paste` scripts,
-- which themselves detect WSL / macOS / Wayland / X11. This is what makes
-- `"+y` (yank to system clipboard) and `"+p` (paste from it) work identically on
-- every machine WITH A BIDIRECTIONAL BACKEND — most importantly on WSL, where
-- Neovim otherwise has NO native clipboard provider and `"+y` silently does nothing.
--
-- The symmetry stops on a headless ssh box, and deliberately so. There `clip` copies
-- via OSC 52 (see core/bin/clip) but `clip-paste` has no counterpart, because reading
-- over OSC 52 means querying the terminal for a reply most terminals refuse to send
-- and some never answer at all. So `"+y` works and `"+p` does not — matching the
-- shell, where `pbcopy` works and `pbpaste` does not. Pasting INTO the remote is your
-- terminal's own paste, which needs no provider.
--
-- Requires `clip` and `clip-paste` on PATH (bootstrap.sh symlinks them into
-- ~/.local/bin). If they're missing, we leave Neovim's own auto-detection alone
-- so nothing breaks on a box that hasn't been bootstrapped.
--
-- NOTE: This is an OPT-IN setup. Yanks/deletes stay in Neovim's own registers
-- by default; you reach the system clipboard explicitly with the "+ register
-- (e.g. "+yy / "+p). That's why options.lua does NOT set clipboard=unnamedplus —
-- the two were contradicting each other before. This keeps `<leader>p`
-- (paste-without-yank) and the black-hole register behaving as intended.
-- ─────────────────────────────────────────────────────────────────────────────

if vim.fn.executable("clip") == 1 and vim.fn.executable("clip-paste") == 1 then
  vim.g.clipboard = {
    name = "clip-crossos",
    copy = {
      ["+"] = "clip",
      ["*"] = "clip",
    },
    paste = {
      ["+"] = "clip-paste",
      ["*"] = "clip-paste",
    },
    -- cache_enabled = 0 on purpose: every "+p reflects the LIVE system clipboard
    -- (including copies made in other apps), never a stale value nvim cached. That
    -- means nvim re-execs clip-paste per access, so the scripts themselves are kept
    -- fork-light — their WSL probe reads /proc/version with a bash builtin instead
    -- of forking grep each time (see bin/clip). Correctness kept, waste removed.
    cache_enabled = 0,
  }
elseif vim.fn.executable("clip.exe") == 1 then
  -- Windows-native fallback (psmux / no Core bootstrap)
  local pwsh = vim.fn.executable("pwsh") == 1 and "pwsh" or "powershell"
  vim.g.clipboard = {
    name = "clip-windows",
    copy = {
      ["+"] = "clip.exe",
      ["*"] = "clip.exe",
    },
    paste = {
      -- -Raw returns the clipboard as a single string; bare Get-Clipboard yields a
      -- string[] split on newlines, which nvim rejoins with CRLF and mangles multi-line pastes.
      ["+"] = { pwsh, "-NoProfile", "-Command", "Get-Clipboard -Raw" },
      ["*"] = { pwsh, "-NoProfile", "-Command", "Get-Clipboard -Raw" },
    },
    cache_enabled = 0,
  }
elseif vim.fn.has("nvim-0.10") == 1
  and vim.fn.executable("pbcopy") == 0
  and vim.fn.executable("wl-copy") == 0
  and vim.fn.executable("xclip") == 0
  and vim.fn.executable("xsel") == 0
  and vim.fn.executable("win32yank") == 0
then
  -- Last-resort fallback, applied ONLY when there is genuinely no native clipboard backend
  -- on PATH: no Core clip/clip.exe AND none of the OS-native tools Neovim would auto-detect
  -- (pbcopy / wl-copy / xclip / xsel / win32yank). This keeps the module contract above — a
  -- working native provider is NEVER overridden (so its blocking OSC52 paste query is never
  -- imposed on a box that has a real provider) — while still closing the "yank does nothing
  -- over tmux/psmux/SSH" gap on a headless/remote box. Neovim 0.10+'s OSC52 provider carries
  -- yanks to the system clipboard over the terminal escape sequence, no external helper needed.
  --
  -- NOTE this branch is NOT what covers a headless Linux box that has been bootstrapped:
  -- there `clip` IS on PATH, so the first branch wins and this one is unreachable. That is
  -- fine, because core/bin/clip has its own OSC52 fallback and copying works through it —
  -- but it is worth stating, because the reverse assumption (that a present-but-backendless
  -- `clip` would fall through to here) is wrong and costs an afternoon to rediscover. What
  -- this branch actually covers is a box with no Core bootstrap at all: psmux, a bare
  -- checkout, nvim installed on its own. Paste differs in both cases — see bin/clip-paste
  -- for why OSC52 reads are not safe to do blind.
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "clip-osc52",
    copy = {
      ["+"] = osc52.copy("+"),
      ["*"] = osc52.copy("+"),
    },
    paste = {
      ["+"] = osc52.paste("+"),
      ["*"] = osc52.paste("+"),
    },
    cache_enabled = 0,
  }
end
