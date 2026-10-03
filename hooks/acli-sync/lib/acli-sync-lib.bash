# acli-sync shared library.
#
# Sourced by hooks/on-launch.acli-sync and hooks/on-modify.acli-sync. Safe
# under `set -u`. Feedback goes to stderr via acli_sync::log so hook stdout
# stays machine-clean (one JSON line per stdout for on-modify, nothing for
# on-launch).
#
# Configuration model: the hooks iterate every `*.conf` (or `*.bash`)
# file in the bundle's `acli-sync/config.d/` (next to the installed
# hooks) - or in `${ACLI_SYNC_CONFIG_DIR}` if set. Each file is its own
# whole config (`set_config_defaults` reapplies per iteration). Filename
# alphabetical order is the iteration order; prefix with a number
# (10-, 20-) for explicit control. on-launch's per-record project is
# baked at queue time so multi-config flows don't all share the last-
# loaded config's project.
#
# Public functions:
#   acli_sync::die "msg"                      print msg to stderr, exit 1
#   acli_sync::set_config_defaults            reset all config globals to the
#                                             built-in defaults (called by
#                                             source_config_file at the top
#                                             of each per-config iteration)
#   acli_sync::source_config_file <path>      source one config file with full
#                                             defaults applied first; re-
#                                             exports globals for the calling
#                                             hook. rc 1 if the file is missing
#                                             or sourcing fails
#   acli_sync::list_config_files <dir>        print sorted *.conf / *.bash paths
#                                             under <dir>, one per line
#                                             (hidden files skipped). rc 1 if
#                                             <dir> doesn't exist
#   acli_sync::require_a_cli                  exit 1 if $acli_bin is missing on
#                                             PATH or `acli --version` fails
#   acli_sync::fetch_jira                     use the currently sourced config's
#                                             filter/jql. Print a flattened
#                                             JSON array of issues on stdout;
#                                             each issue carries `created` if
#                                             init_age_from_jira=1 and the
#                                             per-key `view` lookup succeeded.
#                                             non-zero rc only on acli failure
#   acli_sync::acli_to_task_import_record     build one TW-style JSON record
#     "<flat>" "<now_ts>"                     (with deterministic UUID baked
#                                             from jirakey) from a single flat
#                                             acli record. `project` is taken
#                                             from the flat record first (so
#                                             multi-config flows don't share
#                                             the last-loaded config's project)
#                                             and falls back to the global.
#                                             entry = workitem `created`
#                                             (converted via iso_to_twdate) or
#                                             `<now_ts>`. modified = `<now_ts>`.
#                                             Echo compact JSON; rc 1 if the
#                                             key is empty or jira_key_to_uuid
#                                             fails
#   acli_sync::task_import_records            read newline-delimited flat records
#                                             on stdin, batch them into a
#                                             single `[ {...}, {...} ]` JSON
#                                             file, and `task import` it.
#                                             rc 0 on no-op or success;
#                                             propagated from `task import`
#                                             on acli/TW failure
#   acli_sync::iso_to_twdate <iso>            convert a Jira/POSIX ISO 8601
#                                             datetime (`...T...Z` or `...Z` or
#                                             `...±NNNN`) into TW's compact
#                                             UTC form (`YYYYMMDDTHHMMSSZ`).
#                                             uses `date -u -d` from GNU
#                                             coreutils. rc 1 on parse failure
#   acli_sync::jira_key_to_uuid "KEY"         print a stable 36-char UUID-shaped
#                                             hex string derived
#                                             deterministically from the KEY
#                                             (md5 of `namespace|key`). rc 1
#                                             when md5sum/md5 is missing
#   acli_sync::status_for_jira "Status"       echo `pending` | `completed` for the
#                                             given Jira status (uses
#                                             $status_completed / $status_in_progress)
#   acli_sync::priority_for_jira "Status"     echo $priority_in_progress when the
#                                             status matches $status_in_progress,
#                                             else ""
#   acli_sync::in_list "value" "a|b|c"        0 if value matches a '|'-separated
#                                             token (case-insensitive,
#                                             whitespace tolerant)
#   acli_sync::map_priority                   reserved no-op (acli edit has no
#                                             --priority); retained so
#                                             call-sites can reference it
#   acli_sync::log "msg"                      timestamped line on stderr unless
#                                             quiet=1
#   acli_sync::task "$@"                      run `task` with rc.hooks=off and
#                                             rc.color=no, scoped to the data
#                                             dir resolved (in order) from
#                                             $ACLI_SYNC_DATA_DIR, $TASKDATA,
#                                             ${XDG_DATA_HOME:-$HOME/.local/share}/task,
#                                             or $HOME/.task as last-resort
#                                             fallback. Honours rc:$ACLI_SYNC_RC

