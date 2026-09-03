--- util/php-doctrine-repository.lua
---
--- Resolution logic for the Doctrine entity <-> repository navigation
--- glyph. See docs/superpowers/specs/2026-09-03-doctrine-repository-
--- glyphs-design.md for the full design -- this file implements that
--- spec, it doesn't re-derive it. No side effects here: no signs, no
--- autocmds, no notifications -- plugins/php-doctrine-repository.lua
--- owns all of that.
---
--- Forward (M.compute_forward): parse the buffer's class declaration
--- for a #[ORM\Entity(repositoryClass: X::class)] (or bare
--- #[Entity(...)]) attribute, resolve X's declaring file+line via the
--- SAME free textDocument/definition mechanism util/php-method-
--- glyphs.lua already built and proved (LocationLink[]-aware) --
--- re-implemented here rather than requiring that module's locals,
--- since none of its helpers are exported, but the logic is mirrored
--- verbatim per the spec's "reuse verbatim, not reinvented" call.
--- Unlike method-glyphs, this needs no recursive walk: one attribute
--- argument resolves in one textDocument/definition hop, and that
--- response's own range already IS the target's declaration line, so
--- there's no need to separately load/parse the resolved repository
--- file at all.
---
--- Reverse (M.reverse_index): a lazily-built, session-cached map from
--- repository file -> [{entity_file, entity_line}, ...], built by
--- grepping the workspace for `repositoryClass` and running the same
--- forward resolution against every match. See the spec's "Why LSP
--- resolution, not a hand-rolled PSR-4 path resolver" for why this
--- reuses per-file LSP resolution instead of a textual shortcut.

local M = {}

---@param node userdata
---@return userdata|nil
local function find_class_decl(node)
  if node:type() == "class_declaration" then
    return node
  end
  for child in node:iter_children() do
    local found = find_class_decl(child)
    if found then
      return found
    end
  end
  return nil
end

---@param bufnr integer
---@return userdata|nil
local function get_root(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "php")
  if not ok or not parser then
    return nil
  end
  return parser:parse()[1]:root()
end

---@param bufnr integer
---@return vim.lsp.Client|nil
local function intelephense_client(bufnr)
  return (vim.lsp.get_clients({ bufnr = bufnr, name = "intelephense" }) or {})[1]
end

--- The class-name node inside `decl`'s `#[ORM\Entity(repositoryClass:
--- X::class)]` (or bare `#[Entity(...)]`) attribute argument, or nil if
--- `decl` has no such attribute (most classes don't -- entities only).
--- Matched by the attribute name's LAST path segment being "Entity" --
--- handles both the `ORM\Entity` alias-import form and a bare direct
--- `Entity` import (the spec's two valid forms) without needing to
--- pre-resolve which import an unqualified name came from, since
--- that's exactly what textDocument/definition is for downstream.
---@param bufnr integer
---@param decl userdata
---@return userdata|nil
local function repository_class_name_node(bufnr, decl)
  local attr_list = decl:field("attributes")[1]
  if not attr_list then
    return nil
  end

  for group in attr_list:iter_children() do
    if group:type() == "attribute_group" then
      for attr in group:iter_children() do
        if attr:type() == "attribute" then
          local name_node, args_node
          for c in attr:iter_children() do
            if not name_node and (c:type() == "name" or c:type() == "qualified_name") then
              name_node = c
            elseif c:type() == "arguments" then
              args_node = c
            end
          end
          if name_node and args_node then
            local text = vim.treesitter.get_node_text(name_node, bufnr)
            local last_segment = text:match("([^\\]+)$") or text
            if last_segment == "Entity" then
              for arg in args_node:iter_children() do
                if arg:type() == "argument" then
                  local label = arg:field("name")[1]
                  if label and vim.treesitter.get_node_text(label, bufnr) == "repositoryClass" then
                    -- children are [name, ":", value] positionally --
                    -- "value" isn't a named field (verified against the
                    -- installed grammar), so take whatever follows the
                    -- ":" token.
                    local seen_colon = false
                    for c in arg:iter_children() do
                      if seen_colon and c:type() == "class_constant_access_expression" then
                        for gc in c:iter_children() do
                          if gc:type() == "name" or gc:type() == "qualified_name" then
                            return gc
                          end
                        end
                      end
                      if c:type() == ":" then
                        seen_colon = true
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return nil
end

--- Resolve `name_node`'s definition via Intelephense's free
--- textDocument/definition. Returns the target file+line directly --
--- no recursion, no buffer-loading of the target, since a single
--- attribute-argument reference needs only one hop and the response's
--- own range already covers the target declaration's line (verified
--- against a real Intelephense response, not assumed).
---@param bufnr integer
---@param client vim.lsp.Client
---@param name_node userdata
---@return {file: string, line: integer}|nil
---@return string|nil failure_reason
local function resolve_definition(bufnr, client, name_node)
  local row, col = name_node:start()
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = row, character = col },
  }
  local responses = vim.lsp.buf_request_sync(bufnr, "textDocument/definition", params, 2000)
  local resp = responses and responses[client.id]
  if not resp or resp.err or not resp.result then
    return nil, "textDocument/definition failed or returned nothing"
  end

  -- Same LocationLink[] vs Location normalization php-method-glyphs.lua
  -- already had to add -- Intelephense uses targetUri/
  -- targetSelectionRange, not the plain Location uri/range shape.
  local loc = resp.result[1] or resp.result
  local uri = loc and (loc.uri or loc.targetUri)
  local range = loc and (loc.range or loc.targetSelectionRange)
  if not loc or not uri or not range then
    return nil, "no definition location returned"
  end

  return { file = vim.uri_to_fname(uri), line = range.start.line }, nil
