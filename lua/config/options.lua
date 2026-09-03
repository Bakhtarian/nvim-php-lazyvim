-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- LazyVim is treesitter-only by default and never arms Vim's legacy
-- FileType-triggered `set syntax=...` autocmd -- fine for filetypes with a
-- treesitter grammar, but it silently leaves filetypes that DON'T have one
-- (e.g. Twig, via nelsyeung/twig.vim -- see plugins/symfony.lua) with zero
-- syntax highlighting at all, even once the plugin providing it is
-- correctly loaded. This coexists fine with treesitter for buffers that
-- have a grammar; it's only load-bearing for the ones that don't.
vim.cmd("syntax enable")

-- A second, always-present sign column for plugins/php-method-glyphs.lua's
-- implements/overrides glyphs. LazyVim's default `signcolumn = "yes"` is a
-- single column already shared between gitsigns and diagnostics, which
-- already compete with each other for the same slot -- a third sign
-- source sharing it risks silently not rendering on exactly the lines
-- most likely to have an uncommitted change or a diagnostic (see the
-- design spec's "Rendering" section for the full reasoning). One extra
-- fixed character of width in every buffer, not just PHP ones, is the
-- accepted cost.
vim.opt.signcolumn = "yes:2"
