--- util/projects.lua
---
--- Discovers git repos and their worktrees under ~/projects for the
--- project/worktree switcher (see plugins/projects.lua), and creates new
--- worktrees using whichever convention the target repo already has:
--- nested `.worktrees/<branch>/` (Project A's convention) if that
--- directory already exists, otherwise a plain sibling `../repo-branch`.
---
--- Deliberately does NOT run Project A's `make wt-hosts` /
--- `wt-migrate` / `wt-composer` / `wt-jwt` setup -- this stays a thin,
--- generic "create the worktree and open it" tool that works the same for
--- every repo; docker/DB/hosts setup for Project A-style repos is a
--- separate manual step.

local M = {}

-- Resolved through fs_realpath: ~/projects is itself a symlink (-> /projects),
-- and `find` on a bare symlink argument (no trailing slash) refuses to
-- descend into it at all -- resolving once here keeps every downstream
-- `find`/path-prefix computation working off the real, traversable path.
M.root = vim.uv.fs_realpath(vim.fn.expand("~/projects")) or vim.fn.expand("~/projects")

---@class ProjectEntry
---@field name string        display name, e.g. "my_project/backend" or "my_project/backend > ticket-122"
---@field path string        absolute path
---@field is_worktree boolean

---@return string[] absolute paths of every `.git` dir found
local function find_git_dirs()
  local result = vim
    .system({
      "find",
      M.root,
      "-maxdepth",
      "3",
      "-name",
      ".git",
      "-type",
      "d",
      "-not",
      "-path",
      "*/.worktrees/*",
      "-not",
      "-path",
      "*/node_modules/*",
      "-not",
      "-path",
      "*/vendor/*",
    }, { text = true })
    :wait()
  -- `find` exits non-zero on any per-entry error (e.g. a permission-denied
  -- directory under ~/projects) while still emitting valid results for
  -- everything it *could* read -- so a non-zero exit only gets a warning,
  -- never a dropped result set.
  if result.code ~= 0 and vim.trim(result.stderr or "") ~= "" then
    vim.notify("projects.lua: find: " .. vim.trim(result.stderr), vim.log.levels.WARN)
  end
  return vim.split(vim.trim(result.stdout or ""), "\n", { plain = true, trimempty = true })
end

--- Every repo under ~/projects (excluding worktree checkouts themselves,
--- which `discover_worktrees` surfaces per-project instead).
---@return ProjectEntry[]
function M.discover_projects()
  local entries = {}
  for _, git_dir in ipairs(find_git_dirs()) do
    local path = git_dir:sub(1, -6) -- strip trailing "/.git"
    local name = path:sub(#M.root + 2)
    table.insert(entries, { name = name, path = path, is_worktree = false })
  end
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)
  return entries
end

--- `project_path`'s worktrees via `git worktree list` (authoritative --
--- not a directory-naming guess), excluding the primary checkout itself.
---@param project_path string
---@return ProjectEntry[]
function M.discover_worktrees(project_path)
  local result =
    vim.system({ "git", "-C", project_path, "worktree", "list", "--porcelain" }, { text = true }):wait()
  if result.code ~= 0 then
    return {}
  end
  local project_name = project_path:sub(#M.root + 2)
  local root_real = vim.uv.fs_realpath(project_path) or project_path
  local entries = {}
  for wt_path in (result.stdout or ""):gmatch("worktree ([^\n]+)") do
    local real = vim.uv.fs_realpath(wt_path) or wt_path
    if real ~= root_real then
      table.insert(entries, {
        name = project_name .. " > " .. vim.fn.fnamemodify(wt_path, ":t"),
        path = wt_path,
        is_worktree = true,
      })
    end
  end
  return entries
end

--- Resolve the MAIN repo root for whatever git checkout `cwd` is in.
--- `git rev-parse --show-toplevel` would report a worktree's own root when
--- run from inside one -- `--git-common-dir` always points at the shared
--- `.git`, so this works the same whether `cwd` is the primary checkout or
--- one of its worktrees.
---@param cwd string
---@return string|nil
function M.main_repo_root(cwd)
  -- `--path-format=absolute` (git >=2.31) matters: `--git-common-dir` alone
  -- prints a path relative to `cwd`, and resolving that relative path
  -- against nvim's OWN cwd (`fnamemodify(..., ":p")`) rather than `cwd`
  -- silently produces a path in the wrong directory entirely.
  local result = vim
    .system({ "git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true })
    :wait()
  if result.code ~= 0 then
    return nil
  end
  local common_dir = vim.trim(result.stdout or "")
  if common_dir:sub(-1) == "/" then
    common_dir = common_dir:sub(1, -2)
  end
  if vim.fn.fnamemodify(common_dir, ":t") == ".git" then
    return vim.fn.fnamemodify(common_dir, ":h")
  end
  return common_dir
end

--- Create a worktree of `project_path` for `branch`. Reuses `branch` if it
--- already exists locally, otherwise creates it off HEAD.
---@param project_path string
---@param branch string
---@return string|nil new_path
---@return string|nil error
function M.create_worktree(project_path, branch)
  branch = vim.trim(branch or "")
  if branch == "" then
    return nil, "branch name is required"
  end

  local nested = project_path .. "/.worktrees"
  local target
  if vim.fn.isdirectory(nested) == 1 then
    target = nested .. "/" .. branch
  else
    local repo_name = vim.fn.fnamemodify(project_path, ":t")
    target = vim.fn.fnamemodify(project_path, ":h") .. "/" .. repo_name .. "-" .. branch
  end

  if vim.fn.isdirectory(target) == 1 then
    return nil, "target already exists: " .. target
  end

  local branch_exists = vim
    .system({ "git", "-C", project_path, "rev-parse", "--verify", "--quiet", branch }, { text = true })
    :wait().code == 0

  local cmd = { "git", "-C", project_path, "worktree", "add", target }
  if not branch_exists then
    table.insert(cmd, "-b")
  end
  table.insert(cmd, branch)

  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or "git worktree add failed"
  end
  return target
end

--- Open `path` for editing. `opts.new_tab` opens it in a fresh tabpage;
--- otherwise the current tab's directory switches in place -- the
--- Vimium-style f/F split, expressed as Telescope's own `<CR>`/`<C-t>`
--- idiom (or `:WorktreeCreate` vs `:WorktreeCreate!`) rather than
--- shift-casing a letter.
---@param path string
---@param opts {new_tab: boolean}|nil
function M.open(path, opts)
  opts = opts or {}
  if opts.new_tab then
    vim.cmd("tabnew")
  end
  vim.cmd("tcd " .. vim.fn.fnameescape(path))
  vim.t.project_name = vim.fn.fnamemodify(path, ":t")
  LazyVim.pick.open("files", { cwd = path })
end

return M