acli_sync::die() {
  printf 'acli-sync: %s\n' "$*" >&2
  exit 1
}

acli_sync::log() {
  [ "${quiet:-0}" = "1" ] && return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Match a value against a pipe-separated list of tokens (case-insensitive,
# tolerant of surrounding whitespace). Returns 0 on match.
acli_sync::in_list() {
  local value="$1" list="$2"
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  list=$(printf '%s' "$list" |
    tr '[:upper:]' '[:lower:]' |
    sed -e 's/[[:space:]]*|[[:space:]]*/;/g' \
      -e 's/^[[:space:]]*//' \
      -e 's/[[:space:]]*$//')
  [ -n "$value" ] && [[ ";$list;" == *";$value;"* ]]
}

# Map a Jira status name to a Taskwarrior status. Anything not in
# $status_completed maps to "pending" (status_in_progress is deliberately not a
# terminal state).
acli_sync::status_for_jira() {
  if acli_sync::in_list "$1" "$status_completed"; then
    echo "completed"
  else
    echo "pending"
  fi
}

# Optional: mirror an in-progress Jira status to priority H on mirrored tasks.
# Leave priority_in_progress empty to disable. Only applied on task creation.
acli_sync::priority_for_jira() {
  local status="$1"
  if [ -n "${priority_in_progress:-}" ] && acli_sync::in_list "$status" "$status_in_progress"; then
    echo "$priority_in_progress"
  fi
}

# Reserved. Jira priority is not editable via acli (acli jira workitem edit has
# no --priority flag), so a Taskwarrior -> Jira priority push is not possible.
acli_sync::map_priority() {
  return 0
}

# Apply defaults for all known config keys. Called at the top of every
# per-config iteration so an unset key in one config does not bleed values
# from a previous iteration.
acli_sync::set_config_defaults() {
  project=""
  filter=""
  jql=""
  jira_key_uda="jirakey"
  jira_status_uda="jirastatus"
  jira_url_uda="jiraurl"
  status_completed="Done|Closed|Resolved"
  status_in_progress="In Progress|Review"
  priority_in_progress="H"
  sync_on_modify=1
  sync_description_on_modify=1
  sync_labels_on_modify=0
  sync_description_on_launch=1
  complete_jira_status="Done"
  reopen_jira_status="To Do"
  acli_bin="acli"
  max_results=200
  paginate=1
  quiet=0
  init_age_from_jira=1
}

# Source one config file with full defaults applied first. Returns 1 if the
# file is missing or sourcing fails; callers (the on-launch/on-modify hooks)
# log a warning and skip that config rather than abort.
acli_sync::source_config_file() {
  local config_path="$1"
  [ -n "$config_path" ] || return 1
  acli_sync::set_config_defaults

  if [ ! -f "$config_path" ]; then
    return 1
  fi

  # Relax `set -u` while sourcing: a stray unset-variable reference in a
  # user's config must not abort the hook mid-flight.
  local rc=0
  if [[ $- == *u* ]]; then
    set +u
    # shellcheck disable=SC1090
    . "$config_path"
    rc=$?
    set -u
  else
    # shellcheck disable=SC1090
    . "$config_path"
    rc=$?
  fi
  [ "$rc" -ne 0 ] && return 1

  # Re-export so per-config values are visible to the calling hook.
  export project filter jql
  export jira_key_uda jira_status_uda jira_url_uda
  export status_completed status_in_progress priority_in_progress
  export sync_on_modify sync_description_on_modify sync_labels_on_modify
  export sync_description_on_launch
  export complete_jira_status reopen_jira_status
  export acli_bin max_results paginate quiet
  export init_age_from_jira
  return 0
}

# Print config files in a directory, one per line, sorted lexicographically.
# Recognized extensions are `*.conf` and `*.bash` (both shell-sourceable).
# Hidden files (names starting with `.`) are skipped. Returns 1 if the
# directory does not exist.
acli_sync::list_config_files() {
  local dir="${1:?dir required}"
  [ -d "$dir" ] || return 1
  local f
  # shellcheck disable=SC2045
  for f in $(LC_ALL=C ls -1A "$dir" 2>/dev/null | LC_ALL=C sort); do
    case "$f" in
      *.conf | *.bash) printf '%s/%s\n' "$dir" "$f" ;;
    esac
  done
}

acli_sync::require_a_cli() {
  if ! command -v "$acli_bin" >/dev/null 2>&1; then
    acli_sync::die "acli binary '$acli_bin' not found on PATH"
  fi
  if ! "$acli_bin" --version >/dev/null 2>&1; then
    acli_sync::die "acli binary '$acli_bin' failed its --version check (is it really acli?)"
  fi
  return 0
}

# Run `task` with hooks disabled and colors off, scoped to the data dir the
# outer Taskwarrior actually used. Resolution order:
#   1. data: hook arg (provided by Taskwarrior v2 API; XDG-aware)
#   2. $TASKDATA env var
#   3. ${XDG_DATA_HOME:-$HOME/.local/share}/task (XDG Base Directory Spec)
#   4. $HOME/.task (legacy TW 2.x default)
# Passing rc:$ACLI_SYNC_RC keeps the same rc file (UDAs, data location) in
# effect for internal calls. TASKDATA is set explicitly because it takes
# precedence over data.location from the rc file.
acli_sync::task() {
  local data_dir="${ACLI_SYNC_DATA_DIR:-${TASKDATA:-${XDG_DATA_HOME:-$HOME/.local/share}/task}}"
  local rc_args=()
  if [ -n "${ACLI_SYNC_RC:-}" ]; then
    rc_args=(rc:"$ACLI_SYNC_RC")
  fi
  TASKDATA="$data_dir" task rc.hooks=off rc.color=no "${rc_args[@]}" "$@"
}

# Build a single TW-style JSON task record (compact, no trailing newline)
# from one `flat` acli record line. The UUID is the deterministic value
# derived from the Jira key, so the same key yields the same UUID on every
# import. The `entry` field is the workitem's `created` timestamp when
# available (acli_sync::fetch_jira enriches it via `view`), otherwise the
# caller-supplied "now". `modified` is always the import moment. Optional
# fields (project, jirakey UDA, jirastatus UDA, jiraurl UDA, priority,
# labels) are added conditionally. Returns 1 when the key is empty or the
# UUID derivation itself fails.
acli_sync::acli_to_task_import_record() {
  local flat="$1" now_ts="$2"
  local key summary jstatus tw_status url labels_csv uuid_str prio proj
  local created_iso entry_ts modified_ts

  key=$(printf '%s' "$flat" | jq -r '.key // ""')
  [ -n "$key" ] || return 1

  uuid_str=$(acli_sync::jira_key_to_uuid "$key")
  [ -n "$uuid_str" ] || return 1

  summary=$(printf '%s' "$flat" | jq -r '.summary // ""')
  jstatus=$(printf '%s' "$flat" | jq -r '.status // ""')
  tw_status=$(acli_sync::status_for_jira "$jstatus")
  prio=$(acli_sync::priority_for_jira "$jstatus")
  url=$(printf '%s' "$flat" | jq -r '.url // ""')
  labels_csv=$(printf '%s' "$flat" | jq -r '.labels // [] | join(",")')

  # Per-config $project baked into the flat record at queue time (in
  # on-launch) wins over the global $project, so multi-config flows don't
  # all inherit the last loaded config's project.
  proj=$(printf '%s' "$flat" | jq -r '.project // ""')
  [ -z "$proj" ] && proj="$project"

  created_iso=$(printf '%s' "$flat" | jq -r '.created // ""')
  if [ -n "$created_iso" ]; then
    entry_ts=$(acli_sync::iso_to_twdate "$created_iso" 2>/dev/null) || entry_ts="$now_ts"
  else
    entry_ts="$now_ts"
  fi
  modified_ts="$now_ts"

  # Compose optional fields with conditional jq additions. The
  # `{($key_uda): $jk}` form sets a dynamic object key.
  jq -c -n \
    --arg uuid "$uuid_str" \
    --arg status "$tw_status" \
    --arg desc "$summary" \
    --arg prio "$prio" \
    --arg entry_ts "$entry_ts" \
    --arg mod_ts "$modified_ts" \
    --arg proj "$proj" \
    --arg jk "$key" \
    --arg js "$jstatus" \
    --arg url "$url" \
    --arg key_uda "$jira_key_uda" \
    --arg stat_uda "$jira_status_uda" \
    --arg url_uda "$jira_url_uda" \
    --arg labels "$labels_csv" \
    '{
      uuid: $uuid,
      status: $status,
      description: $desc,
      entry: $entry_ts,
      modified: $mod_ts
    }
    + (if $prio != "" then {priority: $prio} else {} end)
    + (if $proj != "" then {project: $proj} else {} end)
    + (if $jk != "" and $key_uda != "" then {($key_uda): $jk} else {} end)
    + (if $js != "" and $stat_uda != "" then {($stat_uda): $js} else {} end)
    + (if $url != "" and $url_uda != "" then {($url_uda): $url} else {} end)
    + (if $labels != "" then {tags: ($labels | split(","))} else {} end)'
}

