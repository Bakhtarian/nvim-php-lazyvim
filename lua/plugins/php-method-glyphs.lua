--- plugins/php-method-glyphs.lua
---
--- Wiring for the PhpStorm-style implements/overrides gutter glyphs --
--- see util/php-method-glyphs.lua for the resolution logic this calls,
--- and docs/superpowers/specs/2026-09-03-php-method-glyphs-design.md
--- for the full design. This file owns everything the resolver
--- deliberately doesn't: sign definitions, the recompute autocmds, the
--- navigation keymap, and :PhpGlyphsDebug.
---
--- Recomputes on BufEnter/BufWritePost only (not live per keystroke --
--- each recompute is a handful of LSP round trips, see the spec's
--- "Refresh triggers"), scoped to PHP buffers via a FileType autocmd
--- that then registers the other two as buffer-local.

local SIGN_GROUP = "php_method_glyphs"
local IMPLEMENTS_SIGN = "PhpGlyphImplements"
local OVERRIDES_SIGN = "PhpGlyphOverrides"

-- Linked to Neovim's own built-in diagnostic highlight groups (always
-- defined, by every colorscheme) rather than hardcoded hex, so the
-- glyphs stay legible and theme-consistent regardless of colorscheme --
-- see the spec's "Glyph text and color".
vim.fn.sign_define(IMPLEMENTS_SIGN, { text = "I ", texthl = "DiagnosticOk" })
vim.fn.sign_define(OVERRIDES_SIGN, { text = "O ", texthl = "DiagnosticInfo" })

--- Recompute and redraw `bufnr`'s glyphs, and cache the result on the
--- buffer (keyed by 1-indexed line) for the navigation keymap and
--- :PhpGlyphsDebug to read back without recomputing.
---@param bufnr integer
local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local glyphs, failures = require("util.php-method-glyphs").compute(bufnr)

  vim.fn.sign_unplace(SIGN_GROUP, { buffer = bufnr })
  local by_line = {}
  for _, g in ipairs(glyphs) do
    local lnum = g.line + 1
    vim.fn.sign_place(0, SIGN_GROUP, g.kind == "implements" and IMPLEMENTS_SIGN or OVERRIDES_SIGN, bufnr, {
      lnum = lnum,
      priority = 20, -- above gitsigns/diagnostics' typical priority in the OTHER column; irrelevant here since this is its own dedicated column, but keeps this group internally consistent if ever shared
    })
    by_line[lnum] = g
  end

  vim.b[bufnr].php_method_glyphs = by_line
  vim.b[bufnr].php_method_glyphs_failures = failures
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = "php",
  callback = function(event)
    -- Hidden/unlisted buffers are never what a user is looking at --
    -- both this feature's own resolve_and_load and (as of the Doctrine
    -- repository-glyph feature) a workspace-wide reverse-index scan
    -- bufadd/bufload many PHP files as unlisted buffers purely to run
    -- LSP requests against them. Without this guard, EACH of those
    -- loads fires this very autocmd, which recursively bufadd/bufloads
    -- MORE files to walk ITS OWN interface/parent chain -- multiplied
    -- across dozens of files in a tight loop, that recursion blows
    -- Neovim's autocmd nesting limit (E218). Glyphs are purely visual;
    -- there is nothing to compute for a buffer nobody will ever see.
    if not vim.bo[event.buf].buflisted then
      return
    end
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
      buffer = event.buf,
      callback = function()
        refresh(event.buf)
      end,
    })

    -- FileType can fire before Intelephense has actually attached to
    -- this buffer (attach is async) -- an immediate refresh() here would
    -- silently find no client and produce zero glyphs, with nothing
    -- left to trigger a retry until the user happens to leave and
    -- re-enter the buffer or save it. LspAttach is the correct signal
    -- to also refresh on, scoped to intelephense specifically so
    -- phpactor attaching (it has no useful definitionProvider for this
    -- anyway, see plugins/php.lua) doesn't trigger a redundant one.
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

    vim.keymap.set("n", "<leader>ci", function()
      local by_line = vim.b[event.buf].php_method_glyphs or {}
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local glyph = by_line[lnum]
      if not glyph then
        vim.notify("php-method-glyphs: no interface/parent match on this line", vim.log.levels.INFO)
        return
      end
      vim.cmd("edit " .. vim.fn.fnameescape(glyph.target_file))
      vim.api.nvim_win_set_cursor(0, { glyph.target_line + 1, 0 })
    end, { buffer = event.buf, desc = "PHP: Go to Interface/parent implementation" })
  end,
})

vim.api.nvim_create_user_command("PhpGlyphsDebug", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local glyphs, failures = require("util.php-method-glyphs").compute(bufnr)

  local lines = { "php-method-glyphs debug: " .. vim.api.nvim_buf_get_name(bufnr), "" }
  table.insert(lines, string.format("Resolved (%d):", #glyphs))
  for _, g in ipairs(glyphs) do
    table.insert(
      lines,
      string.format("  line %d: %s -> %s:%d", g.line + 1, g.kind, g.target_file, g.target_line + 1)
    )
  end
  table.insert(lines, "")
  table.insert(lines, string.format("Unresolved (%d):", #failures))
  for _, f in ipairs(failures) do
    table.insert(lines, string.format("  %s: %s", f.name, f.reason))
  end

  -- Doctrine repository-attribute resolution shares this debug surface
  -- rather than getting its own command, per that feature's spec
  -- ("rather than introducing a second, parallel debug command a user
  -- would have to remember exists").
  table.insert(lines, "")
  table.insert(lines, "Doctrine:")
  local doctrine = require("util.php-doctrine-repository")
  local fwd, fwd_failure = doctrine.compute_forward(bufnr)
  if fwd then
    table.insert(
      lines,
      string.format("  line %d: repositoryClass -> %s:%d", fwd.line + 1, fwd.target_file, fwd.target_line + 1)
    )
  elseif fwd_failure then
    table.insert(lines, "  repositoryClass unresolved: " .. fwd_failure)
  else
    table.insert(lines, "  (no #[ORM\\Entity(repositoryClass: ...)] attribute on this class)")
  end
  local reverse = doctrine.reverse_index_if_built()
  if not reverse then
    table.insert(lines, "  reverse index: not built yet this session (run <leader>cd on a repository, or :PhpDoctrineRefresh)")
  else
    local entries = reverse[vim.api.nvim_buf_get_name(bufnr)]
    if entries then
      table.insert(lines, string.format("  this file is a repository for %d entit%s:", #entries, #entries == 1 and "y" or "ies"))
      for _, e in ipairs(entries) do
        table.insert(lines, string.format("    %s:%d", e.entity_file, e.entity_line + 1))
      end
    else
      local count = 0
      for _ in pairs(reverse) do
        count = count + 1
      end
      table.insert(lines, string.format("  reverse index built (%d repositories indexed); this file isn't one of them", count))
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "text"
  vim.cmd("botright split | resize 15")
  vim.api.nvim_win_set_buf(0, buf)
end, { desc = "PHP: Show what did/didn't resolve for implements/overrides glyphs" })

return {}
