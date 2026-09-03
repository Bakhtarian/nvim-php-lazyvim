-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- Intelephense caches per-workspace state under globalStoragePath AND,
-- separately, under /tmp/intelephense/<hash>. If that cache is stale or
-- was written by an incompatible intelephense version, it can crash the
-- server on startup while trying to read it back -- silently: no stdout,
-- no stderr, no LSP error notification, it just never finishes
-- `initialize` and `gr`/`gd`/completion quietly stop working. Symptom:
-- `:LspInfo` shows no intelephense client, or one that never attaches.
vim.api.nvim_create_user_command("IntelephenseClearCache", function()
  local cleared = {}
  for _, dir in ipairs({ vim.fn.stdpath("data") .. "/intelephense", "/tmp/intelephense" }) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.fn.delete(dir, "rf")
      table.insert(cleared, dir)
    end
  end
  for _, client in ipairs(vim.lsp.get_clients({ name = "intelephense" })) do
    client:stop(true)
  end
  vim.notify(
    "Intelephense cache cleared (" .. table.concat(cleared, ", ") .. ") -- reopen a .php buffer to reattach.",
    vim.log.levels.INFO
  )
end, { desc = "Clear Intelephense's on-disk cache and restart its client(s) (fixes a silent startup crash)" })

-- :Wt <query> -- cd the whole session into a worktree matching <query>,
-- searched across every project under ~/projects without hardcoding any
-- one project's convention:
--   - nested (Project B's `_worktrees/<ticket>`, Project A's `.worktrees/<name>`)
--   - sibling directories (Project C's `Broker-dev3442-<slug>` next to `Broker`)
-- Matching is substring, case-insensitive, against the directory's own
-- name. `:cd` (not `:lcd`/`:tcd`) so it's a real whole-session move --
-- explorer, telescope, and terminal all follow. LSP/docker resolution
-- were never cwd-based to begin with (see util/docker.lua), so this is
-- purely a navigation convenience, not something either of those needed.
local function find_worktrees(query)
  local query_lower = query:lower()
  local projects_root = vim.fn.expand("~/projects")
  local matches = {}
  local seen = {}

  local function consider(dir, name)
    if seen[dir] then
      return
    end
    if query == "" or name:lower():find(query_lower, 1, true) then
      seen[dir] = true
      table.insert(matches, dir)
    end
  end

  -- Skip dotfiles/dot-directories at this top level (system cruft like
  -- `.Trashes`, not a project) and swallow permission errors from
  -- unreadable directories instead of surfacing an E484 per entry.
  local function safe_readdir(dir)
    local ok, entries = pcall(vim.fn.readdir, dir)
    return ok and entries or {}
  end

  for _, project in ipairs(safe_readdir(projects_root)) do
    local project_path = projects_root .. "/" .. project
    if project:sub(1, 1) ~= "." and vim.fn.isdirectory(project_path) == 1 then
      -- Sibling-worktree convention
      for _, name in ipairs(safe_readdir(project_path)) do
        local path = project_path .. "/" .. name
        if vim.fn.isdirectory(path) == 1 then
          consider(path, name)
        end
      end
      -- Nested-worktree conventions
      for _, container_name in ipairs({ ".worktrees", "_worktrees" }) do
        local container = project_path .. "/" .. container_name
        if vim.fn.isdirectory(container) == 1 then
          for _, name in ipairs(safe_readdir(container)) do
            local path = container .. "/" .. name
            if vim.fn.isdirectory(path) == 1 then
              consider(path, name)
            end
          end
        end
      end
    end
  end

  table.sort(matches)
  return matches
end

vim.api.nvim_create_user_command("Wt", function(opts)
  local matches = find_worktrees(opts.args)
  if #matches == 0 then
    vim.notify("Wt: no worktree found matching '" .. opts.args .. "'", vim.log.levels.WARN)
  elseif #matches == 1 then
    vim.cmd.cd(matches[1])
    vim.notify("cd -> " .. matches[1], vim.log.levels.INFO)
  else
    vim.ui.select(matches, { prompt = "Multiple worktrees match '" .. opts.args .. "':" }, function(choice)
      if choice then
        vim.cmd.cd(choice)
        vim.notify("cd -> " .. choice, vim.log.levels.INFO)
      end
    end)
  end
end, {
  nargs = 1,
  desc = "cd the whole session into a worktree matching <query>, searched across ~/projects",
  complete = function(arg_lead)
    local names = {}
    for _, path in ipairs(find_worktrees("")) do
      local name = vim.fn.fnamemodify(path, ":t")
      if name:lower():find(arg_lead:lower(), 1, true) == 1 then
        table.insert(names, name)
      end
    end
    return names
  end,
})