# Read newline-delimited flat records on stdin, build a JSON array file, and
# `task import` it. Returns 0 on no-op (zero records) or success; propagated
# from `task import` on failure. The temp file is created inside $TASKDATA
# when possible so existing data-dir cleanup reaches it; otherwise /tmp.
acli_sync::task_import_records() {
  local records_csv="" item record entry_ts

  entry_ts=$(date -u '+%Y%m%dT%H%M%SZ')
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    record=$(acli_sync::acli_to_task_import_record "$item" "$entry_ts" 2>/dev/null) || continue
    [ -z "$record" ] && continue
    if [ -z "$records_csv" ]; then
      records_csv="$record"
    else
      records_csv="${records_csv},${record}"
    fi
  done

  [ -z "$records_csv" ] && return 0

  local file
  if file=$(mktemp -p "${TASKDATA:-${TMPDIR:-/tmp}}" 2>/dev/null); then
    :
  else
    file=$(mktemp)
  fi
  # Each $record is a compact JSON object (no embedded newlines), so
  # comma-joining them and wrapping in [...] yields a valid `task import`
  # array. Earlier attempts to round-trip through `jq -R -s` produced an
  # array of strings, which `task import` rejects (and on TW 3.x segfaults).
  printf '[%s]\n' "$records_csv" > "$file"

  acli_sync::task import "$file"
  local rc=$?
  rm -f "$file"
  return "$rc"
}

