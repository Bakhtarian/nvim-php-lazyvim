--- plugins/symfony.lua
---
--- `<leader>sc` opens a Telescope picker over `bin/console` commands
--- (Docker-aware -- see util/symfony.lua), the Symfony equivalent of the
--- Laravel Artisan picker. Selecting one prompts for extra args and runs it
--- in a terminal split.

local function console_picker()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local symfony = require("util.symfony")

  local bufname = vim.api.nvim_buf_get_name(0)
  local commands, err = symfony.list_commands(bufname)
  if not commands then
    vim.notify("Symfony: Console Picker: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end

  pickers
    .new({}, {
      prompt_title = "bin/console",
      -- Telescope's default `horizontal` strategy computes a preview pane
      -- alongside results even with none defined; `previewer = false` (no
      -- preview needed for a name+description command list anyway) plus an
      -- explicit `vertical` layout keeps this a clean, properly-bordered
      -- centered dialog regardless of how wide/narrow the terminal is.
      previewer = false,
      layout_strategy = "vertical",
      layout_config = { width = 0.7, height = 0.8 },
      finder = finders.new_table({
        results = commands,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.name .. "  " .. entry.description,
            ordinal = entry.name .. " " .. entry.description,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(_, map)
        local run = function(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not selection then
            return
          end
          vim.ui.input({ prompt = selection.value.name .. " " }, function(extra_args)
            if extra_args == nil then
              return
            end
            symfony.run_command(bufname, selection.value.name, extra_args)
          end)
        end
        map({ "i", "n" }, "<CR>", run)
        return true
      end,
    })
    :find()
end

return {
  -- Legacy ftdetect/syntax plugin, negligible startup cost -- eager-loaded
  -- (this config's own default for lua/plugins/*.lua) rather than fought
  -- into `ft = "twig"` lazy-loading, which doesn't reliably work here: nvim
  -- already resolves `.twig` to filetype "twig" before this plugin ever
  -- loads, then this plugin's OWN ftdetect immediately rewrites it to the
  -- compound "html.twig.js.css" -- and lazy.nvim's ft-trigger, watching for
  -- exactly "twig", never matches that rewritten value.
  { "nelsyeung/twig.vim" },
  {
    "nvim-telescope/telescope.nvim",
    optional = true,
    keys = {
      { "<leader>sc", console_picker, desc = "Symfony: Console Picker" },
    },
  },
}
