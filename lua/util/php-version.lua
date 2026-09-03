--- util/php-version.lua
---
--- Resolves a project's target PHP version from `composer.json`, mirroring
--- Phpactor's own detection order (config.platform.php, then require.php)
--- -- see lua/plugins/php.lua's intelephense `on_new_config` hook for why:
--- Phpactor already does this on its own, but intelephense doesn't, and
--- was hardcoded to one PHP version for every project regardless of what
--- that project actually targets (e.g. Project A on 8.2 vs Project B on 8.5).

local M = {}

--- The lowest version mentioned in a composer constraint, e.g. "^8.1 || ^8.2"
--- -> "8.1". Deliberately the LOWEST, not highest: the point is catching
--- syntax the project's minimum supported PHP version doesn't allow (e.g.
--- readonly properties on a project that must still run on 7.4), not
--- guessing the newest version someone might be running locally.
---@param constraint string
---@return string|nil
local function lowest_version_in_constraint(constraint)
  local versions = {}
  for major, minor, patch in constraint:gmatch("(%d+)%.(%d+)%.?(%d*)") do
    table.insert(versions, { tonumber(major), tonumber(minor), patch ~= "" and tonumber(patch) or 0, patch })
  end
  if #versions == 0 then
    return nil
  end
  table.sort(versions, function(a, b)
    if a[1] ~= b[1] then
      return a[1] < b[1]
    end
    if a[2] ~= b[2] then
      return a[2] < b[2]
    end
    return a[3] < b[3]
  end)
  local v = versions[1]
  return v[4] ~= "" and (v[1] .. "." .. v[2] .. "." .. v[4]) or (v[1] .. "." .. v[2])
end

--- Resolve the PHP version `root`'s composer.json targets. Returns nil
--- (caller should fall back to a sane default) when composer.json is
--- missing or declares no PHP constraint at all.
---@param root string  directory containing composer.json
---@return string|nil
function M.resolve(root)
  local path = root .. "/composer.json"
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or not decoded then
    return nil
  end

  -- An explicit platform pin is a concrete version, not a constraint --
  -- trust it as-is, same priority order Phpactor itself uses.
  local platform = decoded.config and decoded.config.platform and decoded.config.platform.php
  if platform and platform ~= "" then
    return platform
  end

  local constraint = decoded.require and decoded.require.php
  if constraint and constraint ~= "" then
    return lowest_version_in_constraint(constraint)
  end

  return nil
end

return M
