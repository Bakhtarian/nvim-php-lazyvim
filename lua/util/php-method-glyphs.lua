--- util/php-method-glyphs.lua
---
--- Resolution logic for the PhpStorm-style "implements"/"overrides"
--- gutter glyphs. See docs/superpowers/specs/2026-09-03-php-method-
--- glyphs-design.md for the full design and the reasoning behind every
--- decision below -- this file implements that spec, it doesn't re-derive
--- it. No side effects here: no signs, no autocmds, no notifications --
--- plugins/php-method-glyphs.lua owns all of that.
---
--- Pipeline: treesitter finds the buffer's class/interface/trait/enum
--- declaration and its implements/extends/use clauses -> each named
--- supertype or trait is resolved via a free `textDocument/definition`
--- request against Intelephense (never the premium find-implementations/
--- type-hierarchy capabilities -- see the spec's "Why not Intelephense's
--- premium type hierarchy") -> the resolved file is loaded as a hidden,
--- unlisted buffer and walked the same way, recursively -> every method
--- found anywhere in that walk becomes one entry in a `name -> {abstract,
--- file, line}` map -> the original class's own methods (declared
--- directly, or contributed via a `use SomeTrait;`) are matched against
--- that map to produce glyphs.
---
--- Resolution failures (a vendor interface Intelephense hasn't indexed,
--- a file it can't attach to in time, ...) are swallowed silently, one
--- supertype at a time -- this is deliberately the opposite of
--- util/docker.lua's "fail loud" philosophy, because the consequence
--- here is purely cosmetic (one method doesn't get a glyph it arguably
--- deserves), not a wrong container silently producing wrong output.
--- Every failure is still recorded and returned, though, so
--- `:PhpGlyphsDebug` (plugins/php-method-glyphs.lua) can show what did
--- and didn't resolve on demand without being noisy by default.

local M = {}

---@alias TSNode userdata

local DECL_TYPES = {
  class_declaration = true,
  interface_declaration = true,
  trait_declaration = true,
  enum_declaration = true,
}

--- First class/interface/trait/enum declaration found anywhere in the
--- tree (depth-first) -- real-world PHP is one such declaration per file
--- (PSR-4), so "first found" is "the" declaration in practice, but this
--- doesn't assume it's a direct child of the root: it's still nested
--- under namespace/declare/use statements' sibling structure, which
--- treesitter's PHP grammar keeps flat, but walking generically here
--- costs nothing and needs no assumption about that flatness.
---@param node TSNode
---@return TSNode|nil
local function find_decl_node(node)
  if DECL_TYPES[node:type()] then
    return node
  end
  for child in node:iter_children() do
    local found = find_decl_node(child)
    if found then
      return found
    end
  end
  return nil
end

---@param bufnr integer
---@return TSNode|nil
local function get_root(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "php")
  if not ok or not parser then
    return nil
  end
  return parser:parse()[1]:root()
end

--- Every `implements`/`extends` name in `decl`'s `base_clause` and
--- `class_interface_clause` children. Both node types can hold more than
--- one comma-separated name (multiple `implements`, or an interface
--- `extends`-ing more than one parent interface) -- PHP forbids multiple
--- class extends, but the grammar node shape is shared, so this doesn't
--- special-case it, it just collects whatever names are actually there.
---@param decl TSNode
---@return TSNode[]  name/qualified_name nodes
local function supertype_name_nodes(decl)
  local names = {}
  for child in decl:iter_children() do
    if child:type() == "base_clause" or child:type() == "class_interface_clause" then
      for grandchild in child:iter_children() do
        if grandchild:type() == "name" or grandchild:type() == "qualified_name" then
          table.insert(names, grandchild)
        end
      end
    end
  end
  return names
end

--- Every `use TraitName;` in `decl`'s body, paired with the specific
--- `use_declaration` statement node it came from (needed so a trait-only-
--- contributed method's glyph can land on the right `use` line when a
--- class pulls in more than one trait -- see M.compute).
---@param decl TSNode
---@return {use_node: TSNode, name_node: TSNode}[]
local function trait_use_entries(decl)
  local entries = {}
  for child in decl:iter_children() do
    if child:type() == "use_declaration" then
      for grandchild in child:iter_children() do
        if grandchild:type() == "name" or grandchild:type() == "qualified_name" then
          table.insert(entries, { use_node = child, name_node = grandchild })
        end
      end
    end
  end
  return entries
end

--- Every `method_declaration` directly in `decl`'s body (a
--- `declaration_list` for class/interface/trait, an
--- `enum_declaration_list` for enums -- both hold `method_declaration`
--- children directly, so this doesn't need to care which one it is).
--- "Abstract" is read off the absence of a `body` field: true for every
--- interface method (never has one) and for a class/trait method marked
--- `abstract` (also never has one) alike -- one check covers both, no
--- need to separately special-case `interface_declaration` vs an
--- `abstract_modifier` child.
---@param bufnr integer
---@param decl TSNode
---@return {name: string, abstract: boolean, node: TSNode}[]
local function methods_of(bufnr, decl)
  local body = decl:field("body")[1]
  if not body then
    return {}
  end
  local methods = {}
  for child in body:iter_children() do
    if child:type() == "method_declaration" then
      local name_node = child:field("name")[1]
      if name_node then
        table.insert(methods, {
          name = vim.treesitter.get_node_text(name_node, bufnr),
          abstract = child:field("body")[1] == nil,
          node = child,
        })
      end
    end
  end
  return methods
end

---@param bufnr integer
---@return vim.lsp.Client|nil
local function intelephense_client(bufnr)
  return (vim.lsp.get_clients({ bufnr = bufnr, name = "intelephense" }) or {})[1]
end

--- Resolve `name_node`'s definition via Intelephense's free
--- textDocument/definition, then load the target file as a hidden,
--- unlisted buffer (creating/reusing it via `bufadd`, never displayed)
--- and wait for Intelephense to attach to it so IT can be walked the
--- same way. Returns nil on any failure -- an unresolvable name, a
--- location Intelephense can't or won't return (vendor code it hasn't
--- indexed, a stale/renamed symbol, ...), or a target file Intelephense
--- never attaches to in time -- and records why into `failures`, per
--- this feature's silent-per-supertype failure philosophy (see the file
--- header). `cache` memoizes by resolved path across one whole
--- M.compute() call, since the same interface or parent is often
--- reachable from more than one point in a class's hierarchy; loaded
--- buffers are intentionally left open afterwards (not deleted) so
--- repeat BufEnter/BufWritePost recomputes reuse them instead of paying
--- the attach-wait cost again every time.
---@param bufnr integer
---@param client vim.lsp.Client
---@param name_node TSNode
---@param cache table<string, {bufnr: integer, client: vim.lsp.Client, path: string}|false>
---@param failures {name: string, reason: string}[]
---@return {bufnr: integer, client: vim.lsp.Client, path: string}|nil
local function resolve_and_load(bufnr, client, name_node, cache, failures)
  local row, col = name_node:start()
  local name_text = vim.treesitter.get_node_text(name_node, bufnr)

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = row, character = col },
  }
  local responses = vim.lsp.buf_request_sync(bufnr, "textDocument/definition", params, 2000)
  local resp = responses and responses[client.id]
  if not resp or resp.err or not resp.result then
    table.insert(failures, { name = name_text, reason = "textDocument/definition failed or returned nothing" })
    return nil
  end

  -- Intelephense answers with LSP LocationLink[] (targetUri/
  -- targetSelectionRange), not the plain Location (uri/range) shape --
  -- normalize both, since the spec (correctly) doesn't distinguish and
  -- a server is free to use either per the LSP definition-response type.
  local loc = resp.result[1] or resp.result
  local uri = loc and (loc.uri or loc.targetUri)
  if not loc or not uri then
    table.insert(failures, { name = name_text, reason = "no definition location returned" })
    return nil
  end

  local path = vim.uri_to_fname(uri)
  local cached = cache[path]
  if cached ~= nil then
    return cached or nil -- `false` means "already tried, couldn't attach" -- still a cache hit, still nil to the caller
  end

  local target_bufnr = vim.fn.bufadd(path)
  -- buflisted MUST be set before bufload(), not after: bufload() is what
  -- fires FileType, and plugins/php-method-glyphs.lua's own FileType
  -- autocmd guards on buflisted specifically to stop this recursive load
  -- from cascading into itself (and into deep autocmd-nesting errors)
  -- across dozens of files during a bulk scan -- see that guard's
  -- comment for the full story.
  vim.bo[target_bufnr].buflisted = false
  vim.fn.bufload(target_bufnr)
  if vim.bo[target_bufnr].filetype ~= "php" then
    vim.api.nvim_set_option_value("filetype", "php", { buf = target_bufnr })
  end

  local target_client
  vim.wait(1500, function()
    target_client = intelephense_client(target_bufnr)
    return target_client ~= nil
  end, 25)

  if not target_client then
    table.insert(failures, { name = name_text, reason = "Intelephense never attached to " .. path })
    cache[path] = false
    return nil
  end

  local entry = { bufnr = target_bufnr, client = target_client, path = path }
  cache[path] = entry
  return entry
