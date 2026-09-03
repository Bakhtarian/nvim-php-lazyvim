# Security Policy

This is a personal Neovim configuration, not a network service — but it
does shell out to `git`, `docker`, and `docker compose` based on files it
finds in whatever project directory you happen to have open, so it's worth
being explicit about what that means.

## What this config executes automatically

- **`.nvim-php-docker.json`** (see [`docs/customizing-multi-project.md`](docs/customizing-multi-project.md)):
  a repo-local marker file that tells `util/docker.lua` which Compose
  service/project name to run linting, formatting, testing, and debugging
  commands against. If you open a repo you don't trust, treat this marker
  the same way you'd treat any other repo-provided script or Makefile you
  wouldn't blindly execute — it directs real `docker compose exec` /
  `docker compose -p` invocations.
- **`bin/docker-phpunit-wrapper.sh`**: shells out to `docker compose exec`
  using values resolved from the buffer's own path and the marker above.
- Every other Docker-aware code path (PHPStan, Pint, the Symfony console
  picker) follows the same resolution and only ever targets a service that
  `docker compose config` itself confirms exists — see the "fail loud,
  never silently fall back" design notes at the top of `util/docker.lua`.

None of this reaches out to the network on its own beyond what `git`,
`docker`, and the language servers (Intelephense, Phpactor) already do as
part of normal use.

## Reporting a vulnerability

If you find an actual security issue (e.g. a way for a repo-local file to
make this config do something beyond what's described above), please open
a [private security advisory](../../security/advisories/new) on this repo
rather than a public issue. I'll respond as time allows — this is
maintained solo, in spare time.
