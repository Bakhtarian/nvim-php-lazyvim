return {
  -----------------------------------------------------------------------------
  -- Treesitter: PHP + PHPDoc syntax highlighting
  -----------------------------------------------------------------------------
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed, { "php", "phpdoc" })
    end,
  },

  -----------------------------------------------------------------------------
  -- LSP: Intelephense (completion/hover/diagnostics/references) +
  --      Phpactor (refactor engine only -- its own LSP capabilities that
  --      would duplicate/conflict with Intelephense are switched off below).
  -----------------------------------------------------------------------------
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        intelephense = {
          -- Unlike Phpactor (which already checks composer.json's platform
          -- pin / require.php constraint on its own), intelephense has no
          -- such auto-detection -- it just uses whatever `environment.
          -- phpVersion` is configured, so a single static value here would
          -- apply the SAME PHP version to every project. That's wrong the
          -- moment two projects target different versions (e.g. Project A
          -- on 8.2 while Project B is on 8.5): syntax the older project can't
          -- actually run would go unflagged. `on_new_config` runs once per
          -- resolved project root before the client for that root starts,
          -- so it can override the version per-project from that project's
          -- own composer.json (see util/php-version.lua) -- the static
          -- `environment.phpVersion` below is just the fallback for
          -- projects with no composer.json PHP constraint at all.
          on_new_config = function(new_config, new_root_dir)
            local php_version = require("util.php-version").resolve(new_root_dir)
            if php_version then
              new_config.settings = vim.tbl_deep_extend("force", new_config.settings or {}, {
                intelephense = { environment = { phpVersion = php_version } },
              })
            end
          end,
          settings = {
            intelephense = {
              files = { maxSize = 5000000 },
              environment = { phpVersion = "8.5" },
              format = { enable = true },
              diagnostics = { enable = true },
              completion = {
                fullyQualifyGlobalConstantsAndFunctions = true,
                triggerParameterHints = true,
              },
              phpdoc = { useFullyQualifiedNames = true },
            },
          },
          init_options = {
            licenceKey = os.getenv("INTELEPHENSE_LICENCE_KEY") or "",
            globalStoragePath = vim.fn.stdpath("data") .. "/intelephense",
          },
        },

        phpactor = {
          init_options = {
            ["language_server_configuration.auto_config"] = false,
            ["completion_worse.completor.keyword.enabled"] = false,
            ["language_server_worse_reflection.diagnostics.enable"] = false,
            ["language_server_completion.trim_leading_dollar"] = false,
            ["completion_worse.completor.class.enabled"] = false,
            -- Phpactor bundles its own PHPStan/Psalm/php-cs-fixer diagnostic
            -- extensions, all `enabled: true` by default (confirmed via
            -- `phpactor config:dump`), running `%project_root%/vendor/bin/
            -- <tool>` directly on the HOST -- completely bypassing this
            -- config's Docker-aware docker.lua layer that PHPStan and
            -- Pint/php-cs-fixer are already correctly wired through
            -- elsewhere (nvim-lint / conform.nvim), and Psalm isn't used
            -- anywhere in this config at all. Redundant at best, wrong-
            -- environment at worst, and loudly erroring on any project
            -- missing one of those host-local vendor/bin binaries -- keep
            -- Phpactor scoped to "refactor engine only" as intended.
            ["language_server_phpstan.enabled"] = false,
            ["language_server_psalm.enabled"] = false,
            ["language_server_php_cs_fixer.enabled"] = false,
            -- Belt-and-suspenders on top of the enable flags above: those
            -- get silently re-asserted by ~/.config/phpactor/phpactor.json
            -- (a GLOBAL, user-level Phpactor config this repo doesn't
            -- manage -- `language_server_configuration.auto_config` above
            -- only stops phpactor auto-discovering PROJECT-local config
            -- files, it does nothing about its own always-loaded global
            -- one). Confirmed live: a fresh `:lsp restart` re-sends these
            -- exact init_options correctly, yet worse.missing_member
            -- diagnostics still reappear seconds later -- some provider
            -- re-checks its OWN global config after attach and wins.
            -- diagnostic_ignore_codes filters by code at the very end of
            -- phpactor's own dispatch pipeline, after any provider has
            -- already run, so it isn't vulnerable to that same override --
            -- confirmed working already in that same global config file's
            -- own "worse.docblock_missing_param" entry. This suppresses
            -- ALL worse.missing_member diagnostics globally, including
            -- genuine ones -- accepted trade-off since Phpactor's own
            -- diagnostics are already fully disabled by design here
            -- (diagnosticProvider nulled below, three extensions disabled
            -- above); Intelephense stays the actual diagnostic engine and
            -- doesn't share this check's shallow-hierarchy false positives.
            ["language_server.diagnostic_ignore_codes"] = { "worse.missing_member" },
          },
          on_attach = function(client, _)
            client.server_capabilities.completionProvider = nil
            client.server_capabilities.hoverProvider = nil
            client.server_capabilities.diagnosticProvider = nil
            client.server_capabilities.signatureHelpProvider = nil
            client.server_capabilities.definitionProvider = nil
            client.server_capabilities.referencesProvider = nil
            client.server_capabilities.implementationProvider = nil
            client.server_capabilities.documentSymbolProvider = nil
          end,
        },
      },
    },
  },

  -----------------------------------------------------------------------------
  -- Mason: auto-install the tooling used both as LSP servers and via Docker
  -----------------------------------------------------------------------------
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed, {
        "intelephense",
        "phpactor",
        "php-debug-adapter",
      })
    end,
  },

  -----------------------------------------------------------------------------
  -- Phpactor refactor commands, exposed via LSP `workspace/executeCommand`
  -- instead of the deprecated `phpactor/phpactor` RPC Vim plugin (which
  -- ships :PhpactorMoveFile etc. -- those never worked here because that
  -- plugin was never installed, and it's deprecated upstream in favour of
  -- exactly this LSP-command approach).
  -----------------------------------------------------------------------------
  {
    "gbprod/phpactor.nvim",
    ft = "php",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      install = {
        -- Reuse the Mason-managed phpactor instead of maintaining a second copy.
        bin = vim.fn.stdpath("data") .. "/mason/bin/phpactor",
      },
      -- nvim-lspconfig above already owns the phpactor LSP client.
      lspconfig = { enabled = false },
    },
  },

  -----------------------------------------------------------------------------
  -- Linting: PHPStan -- Docker-aware via util/docker.lua
  --
  -- The whole linter definition is a function (not a static table), so it's
  -- re-resolved for the buffer being linted on every run instead of being
  -- fixed at startup. See util/docker.lua for why silent host-tool fallback
  -- is deliberately NOT what this does when a container can't be pinned down.
  -----------------------------------------------------------------------------
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      local docker = require("util.docker")

      opts.linters_by_ft = opts.linters_by_ft or {}
      opts.linters_by_ft.php = { "phpstan" }

      opts.linters = opts.linters or {}
      opts.linters.phpstan = function()
        local bufname = vim.api.nvim_buf_get_name(0)
        local real_bufname = docker.realpath(bufname)
        local info = docker.resolve(bufname)

        local function parser(output)
          if vim.trim(output or "") == "" then
            return {}
          end
          local ok, decoded = pcall(vim.json.decode, output)
          if not ok or not decoded or not decoded.files then
            return {}
          end
          for container_path, file in pairs(decoded.files) do
            local local_path = info and docker.to_local_path(info, container_path) or container_path
            if local_path == real_bufname or local_path == bufname then
              local diags = {}
              for _, message in ipairs(file.messages or {}) do
                table.insert(diags, {
                  lnum = (message.line or 1) - 1,
                  col = 0,
                  message = message.message,
                  source = "phpstan",
                  code = message.identifier,
                })
              end
              return diags
            end
          end
          return {}
        end

        if info == false then
          return { cmd = "false", args = {}, stdin = false, ignore_exitcode = true, parser = parser }
        end

        if info then
          local args = { "compose" }
          vim.list_extend(args, docker.compose_flags(info))
          vim.list_extend(args, {
            "exec", "-T", info.service,
            "php", "vendor/bin/phpstan", "analyse",
            "--error-format=json", "--no-progress", "--memory-limit=1G",
            docker.to_container_path(info, bufname),
          })
          return {
            cmd = "docker",
            args = args,
            stdin = false,
            append_fname = false,
            ignore_exitcode = true,
            cwd = info.root,
            parser = parser,
          }
        end

        return {
          cmd = "phpstan",
          args = { "analyse", "--error-format=json", "--no-progress", "--memory-limit=1G" },
          stdin = false,
          ignore_exitcode = true,
          parser = parser,
        }
      end
    end,
  },

  -----------------------------------------------------------------------------
  -- Formatting: php-cs-fixer or Laravel Pint -- Docker-aware via
  -- util/docker.lua. Pint is Laravel's own CLI wrapper around php-cs-fixer
  -- (different binary, different config format/flags -- `pint.json` vs
  -- `.php-cs-fixer.dist.php`), so which one a project actually uses is
  -- detected from the project root rather than assumed, the same way
  -- everything else here refuses to guess blindly.
  -----------------------------------------------------------------------------
  {
    "stevearc/conform.nvim",
    opts = function(_, opts)
      local docker = require("util.docker")

      ---@param info table|nil|false
      ---@return "pint"|"php_cs_fixer"
      local function detect_tool(info)
        local project_dir = info and info.mount and info.mount.source
        if project_dir and vim.fn.filereadable(project_dir .. "/pint.json") == 1 then
          return "pint"
        end
        return "php_cs_fixer"
      end

      opts.formatters_by_ft = opts.formatters_by_ft or {}
      opts.formatters_by_ft.php = { "php_cs_fixer" }

      opts.formatters = opts.formatters or {}
      opts.formatters.php_cs_fixer = {
        command = function(_, ctx)
          local info = docker.resolve(ctx.filename)
          if info == false then
            return "false"
          end
          if info then
            return "docker"
          end
          return detect_tool(nil) == "pint" and "pint" or "php-cs-fixer"
        end,
        args = function(_, ctx)
          local info = docker.resolve(ctx.filename)
          if info == false then
            return {}
          end
          local tool = detect_tool(info)
          if info then
            local args = { "compose" }
            vim.list_extend(args, docker.compose_flags(info))
            if tool == "pint" then
              vim.list_extend(args, {
                "exec", "-T", info.service,
                "php", "vendor/bin/pint", "--quiet",
                docker.to_container_path(info, ctx.filename),
              })
            else
              vim.list_extend(args, {
                "exec", "-T", info.service,
                "php", "vendor/bin/php-cs-fixer", "fix",
                "--using-cache=no", "--quiet",
                docker.to_container_path(info, ctx.filename),
              })
            end
            return args
          end
          if tool == "pint" then
            return { "--quiet", ctx.filename }
          end
          return { "fix", "--using-cache=no", "--quiet", ctx.filename }
        end,
        cwd = function(_, ctx)
          local info = docker.resolve(ctx.filename)
          if info then
            return info.root
          end
          return nil
        end,
        stdin = false,
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- Testing: Neotest + PHPUnit -- Docker-aware.
  --
  -- neotest-phpunit builds its command for a local `phpunit`: an absolute
  -- host test path, and a --log-junit=<host tmpfile> it reads back after
  -- the process exits. Both break once PHPUnit runs in a container (wrong
  -- path, and the container's --log-junit output is invisible to the
  -- host), so a small wrapper script handles the translation. See
  -- bin/docker-phpunit-wrapper.sh for the full explanation.
  -----------------------------------------------------------------------------
  {
    "nvim-neotest/neotest",
    dependencies = { "olimorris/neotest-phpunit" },
    -- <leader>tD arms a sticky, session-wide flag that makes the next
    -- test run(s) tell Xdebug to activate -- see the env() function
    -- below and bin/docker-phpunit-wrapper.sh's NVIM_XDEBUG_TRIGGER
    -- handling. Off by default: a normal `docker compose exec` does NOT
    -- forward host env vars into the container, so without this a
    -- breakpoint set via nvim-dap's "Listen for Xdebug" config is never
    -- reached even though the DAP session itself started fine.
    keys = {
      {
        "<leader>tD",
        function()
          vim.g.php_test_debug = not vim.g.php_test_debug
          vim.notify("Xdebug trigger for test runs: " .. (vim.g.php_test_debug and "ON" or "OFF"))
        end,
        desc = "Toggle Xdebug Trigger for Tests",
      },
    },
    opts = function(_, opts)
      local docker = require("util.docker")
      local wrapper = vim.fn.stdpath("config") .. "/bin/docker-phpunit-wrapper.sh"

      opts.adapters = opts.adapters or {}
      opts.adapters["neotest-phpunit"] = {
        phpunit_cmd = function()
          local bufname = vim.api.nvim_buf_get_name(0)
          local info = docker.resolve(bufname)
          if info == false then
            return { "false" }
          end
          if info and info.mount then
            return { wrapper }
          end
          -- Symfony's `bin/phpunit` wrapper (symfony/phpunit-bridge) takes
          -- priority over the plain vendor binary when both exist, same
          -- convention as the Docker-side wrapper script.
          local root = vim.fs.root(bufname, "composer.json") or vim.fn.getcwd()
          if vim.fn.filereadable(root .. "/bin/phpunit") == 1 then
            return { "php", "bin/phpunit" }
          end
          return { "php", "vendor/bin/phpunit" }
        end,
        env = function()
          local info = docker.resolve(vim.api.nvim_buf_get_name(0))
          -- XDEBUG_MODE is set (rather than relying on the container's own
          -- php.ini) so this works even when the image's default mode
          -- doesn't include "debug"; XDEBUG_TRIGGER covers the common
          -- xdebug.start_with_request=trigger setup. Either way, the
          -- extension being loaded and xdebug.client_host actually
          -- reaching this host remain that project's own container
          -- config, not something resolvable from here.
          --
          -- The Docker branch below passes the NVIM_-prefixed form instead
          -- of these directly: `docker compose exec` does not forward the
          -- wrapper script's own env into the container, so
          -- docker-phpunit-wrapper.sh reads NVIM_XDEBUG_TRIGGER itself and
          -- re-issues it as `-e XDEBUG_MODE=... -e XDEBUG_TRIGGER=...` on
          -- the exec call.
          local xdebug_env = vim.g.php_test_debug and { XDEBUG_MODE = "debug", XDEBUG_TRIGGER = "1" } or {}
          if info and info.mount then
            if (info.compose_files or {})[2] then
              vim.notify(
                "docker.lua: more than one extra compose file resolved for this buffer; "
                  .. "docker-phpunit-wrapper.sh only forwards the first one to PHPUnit.",
                vim.log.levels.WARN
              )
            end
            return {
              NVIM_DOCKER_ROOT = info.root,
              NVIM_DOCKER_SERVICE = info.service,
              NVIM_MOUNT_SOURCE = info.mount.source,
              NVIM_MOUNT_TARGET = info.mount.target,
              NVIM_DOCKER_BASE_COMPOSE_FILE = info.base_file,
              -- Wrapper is POSIX sh (no arrays); every real case so far
              -- needs at most one extra overlay (Project A's generated
              -- worktree compose file), so only that's supported here.
              NVIM_DOCKER_EXTRA_COMPOSE_FILE = (info.compose_files or {})[1] or "",
              -- Set via a marker's "project_prefix" -- see util/docker.lua's
              -- resolve_project_name. Empty when unset (plain `docker
              -- compose` default project-name resolution applies).
              NVIM_DOCKER_PROJECT_NAME = info.project_name or "",
              NVIM_XDEBUG_TRIGGER = vim.g.php_test_debug and "1" or "",
            }
          end
          -- Local (non-Docker) run: neotest spawns `php` directly, which
          -- inherits this table as its process env, so XDEBUG_MODE/
          -- XDEBUG_TRIGGER take effect without any wrapper involved.
          return xdebug_env
        end,
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- DAP: Xdebug -- Docker-aware.
  --
  -- pathMappings is a function so it's resolved fresh against whichever
  -- buffer is active when the debug session actually starts, using the
  -- bind mount util/docker.lua discovered (no more hardcoded
  -- `/var/www/html` guess -- Project B's containers use `/srv/app`, and the
  -- old hardcoded default was simply wrong).
  -----------------------------------------------------------------------------
  {
    "mfussenegger/nvim-dap",
    opts = function()
      local dap = require("dap")
      local docker = require("util.docker")

      dap.adapters.php = {
        type = "executable",
        command = "node",
        args = { vim.fn.stdpath("data") .. "/mason/packages/php-debug-adapter/extension/out/phpDebug.js" },
      }

      dap.configurations.php = {
        {
          type = "php",
          request = "launch",
          name = "Listen for Xdebug",
          -- nvim-dap resolves any function-valued config field (same
          -- mechanism pathMappings below already relies on), so this
          -- reads a marker's "xdebug_port" for the buffer active when the
          -- session starts, falling back to Xdebug's own default (9003)
          -- when unset -- see util/docker.lua's find_marker_service. Only
          -- overrides the nvim-dap side; the container's own
          -- xdebug.client_port ini setting must be changed to match.
          port = function()
            local info = docker.resolve(vim.api.nvim_buf_get_name(0))
            return (info and info.xdebug_port) or 9003
          end,
          pathMappings = function()
            local info = docker.resolve(vim.api.nvim_buf_get_name(0))
            if info and info.mount then
              return { [info.mount.target] = info.mount.source }
            end
            return {}
          end,
        },
      }
    end,
  },
}