end

--- Recursively fold every method `decl` provides into `map` (keyed by
--- method name, first write wins -- callers walk outward from their
--- starting point, so the first write is always the closest one, per
--- spec step 5). "Provides" means: declared directly in `decl`'s own
--- body; contributed via any trait `decl` itself uses (recursively --
--- a trait can use other traits); or declared on anything `decl` itself
--- extends/implements (recursively). This one function is reused
--- identically whether `decl` is an interface, an abstract or concrete
--- parent class, or a trait -- a trait node simply has no base_clause/
--- class_interface_clause to walk, so that part is a silent no-op for
--- it, not a special case this function needs to know about.
---@param bufnr integer
---@param path string
---@param client vim.lsp.Client
---@param decl TSNode
---@param cache table
---@param failures table
---@param map table<string, {abstract: boolean, file: string, line: integer}>
---@param visited table<string, true>  paths already folded into THIS map
local function collect(bufnr, path, client, decl, cache, failures, map, visited)
  if visited[path] then
    return
  end
  visited[path] = true

  for _, m in ipairs(methods_of(bufnr, decl)) do
    if map[m.name] == nil then
      local nrow = select(1, m.node:field("name")[1]:start())
      map[m.name] = { abstract = m.abstract, file = path, line = nrow }
    end
  end

  for _, entry in ipairs(trait_use_entries(decl)) do
    local target = resolve_and_load(bufnr, client, entry.name_node, cache, failures)
    if target then
      local tdecl = find_decl_node(get_root(target.bufnr) or target.bufnr)
      if tdecl then
        collect(target.bufnr, target.path, target.client, tdecl, cache, failures, map, visited)
      end
    end
  end

  for _, name_node in ipairs(supertype_name_nodes(decl)) do
    local target = resolve_and_load(bufnr, client, name_node, cache, failures)
    if target then
      local tdecl = find_decl_node(get_root(target.bufnr))
      if tdecl then
        collect(target.bufnr, target.path, target.client, tdecl, cache, failures, map, visited)
      end
    end
  end
