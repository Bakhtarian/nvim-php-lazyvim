--- plugins/frontend.lua
---
--- Vue/TypeScript linting (ESLint) and formatting (Prettier), Docker-aware
--- via util/docker.lua -- the same pattern plugins/php.lua uses for
--- PHPStan/Pint/PHPUnit. Both run as one-shot CLI processes (unlike the
--- vtsls/vue_ls LSP servers enabled via the `lang.vue` extra in
--- config/lazy.lua, which stay local: an LSP is a long-lived process, not a
--- per-invocation command, so it doesn't fit this container-resolution
--- pattern the way a CLI tool does).
local FRONTEND_FILETYPES = { "javascript", "javascriptreact", "typescript", "typescriptreact", "vue" }

return {
  -----------------------------------------------------------------------------
  -- Treesitter: the `lang.vue` extra only ensures `vue`/`css` -- plain
  -- JS/TS/TSX parsers still need to be requested explicitly.
  -----------------------------------------------------------------------------
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed, { "javascript", "typescript", "tsx" })
    end,
  },

  -----------------------------------------------------------------------------
  -- Linting: ESLint -- Docker-aware via util/docker.lua.
  --
  -- Deliberately a one-shot CLI linter (nvim-lint) rather than LazyVim's
  -- stock LSP-based `linting.eslint` extra: an LSP is a long-lived process
  -- nvim talks to directly, which can't be resolved into "run inside
  -- whichever container owns this buffer" per invocation the way a plain
  -- command can. Trade-off: no inline LSP quick-fixes/hover from ESLint
  -- itself (vtsls/vue_ls still give you those for type errors) -- diagnostics
  -- only, same shape as the PHPStan integration below.
  -----------------------------------------------------------------------------
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      local docker = require("util.docker")

      opts.linters_by_ft = opts.linters_by_ft or {}
      for _, ft in ipairs(FRONTEND_FILETYPES) do
        opts.linters_by_ft[ft] = { "eslint" }
      end

      opts.linters = opts.linters or {}
      opts.linters.eslint = function()
        local bufname = vim.api.nvim_buf_get_name(0)
        local info = docker.resolve(bufname)

        local severities = { vim.diagnostic.severity.WARN, vim.diagnostic.severity.ERROR }
        local parser = function(output)
          local trimmed = vim.trim(output or "")
          if trimmed == "" then
            return {}
          end
          if trimmed:find("No ESLint configuration found", 1, true) then
            vim.notify_once(trimmed, vim.log.levels.WARN)
            return {}
          end
          local ok, decoded = pcall(vim.json.decode, output, { luanil = { object = true, array = true } })
          if not ok then
            return {}
          end
          local diagnostics = {}
          for _, result in ipairs(decoded or {}) do
            for _, msg in ipairs(result.messages or {}) do
              table.insert(diagnostics, {
                lnum = msg.line and (msg.line - 1) or 0,
                end_lnum = msg.endLine and (msg.endLine - 1) or nil,
                col = msg.column and (msg.column - 1) or 0,
                end_col = msg.endColumn and (msg.endColumn - 1) or nil,
                message = msg.message,
                code = msg.ruleId,
                severity = severities[msg.severity],
                source = "eslint",
              })
            end
          end
          return diagnostics
        end

        if info == false then
          return { cmd = "false", args = {}, stdin = false, ignore_exitcode = true, parser = parser }
        end

        local stdin_filename = info and docker.to_container_path(info, bufname) or bufname
        local eslint_args = { "--format", "json", "--stdin", "--stdin-filename", stdin_filename }

        if info then
          local args = { "compose" }
          vim.list_extend(args, docker.compose_flags(info))
          vim.list_extend(args, { "exec", "-T", info.service, "./node_modules/.bin/eslint" })
          vim.list_extend(args, eslint_args)
          return {
            cmd = "docker",
            args = args,
            stdin = true,
            ignore_exitcode = true,
            cwd = info.root,
            parser = parser,
          }
        end

        local local_binary = vim.fn.fnamemodify("./node_modules/.bin/eslint", ":p")
        local eslint_bin = (vim.uv.fs_stat(local_binary) and local_binary) or "eslint"
        return {
          cmd = eslint_bin,
          args = eslint_args,
          stdin = true,
          ignore_exitcode = true,
          parser = parser,
        }
      end
    end,
  },

  -----------------------------------------------------------------------------
  -- Formatting: Prettier -- Docker-aware via util/docker.lua, same shape as
  -- the php_cs_fixer/pint formatter in plugins/php.lua.
  -----------------------------------------------------------------------------
  {
    "stevearc/conform.nvim",
    opts = function(_, opts)
      local docker = require("util.docker")

      opts.formatters_by_ft = opts.formatters_by_ft or {}
      for _, ft in ipairs(FRONTEND_FILETYPES) do
        opts.formatters_by_ft[ft] = { "prettier" }
      end

      opts.formatters = opts.formatters or {}
      opts.formatters.prettier = {
        command = function(_, ctx)
          local info = docker.resolve(ctx.filename)
          if info == false then
            return "false"
          end
          if info then
            return "docker"
          end
          return "prettier"
        end,
        args = function(_, ctx)
          local info = docker.resolve(ctx.filename)
          if info == false then
            return {}
          end
          local stdin_filename = info and docker.to_container_path(info, ctx.filename) or ctx.filename
          if info then
            local args = { "compose" }
            vim.list_extend(args, docker.compose_flags(info))
            vim.list_extend(args, {
              "exec", "-T", info.service,
              "./node_modules/.bin/prettier", "--stdin-filepath", stdin_filename,
            })
            return args
          end
          return { "--stdin-filepath", stdin_filename }
        end,
        cwd = function(_, ctx)
          local info = docker.resolve(ctx.filename)
          if info then
            return info.root
          end
          return nil
        end,
        stdin = true,
      }
    end,
  },
}