end

---@class PhpDoctrineForward
---@field line integer          0-indexed: the #[ORM\Entity(...)] attribute line
---@field target_file string
---@field target_line integer   0-indexed

--- Forward resolution for `bufnr`: does this buffer's class carry a
--- repositoryClass attribute, and if so, what does it resolve to.
---@param bufnr integer
---@return PhpDoctrineForward|nil
---@return string|nil failure_reason  present only when a repositoryClass WAS found but couldn't resolve
function M.compute_forward(bufnr)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()

  local root = get_root(bufnr)
  if not root then
    return nil, nil
  end
  local decl = find_class_decl(root)
  if not decl then
    return nil, nil
  end

  local name_node = repository_class_name_node(bufnr, decl)
  if not name_node then
    return nil, nil -- not an entity -- not a failure, just nothing to glyph
  end

  local client = intelephense_client(bufnr)
  if not client then
    return nil, "no Intelephense client attached"
  end

  local target, reason = resolve_definition(bufnr, client, name_node)
  if not target then
    return nil, reason
  end

  local attr_row = select(1, name_node:start())
  -- Walk up from the class-name token to the enclosing attribute_group's
  -- own start row, since name_node sits deep inside
  -- argument/arguments/attribute -- the glyph belongs on the `#[...]`
  -- line itself (spec: "the attribute line itself"), which for a
  -- single-line attribute (the overwhelmingly common case) is the same
  -- row as the class-constant token anyway, but this is correct even if
  -- someone wraps the attribute across lines.
  local node = name_node
  while node and node:type() ~= "attribute_group" do
    node = node:parent()
  end
  local glyph_row = node and select(1, node:start()) or attr_row

  return { line = glyph_row, target_file = target.file, target_line = target.line }, nil
end

-- Reverse index: repository file -> [{entity_file, entity_line}, ...].
-- Session-cached, built lazily on first repository-file open. See the
-- spec's "Index lifecycle" for why this is never auto-invalidated.
local reverse_cache = nil

