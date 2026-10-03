#!/usr/bin/env bash
#
# test-acli-sync.bash -- fast shell tests for the acli-sync hooks.
#
# Stubs `acli` with a fake script earlier on PATH (canned search JSON, logged
# transition/edit calls) and runs the hooks directly against a throwaway
# TASKDATA. No bats, no install needed.
#
# Input:  none.
# Output: PASS/FAIL lines plus a summary on stdout.
# Exit:   0 if all tests pass, 1 otherwise.
#
# Synopsis:
#   bash tests/test-acli-sync.bash
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$REPO_DIR/hooks"
EXAMPLE_CONF="$REPO_DIR/config.d/example-team.conf"

# --- Throwaway environment ---------------------------------------------------
TASKDATA=""
TASKRC=""
TEST_CONFIG_DIR=""
FAKE_BIN=""
FAKE_ACLI_LOG=""
OUT=""
ERR=""

cleanup() {
    rm -rf -- "$TASKDATA" "$TASKRC" "$TEST_CONFIG_DIR" "$FAKE_BIN" "$FAKE_ACLI_LOG" "$OUT" "$ERR"
}
trap cleanup EXIT

TASKDATA=$(mktemp -d)
TASKRC=$(mktemp)
TEST_CONFIG_DIR=$(mktemp -d)
EXAMPLE_CONF="$REPO_DIR/config.d/example-team.conf"
mkdir -p "$TEST_CONFIG_DIR"
# Seed the test config dir with the default example so most tests just work
# without needing to write config files themselves. Tests that exercise
# multi-config flow wipe and replace these.
cp "$EXAMPLE_CONF" "$TEST_CONFIG_DIR/00-default.conf"

FAKE_BIN=$(mktemp -d)
FAKE_ACLI_LOG=$(mktemp)
OUT=$(mktemp)
ERR=$(mktemp)

# --- Fake acli stub ----------------------------------------------------------
cat >"$FAKE_BIN/acli" <<'BASH'
#!/usr/bin/env bash
# Fake acli for tests. The verb is read off the args
# (`jira workitem <verb> ...`), not from FAKE_ACLI_MODE — so the same fake
# serves a search call AND a per-key view call (for the init-age enrichment)
# in the same on-launch pass.
set -u
if [ "${1:-}" = "--version" ]; then
    echo "acli 9.9.9 (fake for acli-sync tests)"
    exit 0
fi

verb=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "workitem" ]; then
        verb="$arg"
        break
    fi
    prev="$arg"
done

case "$verb" in
    search)
        # Parse --filter / --jql so the multi-config test can drive
        # different filter values to distinct canned issues.
        filter=""
        jql=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --filter) filter="$2"; shift 2 ;;
                --jql) jql="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        case "$filter" in
            "")
                # No filter (only --jql, or neither — fake has no
                # canned JQL response) returns empty.
                printf '[]\n'
                ;;
            67890)
                # The multi-config test writes a second config with this
                # filter; return the BETA family.
                cat <<'JSON'
[
  {"key":"BETA-1","id":"20001","fields":{"summary":"Beta item one","status":{"name":"In Progress"},"priority":{"name":"Medium"},"assignee":null,"labels":["beta"]}},
  {"key":"BETA-2","id":"20002","fields":{"summary":"Beta item two","status":{"name":"Done"},"priority":{"name":"Medium"},"assignee":null,"labels":[]}}
]
JSON
                ;;
            *)
                # Default: every other filter ID (including the example
                # conf's 23465 and the multi-config test's 12345) returns
                # the canned KEY family so existing tests keep working.
                cat <<'JSON'
