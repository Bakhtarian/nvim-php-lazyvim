--- php-class-create.lua
---
--- Creates a new PHP class/interface/trait/enum file with the correct
--- namespace resolved from the project's composer.json PSR-4 autoload
--- configuration, plus the right skeleton for the chosen type.
---
--- Usage:  require("util.php-class-create").create()
---         or via keymap: <leader>cn

local M = {}

--- Find the project root by looking for composer.json
---@return string|nil
local function find_project_root()
  local root_markers = { "composer.json" }
  local path = vim.fn.expand("%:p:h")
  if path == "" then
    path = vim.fn.getcwd()
  end

  for _ = 1, 50 do
    for _, marker in ipairs(root_markers) do
      if vim.fn.filereadable(path .. "/" .. marker) == 1 then
        return path
      end
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then
      break
    end
    path = parent
  end
  return nil
end

--- Parse PSR-4 autoload mappings from composer.json
---@param root string
---@return table<string, string> namespace_prefix -> directory (absolute)
local function parse_psr4_mappings(root)
  local composer_path = root .. "/composer.json"
  local file = io.open(composer_path, "r")
  if not file then
    return {}
  end

  local content = file:read("*a")
  file:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or not decoded then
    return {}
  end

  local mappings = {}

  for _, section in ipairs({ "autoload", "autoload-dev" }) do
    local autoload = decoded[section]
    if autoload and autoload["psr-4"] then
      for namespace, dirs in pairs(autoload["psr-4"]) do
        if type(dirs) == "string" then
          dirs = { dirs }
        end
        for _, dir in ipairs(dirs) do
          dir = dir:gsub("/$", "")
          if not namespace:match("\\$") then
            namespace = namespace .. "\\"
          end
          mappings[namespace] = root .. "/" .. dir
        end
      end
    end
  end

  return mappings
end

--- Resolve the PHP namespace for a given directory path
---@param dir string       absolute path to directory
---@param mappings table   PSR-4 mappings
---@return string|nil      fully-qualified namespace (without trailing \)
local function resolve_namespace(dir, mappings)
  local best_prefix = nil
  local best_base = nil
  local best_len = 0

  for ns_prefix, base_dir in pairs(mappings) do
    local norm_base = vim.fn.resolve(base_dir)
    local norm_dir = vim.fn.resolve(dir)

    if norm_dir:sub(1, #norm_base) == norm_base and #norm_base > best_len then
      best_prefix = ns_prefix
      best_base = norm_base
      best_len = #norm_base
    end
  end

  if not best_prefix or not best_base then
    return nil
  end

  local norm_dir = vim.fn.resolve(dir)
  local relative = norm_dir:sub(#best_base + 1)
  relative = relative:gsub("^/", "")

  local ns_suffix = relative:gsub("/", "\\")

  local namespace = best_prefix:gsub("\\$", "")
  if ns_suffix ~= "" then
    namespace = namespace .. "\\" .. ns_suffix
  end

  return namespace
end

---@class PhpTypeKind
---@field label string        shown in the picker
---@field keyword string      "class" | "interface" | "trait" | "enum"
---@field default_final boolean whether a plain class defaults to `final class`
local KINDS = {
  { label = "Class (final)", keyword = "class", modifier = "final " },
  { label = "Class (abstract)", keyword = "class", modifier = "abstract " },
  { label = "Interface", keyword = "interface", modifier = "" },
  { label = "Trait", keyword = "trait", modifier = "" },
  { label = "Enum (pure)", keyword = "enum", modifier = "", enum_backing = nil },
  { label = "Enum (backed: string)", keyword = "enum", modifier = "", enum_backing = "string" },
  { label = "Enum (backed: int)", keyword = "enum", modifier = "", enum_backing = "int" },
}

---@param kind table  one entry from KINDS
---@param name string
---@return string[]
local function skeleton_body(kind, name)
  local header = (kind.modifier or "") .. kind.keyword .. " " .. name
  if kind.enum_backing then
    header = header .. ": " .. kind.enum_backing
  end
  return { header, "{", "}", "" }
end

--- Prompt for kind + name and create the file with proper boilerplate
function M.create()
  local root = find_project_root()
  if not root then
    vim.notify("Could not find composer.json in parent directories", vim.log.levels.ERROR)
    return
  end

  local mappings = parse_psr4_mappings(root)
  if vim.tbl_isempty(mappings) then
    vim.notify("No PSR-4 autoload mappings found in composer.json", vim.log.levels.WARN)
  end

  local current_dir = vim.fn.expand("%:p:h")
  if current_dir == "" then
    current_dir = vim.fn.getcwd()
  end

  vim.ui.select(KINDS, {
    prompt = "New PHP type:",
    format_item = function(kind)
      return kind.label
    end,
  }, function(kind)
    if not kind then
      return
    end

    vim.ui.input({ prompt = kind.label .. " name: " }, function(name)
      if not name or name == "" then
        return
      end

      if not name:match("^[A-Z][A-Za-z0-9_]*$") then
        vim.notify("Invalid name. Must start with an uppercase letter.", vim.log.levels.ERROR)
        return
      end

      local filepath = current_dir .. "/" .. name .. ".php"

      if vim.fn.filereadable(filepath) == 1 then
        vim.notify("File already exists: " .. filepath, vim.log.levels.ERROR)
        return
      end

      local namespace = resolve_namespace(current_dir, mappings)

      local lines = { "<?php", "", "declare(strict_types=1);", "" }

      if namespace then
        table.insert(lines, "namespace " .. namespace .. ";")
        table.insert(lines, "")
      end

      vim.list_extend(lines, skeleton_body(kind, name))

      local file = io.open(filepath, "w")
      if not file then
        vim.notify("Could not create file: " .. filepath, vim.log.levels.ERROR)
        return
      end
      file:write(table.concat(lines, "\n"))
      file:close()

      vim.cmd("edit " .. vim.fn.fnameescape(filepath))
      vim.api.nvim_win_set_cursor(0, { #lines - 2, 0 })
      vim.cmd("startinsert")

      vim.notify("Created: " .. name .. ".php (" .. kind.label .. ")", vim.log.levels.INFO)
    end)
  end)
end

return M