end

---@class PhpMethodGlyph
---@field line integer         0-indexed line to place the glyph on
---@field kind "implements"|"overrides"
---@field target_file string
---@field target_line integer  0-indexed

--- Compute every implements/overrides glyph for `bufnr`'s PHP buffer.
---@param bufnr integer
---@return PhpMethodGlyph[] glyphs
---@return {name: string, reason: string}[] failures  for :PhpGlyphsDebug
function M.compute(bufnr)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()

  local root = get_root(bufnr)
  if not root then
    return {}, {}
  end
  local decl = find_decl_node(root)
  if not decl then
    return {}, {}
  end

  local client = intelephense_client(bufnr)
  if not client then
    return {}, {}
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local cache = {}
  local failures = {}

  -- What this class HAS via traits (a contribution, not a requirement) --
  -- its own separate map/visited-set so a file reachable via both a
  -- trait chain and a supertype chain below gets folded into BOTH,
  -- rather than the second walk silently no-op'ing because the first
  -- one already marked that path visited.
  local trait_map = {}
  local trait_source = {} -- method name -> the use_declaration node providing it (first wins)
  for _, entry in ipairs(trait_use_entries(decl)) do
    local target = resolve_and_load(bufnr, client, entry.name_node, cache, failures)
    if target then
      local tdecl = find_decl_node(get_root(target.bufnr))
      if tdecl then
        local this_trait_map, visited = {}, {}
        collect(target.bufnr, target.path, target.client, tdecl, cache, failures, this_trait_map, visited)
        for name in pairs(this_trait_map) do
          if trait_source[name] == nil then
            trait_map[name] = this_trait_map[name]
            trait_source[name] = entry.use_node
          end
        end
      end
    end
  end

  -- What this class is REQUIRED to satisfy, via extends/implements.
  local requirement_map, visited = {}, {}
  for _, name_node in ipairs(supertype_name_nodes(decl)) do
    local target = resolve_and_load(bufnr, client, name_node, cache, failures)
    if target then
      local tdecl = find_decl_node(get_root(target.bufnr))
      if tdecl then
        collect(target.bufnr, target.path, target.client, tdecl, cache, failures, requirement_map, visited)
      end
    end
  end

  local own_methods = methods_of(bufnr, decl)
  local own_names = {}
  for _, m in ipairs(own_methods) do
    own_names[m.name] = true
  end

  local glyphs = {}

  -- Methods declared directly in this class: glyph their own line.
  for _, m in ipairs(own_methods) do
    local req = requirement_map[m.name]
    if req then
      table.insert(glyphs, {
        line = select(1, m.node:field("name")[1]:start()),
        kind = req.abstract and "implements" or "overrides",
        target_file = req.file,
        target_line = req.line,
      })
    end
  end

  -- Methods satisfied ONLY via a trait (not redeclared directly): glyph
  -- the `use TraitName;` line instead (spec step 9). A single use-line
  -- can satisfy more than one requirement at once; if those disagree on
  -- kind, "overrides" wins -- not explicitly covered by the spec, this
  -- extends its own step-8 diamond tiebreak (a concrete override is the
  -- more specific, more useful fact) to the same situation on a use-line.
  local use_line_kind, use_line_target = {}, {}
  for name in pairs(trait_map) do
    if not own_names[name] then
      local req = requirement_map[name]
      if req then
        local use_node = trait_source[name]
        local id = tostring(use_node:id())
        local kind = req.abstract and "implements" or "overrides"
        if use_line_kind[id] == nil or (use_line_kind[id] == "implements" and kind == "overrides") then
          use_line_kind[id] = kind
          use_line_target[id] = { node = use_node, file = req.file, line = req.line }
        end
      end
    end
  end
  for _, target in pairs(use_line_target) do
    table.insert(glyphs, {
      line = select(1, target.node:start()),
      kind = use_line_kind[tostring(target.node:id())],
      target_file = target.file,
      target_line = target.line,
    })
  end

  return glyphs, failures
end

return M