# Print a flattened JSON array of issues on stdout. Chunking is delegated to
# acli's --limit/--paginate flags. Returns non-zero only when acli itself fails.
acli_sync::fetch_jira() {
  if ! command -v jq >/dev/null 2>&1; then
    acli_sync::log "warning: jq not found; cannot parse acli output, skipping sync"
    printf '%s\n' "[]"
    return 0
  fi

  local query=("$acli_bin" jira workitem search)
  if [ -n "$filter" ]; then
    query+=(--filter "$filter")
  elif [ -n "$jql" ]; then
    query+=(--jql "$jql")
  else
    acli_sync::log "warning: neither filter nor jql configured; skipping sync"
    printf '%s\n' "[]"
    return 0
  fi
  if [ -n "$max_results" ]; then
    query+=(--limit "$max_results")
  fi
  if [ "$paginate" = "1" ]; then
    query+=(--paginate)
  fi
  query+=(--json)

  local raw
  raw=$("${query[@]}" 2>/dev/null) || return 1

  # Flatten acli's nested issue shape. url is derived from .self when present
  # (a Jira API url is rewritten into a /browse/ url); otherwise it stays "".
  local flat
  flat=$(printf '%s' "$raw" | jq -c '[.[] | {
        key: .key,
        summary: (.fields.summary // ""),
        status: (.fields.status.name // ""),
        priority: (.fields.priority.name // ""),
        assignee: (.fields.assignee.displayName // ""),
        labels: (.fields.labels // []),
        url: ((.self // "") | if contains("/browse/") then . else sub("/rest/api/[0-9]+/issue/"; "/browse/") end),
        raw: .
    }]' 2>/dev/null) || {
    acli_sync::log "warning: could not parse acli output with jq"
    printf '%s\n' "[]"
    return 0
  }

  # Optional enrichment: pull each issue's `created` timestamp via `view`
  # so the imported task's age matches the workitem's age. Search doesn't
  # expose `created` (verified against acli 1.3.39's allowed-fields list);
  # `view --fields "*all"` does. Cost is one extra acli call per key (per
  # new mirror); the no-op path is skipped by leaving init_age_from_jira=0.
  if [ "${init_age_from_jira:-0}" = "1" ]; then
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      local view_json created
      view_json=$("$acli_bin" jira workitem view --key "$k" --fields "*all" --json 2>/dev/null) || continue
      created=$(printf '%s' "$view_json" | jq -r '.[0].created // ""' 2>/dev/null)
      [ -n "$created" ] || continue
      flat=$(printf '%s' "$flat" | jq -c --arg k "$k" --arg c "$created" \
        'map(if .key == $k then . + {created: $c} else . end)')
    done < <(printf '%s' "$flat" | jq -r '.[].key')
  fi

  printf '%s' "$flat"
}

# Convert a Jira/POSIX ISO 8601 datetime string (e.g.
# "2026-03-31T09:20:42.499-0700") into Taskwarrior's compact UTC format
# ("20260331T162042Z"). Uses `date -u -d` from GNU coreutils, which handles
# fractional seconds and POSIX timezone offsets correctly. jq's `fromdate`
# was tried but does not consistently accept the `+0000` offset form that
# acli's `--json` output uses. macOS/BSD users can install `coreutils`
# (provides `gdate`) and set `acli_bin=...` accordingly; this hookset
# targets Linux first. Returns 1 on parse failure.
acli_sync::iso_to_twdate() {
  local iso="$1"
  [ -n "$iso" ] || return 1
  date -u -d "$iso" '+%Y%m%dT%H%M%SZ' 2>/dev/null
}

# Print one `task add` attribute per line, e.g.
#   project:acli
#   jirakey:E30N-3
#   jirastatus:In Progress
#   description:Fix the frobnicator
#   +bug
# Newline-delimited (not space-separated) so the hook can `mapfile -t` into an
# array and call `task add "${args[@]}"` without eval; values are still safe
# when they contain spaces, quotes, or glob characters. Jira summaries and
# labels are single-line by construction.
acli_sync::acli_to_task_add_args() {
  local flat="$1"
  [ -z "$flat" ] && return 0

  local key summary status tw_status url prio label out=""
  key=$(printf '%s' "$flat" | jq -r '.key // ""')
  summary=$(printf '%s' "$flat" | jq -r '.summary // ""')
  status=$(printf '%s' "$flat" | jq -r '.status // ""')
  tw_status=$(acli_sync::status_for_jira "$status")
  url=$(printf '%s' "$flat" | jq -r '.url // ""')
  prio=$(acli_sync::priority_for_jira "$status")

  [ -n "$project" ] && out+="project:$project"$'\n'
  [ -n "$key" ] && out+="$jira_key_uda:$key"$'\n'
  [ -n "$tw_status" ] && out+="status:$tw_status"$'\n'
  [ -n "$status" ] && out+="$jira_status_uda:$status"$'\n'
  [ -n "$url" ] && out+="$jira_url_uda:$url"$'\n'
  [ -n "$prio" ] && out+="priority:$prio"$'\n'
  [ -n "$summary" ] && out+="description:$summary"$'\n'
  while IFS= read -r label; do
    [ -n "$label" ] && out+="+$label"$'\n'
  done < <(printf '%s' "$flat" | jq -r '.labels // [] | .[]')
  printf '%s' "$out"
}

# Stable namespace discriminator for the deterministic Jira-key -> task UUID
# mapping. Pinning to a literal keeps the mapping immune to upstream
# changes that might repurpose symbolic UUIDs. (A function, not a variable:
# bash forbids '::' in variable names but allows it in function names, which
# every other acli_sync::* name here is too.)
acli_sync::JIRA_KEY_UUID_NS() {
  printf '%s\n' "acli-sync-jira-key-derived-v1"
}

# Print a stable, UUID-shaped 36-char hex string for the given Jira key.
# Identical inputs always produce identical output, regardless of when or
# where this is called. Returns 1 on failure (e.g. md5sum missing).
acli_sync::jira_key_to_uuid() {
  local key="$1" ns
  ns=$(acli_sync::JIRA_KEY_UUID_NS) || return 1
  [ -n "$key" ] || return 1

  local md5_cmd=""
  if command -v md5sum >/dev/null 2>&1; then
    md5_cmd="md5sum"
  elif command -v md5 >/dev/null 2>&1; then
    md5_cmd="md5"
  fi
  [ -n "$md5_cmd" ] || return 1

  local md5
  if ! md5=$(printf '%s' "${ns}|${key}" | $md5_cmd 2>/dev/null | awk '{print $1}'); then
    return 1
  fi
  [ "${#md5}" -ge 32 ] || return 1

  printf '%s-%s-%s-%s-%s\n' \
    "${md5:0:8}" "${md5:8:4}" "${md5:12:4}" "${md5:16:4}" "${md5:20:12}"
}
