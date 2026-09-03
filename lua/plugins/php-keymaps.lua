return {
  {
    "neovim/nvim-lspconfig",
    opts = function()
      -- Native LSP navigation already covers "step into" / "find usage":
      --   gd  go to definition        gr  find references
      --   gi  go to implementation    gy  go to type definition
      --   gD  go to declaration       K   hover documentation
      -- These are LazyVim defaults, not redefined here.

      vim.api.nvim_create_autocmd("FileType", {
        pattern = "php",
        callback = function(event)
          local opts = function(desc)
            return { buffer = event.buf, desc = desc }
          end
          local phpactor = function(cmd)
            return function()
              require("phpactor").rpc(cmd, {})
            end
          end

          -- ── Refactoring (native LSP) ─────────────────────────────────
          vim.keymap.set("n", "<leader>cr", vim.lsp.buf.rename, opts("Rename symbol (updates all references)"))

          -- ── Refactoring (Phpactor, via LSP workspace/executeCommand) ──
          -- Note: the deprecated `phpactor/phpactor` RPC Vim plugin used
          -- to be the only way to reach these (:PhpactorMoveFile etc.) --
          -- that plugin was never actually installed here, so those
          -- commands never worked. gbprod/phpactor.nvim talks to the same
          -- Phpactor server this LSP client already runs, over LSP.
          vim.keymap.set("n", "<leader>cm", phpactor("move_class"), opts("Move/rename class (updates references)"))
          vim.keymap.set("n", "<leader>cy", phpactor("copy_class"), opts("Copy class"))
          vim.keymap.set("n", "<leader>cu", phpactor("import_class"), opts("Import class (add use statement)"))
          vim.keymap.set("n", "<leader>cU", phpactor("import_missing_classes"), opts("Import all missing classes"))
          vim.keymap.set("n", "<leader>ce", phpactor("expand_class"), opts("Expand class alias to FQCN"))
          vim.keymap.set("n", "<leader>cF", phpactor("copy_fcqn"), opts("Copy fully-qualified class name"))
          vim.keymap.set("n", "<leader>cg", phpactor("generate_accessor"), opts("Generate getter/setter"))
          vim.keymap.set("n", "<leader>cv", phpactor("change_visibility"), opts("Change visibility"))
          vim.keymap.set("n", "<leader>ct", phpactor("transform"), opts("Transform (implement contracts, add missing methods, ...)"))
          -- Extract method / extract expression live under the context
          -- menu when a visual selection is active -- Phpactor doesn't
          -- expose them as standalone commands.
          vim.keymap.set({ "n", "v" }, "<leader>cx", phpactor("context_menu"), opts("Phpactor context menu (extract method/expression on selection)"))

          -- ── Class/interface/trait/enum generation ───────────────────
          vim.keymap.set("n", "<leader>cn", function()
            require("util.php-class-create").create()
          end, opts("New PHP class/interface/trait/enum"))
          vim.keymap.set("n", "<M-Insert>", function()
            require("util.php-class-create").create()
          end, opts("New PHP class/interface/trait/enum"))

          -- ── Refactor menu (PhpStorm Alt+F6: rename OR move, one key) ──
          vim.keymap.set("n", "<M-F6>", function()
            vim.ui.select({ "Rename symbol", "Move/rename class" }, { prompt = "Refactor:" }, function(choice)
              if choice == "Rename symbol" then
                vim.lsp.buf.rename()
              elseif choice == "Move/rename class" then
                phpactor("move_class")()
              end
            end)
          end, opts("Refactor: rename symbol / move class"))
        end,
      })
    end,
  },
}
