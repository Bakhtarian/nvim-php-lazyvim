#!/bin/sh
# docker-phpunit-wrapper.sh
#
# neotest-phpunit builds its PHPUnit invocation for a LOCAL `phpunit`
# process: an absolute host test path, and a `--log-junit=<host tmpfile>`
# argument pointing at a JUnit results file it expects to read back
# afterwards. Neither is valid once PHPUnit actually needs to run inside a
# Docker container:
#
#   - the host test path doesn't exist in the container's filesystem
#   - the container writes --log-junit's output into its OWN filesystem,
#     invisible to the host, so neotest would just see "no output file"
#
# This translates the test path to its container-side equivalent (via the
# resolved bind mount) and reroutes the JUnit output through a file INSIDE
# the bind mount, then copies it back out to where neotest actually expects
# it once the container process exits. All other arguments (PHPUnit filter
# expressions, which may themselves contain spaces) are passed through
# untouched and in their original order -- this never joins/re-splits
# argv as a string, so embedded spaces can't corrupt anything.
#
# The test path is canonicalized (readlink -f) before the mount-prefix
# match, matching NVIM_MOUNT_SOURCE (already realpath'd by docker.lua) --
# without this, a symlink between the two (e.g. `~/projects` ->
# `/projects`) makes an identical file look like a mismatch and the path
# silently fails to translate.
#
# Configured via env vars (set by lua/plugins/php.lua, from
# util/docker.lua's resolution of the buffer being tested):
#   NVIM_DOCKER_ROOT               directory containing the base compose file (exec's cwd)
#   NVIM_DOCKER_SERVICE            compose service name
#   NVIM_MOUNT_SOURCE              local path of the bind mount covering the workdir
#   NVIM_MOUNT_TARGET              container path of that same bind mount
#   NVIM_DOCKER_BASE_COMPOSE_FILE  the base compose file's name (only used,
#                                  i.e. only needs to be correct, when an
#                                  extra overlay is also set -- see below)
#   NVIM_DOCKER_EXTRA_COMPOSE_FILE optional: one extra `-f` layer on top of
#                                  the base compose file (e.g. Project A's
#                                  generated `.worktrees/compose.<ticket>.yml`
#                                  overlay). Empty when there isn't one.
#   NVIM_DOCKER_PROJECT_NAME       optional: explicit `docker compose -p`
#                                  override, for a project whose own tooling
#                                  computes the Compose project name
#                                  dynamically per worktree (a marker's
#                                  "project_prefix" -- see util/docker.lua's
#                                  resolve_project_name). Without it, plain
#                                  `docker compose`'s default project-name
#                                  resolution silently targets the wrong (or
#                                  no) container instead of that worktree's
#                                  actual running stack. Empty when unset.
#                                  Passing ANY `-f` to `docker compose`
#                                  suppresses its default-file
#                                  auto-discovery, so the base file must be
#                                  listed explicitly alongside the overlay.
#   NVIM_XDEBUG_TRIGGER            optional: set (to "1") when <leader>tD
#                                  has armed debug mode. `docker compose
#                                  exec` does NOT forward this script's own
#                                  env into the container by itself, so this
#                                  is re-issued as `-e XDEBUG_MODE=debug -e
#                                  XDEBUG_TRIGGER=1` on the exec call.
#                                  Requires the container's own php.ini to
#                                  actually load the Xdebug extension and
#                                  have xdebug.client_host reachable from
#                                  the host -- both outside this script's
#                                  control. Empty when unset.

set -eu

junit_local=""
translated_path=""

remaining=$#
i=0
while [ "$i" -lt "$remaining" ]; do
  arg="$1"
  shift
  i=$((i + 1))
  case "$arg" in
    --log-junit=*)
      junit_local="${arg#--log-junit=}"
      ;;
    /*)
      real_arg=$(readlink -f "$arg" 2>/dev/null || printf '%s' "$arg")
      case "$real_arg" in
        "$NVIM_MOUNT_SOURCE"/*)
          translated_path="$NVIM_MOUNT_TARGET${real_arg#"$NVIM_MOUNT_SOURCE"}"
          ;;
        *)
          set -- "$@" "$arg"
          ;;
      esac
      ;;
    *)
      set -- "$@" "$arg"
      ;;
  esac
done
# "$@" now holds only the untouched filter args (e.g. --filter), in their
# original order and word boundaries.

junit_container=""
if [ -n "$junit_local" ]; then
  junit_container="$NVIM_MOUNT_TARGET/.neotest-junit-$$.xml"
fi

cd "$NVIM_DOCKER_ROOT"

# Symfony projects run tests through `bin/phpunit` (the symfony/phpunit-bridge
# wrapper, which manages its own phpunit.phar) rather than `vendor/bin/phpunit`
# directly. Checked on the HOST via the bind-mount source, since it mirrors
# the container's own filesystem 1:1 -- this script itself never runs inside
# the container to test the path directly.
phpunit_bin="vendor/bin/phpunit"
if [ -f "$NVIM_MOUNT_SOURCE/bin/phpunit" ]; then
  phpunit_bin="bin/phpunit"
fi

set +e
docker compose ${NVIM_DOCKER_PROJECT_NAME:+-p "$NVIM_DOCKER_PROJECT_NAME"} \
  ${NVIM_DOCKER_EXTRA_COMPOSE_FILE:+-f "$NVIM_DOCKER_BASE_COMPOSE_FILE" -f "$NVIM_DOCKER_EXTRA_COMPOSE_FILE"} \
  exec -T ${NVIM_XDEBUG_TRIGGER:+-e XDEBUG_MODE=debug -e XDEBUG_TRIGGER=1} "$NVIM_DOCKER_SERVICE" php "$phpunit_bin" \
  ${translated_path:+"$translated_path"} \
  ${junit_container:+"--log-junit=$junit_container"} \
  "$@"
status=$?
set -e

if [ -n "$junit_local" ]; then
  cp "$NVIM_MOUNT_SOURCE/.neotest-junit-$$.xml" "$junit_local" 2>/dev/null || true
  rm -f "$NVIM_MOUNT_SOURCE/.neotest-junit-$$.xml" 2>/dev/null || true

  # PHPUnit wrote this file's `file="..."` attributes as it sees paths
  # itself: inside the container (e.g. /var/www/html/...). neotest-phpunit's
  # results() builds its own result ids straight from that attribute with no
  # translation at all, matched against ids neotest already built from the
  # buffer's name -- so without rewriting these back to the host path, every
  # result silently fails to match its position and the whole file shows as
  # failed in the buffer regardless of what PHPUnit actually reported.
  #
  # This assumes the buffer was opened through NVIM_MOUNT_SOURCE's own
  # (realpath'd) form -- true for anything opened via this config's project
  # picker (util/projects.lua's M.root is realpath'd the same way). A buffer
  # opened through a different path to the same file (e.g. typed via a
  # symlink like `~/projects/...` instead of the picker) can still end up
  # with a mismatched position id neotest itself tracks in that other form --
  # not something this script can detect or correct for.
  if [ -n "$NVIM_MOUNT_SOURCE" ] && [ -f "$junit_local" ]; then
    sed -i "s|$NVIM_MOUNT_TARGET|$NVIM_MOUNT_SOURCE|g" "$junit_local" 2>/dev/null || true
  fi
fi

exit "$status"
