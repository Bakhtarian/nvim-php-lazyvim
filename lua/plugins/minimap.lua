-- Sublime-style minimap: a scaled overview of the whole buffer stuck to the
-- right edge, with a scrollbar box showing the current viewport.
return {
  {
    "nvim-mini/mini.map",
    version = false,
    -- `keys` alone would make lazy.nvim treat this as lazy-loaded (overriding
    -- the "custom plugins load eagerly" default), which would delay config()
    -- past VimEnter and silently break the auto-open below.
    lazy = false,
    keys = {
      { "<leader>um", function() require("mini.map").toggle() end, desc = "Toggle Minimap" },
    },
    config = function()
      local map = require("mini.map")
      map.setup({
        integrations = {
          map.gen_integration.builtin_search(),
          map.gen_integration.diagnostic(),
          map.gen_integration.gitsigns(),
        },
        symbols = {
          encode = map.gen_encode_symbols.dot("4x2"),
        },
        window = {
          side = "right",
          width = 12,
          winblend = 15,
        },
      })

      -- mini.map doesn't auto-show; open it once at startup so it behaves
      -- like an always-on sidebar (toggle off/on with <leader>um).
      vim.api.nvim_create_autocmd("VimEnter", {
        once = true,
        callback = function() map.open() end,
      })
    end,
  },
}
