--- plugins/projects.lua
---
--- Project/worktree switcher: `<leader>fp` opens a Telescope picker listing
--- every repo under ~/projects plus its worktrees, flattened together.
--- `<CR>` opens the selection in the current tab, `<C-t>` opens it in a new
--- one. `:WorktreeCreate {branch}` creates+opens a worktree of the current
--- tab's repo (current tab); `:WorktreeCreate! {branch}` does the same in a
--- new tab. See util/projects.lua for the discovery/creation logic.

local function project_picker()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local projects = require("util.projects")

  local entries = {}
  for _, project in ipairs(projects.discover_projects()) do
    table.insert(entries, project)
    vim.list_extend(entries, projects.discover_worktrees(project.path))
  end

  local function open_selection(prompt_bufnr, new_tab)
    local selection = action_state.get_selected_entry()
    actions.close(prompt_bufnr)
    if selection then
      projects.open(selection.value.path, { new_tab = new_tab })
    end
  end

  pickers
    .new({}, {
      prompt_title = "Projects & Worktrees",
      -- Same reasoning as the Symfony console picker (plugins/symfony.lua):
      -- no previewer needed for a project/worktree name list, and an
      -- explicit vertical layout keeps this a clean, properly-bordered
      -- centered dialog regardless of terminal width.
      previewer = false,
      layout_strategy = "vertical",
      layout_config = { width = 0.7, height = 0.8 },
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return { value = entry, display = entry.name, ordinal = entry.name }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(_, map)
        map({ "i", "n" }, "<CR>", function(bufnr)
          open_selection(bufnr, false)
        end)
        map({ "i", "n" }, "<C-t>", function(bufnr)
          open_selection(bufnr, true)
        end)
        return true
      end,
    })
    :find()
end

vim.api.nvim_create_user_command("WorktreeCreate", function(cmd_opts)
  local projects = require("util.projects")
  local root = projects.main_repo_root(vim.fn.getcwd())
  if not root then
    vim.notify("WorktreeCreate: not inside a git repo", vim.log.levels.ERROR)
    return
  end

  local path, err = projects.create_worktree(root, cmd_opts.args)
  if not path then
    vim.notify("WorktreeCreate: " .. err, vim.log.levels.ERROR)
    return
  end

  projects.open(path, { new_tab = cmd_opts.bang })
end, { nargs = 1, bang = true, desc = "Create a git worktree and open it (! = new tab)" })

return {
  "nvim-telescope/telescope.nvim",
  optional = true,
  keys = {
    { "<leader>fp", project_picker, desc = "Projects & Worktrees" },
  },
}
