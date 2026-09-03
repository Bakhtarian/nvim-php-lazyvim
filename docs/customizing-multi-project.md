# Customizing for Multiple Projects

This config runs against three real projects at once — Project A, Project B,
and Project C — with no per-project config file to edit. Here's how that
actually works, and what to change (rarely) versus what "just works"
(usually).

## The one thing that's structural: `~/projects`

`util/projects.lua`'s `M.root` and `config/autocmds.lua`'s `:Wt` command
both assume every project lives under `~/projects` (one level: your repos
directly inside it, or nested one level deeper for an umbrella directory
like Project A's — see below). If your projects live somewhere else,
that's the one line to change, in both files. Everything past that point —
discovery, worktree conventions, Docker resolution — adapts automatically.

## Adding a new project: usually nothing to do

Drop a new git repo under `~/projects` and it's immediately visible in the
`<leader>fp` picker and `:Wt` — `discover_projects()` just scans for
`.git` directories, nothing to register. If it has a `docker-compose.yml`
anywhere above the files you're editing, PHPStan/Pint/PHPUnit/Xdebug/the
Symfony console picker all resolve the right container automatically (see
`docs/architecture.md` for the exact resolution order). If it's a Laravel
project (has an `artisan` file), `laravel.nvim` loads for it on its own.

## An umbrella directory of separate repos (Project A's shape)

Project A isn't one repo — `my_project/` is a plain directory
containing five separate git repos (`backend/`, `website/`, `manager/`,
`frontend/`, `vault/`), each with its own `.git`. `discover_projects()`'s
3-level-deep scan finds all of them as independent entries
(`my_project/backend`, `my_project/website`, ...) without
any special-casing — this is just what a `find ~/projects -maxdepth 3
-name .git` naturally returns. If you have a similar setup (a client or
product split across several repos under one folder), it works the same
way with zero config.

## Worktree conventions: detected, not configured

Three real conventions exist across these three projects, and none of them
are hardcoded anywhere except as fallback defaults:

- **Project A**: nested `.worktrees/<ticket>/`, sometimes at the umbrella
  level (`my_project/.worktrees/mt-1562/manager`) and sometimes
  inside the individual repo (`manager/.worktrees/mt-1570-whop-fix`) —
  both work, since `discover_worktrees()` reads `git worktree list`
  directly instead of guessing a directory shape.
- **Project B**: `_worktrees/<ticket>/`, each carrying a full copy of
  `docker-compose.yml` (so Docker resolution finds it before ever reaching
  the main checkout).
- **Project C**: sibling directories, `Broker-dev3442-<slug>` next to
  `Broker`.

**Discovering** worktrees never needs configuration — `git worktree list
--porcelain` is authoritative regardless of which convention produced
them. **Creating** a new one via `:WorktreeCreate` picks nested
`.worktrees/<branch>/` if that directory already exists in the repo,
otherwise falls back to a plain sibling `../repo-branch`. If you want a
third convention for creation specifically, that's the one place in
`util/projects.lua`'s `create_worktree()` you'd extend — everything else
(discovery, Docker resolution, the picker) doesn't care.

## Docker resolution: four fallbacks, extend if you need a fifth

`util/docker.lua`'s resolution order (env var → generated worktree overlay
→ marker file → `services/<name>` convention) is written as an ordered
list of independent checks, each of which simply returns nothing if it
doesn't apply. For a genuinely new convention that doesn't fit any of the
four:

- **Quick, per-project override**: drop a `.nvim-php-docker.json` file
  (`{"service": "name"}`) anywhere from the buffer's directory up to the
  compose root — checked before the path-convention fallback, no code
  changes needed. This is the escape hatch for "none of the automatic
  conventions apply here."
- **A project whose Compose project name is computed dynamically per
  worktree** (rather than a fixed name, or the directory-basename default):
  add `"project_prefix"` to the marker, e.g.
  `{"service": "app", "project_prefix": "broker"}`. Every Docker-aware
  command then gets an explicit `docker compose -p <prefix>-<slug>`, where
  `<slug>` is the current branch, slugified the same way as (and meant to
  match) a project's own worktree-aware compose wrapper script would.
  Without this, plain `docker compose` falls back to its own default
  project-name resolution and can silently target the wrong (or no)
  container instead of the worktree's actual running stack — see
  `resolve_project_name` in `util/docker.lua` for the exact algorithm.
- **Debugging more than one project at once**: Xdebug's own default
  `client_port` (9003) is shared by every project until each is given a
  distinct one — add `"xdebug_port"` to the marker, e.g.
  `{"service": "app", "xdebug_port": 9004}`. This only changes which port
  `lua/plugins/php.lua`'s "Listen for Xdebug" DAP config listens on (via a
  function-valued `port` field, resolved fresh per buffer the same way
  `pathMappings` already is); the container's own `xdebug.client_port` ini
  setting must be changed to match, which this repo has no way to do for
  you.
- **A genuinely new convention worth automating** (like Project A's
  generated-overlay detection or Project B's `services/<name>` mapping): add
  a new resolution step to `util/docker.lua`, following the same shape as
  the existing ones — verify the candidate against `docker compose config`
  before trusting it, and return `nil` (not a guess) if it doesn't apply.

## What to add for a Laravel vs. Symfony project

Nothing — both are already handled. `laravel.nvim` (Artisan/routes/make
pickers, Blade support) gates itself on an `artisan` file existing at the
project root; everything else (PHPStan, Pint vs. PHP-CS-Fixer detection,
PHPUnit vs. Symfony's `bin/phpunit`, the console picker) either checks for
the relevant file itself or works identically for both frameworks.
