return {
  "lewis6991/gitsigns.nvim",
  opts = {
    current_line_blame = true,
    -- author:date:summary -- the branch was here before (vim.b.gitsigns_head)
    -- but it's identical on every line in the buffer, so it told you nothing
    -- line-to-line; it's also always visible in lualine's statusline anyway.
    -- The commit summary is what actually varies per line and is useful.
    current_line_blame_formatter = function(_, blame_info)
      local date = os.date("%Y-%m-%d", blame_info.author_time)
      return {
        { ("   %s:%s:%s"):format(blame_info.author, date, blame_info.summary), "GitSignsCurrentLineBlame" },
      }
    end,
  },
}
