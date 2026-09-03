--- plugins/visual-multi.lua
---
--- Multi-cursor support (nvim has none built in). `<M-j>` mirrors
--- PhpStorm's "select next occurrence of word under cursor" -- press once
--- to select the word, press again to add the next occurrence as another
--- cursor. `g:VM_maps` must be set before the plugin loads (it's a legacy
--- vimscript plugin reading its own global config at source time), so it's
--- set in `init`, not `opts`.
return {
  "mg979/vim-visual-multi",
  branch = "master",
  init = function()
    vim.g.VM_maps = vim.g.VM_maps or {}
    vim.g.VM_maps["Find Under"] = "<M-j>"
    vim.g.VM_maps["Find Subword Under"] = "<M-j>"
  end,
  keys = {
    { "<M-j>", mode = { "n", "v" }, desc = "Multi-cursor: select next occurrence" },
  },
}
