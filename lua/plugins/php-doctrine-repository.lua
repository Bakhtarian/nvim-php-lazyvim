--- plugins/php-doctrine-repository.lua
---
--- Wiring for the Doctrine entity <-> repository navigation glyph --
--- see util/php-doctrine-repository.lua for the resolution logic this
--- calls, and docs/superpowers/specs/2026-09-03-doctrine-repository-
--- glyphs-design.md for the full design. This file owns everything the
--- resolver deliberately doesn't: sign definition, the recompute
--- autocmds, the <leader>cd keymap, and :PhpDoctrineRefresh.
---
--- Judgment call not pinned down by the spec: the spec only describes
--- glyph placement on the ENTITY side (the #[ORM\Entity(...)] attribute
--- line). A repository file has no attribute of its own to anchor to,
--- but leaving it with no visual cue at all would mean half of this
--- "PhpStorm-style navigation" feature is invisible -- so a repository
--- whose file appears as a key in the (already-built) reverse index
--- also gets a "D " glyph, on its own class declaration line. This is
--- deliberately NOT used to trigger the first, lazy reverse-index
--- build (see refresh() below) -- only <leader>cd does that -- so it
--- only appears once the index has been built by some other means in
--- this session, exactly matching the "lazily built on first
--- repository-file open" wording by treating "open" as "first
--- attempted navigation", not literally every BufEnter.

local SIGN_GROUP = "php_doctrine_repository"
local DOCTRINE_SIGN = "PhpGlyphDoctrine"

-- A third color distinct from method-glyphs' green ("I") / blue ("O"),
-- still linked to a built-in highlight group rather than hardcoded hex
-- for the same theme-adaptive reasons -- see that file's sign_define.
vim.fn.sign_define(DOCTRINE_SIGN, { text = "D ", texthl = "DiagnosticHint" })

---@param bufnr integer
---@return userdata|nil
local function get_class_decl_node(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "php")
  if not ok or not parser then
    return nil
  end
  local root = parser:parse()[1]:root()
  local function find(node)
    if node:type() == "class_declaration" then
      return node
    end
    for child in node:iter_children() do
      local found = find(child)
      if found then
        return found
      end
    end
  end
  return find(root)
end

--- Recompute and redraw `bufnr`'s Doctrine glyph(s), caching results on
--- the buffer for the keymap and :PhpGlyphsDebug to read back.
--- Forward (entity) glyph is always (re)computed here. The repository-
--- side glyph is only rendered if the reverse index has ALREADY been
--- built by this point in the session -- see the file header for why
--- this deliberately doesn't force that (comparatively expensive,
--- ~74-file) build just from passively opening some unrelated buffer.
---@param bufnr integer
local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.fn.sign_unplace(SIGN_GROUP, { buffer = bufnr })
  vim.b[bufnr].php_doctrine_forward = nil
  vim.b[bufnr].php_doctrine_forward_failure = nil
  vim.b[bufnr].php_doctrine_reverse_entries = nil

  local doctrine = require("util.php-doctrine-repository")
  local fwd, failure = doctrine.compute_forward(bufnr)
  if fwd then
    vim.fn.sign_place(0, SIGN_GROUP, DOCTRINE_SIGN, bufnr, { lnum = fwd.line + 1, priority = 20 })
    vim.b[bufnr].php_doctrine_forward = fwd
  elseif failure then
    vim.b[bufnr].php_doctrine_forward_failure = failure
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local built = doctrine.reverse_index_if_built()
  local entries = built and built[path]
  if entries and #entries > 0 then
    local decl = get_class_decl_node(bufnr)
    local name_node = decl and decl:field("name")[1]
    if name_node then
      local row = select(1, name_node:start())
      vim.fn.sign_place(0, SIGN_GROUP, DOCTRINE_SIGN, bufnr, { lnum = row + 1, priority = 20 })
      vim.b[bufnr].php_doctrine_reverse_entries = entries
    end
  end
