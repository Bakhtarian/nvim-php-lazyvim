-- Laravel tooling (artisan/routes/make pickers, Tinker, Eloquent completion, etc.)
-- Only loads for actual Laravel projects (an `artisan` file at the cwd) --
-- everything else is presumably Symfony or plain PHP, not Laravel.
local function in_laravel_project()
  return vim.fn.filereadable((vim.uv or vim.loop).cwd() .. "/artisan") == 1
end

return {
  -- Blade syntax highlighting. Neovim already resolves `*.blade.php` to
  -- filetype "blade" on its own (builtin, no config needed here) -- but
  -- there's no treesitter grammar for Blade and laravel.nvim below only
  -- uses "blade" as a lazy-load trigger, not a highlighter, so without this
  -- a .blade.php file has a correct filetype and zero highlighting. Same
  -- gap Twig had (see plugins/symfony.lua) and the same fix: a small
  -- legacy syntax plugin, eager-loaded rather than fought into `ft=`
  -- lazy-loading (see that file's comment for why `ft=` doesn't work for
  -- this class of plugin).
  { "jwalton512/vim-blade" },

  {
    "adalessa/laravel.nvim",
    cond = in_laravel_project,
    dependencies = {
      "MunifTanjim/nui.nvim",
      "nvim-lua/plenary.nvim",
      "nvim-neotest/nvim-nio",
    },
    ft = { "php", "blade" },
    event = { "BufEnter composer.json" },
    keys = {
      { "<leader>ll", function() Laravel.pickers.laravel() end, desc = "Laravel: Picker" },
      { "<leader>la", function() Laravel.pickers.artisan() end, desc = "Laravel: Artisan Picker" },
      { "<leader>lr", function() Laravel.pickers.routes() end, desc = "Laravel: Routes Picker" },
      { "<leader>lm", function() Laravel.pickers.make() end, desc = "Laravel: Make Picker" },
      { "<leader>lc", function() Laravel.pickers.commands() end, desc = "Laravel: Custom Commands Picker" },
      { "<leader>lo", function() Laravel.pickers.resources() end, desc = "Laravel: Resources Picker" },
      { "<leader>lh", function() Laravel.run("artisan docs") end, desc = "Laravel: Documentation" },
      { "<leader>lt", function() Laravel.commands.run("actions") end, desc = "Laravel: Code Actions" },
      { "<leader>lu", function() Laravel.commands.run("hub") end, desc = "Laravel: Artisan Hub" },
      { "<leader>lp", function() Laravel.commands.run("command_center") end, desc = "Laravel: Command Center" },
      { "<c-g>", function() Laravel.commands.run("view:finder") end, desc = "Laravel: View Finder" },
      {
        "gf",
        function()
          if Laravel.app("gf").cursorOnResource() then
            return "<cmd>lua Laravel.commands.run('gf')<cr>"
          end
          return "gf"
        end,
        expr = true,
        noremap = true,
        desc = "Laravel: Go to resource",
      },
    },
    opts = {
      features = {
        pickers = {
          provider = "telescope",
        },
      },
    },
  },
}
