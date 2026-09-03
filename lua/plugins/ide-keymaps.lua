--- plugins/ide-keymaps.lua
---
--- PhpStorm-style keymaps mapped onto nvim/LSP built-ins:
---   Ctrl+B          go to definition (was: Snacks smooth scroll-back --
---                   Ctrl+U/Ctrl+D still scroll, just without that effect)
---   Alt+Left/Right  jump back/forward through the jumplist (nvim's own
---                   "navigate back/forward" -- LSP jumps already push to
---                   it, so this retraces exactly the route travelled)
---   Ctrl+Space      signature help (insert mode -- via blink.cmp's own
---                   native signature-help action, not a raw
---                   vim.lsp.buf.signature_help() call: blink.cmp already
---                   owned Ctrl+Space for its completion menu/docs toggle,
---                   and a plain vim.keymap.set here would've been just as
---                   silently overwritten as the Ctrl+B case below -- same
---                   root cause, different plugin)
---   Ctrl+E          recently-used open buffers, sorted by last use, as a
---                   plain (non-fuzzy) list -- vim.ui.select's default
---                   handler is a numbered list, not a fuzzy prompt
---   Ctrl+P          global file search (Telescope, root-aware)
---
--- PHP-specific refactor/scaffolding keymaps (Alt+F6, Alt+Insert) live in
--- plugins/php-keymaps.lua instead, alongside <leader>cr/<leader>cm/<leader>cn
--- which they mirror -- they need phpactor.nvim, which only loads for php
--- buffers.
---
--- "Double Shift" (PhpStorm's Search Everywhere) has no nvim/terminal
--- equivalent: a bare Shift keypress sends no keycode at all in a terminal,
--- so there is nothing for nvim to detect, let alone double-tap-time.
--- Bound to Ctrl+P instead -- the VSCode/Sublime convention for the same
--- kind of global search.

vim.keymap.set("n", "<M-Left>", "<C-o>", { desc = "Jump back" })
vim.keymap.set("n", "<M-Right>", "<C-i>", { desc = "Jump forward" })

vim.keymap.set("n", "<C-e>", function()
  local bufs = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if info.name ~= "" then
      table.insert(bufs, info)
    end
  end
  table.sort(bufs, function(a, b)
    return a.lastused > b.lastused
  end)
  vim.ui.select(bufs, {
    prompt = "Open buffers:",
    format_item = function(item)
      return vim.fn.fnamemodify(item.name, ":~:.")
    end,
  }, function(choice)
    if choice then
      vim.api.nvim_set_current_buf(choice.bufnr)
    end
  end)
end, { desc = "Recent/open buffers (plain list)" })

return {
  {
    -- Ctrl+B is claimed by noice.nvim for scrolling LSP hover/doc windows
    -- (falls through to a normal page-scroll when no doc window is open).
    -- lazy.nvim applies plugin-declared `keys=` entries AFTER plain
    -- vim.keymap.set calls run at spec-load time, so a plain
    -- vim.keymap.set("n", "<C-b>", ...) here would get silently
    -- overwritten -- disabling noice's binding, and defining the
    -- replacement below, both have to go through that same `keys=`
    -- mechanism to actually stick.
    "folke/noice.nvim",
    optional = true,
    keys = {
      { "<c-b>", false, mode = { "i", "n", "s" } },
    },
  },
  {
    "neovim/nvim-lspconfig",
    optional = true,
    keys = {
      { "<C-b>", vim.lsp.buf.definition, desc = "Go to definition" },
    },
  },
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      -- blink.cmp's signature-help feature is OFF by default (a separate
      -- master switch from the keymap below) -- without this, Ctrl+Space
      -- would silently do nothing at all, no error, nothing to debug.
      opts.signature = opts.signature or {}
      opts.signature.enabled = true

      opts.keymap = opts.keymap or {}
      -- Was blink's own completion-menu-show/doc-toggle key; blink
      -- auto-shows completions as you type regardless, so handing this key
      -- fully to signature help (matching Ctrl+Space's PhpStorm meaning)
      -- costs little. 'fallback' at the end matches blink's own default
      -- <C-k> binding: falls through to whatever Ctrl+Space would
      -- otherwise do when there's no signature to show/hide.
      opts.keymap["<C-space>"] = { "show_signature", "hide_signature", "fallback" }
    end,
  },
  {
    "nvim-telescope/telescope.nvim",
    optional = true,
    keys = {
      { "<C-p>", function() LazyVim.pick.open("files") end, desc = "Find files (global)" },
    },
  },
}
