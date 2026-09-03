# Keymap Reference

Everything custom in this config, grouped by where it lives. LazyVim's own
defaults (`gd`, `gr`, `K`, `<leader>ff`, etc.) aren't repeated here — see
`:LazyExtras` / `:help lazyvim` for those.

## PhpStorm-style navigation (`lua/plugins/ide-keymaps.lua`)

Global, not PHP-specific.

| Key | Action |
| --- | --- |
| `Ctrl+B` | Go to definition (same as `gd`, mapped for PhpStorm muscle memory) |
| `Alt+Left` | Jump back through the jumplist |
| `Alt+Right` | Jump forward through the jumplist |
| `Ctrl+Space` (insert mode) | Show signature help (blink.cmp's native signature window) |
| `Ctrl+E` | Recent/open buffers, sorted by last use, as a plain non-fuzzy list |
| `Ctrl+P` | Global file search (Telescope, root-aware) |

`Ctrl+B` replaced noice.nvim's smooth scroll-back on that key; `Ctrl+U`/`Ctrl+D`
still do plain half-page scrolling. There's no terminal equivalent to
PhpStorm's "double-tap Shift" (Search Everywhere) — a bare Shift keypress
sends no keycode at all in a terminal — so that's on `Ctrl+P` instead.

PhpStorm's `Ctrl+Shift+F` (Find in Path) is a stock LazyVim keymap, not
custom to this config, so it's not in the table above — but it's the one
people usually go looking for: `<leader>sg` (or `<leader>/`) for a
root-aware, ripgrep-backed live grep across the whole project, `<leader>sG`
for the same scoped to the cwd instead of the project root.

## PHP refactoring & scaffolding (`lua/plugins/php-keymaps.lua`)

Buffer-local, only active in `.php` files. `<leader>c*` is refactor-flavored
LSP/Phpactor actions; native LSP navigation (`gd`, `gr`, `gi`, `gy`, `gD`, `K`)
already covers "step into"/"find usage" and isn't redefined here.

| Key | Action |
| --- | --- |
| `<leader>cr` | Rename symbol (updates all references) |
| `<leader>cm` | Move/rename class (Phpactor, updates references) |
| `<leader>cy` | Copy class |
| `<leader>cu` | Import class (add `use` statement) |
| `<leader>cU` | Import all missing classes |
| `<leader>ce` | Expand class alias to fully-qualified name |
| `<leader>cF` | Copy fully-qualified class name |
| `<leader>cg` | Generate getter/setter |
| `<leader>cv` | Change visibility |
| `<leader>ct` | Transform (implement contracts, add missing methods, ...) |
| `<leader>cx` (normal/visual) | Phpactor context menu (extract method/expression on selection) |
| `<leader>cn` | New PHP class/interface/trait/enum, namespaced from `composer.json` |
| `Alt+Insert` | Same as `<leader>cn` (PhpStorm muscle memory) |
| `Alt+F6` | Refactor menu: choose "Rename symbol" or "Move/rename class" |

## Implements/overrides gutter glyphs (`lua/plugins/php-method-glyphs.lua`)

Green "I " marks a method satisfying an abstract requirement (an interface
method, or an abstract parent method); blue "O " marks overriding a concrete
parent method. Recomputed on `BufEnter`/`BufWritePost` for `.php` buffers.

| Key / Command | Action |
| --- | --- |
| `<leader>ci` | Jump to the interface/parent method the glyphed line implements/overrides |
| `:PhpGlyphsDebug` | Show what did/didn't resolve for the current buffer, including Doctrine glyph misses |

## Doctrine entity ↔ repository glyphs (`lua/plugins/php-doctrine-repository.lua`)

A third gutter glyph ("D ") linking a Doctrine entity's
`#[ORM\Entity(repositoryClass: X::class)]` attribute to its repository, and
back. The reverse direction (repository → entity/entities) is a lazily-built,
session-cached workspace index — first built on the first `<leader>cd` press
in a repository file, not eagerly at startup.

| Key / Command | Action |
| --- | --- |
| `<leader>cd` | On an entity's glyphed attribute line: jump to its repository. On a repository's declaration line: jump to the entity that declares it, or show a picker if more than one does |
| `:PhpDoctrineRefresh` | Clear the cached reverse index — next `<leader>cd` (or buffer open) rebuilds it |

## Project & worktree switcher (`lua/plugins/projects.lua`)

| Key / Command | Action |
| --- | --- |
| `<leader>fp` | Telescope picker: every repo under `~/projects` plus their worktrees |
| `<CR>` (in picker) | Open selection in the current tab |
| `Ctrl+T` (in picker) | Open selection in a new tab |
| `:WorktreeCreate {branch}` | Create + open a worktree of the current tab's repo, current tab |
| `:WorktreeCreate! {branch}` | Same, opened in a new tab |
| `:Wt {query}` | (`lua/config/autocmds.lua`) `:cd` the whole session into the first worktree under `~/projects` whose directory name matches `{query}` |

## Symfony (`lua/plugins/symfony.lua`)

| Key | Action |
| --- | --- |
| `<leader>sc` | Docker-aware `bin/console` picker — select a command, get prompted for extra args, runs in a terminal split |

This table only covers the console picker itself. The rest of this config's
Symfony support isn't consolidated into one plugin (there's no "symfony.nvim"
equivalent of `laravel.nvim`), so it's split across other sections: see
[Doctrine entity ↔ repository glyphs](#doctrine-entity--repository-glyphs-luapluginsphp-doctrine-repositorylua)
above for entity/repository navigation, and the general
[PHP refactoring & scaffolding](#php-refactoring--scaffolding-luapluginsphp-keymapslua)
and [PhpStorm-style navigation](#phpstorm-style-navigation-luapluginside-keymapslua)
sections for everything that applies to Symfony projects without being
Symfony-specific. Docker-aware PHPStan/Pint/PHPUnit tooling (see the README)
also runs automatically in Symfony projects — no keybinding, since it's
triggered on save/test rather than invoked directly.

## Multi-cursor (`lua/plugins/visual-multi.lua`)

| Key | Action |
| --- | --- |
| `Alt+J` (normal/visual) | Select word under cursor; press again to add the next occurrence as another cursor |

## Laravel (`lua/plugins/laravel.lua`, only loads for actual Laravel projects)

| Key | Action |
| --- | --- |
| `<leader>ll` | Laravel picker |
| `<leader>la` | Artisan picker |
| `<leader>lr` | Routes picker |
| `<leader>lm` | Make picker |
| `<leader>lc` | Custom commands picker |
| `<leader>lo` | Resources picker |
| `<leader>lh` | Open Artisan docs |
| `<leader>lt` | Code actions |
| `<leader>lu` | Artisan hub |
| `<leader>lp` | Command center |
| `Ctrl+G` | View finder |
| `gf` | Go to resource under cursor (falls through to normal `gf` otherwise) |

## Testing & debugging (`lua/plugins/php.lua`)

| Key / Command | Action |
| --- | --- |
| `<leader>tD` | Toggle Xdebug trigger for test runs (sticky — stays on until toggled off) |

`<leader>tt` and friends (neotest) and `<leader>db`/`<leader>dc`/etc. (DAP) are
stock LazyVim keymaps, not custom to this config, so they're not repeated
here — but they're what you'll actually use alongside `<leader>tD` to step
into a test: set a breakpoint (`<leader>db`), start listening for Xdebug
(`<leader>dc`), arm the trigger (`<leader>tD`), then run the test
(`<leader>tt`). `<leader>tD` only tells Xdebug to *activate* for that run
(`XDEBUG_MODE=debug` / `XDEBUG_TRIGGER=1`, forwarded into the container by
`bin/docker-phpunit-wrapper.sh` since `docker compose exec` doesn't forward
host env vars on its own) — the Xdebug extension actually being installed
and `xdebug.client_host` reaching this host from inside the container is
that project's own image config, outside this repo's control.

`<leader>dc` offers a choice of two configs — pick **"Listen for Xdebug"**
(this config's own, in `lua/plugins/php.lua`). It's Docker-aware: its
`pathMappings` translates the container's file paths back to this host via
`util/docker.lua`, and its `port` reads an optional `"xdebug_port"` from a
`.nvim-php-docker.json` marker (see `docs/customizing-multi-project.md`),
falling back to Xdebug's own default (9003) when unset. The other entry,
`"PHP: Listen for Xdebug"`, is `mason-nvim-dap.nvim`'s auto-registered
default — same port, no path translation, so a Docker-run breakpoint
appears to connect but never visibly stops.

## Misc

| Key / Command | Action |
| --- | --- |
| `:IntelephenseClearCache` | Clear intelephense's on-disk cache and restart its client(s) — fixes a silent startup crash |
| `:PhpDockerRefresh` | Clear the cached Docker Compose service resolution (`lua/util/docker.lua`) |