end

--- <leader>cd handler. Entity side: cursor must be on the glyphed
--- attribute line, same UX as php-method-glyphs.lua's <leader>ci --
--- jump to the already-resolved target, no extra LSP round trip.
--- Repository side: no cursor-position requirement (a repository file
--- has exactly one relevant "line" conceptually, the class itself) --
--- looks up the reverse index BY THIS BUFFER'S PATH, building it
--- lazily on first use if it hasn't been built yet this session (this
--- is the actual "first repository-file open" trigger the spec
--- describes, deliberately fired by attempted navigation rather than
--- passive BufEnter -- see the file header). One match jumps directly;
--- more than one shows a picker, mirroring php-keymaps.lua's <M-F6>
--- refactor menu; zero matches (or nothing resolvable either
--- direction) is a silent no-op with an informational notify, matching
--- php-method-glyphs.lua's own <leader>ci UX for "nothing here".
---@param bufnr integer
local function navigate(bufnr)
  local doctrine = require("util.php-doctrine-repository")

  local fwd = vim.b[bufnr].php_doctrine_forward
  if fwd then
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    if lnum - 1 == fwd.line then
      vim.cmd("edit " .. vim.fn.fnameescape(fwd.target_file))
      vim.api.nvim_win_set_cursor(0, { fwd.target_line + 1, 0 })
      return
    end
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local index = doctrine.reverse_index(path) -- builds lazily if needed
  local entries = index and index[path]

  if not entries or #entries == 0 then
    vim.notify("php-doctrine-repository: no entity/repository link on this buffer", vim.log.levels.INFO)
    return
  end

  -- Now that the index exists, this buffer's own repository-side glyph
  -- (if any) may not have been drawn yet if this was the FIRST
  -- <leader>cd press in the session -- refresh so it appears immediately
  -- rather than only on the next BufEnter/save.
  refresh(bufnr)

  if #entries == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(entries[1].entity_file))
    vim.api.nvim_win_set_cursor(0, { entries[1].entity_line + 1, 0 })
    return
  end

  local choices = {}
  for _, e in ipairs(entries) do
    table.insert(choices, vim.fn.fnamemodify(e.entity_file, ":t:r"))
  end
  vim.ui.select(choices, { prompt = "Entity:" }, function(_, idx)
    if idx then
      local e = entries[idx]
      vim.cmd("edit " .. vim.fn.fnameescape(e.entity_file))
      vim.api.nvim_win_set_cursor(0, { e.entity_line + 1, 0 })
    end
  end)
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = "php",
  callback = function(event)
    -- Same buflisted guard as php-method-glyphs.lua, and for the same
    -- reason: this feature's own reverse-index build bufadd/bufloads
    -- ~74 hidden buffers, and without this guard THIS autocmd firing
    -- for every one of them would be redundant work at best.
    if not vim.bo[event.buf].buflisted then
      return
    end

    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
      buffer = event.buf,
      callback = function()
        refresh(event.buf)
      end,
    })

    vim.api.nvim_create_autocmd("LspAttach", {
      buffer = event.buf,
      callback = function(attach_event)
        local client = vim.lsp.get_client_by_id(attach_event.data.client_id)
        if client and client.name == "intelephense" then
          refresh(event.buf)
        end
      end,
    })

    refresh(event.buf)

    vim.keymap.set("n", "<leader>cd", function()
      navigate(event.buf)
    end, { buffer = event.buf, desc = "PHP: Go to Doctrine entity/repository" })
  end,
})

vim.api.nvim_create_user_command("PhpDoctrineRefresh", function()
  require("util.php-doctrine-repository").clear_reverse_cache()
  vim.notify(
    "php-doctrine-repository: reverse index cleared, next <leader>cd (or buffer open) rebuilds it",
    vim.log.levels.INFO
  )
end, { desc = "Clear the cached Doctrine repository->entity reverse index" })

return {}
