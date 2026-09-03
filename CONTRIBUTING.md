# Contributing

This is a personal Neovim configuration, maintained solo, opinionated by
design. That shapes how contributions work here more than typical
open-source project etiquette does.

## Before opening a PR

For anything beyond a small, obvious fix (a typo, a broken link, a genuine
bug), open an issue first describing what you want to change and why.
This is opinionated tooling built around three specific real-world
workflows (see [`docs/customizing-multi-project.md`](docs/customizing-multi-project.md)
and [`docs/architecture.md`](docs/architecture.md)) — a PR adding support
for a workflow or tool the maintainer doesn't actually use is likely to be
declined even if it's well-written, simply because there's no way to keep
it working long-term. Checking first saves everyone the wasted effort.

## What a good PR looks like

- Follow the [`PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md) —
  it's short on purpose.
- Explain the *why*, not just the *what*. Comments in this codebase lean
  toward documenting non-obvious reasoning (see the existing code for the
  style) — match that rather than describing what the code already makes
  obvious.
- If you're fixing a bug, show how to reproduce it before your fix and
  confirm it's gone after. A quick `nvim --headless -u NONE -l -` repro
  script or a screenshot/GIF is usually the fastest way.
- Keep the diff focused. Unrelated formatting/refactoring changes mixed
  into a functional PR make it harder to review and more likely to be
  rejected outright.

## Reporting bugs

Use the issue templates — they ask for the specific things needed to
reproduce a Neovim config issue (Neovim version, whether Docker is
involved, `:checkhealth` output).

## Security issues

Do not open a public issue for a security concern — see
[`SECURITY.md`](SECURITY.md).
