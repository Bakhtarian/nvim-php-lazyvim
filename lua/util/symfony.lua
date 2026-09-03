--- util/symfony.lua
---
--- Docker-aware `bin/console` command listing/execution for the Symfony
--- console picker (see plugins/symfony.lua). Runs through util/docker.lua's
--- container resolution exactly like PHPStan/Pint/PHPUnit already do -- so
--- picking a command runs it inside whichever compose service owns the
--- buffer's project, not whatever PHP happens to be on the host.

local M = {}

---@param bufname string
---@return string|nil root  directory containing `bin/console`
local function find_console_root(bufname)
  local dir = vim.fn.fnamemodify(bufname ~= "" and bufname or vim.fn.getcwd(), ":p:h")
  for _ = 1, 50 do
    if vim.fn.filereadable(dir .. "/bin/console") == 1 then
      return dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

--- List every `bin/console` command as {name, description}, resolved
--- Docker-aware (inside the buffer's container, when the project runs in one).
---@param bufname string
---@return {name: string, description: string}[]|nil commands
---@return string|nil error
function M.list_commands(bufname)
  local root = find_console_root(bufname)
  if not root then
    return nil, "no bin/console found above " .. bufname
  end

  local docker = require("util.docker")
  local info = docker.resolve(root .. "/bin/console")
  if info == false then
    return nil, "docker service could not be resolved (see the notification docker.lua already showed)"
  end

  local cmd
  if info then
    cmd = { "docker", "compose" }
    vim.list_extend(cmd, docker.compose_flags(info))
    -- Bare "bin/console" relies on `docker compose exec`'s default working
    -- directory (the image's WORKDIR) matching `root` -- true for the main
    -- checkout but NOT guaranteed for a project's generated per-worktree
    -- overlay services, which is why this failed identically whether or
    -- not the container was actually running. Every other Docker-aware
    -- tool here (php.lua's PHPStan/Pint) passes an explicit container path
    -- instead of trusting exec's default cwd -- do the same.
    vim.list_extend(
      cmd,
      { "exec", "-T", info.service, "php", docker.to_container_path(info, root .. "/bin/console"), "list", "--format=json" }
    )
  else
    cmd = { "php", "bin/console", "list", "--format=json" }
  end

  -- The base compose file (e.g. "compose.yml") is passed to `-f` as just a
  -- filename, resolved relative to THIS cwd -- must be the compose root
  -- (info.root), not `root` (bin/console's own directory, which can be a
  -- subdirectory like apps/client-api in a multi-app monorepo). This was
  -- silently masked as long as no `-f` flags were passed at all: Compose
  -- auto-discovers its own compose file by walking up from cwd when given
  -- none, which happened to paper over the wrong cwd here -- but passing
  -- any `-f` (needed for worktree/marker overlays) suppresses that
  -- auto-discovery entirely, surfacing the mismatch as a hard failure.
  local result = vim.system(cmd, { cwd = info and info.root or root, text = true }):wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or "bin/console list failed"
  end

  local ok, decoded = pcall(vim.json.decode, result.stdout or "")
  if not ok or not decoded or not decoded.commands then
    return nil, "unexpected `bin/console list --format=json` output"
  end

  -- `bin/console list --format=json`'s "commands" is a JSON ARRAY of
  -- command objects (each carrying its own "name"), not an object keyed by
  -- name -- pairs() over a decoded array iterates 1,2,3... as "name",
  -- which is why every command showed up as a bare number until this run
  -- was the first to ever get far enough to actually reach this parsing.
  local commands = {}
  for _, def in ipairs(decoded.commands) do
    table.insert(commands, { name = def.name, description = def.description or "" })
  end
  table.sort(commands, function(a, b)
    return a.name < b.name
  end)
  return commands, nil
end

--- Run `bin/console <name> <extra_args>` in a terminal split, Docker-aware.
--- No `-T` on the docker exec here (unlike list_commands' piped JSON call)
--- -- this runs inside a real `:terminal`, so it should get a pty the same
--- as any other interactive command would.
---@param bufname string
---@param name string
---@param extra_args string  raw extra CLI args, e.g. "--env=test"
function M.run_command(bufname, name, extra_args)
  local root = find_console_root(bufname)
  if not root then
    vim.notify("symfony.lua: no bin/console found", vim.log.levels.ERROR)
    return
  end

  local docker = require("util.docker")
  local info = docker.resolve(root .. "/bin/console")
  if info == false then
    return
  end

  local parts
  if info then
    parts = { "docker", "compose" }
    vim.list_extend(parts, docker.compose_flags(info))
    vim.list_extend(parts, { "exec", info.service, "php", docker.to_container_path(info, root .. "/bin/console"), name })
  else
    parts = { "php", "bin/console", name }
  end

  local shell_cmd = table.concat(vim.tbl_map(vim.fn.shellescape, parts), " ")
  if extra_args and extra_args ~= "" then
    shell_cmd = shell_cmd .. " " .. extra_args
  end

  -- `:new`, not a bare `:split` -- split shares the CURRENT buffer with the
  -- new window, and termopen() below converts the current buffer in place
  -- into a terminal. With split, that flips BOTH windows to the terminal
  -- and the original file buffer is gone. `:new` gives the split window its
  -- own fresh empty buffer, so termopen only touches that one.
  vim.cmd("botright new | resize 15")
  -- Same cwd fix as list_commands above -- see that comment for why.
  vim.fn.termopen(shell_cmd, { cwd = info and info.root or root })
  vim.cmd("startinsert")
end

return M
