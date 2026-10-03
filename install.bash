#!/usr/bin/env bash
#
# install.bash -- install the acli-sync Taskwarrior hooks.
#
# Copies the two hook scripts into the destination directory
# (default $XDG_CONFIG_HOME/task/hooks) and bundles the shared lib, the
# taskrc fragment, and example configs under an `acli-sync/` subdirectory
# of that location. The hooks source the lib from
# `../acli-sync/lib/acli-sync-lib.bash` and the default config dir is
# `../acli-sync/config.d/`, so the layout is fully self-contained within
# that one bundle. Prints the single `include` line to add to ~/.taskrc
# (pointing at the installed taskrc fragment) and a reminder to copy/edit
# the config files.
#
# Input:  none.
# Output: progress/instructions on stdout.
# Exit:   0 on success; 1 on usage errors or missing source files.
#
# Synopsis:
#   bash install.bash [--force] [--help]
#     --force   overwrite existing hook/lib files
#     --help    print this help and exit
set -u

usage() {
  cat <<'EOF'
Usage: bash install.bash [--force] [--help]

Installs the acli-sync Taskwarrior hooks.

  hooks/on-launch.acli-sync                            -> $HOOK_DEST/on-launch.acli-sync
  hooks/on-modify.acli-sync                            -> $HOOK_DEST/on-modify.acli-sync
  hooks/acli-sync/acli-sync.taskrc                     -> $HOOK_DEST/acli-sync/acli-sync.taskrc
  hooks/acli-sync/lib/acli-sync-lib.bash               -> $HOOK_DEST/acli-sync/lib/acli-sync-lib.bash
  config.d/example-team.conf, example-other.conf       -> $HOOK_DEST/acli-sync/config.d/

Options:
  --force   Overwrite files that already exist.
  --help    Show this help and exit.

After install:
  1. Add the printed `include` line to ~/.taskrc (one line; no paste).
  2. Edit the example configs the installer copied into
     `$HOOK_DEST/acli-sync/config.d/` (one file per team/filter/Jira
     account; the hooks default to reading from this dir).
  3. Run `task diag` and `task list` to confirm the hooks are active.
EOF
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hook installation destination. TASK_HOOKS_DIR overrides everything.
# Otherwise: ${XDG_CONFIG_HOME:-$HOME/.config}/task/hooks (per XDG Base
# Directory Spec - hooks are user-managed config files, not application
# data, so they belong under XDG_CONFIG_HOME). Falls back to ~/.task/hooks
# for callers whose Taskwarrior still uses the legacy 2.x default.
HOOK_DEST="${TASK_HOOKS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/task/hooks}"
# The bundle subdirectory installed alongside the hooks. Holds the taskrc
# fragment the user `include`s and the lib the hooks source. Lives inside
# the hooks dir so the layout is independent of XDG_CONFIG_HOME's
# structure for the lib path.
ACLI_SYNC_DEST="$HOOK_DEST/acli-sync"
force=0

for arg in "$@"; do
  case "$arg" in
  --force) force=1 ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    echo "install.bash: unknown option: $arg" >&2
    usage
    exit 1
    ;;
  esac
done

install_file() { # install_file <src> <dst>
  local src="$1" dst="$2"
  if [ ! -f "$src" ]; then
    echo "install.bash: missing source: $src" >&2
    return 1
  fi
  if [ -e "$dst" ] && [ "$force" -ne 1 ]; then
    echo "skip: $dst exists (use --force to overwrite)"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  install -m 755 "$src" "$dst"
  echo "installed: $dst"
}

mkdir -p "$HOOK_DEST"
ok=0
install_file "$REPO_DIR/hooks/on-launch.acli-sync" "$HOOK_DEST/on-launch.acli-sync" || ok=1
install_file "$REPO_DIR/hooks/on-modify.acli-sync" "$HOOK_DEST/on-modify.acli-sync" || ok=1
install_file "$REPO_DIR/hooks/acli-sync/acli-sync.taskrc" "$ACLI_SYNC_DEST/acli-sync.taskrc" || ok=1
install_file "$REPO_DIR/hooks/acli-sync/lib/acli-sync-lib.bash" "$ACLI_SYNC_DEST/lib/acli-sync-lib.bash" || ok=1
# Ship example configs into the bundle's config.d/ so the hooks have
# visible starter configs on first install. Users rename/edit them to
# their team filters / JQLs.
for example_conf in "$REPO_DIR"/config.d/*.conf; do
  [ -f "$example_conf" ] || continue
  install_file "$example_conf" "$ACLI_SYNC_DEST/config.d/$(basename "$example_conf")" || ok=1
done
[ "$ok" -ne 0 ] && exit 1

echo
echo "Add this single line to ~/.taskrc (or your TASKRC file):"
echo
echo "  include $ACLI_SYNC_DEST/acli-sync.taskrc"
echo
echo "(Taskwarrior's include directive reads file paths literally; no"
echo "paste of multiple lines needed - the included file defines the UDAs"
echo "and hooks config internally.)"
echo

if [ ! -d "$ACLI_SYNC_DEST/config.d" ] || [ -z "$(ls -A "$ACLI_SYNC_DEST/config.d" 2>/dev/null)" ]; then
  echo "$ACLI_SYNC_DEST/config.d/ is empty -- create one *.conf per team/filter/Jira"
  echo "account (see README + config.d/example-team.conf / config.d/example-other.conf)."
fi
exit 0
