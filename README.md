# acli-sync: Taskwarrior <-> Jira sync hooks

> **AI-written, unowned code.** This repository is the output of an AI
> coding session with light human direction. No human claims authorship
> or ownership of the design, code, or documentation — see
> [NOTICE](./NOTICE) and [LICENSE](./LICENSE). Treat it as disposable
> source: copy, rewrite, lift, or borrow freely.

Two Taskwarrior hook scripts that sync Jira work items (read and written via the
[Atlassian CLI](https://www.atlassian.com/software/jira/atlassian-cli),
`acli`) with a local Taskwarrior task list.

| Hook | Runs | Direction |
|------|------|-----------|
| `hooks/on-launch.acli-sync` | before every `task` invocation | Jira -> Taskwarrior (mirror, with deterministic UUIDs) |
| `hooks/on-modify.acli-sync` | after every task edit | Taskwarrior -> Jira (push) |

Tasks are linked to Jira issues through a `jirakey` UDA, so only tasks that
carry one are ever touched by the hooks.

## Requirements

- **Taskwarrior 2.4.3+** (uses the v2 hooks API; tested on 3.4.2)
- **acli** installed and authenticated (`acli jira auth login --site ...
  --email ...
  --token`)
- **jq** (standard on Linux) — if missing, the hooks fail open with a warning
- **bash 4+** (for `mapfile`)

## Install

```sh
bash install.bash
```

This copies the two hooks into the destination directory and lays out the shared
library plus the taskrc fragment into a self-contained `acli-sync/` subdirectory
next to them.
The hooks source the lib from `../acli-sync/lib/acli-sync-lib.bash`.
The install then prints **one** line to drop into your `.taskrc` — an `include`
pointing at the installed taskrc fragment (which itself defines the UDAs and
`hooks.location`).
`--force` overwrites existing copies.
The install is idempotent:
already-present files are skipped unless `--force` is given.

The install destination is resolved in this order:

1. `$TASK_HOOKS_DIR` (env override wins)
2. `${XDG_CONFIG_HOME:-$HOME/.config}/task/hooks` (XDG Base Directory Spec —
   hooks are user-managed config files, so they live alongside `.taskrc` under
   `XDG_CONFIG_HOME`)
3. `$HOME/.task/hooks` (legacy Taskwarrior 2.x default; co-located with the task
   data)

Note:
this only affects where the **hook scripts** are installed.
The task **data** directory used by the hooks themselves still follows
taskwarrior's own `data.location` (via the `data:` hook arg), which on stock TW
3.x lives under `$XDG_DATA_HOME/task`.
If your task data lives elsewhere (e.g., `~/.task` for TW 2.x or a custom path),
nothing here needs to change — the hooks reach it via the `data:` arg your
taskwarrior passes them.

If you keep your `.taskrc` under `$XDG_CONFIG_HOME/task/` (the typical XDG
layout), the helper installs into the matching `task/hooks` directory
automatically.
To install elsewhere, set `TASK_HOOKS_DIR` to that path before running install,
or set `hooks.location` in your rc and pass `TASK_HOOKS_DIR` accordingly.
Add the printed `include` line to `~/.taskrc` (no copy-pasting of contents to do
— the included file defines the UDAs and `hooks.location` internally):

```conf
include /home/you/.config/task/hooks/acli-sync/acli-sync.taskrc
```

Replace the path above with whichever absolute path `install.bash` actually
printed; `taskwarrior`'s `include` directive reads file paths literally (no `~`
or env-var expansion).
Create one or more configs in the bundle's `config.d/` directory — each
file is a **whole** config (defaults are reapplied per file, so a key
unset in this file does NOT leak from the previous file):

```sh
# The bundle's config.d/ lives next to the hooks - the paths below match
# what `bash install.bash` just deployed. Override hooks.location in your
# rc and re-run install to put the whole bundle elsewhere.
HOOK_BUNDLE="$HOME/.config/task/hooks/acli-sync"      # adjust to match your install
mkdir -p "$HOOK_BUNDLE/config.d"
# One config per team / filter / Jira account. Filename's alphabetical
# order is also the loading order, so prefix with a number (10-, 20-)
# to keep things deterministic when you need finer control.
cp config.d/example-team.conf  "$HOOK_BUNDLE/config.d/10-team-alpha.conf"
cp config.d/example-other.conf "$HOOK_BUNDLE/config.d/20-team-beta.conf"
$EDITOR "$HOOK_BUNDLE/config.d/10-team-alpha.conf"
```

