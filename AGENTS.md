# AGENTS.md

This repository is heavily AI-written and unowned (see [NOTICE](./NOTICE)).
Treat it as disposable source — copy, rewrite, lift, or borrow from
freely under the MIT licence in [LICENSE](./LICENSE).

What this is
------------

A Taskwarrior hooks bundle that mirrors Atlassian Jira work items into
TW via `acli`. The two Taskwarrior hooks (`on-launch`, `on-modify`)
plus the shared library (`lib/acli-sync-lib.bash`), the taskrc fragment
(`acli-sync.taskrc`), and the example configs (`config.d/*.conf`)
together form a self-contained bundle that `install.bash` deploys under
`<hooks.location>/acli-sync/`.

Layout
------

```
acli-task/
├── LICENSE                       # MIT
├── NOTICE                        # AI-written / unowned disclosure
├── AGENTS.md                     # this file
├── README.md                     # user-facing docs (install + config + troubleshooting)
├── install.bash                  # bash installer (requires bash 4+)
├── config.d/
│   ├── example-team.conf         # first-team starter config
│   └── example-other.conf        # second-team starter config
├── hooks/
│   ├── on-launch.acli-sync       # mirror Jira → TW (run on every `task` invocation)
│   ├── on-modify.acli-sync       # push TW edits → Jira (run on every task modification)
│   └── acli-sync/
│       ├── acli-sync.taskrc      # `include` this in your .taskrc
│       └── lib/
│           └── acli-sync-lib.bash # shared library sourced by both hooks
└── tests/
    └── test-acli-sync.bash       # full test suite (bash, no bats)
```

Conventions
-----------

- **Bash 4+.** All scripts target bash 4+ (uses `declare -A`, `mapfile`,
  `printf -v`, `[[ ]]`). The shebangs are `#!/usr/bin/env bash`.
- **File extensions**: `.bash` for bash-specific scripts; `.sh`
  reserved for POSIX-compliant scripts (none in this repo today).
- **`set -u` everywhere.** Every script uses `set -u` to catch unset-
  variable mistakes. The lib temporarily `set +u` around user `source`
  calls so a stray unset in a user's config doesn't abort the hook.
- **`acli_sync::` namespace.** All lib helpers are `acli_sync::name`
  bash functions. Variables are exported across the hook boundary so
  each hook can read them under its own `set -u`.
- **Hook output conventions.**
  - `on-launch` writes feedback on **stderr**, never stdout.
  - `on-modify` writes the modified task JSON as its **first stdout
    line** and feedback on subsequent stdout lines / stderr.
- **Fail-open.** Every helper returns 1 cleanly when its prerequisites
  are missing (jq, config, etc.) and the caller logs a feedback line
  without aborting the hook. The only hard exits (`exit 1`) are for
  structurally fatal config errors a user could not be expected to
  ignore.

Editing the lib
---------------

Default values for all config keys live in
`acli_sync::set_config_defaults` — update this function AND the
matching `export ...` line at the bottom of `acli_sync::source_config_file`
when adding a new key.

New helpers belong in `lib/acli-sync-lib.bash` and should be sourced
automatically by both hooks through `acli-sync/lib/acli-sync-lib.bash`.
Avoid `eval`. Prefer bash arrays + `mapfile`/`read -a`.

When a helper takes a per-config runtime flag (e.g. `init_age_from_jira`)
and reads it from `set_config_defaults`, make sure the per-config
function `acli_sync::source_config_file` re-exports the flag, and the
hook refreshes it between config iterations.

Editing the hooks
----------------

- Hooks source the lib via
  `source "$SELF_DIR/acli-sync/lib/acli-sync-lib.bash"`. Don't hardcode
  absolute paths.
- The config dir default is `$SELF_DIR/acli-sync/config.d/`. Override
  with `$ACLI_SYNC_CONFIG_DIR` to point at a different directory.
- `on-launch` skips mirroring when the user is mid-`add` or mid-`import`.
  Reason: the user's just-saved task isn't yet visible to our
  `task export`, and mirroring in that state would race the user's
  task. New Jira issues get mirrored at the next `task list` instead.
- Per-record fields that depend on a config's values (`project`,
  `priority_in_progress`) must be evaluated *per issue* and baked
  into the flat record before batched import — otherwise multi-config
  flows inherit the last-loaded config's values.

Editing tests
------------

- The single test entrypoint is `tests/test-acli-sync.bash`. Run it
  directly with `bash tests/test-acli-sync.bash` (no bats).
- The fake `acli` is on `$FAKE_BIN` (earlier on `PATH`). It detects
  `acli`'s verb from args (search/view/transition/edit) rather than
  relying on `FAKE_ACLI_MODE`. For search, it inspects `--filter` to
  return canned issues per filter ID; for view, it inspects `--key`.
- Helpers near the top of the test file (`fresh_tasks`, `add_config`,
  `reset_configs`, `tx`, `t`) are the recommended primitives. Tests
  should compose them rather than build their own scaffolding.

Adding a new config key
----------------------

1. Add the default to `acli_sync::set_config_defaults` in the lib.
2. Add the key to the `export ...` line at the end of
   `acli_sync::source_config_file`.
3. If the key drives a per-record field, add the corresponding `+ (if
   $X != "" then {…})` line to the jq block at the bottom of
   `acli_sync::acli_to_task_import_record`.
4. Document the key:
   - In `README.md`'s Configuration table.
   - In `config.d/example-team.conf` (with a sensible example value).

Releasing
---------

No formal release cadence. Push to git whenever tests pass
(`bash tests/test-acli-sync.bash` reports 18 PASS / 0 FAIL is the
current bar). No CHANGELOG file is kept — git history is the source.

Where to look first when something breaks
------------------------------------------

- Hook isn't firing: check `task diag` (Taskwarrior lists discovered
  hooks and their executability).
- Tasks aren't being mirrored: `bash install.bash --help`, check the
  bundle's `acli-sync/config.d/` for `.conf` files.
- Tasks are mirrored but statuses don't match: the issue is almost
  certainly in `status_completed` / `status_in_progress` of one of
  your configs. Lowercase/whitespace differences matter — `acli_sync::in_list`
  does case-insensitive whitespace-tolerant matching.
- acli push-back (on-modify) silently fails: check the `FAKE_ACLI_LOG`
  or run your modified `task modify` with `acli --version` first so
  you see credential / profile errors.

Background context
------------------

- Taskwarrior hook contract: see <https://taskwarrior.org/docs/hooks2/>.
  Hooks v2 (`api:2`) is the supported protocol.
- Atlassian CLI (`acli`): see
  <https://developer.atlassian.com/cloud/acli/reference/commands/jira-workitem-search/>.
  `acli jira workitem search --json` does NOT include the workitem's
  `created` field (verified against v1.3.39's allowed-fields list), so the
  init-age feature pulls it via `acli jira workitem view --key X --fields "*all" --json`
  per new key.
