# Architecture

How the Docker-aware tooling actually resolves which container owns a
buffer, and how the project/worktree switcher discovers repos. Both are
built against three real projects this config runs against day to day —
Project A (a Symfony monorepo, backend/website/manager as separate repos
under one umbrella directory, `.worktrees/<ticket>/` convention with a
generated Docker Compose overlay per worktree), Project B (a Symfony
microservices monorepo, `services/<name>/` layout, `_worktrees/<ticket>/`
worktrees that carry a full copy of `docker-compose.yml`), and Project C (a
Laravel project, sibling-directory worktrees named `Core-dev3442-<slug>`
next to `Core`). None of the code below hardcodes any of these — it's
written as a set of conventions it tries in order, so it keeps working
whichever of these (or a new project entirely) you're actually in.

## Docker service resolution (`lua/util/docker.lua`)

Every Docker-aware tool (PHPStan, PHP-CS-Fixer/Pint, PHPUnit, the Xdebug
DAP config, the Symfony console picker) goes through one function:
`docker.resolve(filepath)`. It walks **up** from the buffer's own directory
(never `getcwd()`) to find the nearest `docker-compose.yml` — this is what
makes plain worktrees "just work": a worktree carrying its own copy of the
compose file (Project B's `_worktrees/<ticket>/`) is found before the walk
ever reaches the main checkout's copy.

Once a compose root is found, resolving the actual **service** name tries,
in order:

1. **`$PHP_DOCKER_SERVICE`** — explicit override, always trusted if valid.
2. **Generated worktree overlay** — a buffer under `.worktrees/<dir>/` where
   the repo root has a matching `.worktrees/compose.<ticket>.yml` (this is
   Project A's convention: its `/wt` workflow generates one compose overlay
   per ticket). `<dir>`'s ticket prefix is found by trying dash-separated
   prefixes against real generated files, since a ticket's worktrees can
   carry a role suffix (`mt-1203-backend`, `mt-1203-client`, ...).
3. **`.nvim-php-docker.json` marker file** (`{"service": "name"}`), searched
   from the buffer's directory up to the compose root — needed for repos
   like Project A's main checkout, where multiple compose services
   (`client_api`, `manager_api`, ...) all front the *same* `backend/`
   directory, so no path-segment convention can pick the one that actually
   runs PHP.
4. **`services/<name>/...` → `<name>-service`** path convention — Project B's
   monorepo layout, walking from the path segment closest to the file
   toward the compose root.

Every candidate service name is verified against
`docker compose config --format json <name>` before being trusted — nothing
is guessed and used blindly, and naming the service explicitly sidesteps
Compose *profile* gating (which otherwise hides most services from a plain
`docker compose config --services`).

**Failure is loud, on purpose.** If a compose project is found near the
file but the service can't be pinned down, callers get `false` back and
must *not* fall back to running a local/host tool — a previous version of
this file silently fell back to local PHPStan/PHPUnit whenever detection
failed, which produced results from the wrong PHP version against the
wrong config, with no indication anything was wrong. `false` means "tell
the user, don't guess."

## Project & worktree discovery (`lua/util/projects.lua`)

`discover_projects()` scans `~/projects` (resolved through `fs_realpath` —
`find` refuses to descend into a bare symlink argument without a trailing
slash) up to 3 levels deep for `.git` directories. That depth is what
naturally picks up Project A's layout: `my_project/backend/.git`,
`my_project/website/.git`, `my_project/manager/.git`, etc.,
as separate entries, alongside flat single-repo projects like Project B.

`discover_worktrees(project_path)` doesn't guess directory names — it runs
`git worktree list --porcelain` and reads git's own authoritative answer,
so it finds worktrees under **any** convention: Project A's nested
`.worktrees/<ticket>/`, Project B's `_worktrees/<ticket>/`, or Project C's
sibling `Core-dev3442-<slug>` next to `Core`.

`create_worktree(project_path, branch)` picks the convention automatically:
nested `.worktrees/<branch>/` if that directory already exists in the repo
(Project A-style), otherwise a plain sibling `../repo-branch` directory.
It deliberately does **not** run Project A's `make wt-hosts` /
`wt-migrate` / `wt-composer` / `wt-jwt` setup — creating the worktree and
opening it stays generic; project-specific Docker/DB/hosts setup is a
separate manual step you run yourself afterward.

## Symfony console picker (`lua/util/symfony.lua`)

Walks up from the buffer to find `bin/console`, then resolves Docker
context the exact same way as everything else (`docker.resolve()`) before
running `bin/console list --format=json` — either directly, or via
`docker compose exec -T <service> php bin/console list --format=json` when
the project runs in a container. Running a command from the picker uses
the same resolution, minus `-T` (no pseudo-tty), since it opens inside a
real `:terminal` and should behave like any other interactive command
there.

## Xdebug (`lua/plugins/php.lua`, DAP section)

The `pathMappings` for the PHP DAP adapter are resolved as a **function**,
called fresh every time a debug session actually starts — not a static
table computed once at config load. It calls `docker.resolve()` against
whichever buffer is currently active and maps the container's bind-mount
target back to its local source, so breakpoints resolve correctly whether
Xdebug connects from the main checkout or from inside a specific worktree's
container — no hardcoded `/var/www/html` guess (Project B's containers use
`/srv/app`, Project A's use something else again).