Each file gets its own `filter` (or `jql`), `project`, `sync_on_modify`,
etc. Keys that differ across configs are picked up per record at queue
time — for instance, the `project` you set in `10-team-alpha.conf`
applies to the tasks mirrored from THAT config's filter, even if a
later config (`20-team-beta.conf`) overrides the global `$project`
during its loop.

Verify with `task diag` (hooks should be listed as executable) and then `task
list` — mirrored issues appear as tasks.

## Configuration

`KEY=VALUE`, bash-sourceable.
Default path is the bundle's own `acli-sync/config.d/` (relative to
the hooks location — i.e. alongside `acli-sync.taskrc` and `lib/`,
inside the directory that `bash install.bash` deployed). Override with
the `ACLI_SYNC_CONFIG_DIR` environment variable to put configs anywhere
else (e.g. `ACLI_SYNC_CONFIG_DIR=/srv/jira-configs`). Each `*.conf` (or
`*.bash`) file in that directory is loaded as a complete config; the
alphabetical order of filenames is the iteration order.

│Key⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│Default⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│Meaning⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│-----⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│---------⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│---------⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
┊`filter`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊*(empty)*⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊Numeric
saved Jira filter ID for the snapshot┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
┊`jql`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊*(empty)*⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊JQL for
the snapshot.
Use **either** `filter`┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│ or
`jql`, not both.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
┊`project`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊*(empty)*⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊Project
assigned to mirrored tasks; empty = n┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│o
project.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│`jira_key_uda`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`jirakey`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│UDA
holding the Jira key.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│`jira_status_uda`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`jirastatus`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│UDA
holding the Jira status name.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
┊`jira_url_uda`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊`jiraurl`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊UDA
holding the Jira browse URL (set when acl┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│i
provides `.self`).⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
┊`status_completed`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊`Done|Closed|Resolved`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊`|`-separated
Jira statuses that map to task ┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`completed`.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
┊`status_in_progress`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊`In
Progress|Review`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊`|`-separated statuses that map to task `pend┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│ing`.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
┊`priority_in_progress`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊`H`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊Priority
for newly mirrored in-progress tasks┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│; empty
disables.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│`sync_on_modify`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`1`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│Push
task edits back to Jira.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│`sync_description_on_modify`⠀⠀⠀⠀⠀⠀⠀⠀│`1`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│Push
description changes as summary edits.⠀⠀⠀│
│`sync_labels_on_modify`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`0`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│Push
tag changes as label edits.
**Off by⠀⠀⠀⠀│
│default.**⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
┊`sync_description_on_launch`⠀⠀⠀⠀⠀⠀⠀⠀┊`1`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊Mirror
Jira summaries over local description ┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│edits
on launch.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│`complete_jira_status`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`Done`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│Jira
status to set when a task is completed.⠀│
┊`reopen_jira_status`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊`To Do`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊Jira
status to set when a completed task is r┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│eopened.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│`acli_bin`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`acli`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│Path/name
of the acli binary.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
┊`max_results`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊`200`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀┊`--limit`
passed to `acli jira workitem searc┊
│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│h`.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│`paginate`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`1`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│Whether
to pass `--paginate`.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│`quiet`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`0`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`1`
silences non-error feedback.⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
│`init_age_from_jira`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│`1`⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│When
`1`, mirror the workitem's `created` timestamp to the imported task's `entry`
(so its `age` matches the issue's age).
Costs one extra `acli jira workitem view` per new key per on-launch pass.
Set `0` to fall back to import-time `entry`.⠀⠀⠀⠀ │

## How it works

### on-launch (Jira -> Taskwarrior)

1. Reads the v2 hook args (`data:` / `rc:` / `command:`), sources
   `hooks/acli-sync/lib/acli-sync-lib.bash`, loads the config, and verifies
   `acli` exists.
2. **Skips mirroring when the user is mid-`add` or mid-`import`** — those
   commands race the hooks' UUID assignment, so any new Jira issues are mirrored
   at the next `task list` / `task next` / etc invocation instead.
3. Exports the local task list (hooks disabled internally with `rc.hooks=off
   rc.color=no`) and indexes it by the `jirakey` UDA.
4. Fetches the snapshot:
   `acli jira workitem search --filter <id> --json` (or `--jql <jql>`), with
   `--limit $max_results` and `--paginate` per config.
5. For each issue:
   if no task has its key, the issue is queued for batch import.
   If a task matches, its status is reconciled (`pending`/`completed`) and its
   description is re-synced to the summary (when
   `sync_description_on_launch=1`).
   Tasks in `deleted`/`waiting`/`recurring` state with a `jirakey` are matched
   but left untouched, so they are never mirrored twice.
6. After the loop, queued issues are batched into a single JSON file and
   imported via `task import`.
   Each record carries a **deterministic UUID** derived from its `jirakey` (see
   `acli_sync::jira_key_to_uuid` in `hooks/acli-sync/lib/acli-sync-lib.bash`),
   so deleting and re-running on-launch (or replaying the import) yields the
   identical UUID again every time.
   When `init_age_from_jira=1` (the default), `fetch_jira` enrichment has
   pre-fetched each issue's `created` via `acli jira workitem view --fields
   "*all"`, so `entry` is that timestamp (converted to TW compact UTC) and `age`
   is the issue's age in Jira; `modified` is still the import moment.
   re-running on-launch (or replaying the import) yields the identical UUID
   again every time.

### on-modify (Taskwarrior -> Jira)

Reads the two JSON lines (original, modified).
If the task has no `jirakey` UDA, or `sync_on_modify=0`, it passes the
modification through unchanged.
Otherwise it pushes the deltas:

- `pending -> completed`:
  `acli jira workitem transition --key $key --status "$complete_jira_status"
  --yes`, and the `jirastatus` UDA is set to the new status in the emitted JSON.
- `completed -> pending`:
  transition to `$reopen_jira_status`, UDA updated.
- description changed (if enabled):
  `acli jira workitem edit --key $key --summary ...
  --yes`.
- tags changed (if enabled):
  `edit --labels ...` / `--remove-labels`.

The modified task JSON is always the **first** stdout line; feedback follows.
The hook never vetoes (always exit 0).

## Worked example

Config:

```conf
jql=project = TEAM AND assignee = currentUser()
project=acli
status_completed="Done|Closed|Resolved"
complete_jira_status=Done
reopen_jira_status="To Do"
```

`task list`:

```text
ID St UUID     Age Project  Description          JiraKey   JiraStatus
-- -- -------- --- -------- ------------------- ---------- -----------
 -  P  a1b2...  2h acli     Fix the frobnicator  E30N-3     In Progress
 -  C  c3d4...  1d acli     Document the widget  E30N-4     Done
```

`task 1 done` fires `on-modify.acli-sync`, which transitions E30N-3 to `Done` in
Jira and writes `jirastatus:Done` into the task.
The next `task` invocation runs `on-launch.acli-sync`, which re-syncs from Jira
and marks E30N-4 completed (its mirror task) if it is now `Done` in Jira.

## Troubleshooting

- **`acli-sync:
  config missing or invalid`** — create `*.conf` files in the bundle's
  `acli-sync/config.d/` (next to the hooks the installer deployed, see
  install step 2). Override the default location with the
  `${ACLI_SYNC_CONFIG_DIR}` environment variable.
- **`acli-sync:
  acli binary ...
  failed its --version check`** — the hooks run `acli --version` on launch.
  If your acli build lacks that flag, set `acli_bin` to a wrapper that answers
  it.
- **Auth failures** — run `acli jira auth login` interactively first; acli
  stores credentials in its own config.
  `quiet=0` shows hook feedback on stderr, and the on-modify hook reports `Sync
  FAILED for KEY:
  ...` lines.
- **Tasks not appearing** — verify `filter`/`jql` match something (`acli jira
  workitem search --filter <id> --count`), that `max_results` is large enough,
  and that `paginate=1` for large snapshots.
- **Hooks not running** — confirm `hooks=1` in `~/.taskrc`, that the files in
  `~/.task/hooks/` are executable, and check `task diag`.
  Debug with `task rc.debug.hooks=2 list`.
- **Description keeps reverting** — Jira summaries are mirrored on launch (Jira
  is the source of truth).
  Set `sync_description_on_launch=0` to keep local edits.
- **No `jiraurl` set** — the URL is derived from `.self` in acli's JSON; if your
  acli output omits it, the UDA is simply left unset.

## Quirks & TODOs

- `sync_labels_on_modify=0` by default — label/tag sync is conservative.
- Jira **priority is not editable via acli** (`acli jira workitem edit` has no
  `--priority` flag), so there is no Taskwarrior -> Jira priority push.
  `priority_in_progress` only sets a local priority on newly mirrored
  in-progress tasks.
- The launch hook runs before **every** `task` command (including reports), so
  it adds a small acli round-trip to each invocation.
  Slow down your `filter`/`jql` rather than mirroring the whole instance.
- Deleted/waiting tasks with a `jirakey` are preserved as-is; re-adding a
  deliberately deleted mirror is a manual act.
- Internal `task` calls always run with `rc.hooks=off rc.color=no`, so the hooks
  never recurse and never emit color codes.
- Test with `bash tests/test-acli-sync.bash` (stubs `acli`, throws away
  `TASKDATA`).