[
  {"key":"KEY-1","id":"10001","fields":{"summary":"Fix the frobnicator","status":{"name":"In Progress"},"priority":{"name":"High"},"assignee":{"displayName":"Ada Lovelace"},"labels":["bug","backend"]}},
  {"key":"KEY-2","id":"10002","fields":{"summary":"Document the widget","status":{"name":"Done"},"priority":{"name":"Medium"},"assignee":null,"labels":[]}}
]
JSON
                ;;
        esac
        ;;
    view)
        # Parse --key from the args.
        key=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --key) key="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        # Return per-key `created` timestamps. Offsets in the tests are +0000
        # so the conversion to TW compact UTC is identity (no TZ math).
        case "$key" in
            KEY-1) printf '[{"key":"KEY-1","id":"10001","created":"2020-01-15T10:30:00.000+0000","updated":"2024-09-01T12:00:00.000+0000"}]\n' ;;
            KEY-2) printf '[{"key":"KEY-2","id":"10002","created":"2019-06-01T08:00:00.000+0000","updated":"2024-09-01T12:00:00.000+0000"}]\n' ;;
            BETA-1) printf '[{"key":"BETA-1","id":"20001","created":"2020-03-10T09:00:00.000+0000","updated":"2024-09-01T12:00:00.000+0000"}]\n' ;;
            BETA-2) printf '[{"key":"BETA-2","id":"20002","created":"2020-04-20T11:00:00.000+0000","updated":"2024-09-01T12:00:00.000+0000"}]\n' ;;
            *)     printf '[]\n' ;;
        esac
        ;;
    transition|edit)
        # Honor FAKE_ACLI_MODE for legacy callers but the verb path is enough.
        printf '%s\n' "$*" >> "${FAKE_ACLI_LOG:-/dev/null}"
        ;;
    *)
        echo "unknown acli verb=$verb" >&2
        exit 1
        ;;
esac
BASH
chmod +x "$FAKE_BIN/acli"

# Test taskrc: hooks on, pointing at the repo hooks, UDAs defined. The
# data.location line is a convenience only; TASKDATA (env) takes precedence.
cat >"$TASKRC" <<EOF
hooks=1
hooks.location=$HOOKS_DIR
data.location=$TASKDATA
uda.jirakey.type=string
uda.jirakey.label=Jira Key
uda.jirastatus.type=string
uda.jirastatus.label=Jira Status
uda.jiraurl.type=string
uda.jiraurl.label=Jira URL
EOF

export TASKDATA
export TASKRC
export PATH="$FAKE_BIN:$PATH"
export ACLI_SYNC_CONFIG_DIR="$TEST_CONFIG_DIR"
export FAKE_ACLI_LOG

# task helpers: setup and assertions must not re-trigger hooks.
t() { task rc.hooks=off rc.color=no "$@"; }
tx() { task rc.hooks=off rc.color=no rc.json.array=on export 2>/dev/null; }