--- Every PHP file under `<composer-root>/...` that mentions
--- `repositoryClass` at all (a cheap textual pre-filter -- the real
--- attribute parse happens per-candidate below, this just avoids
--- treesitter-parsing every file in the project).
---@param src_root string
---@return string[]
local function grep_candidates(src_root)
  local result = vim.system({ "grep", "-rl", "repositoryClass", src_root }, { text = true }):wait()
  -- grep exits 1 (not an error) when nothing matches at all -- only
  -- treat a genuinely unexpected exit code as worth reporting, and even
  -- then just return no candidates rather than blocking the index build
  -- (this is a best-effort scan, not a docker.lua-style "fail loud").
  if result.code ~= 0 and result.code ~= 1 then
    return {}
  end
  return vim.split(vim.trim(result.stdout or ""), "\n", { plain = true, trimempty = true })
end

--- Build (or rebuild) the reverse index by grepping `src_root` and
--- forward-resolving every candidate file. Each candidate is loaded as
--- a hidden, unlisted buffer (never displayed) so it can carry its own
--- Intelephense client to run textDocument/definition from -- the
--- SAME load-and-wait-for-attach shape php-method-glyphs.lua's
--- resolve_and_load uses, just not recursive (Doctrine resolution is
--- always exactly one hop). Buffers loaded here are left open
--- afterwards (not deleted), matching that same precedent, so a
--- :PhpDoctrineRefresh-triggered rebuild in the same session doesn't
--- pay the attach-wait cost again for files already touched.
---@param src_root string
---@return table<string, {entity_file: string, entity_line: integer}[]>
local function build_reverse_index(src_root)
  local index = {}
  for _, path in ipairs(grep_candidates(src_root)) do
    local bufnr = vim.fn.bufadd(path)
    -- buflisted MUST be set before bufload(), not after -- see the
    -- matching comment in php-method-glyphs.lua's resolve_and_load for
    -- why: bufload() fires FileType, and that feature's FileType
    -- autocmd guards on buflisted specifically to stop a bulk scan like
    -- this one from cascading into E218 (autocommand nesting too deep).
    vim.bo[bufnr].buflisted = false
    vim.fn.bufload(bufnr)
    if vim.bo[bufnr].filetype ~= "php" then
      vim.api.nvim_set_option_value("filetype", "php", { buf = bufnr })
    end

    local client
    vim.wait(1500, function()
      client = intelephense_client(bufnr)
      return client ~= nil
    end, 25)
    if client then
      local root = get_root(bufnr)
      local decl = root and find_class_decl(root)
      if decl then
        local name_node = repository_class_name_node(bufnr, decl)
        if name_node then
          local target = resolve_definition(bufnr, client, name_node)
          if target then
            local class_name_node = decl:field("name")[1]
            local entity_line = class_name_node and select(1, class_name_node:start()) or 0
            index[target.file] = index[target.file] or {}
            table.insert(index[target.file], { entity_file = path, entity_line = entity_line })
          end
        end
      end
    end
  end
  return index
end

--- The reverse index for `bufname`'s project, building it lazily on
--- first call and caching for the rest of the session (see "Index
--- lifecycle" in the spec). Returns nil if no composer.json root can
--- be found at all.
---@param bufname string
---@return table<string, {entity_file: string, entity_line: integer}[]>|nil
function M.reverse_index(bufname)
  if reverse_cache then
    return reverse_cache
  end
  local src_root = vim.fs.root(bufname, "composer.json")
  if not src_root then
    return nil
  end
  reverse_cache = build_reverse_index(src_root)
  return reverse_cache
end

--- The cached reverse index if one has already been built this
--- session, WITHOUT triggering a build -- for callers (the repository-
--- side glyph render in plugins/php-doctrine-repository.lua) that
--- should only use an index that's already there, never pay the
--- ~74-file scan cost just from a passive buffer open. Contrast with
--- M.reverse_index() above, which builds lazily on demand -- that one
--- is for <leader>cd itself, the intentional "first repository-file
--- open" trigger.
---@return table<string, {entity_file: string, entity_line: integer}[]>|nil
function M.reverse_index_if_built()
  return reverse_cache
end

--- Drop the cached reverse index so the next M.reverse_index() call
--- rebuilds it from scratch. Bound to :PhpDoctrineRefresh.
function M.clear_reverse_cache()
  reverse_cache = nil
end

return M