# Clear task data between tests. TW 2.x uses *.data files, TW 3.x a sqlite db.
fresh_tasks() { rm -f -- "$TASKDATA"/*.data "$TASKDATA"/taskchampion.sqlite3; }

# Add a config file to the test config dir.
add_config() {  # add_config <name> <body>
    local name="$1" body="$2"
    printf '%s\n' "$body" > "$TEST_CONFIG_DIR/$name"
}

# Wipe all config files in the test config dir so the next test starts
# with a clean slate.
reset_configs() {
    rm -f -- "$TEST_CONFIG_DIR"/*.conf \
        "$TEST_CONFIG_DIR"/*.bash \
        "$TEST_CONFIG_DIR"/.[!.]* 2>/dev/null || true
}

pass=0
fail=0

run_test() { # run_test <name> <fn>
  local name="$1" fn="$2"
  if "$fn"; then
    pass=$((pass + 1))
    echo "PASS: $name"
  else
    fail=$((fail + 1))
    echo "FAIL: $name"
  fi
}

# --- Test cases --------------------------------------------------------------

test_launch_adds_new() {
  fresh_tasks
  FAKE_ACLI_MODE=search bash "$HOOKS_DIR/on-launch.acli-sync" >/dev/null 2>&1 || return 1
  tx | jq -e 'length == 2' >/dev/null || return 1
  tx | jq -e '[.[] | select(.jirakey != null)] | length == 2' >/dev/null || return 1
  tx | jq -e '[.[] | select(.jirastatus != null)] | length == 2' >/dev/null || return 1
  tx | jq -e '[.[] | select(.project == "acli")] | length == 2' >/dev/null || return 1
  # KEY-1 is "In Progress" -> pending, priority H (status_in_progress).
  tx | jq -e '.[] | select(.jirakey == "KEY-1") | .status == "pending" and .jirastatus == "In Progress" and .priority == "H"' >/dev/null || return 1
  # KEY-2 is "Done" -> completed.
  tx | jq -e '.[] | select(.jirakey == "KEY-2") | .status == "completed" and .jirastatus == "Done"' >/dev/null || return 1
  return 0
}

test_launch_reconciles_status() {
  fresh_tasks
  t add jirakey:KEY-1 description:Old >/dev/null 2>&1 || return 1
  U=$(tx | jq -r '.[0].uuid')
  [ -n "$U" ] || return 1
  t "$U" modify status:completed >/dev/null 2>&1 || return 1
  FAKE_ACLI_MODE=search bash "$HOOKS_DIR/on-launch.acli-sync" >/dev/null 2>&1 || return 1
  # KEY-1 is "In Progress" in Jira -> reopened to pending, no duplicate.
  tx | jq -e --arg u "$U" '.[] | select(.uuid == $u) | .status == "pending"' >/dev/null || return 1
  tx | jq -e 'length == 2' >/dev/null || return 1
  return 0
}

test_modify_completes_triggers_transition() {
  fresh_tasks
  t add jirakey:KEY-1 description:"Fix the frobnicator" >/dev/null 2>&1 || return 1
  orig=$(tx | jq -c '.[0]')
  mod=$(printf '%s' "$orig" | jq -c '.status = "completed"')
  : >"$FAKE_ACLI_LOG"
  printf '%s\n%s\n' "$orig" "$mod" |
    FAKE_ACLI_MODE=transition bash "$HOOKS_DIR/on-modify.acli-sync" >"$OUT" 2>"$ERR" || return 1
  # First stdout line is the modified JSON with the jirastatus UDA set to Done.
  head -n1 "$OUT" | jq -e '.status == "completed" and .jirastatus == "Done"' >/dev/null || return 1
  grep -q 'transition.*KEY-1.*Done' "$FAKE_ACLI_LOG" || return 1
  return 0
}

test_modify_no_jirakey_is_pass_through() {
  fresh_tasks
  t add description:Hello >/dev/null 2>&1 || return 1
  orig=$(tx | jq -c '.[0]')
  mod=$(printf '%s' "$orig" | jq -c '.description = "Changed"')
  : >"$FAKE_ACLI_LOG"
  printf '%s\n%s\n' "$orig" "$mod" |
    FAKE_ACLI_MODE=edit bash "$HOOKS_DIR/on-modify.acli-sync" >"$OUT" 2>"$ERR" || return 1
  [ "$(head -n1 "$OUT")" = "$mod" ] || return 1
  [ ! -s "$FAKE_ACLI_LOG" ] || return 1
  return 0
}

test_launch_missing_config_exits_nonzero() {
    fresh_tasks
    if ACLI_SYNC_CONFIG_DIR=/nonexistent bash "$HOOKS_DIR/on-launch.acli-sync" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

test_launch_iterates_multiple_configs() {
    fresh_tasks
    # Wipe the default config; build two configs explicitly.
    reset_configs
    add_config "10-alpha.conf" 'filter=12345
project=alpha'
    add_config "20-beta.conf" 'filter=67890
project=beta'
    FAKE_ACLI_MODE=search bash "$HOOKS_DIR/on-launch.acli-sync" >/dev/null 2>&1 || return 1
    # The union of both configs' snapshots is 4 issues; the dedup-by-key
    # index in the hook ensures no overlap is needed for this test to pass.
    tx | jq -e 'length == 4' >/dev/null || return 1
    tx | jq -e '.[] | select(.jirakey == "KEY-1") | .project == "alpha"' >/dev/null || return 1
    tx | jq -e '.[] | select(.jirakey == "KEY-2") | .project == "alpha"' >/dev/null || return 1
    tx | jq -e '.[] | select(.jirakey == "BETA-1") | .project == "beta"' >/dev/null || return 1
    tx | jq -e '.[] | select(.jirakey == "BETA-2") | .project == "beta"' >/dev/null || return 1
    return 0
}

# --- XDG-aware install destination -------------------------------------------
# Run install.bash in a sandboxed HOME / XDG_CONFIG_HOME and verify the default
# destination honors the XDG Base Directory Spec. Hooks are config files and
# therefore live under XDG_CONFIG_HOME/task/hooks (NOT XDG_DATA_HOME/task).

run_install_in_sandbox() { # run_install_in_sandbox <home> <xdg_config_home> <task_hooks_dir>
  local home="$1" xdg_cfg="$2" thd="$3"
  mkdir -p "$home"
  [ -n "$xdg_cfg" ] && mkdir -p "$xdg_cfg"
  # Note: we do NOT export these inside the sandbox shell; install.bash reads
  # them as regular env vars, but we also have to scope HOME so the
  # ${HOME:?} fallbacks used by install.bash and the lib see the sandbox.
  HOME="$home" XDG_CONFIG_HOME="$xdg_cfg" TASK_HOOKS_DIR="$thd" bash install.bash --force 2>&1
}

test_install_xdg_config_home_respected() {
  local base
  base=$(mktemp -d)
  local home="$base/home" xdg_cfg="$base/xdg_cfg"
  local out
  out=$(run_install_in_sandbox "$home" "$xdg_cfg" "") || {
    rm -rf -- "$base"
    return 1
  }
if [[ "$out" != *"installed: $xdg_cfg/task/hooks/on-launch.acli-sync"* ]]; then
        rm -rf -- "$base"
        return 1
    fi
    if [[ "$out" != *"installed: $xdg_cfg/task/hooks/acli-sync/lib/acli-sync-lib.bash"* ]]; then
        rm -rf -- "$base"
        return 1
    fi
    if [[ "$out" != *"installed: $xdg_cfg/task/hooks/acli-sync/acli-sync.taskrc"* ]]; then
        rm -rf -- "$base"
        return 1
    fi
    # Example configs land in the bundle's config.d/ so the hooks have
    # visible starter configs on first install.
    if [[ "$out" != *"installed: $xdg_cfg/task/hooks/acli-sync/config.d/example-team.conf"* ]]; then
        rm -rf -- "$base"
        return 1
    fi
    if [[ "$out" != *"installed: $xdg_cfg/task/hooks/acli-sync/config.d/example-other.conf"* ]]; then
        rm -rf -- "$base"
        return 1
    fi
    rm -rf -- "$base"
    return 0
}

test_install_xdg_empty_uses_dot_config() {
    local base
    base=$(mktemp -d)
    local home="$base/home"
    local out expected_hook expected_lib expected_taskrc
    out=$(run_install_in_sandbox "$home" "" "") || { rm -rf -- "$base"; return 1; }
    expected_hook="$home/.config/task/hooks/on-launch.acli-sync"
    expected_lib="$home/.config/task/hooks/acli-sync/lib/acli-sync-lib.bash"
    expected_taskrc="$home/.config/task/hooks/acli-sync/acli-sync.taskrc"
  if [[ "$out" != *"installed: $expected_hook"* ]] ||
    [[ "$out" != *"installed: $expected_lib"* ]] ||
    [[ "$out" != *"installed: $expected_taskrc"* ]] ||
    [[ "$out" != *"installed: $home/.config/task/hooks/acli-sync/config.d/example-team.conf"* ]] ||
    [[ "$out" != *"installed: $home/.config/task/hooks/acli-sync/config.d/example-other.conf"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  rm -rf -- "$base"
  return 0
}

test_install_task_hooks_dir_overrides() {
  local base
  base=$(mktemp -d)
  local home="$base/home" xdg_cfg="$base/xdg_cfg" custom="$base/custom"
  local out
  out=$(run_install_in_sandbox "$home" "$xdg_cfg" "$custom/hooks") || {
    rm -rf -- "$base"
    return 1
  }
  if [[ "$out" != *"installed: $custom/hooks/on-launch.acli-sync"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  # Lib lives inside the acli-sync/ bundle under HOOK_DEST (alongside the
  # hooks).
  if [[ "$out" != *"installed: $custom/hooks/acli-sync/lib/acli-sync-lib.bash"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  if [[ "$out" != *"installed: $custom/hooks/acli-sync/acli-sync.taskrc"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  if [[ "$out" != *"installed: $custom/hooks/acli-sync/config.d/example-team.conf"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  if [[ "$out" != *"installed: $custom/hooks/acli-sync/config.d/example-other.conf"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  # Neither XDG_CONFIG_HOME nor legacy ~/.task path should be chosen when
  # TASK_HOOKS_DIR is set.
  if [[ "$out" == *"installed: $xdg_cfg/task/hooks/"* ]] ||
    [[ "$out" == *"installed: $home/.config/task/"* ]] ||
    [[ "$out" == *"installed: $home/.task/hooks/"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  rm -rf -- "$base"
  return 0
}

test_install_xdg_preempts_legacy_dot_task() {
  # With XDG_CONFIG_HOME set, the legacy ~/.task/hooks path (and the
  # ~/.local/share/task/hooks DATA-home path) must never appear.
  local base
  base=$(mktemp -d)
  local home="$base/home" xdg_cfg="$base/xdg_cfg"
  local out
  out=$(run_install_in_sandbox "$home" "$xdg_cfg" "") || {
    rm -rf -- "$base"
    return 1
  }
  if [[ "$out" == *"$home/.task/hooks/"* ]] ||
    [[ "$out" == *"$home/.local/share/task/hooks/"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  rm -rf -- "$base"
  return 0
}

test_install_prints_include_line_not_pasted_snippet() {
    # The installer must tell the user to add ONE `include` line and must
    # NOT print the UDA / hooks block contents to paste.
    local base home out
    base=$(mktemp -d)
    home="$base/home"
    out=$(run_install_in_sandbox "$home" "" "") || { rm -rf -- "$base"; return 1; }
    local include_line
    include_line="include $home/.config/task/hooks/acli-sync/acli-sync.taskrc"
    if [[ "$out" != *"$include_line"* ]]; then
        echo "missing include line: $include_line" >&2
        rm -rf -- "$base"
        return 1
    fi
    # Reject any of the old pasted contents.
    if [[ "$out" == *"uda.jirakey.type=string"* ]] || \
       [[ "$out" == *"hooks.location="* ]]; then
        echo "installer still prints the previous snippet contents" >&2
        rm -rf -- "$base"
        return 1
    fi
    # The taskrc fragment was actually installed alongside the hooks.
    [ -f "$home/.config/task/hooks/acli-sync/acli-sync.taskrc" ] || \
        { rm -rf -- "$base"; return 1; }
    rm -rf -- "$base"
    return 0
}

test_jira_key_to_uuid_deterministic() {
  command -v md5sum >/dev/null 2>&1 || { echo "SKIP: md5sum not found"; return 0; }
  local u1 u2
  u1=$(bash -c "source '$REPO_DIR/hooks/acli-sync/lib/acli-sync-lib.bash'; acli_sync::jira_key_to_uuid KEY-1") || return 1
  u2=$(bash -c "source '$REPO_DIR/hooks/acli-sync/lib/acli-sync-lib.bash'; acli_sync::jira_key_to_uuid KEY-1") || return 1
  [ -n "$u1" ] || return 1
  [ "$u1" = "$u2" ] || return 1
  return 0
}

test_jira_key_to_uuid_unique() {
  command -v md5sum >/dev/null 2>&1 || { echo "SKIP: md5sum not found"; return 0; }
  local u1 u2
  u1=$(bash -c "source '$REPO_DIR/hooks/acli-sync/lib/acli-sync-lib.bash'; acli_sync::jira_key_to_uuid KEY-1") || return 1
  u2=$(bash -c "source '$REPO_DIR/hooks/acli-sync/lib/acli-sync-lib.bash'; acli_sync::jira_key_to_uuid KEY-2") || return 1
  [ -n "$u1" ] && [ -n "$u2" ] || return 1
  [ "$u1" != "$u2" ] || return 1
  return 0
}

test_launch_creates_task_with_deterministic_uuid() {
  command -v md5sum >/dev/null 2>&1 || { echo "SKIP: md5sum not found"; return 0; }
  fresh_tasks
  local uuid_k1 uuid_k2 actual_k1 actual_k2
  uuid_k1=$(bash -c "source '$REPO_DIR/hooks/acli-sync/lib/acli-sync-lib.bash'; acli_sync::jira_key_to_uuid KEY-1") || return 1
  uuid_k2=$(bash -c "source '$REPO_DIR/hooks/acli-sync/lib/acli-sync-lib.bash'; acli_sync::jira_key_to_uuid KEY-2") || return 1
  FAKE_ACLI_MODE=search bash "$HOOKS_DIR/on-launch.acli-sync" >/dev/null 2>&1 || return 1
  actual_k1=$(tx | jq -r '.[] | select(.jirakey == "KEY-1") | .uuid')
  actual_k2=$(tx | jq -r '.[] | select(.jirakey == "KEY-2") | .uuid')
  [ "$actual_k1" = "$uuid_k1" ] || { echo "want KEY-1 uuid=$uuid_k1 got $actual_k1" >&2; return 1; }
  [ "$actual_k2" = "$uuid_k2" ] || { echo "want KEY-2 uuid=$uuid_k2 got $actual_k2" >&2; return 1; }
  return 0
}

test_launch_reimport_yields_same_uuid() {
  command -v md5sum >/dev/null 2>&1 || { echo "SKIP: md5sum not found"; return 0; }
  fresh_tasks
  FAKE_ACLI_MODE=search bash "$HOOKS_DIR/on-launch.acli-sync" >/dev/null 2>&1 || return 1
  local u1 u2
  u1=$(tx | jq -r '.[] | select(.jirakey == "KEY-1") | .uuid')
  [ -n "$u1" ] || return 1
  # Delete the KEY-1 task so the next on-launch pass re-imports it from
  # the same fake acli snapshot. The deterministic UUID must come back
  # identical. Pipe "y" into the delete so TW's interactive prompt is
  # satisfied when running under a non-TTY test harness.
  yes y | t "$u1" delete >/dev/null 2>&1 || return 1
  FAKE_ACLI_MODE=search bash "$HOOKS_DIR/on-launch.acli-sync" >/dev/null 2>&1 || return 1
  u2=$(tx | jq -r '.[] | select(.jirakey == "KEY-1") | .uuid')
  [ "$u1" = "$u2" ] || { echo "want $u1 got $u2" >&2; return 1; }
  return 0
}

test_launch_skips_mirroring_during_command_add_or_import() {
    fresh_tasks
    # Simulate TW firing on-launch while the user is mid-add (or mid-import).
    # The hook must short-circuit to exit 0 without touching the task list.
    FAKE_ACLI_MODE=search bash "$HOOKS_DIR/on-launch.acli-sync" \
        'api:2' 'args:task add something' 'command:add' 'rc:/tmp/x' 'data:/tmp/x' 'version:3.4.2' \
        >/dev/null 2>&1 || return 1
    tx | jq -e 'length == 0' >/dev/null || return 1

    FAKE_ACLI_MODE=search bash "$HOOKS_DIR/on-launch.acli-sync" \
        'api:2' 'args:task import ./x.json' 'command:import' 'rc:/tmp/x' 'data:/tmp/x' 'version:3.4.2' \
        >/dev/null 2>&1 || return 1
    tx | jq -e 'length == 0' >/dev/null || return 1
    return 0
}

test_launch_init_age_from_jira_created() {
    fresh_tasks
    # Default config has init_age_from_jira=1. The fake view returns
    # created="2020-01-15T10:30:00.000+0000" for KEY-1 (+0000 offset, so
    # the conversion to TW compact UTC is identity).
    FAKE_ACLI_MODE=search bash "$HOOKS_DIR/on-launch.acli-sync" >/dev/null 2>&1 || return 1
    local k1_entry k1_modified
    k1_entry=$(tx | jq -r '.[] | select(.jirakey == "KEY-1") | .entry')
    [ "$k1_entry" = "20200115T103000Z" ] || \
        { echo "want KEY-1 entry=20200115T103000Z got=$k1_entry" >&2; return 1; }
    # modified is the import moment, distinct from entry.
    k1_modified=$(tx | jq -r '.[] | select(.jirakey == "KEY-1") | .modified')
    [ -n "$k1_modified" ] || return 1
    [ "$k1_modified" != "$k1_entry" ] || \
        { echo "modified should differ from entry, both=$k1_entry" >&2; return 1; }
    return 0
}

test_launch_init_age_off_uses_now() {
    fresh_tasks
    # Override the config with init_age_from_jira=0; entry should default to
    # the import moment ("now") rather than the workitem's created date.
    local tmp_config k1_entry
    # Override the config dir: a single config file that flips
  # init_age_from_jira=0. Every other default from set_config_defaults applies,
  # so the mirrored task falls back to "now" for entry.
  override_dir=$(mktemp -d)
  # Carry the example config's `filter` along so `fetch_jira` actually runs;
  # init_age_from_jira=0 overrides the default so entry falls back to "now".
  printf 'filter=23465\ninit_age_from_jira=0\n' >"$override_dir/00-disable.conf"
  ACLI_SYNC_CONFIG_DIR="$override_dir" FAKE_ACLI_MODE=search \
        bash "$HOOKS_DIR/on-launch.acli-sync" >/dev/null 2>&1 ||
        { rm -rf "$override_dir"; return 1; }
    k1_entry=$(tx | jq -r '.[] | select(.jirakey == "KEY-1") | .entry')
    rm -rf "$override_dir"
    # It must NOT equal the workitem's created-derived timestamp; that
    # confirms enrichment was skipped and entry defaulted to "now".
    [ "$k1_entry" != "20200115T103000Z" ] || return 1
    [ -n "$k1_entry" ] || return 1
    return 0
}

# --- Run ---------------------------------------------------------------------
run_test "on-launch adds new mirrored tasks" test_launch_adds_new
run_test "on-launch reconciles status of matched task" test_launch_reconciles_status
run_test "on-modify completed task triggers Jira transition" test_modify_completes_triggers_transition
run_test "on-modify task without jirakey passes through" test_modify_no_jirakey_is_pass_through
run_test "jira_key_to_uuid is deterministic for KEY-1" test_jira_key_to_uuid_deterministic
run_test "jira_key_to_uuid differs for KEY-1 vs KEY-2" test_jira_key_to_uuid_unique
run_test "on-launch creates tasks with deterministic UUIDs" test_launch_creates_task_with_deterministic_uuid
run_test "on-launch reimport yields same UUID after delete" test_launch_reimport_yields_same_uuid
run_test "on-launch skips mirroring during command:add|import" test_launch_skips_mirroring_during_command_add_or_import
run_test "on-launch inherits task entry from Jira created" test_launch_init_age_from_jira_created
run_test "on-launch falls back to now when init_age_from_jira=0" test_launch_init_age_off_uses_now
run_test "on-launch exits non-zero when config dir is missing" test_launch_missing_config_exits_nonzero
run_test "on-launch iterates multiple config.d files" test_launch_iterates_multiple_configs
run_test "install respects XDG_CONFIG_HOME" test_install_xdg_config_home_respected
run_test "install falls back to ~/.config/task when XDG_CONFIG_HOME is unset" test_install_xdg_empty_uses_dot_config
run_test "install honors TASK_HOOKS_DIR override" test_install_task_hooks_dir_overrides
run_test "install does not fall back to legacy paths when XDG_CONFIG_HOME is set" test_install_xdg_preempts_legacy_dot_task
run_test "install prints include line not pasted snippet" test_install_prints_include_line_not_pasted_snippet

echo
echo "Tests passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
