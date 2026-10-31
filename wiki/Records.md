Everything workz writes for itself lives in `.workz/` in the working directory, which only its owner can read: it holds every attempt's output and the values of the variables passed with `--pass-env`. This page describes every file there, for scripts that read the records and for anyone who wants to know where an answer comes from. The JSON files carry a format version, `v`: `state.json` its `format_version`, the others `v`, 1 in this version. workz refuses a state of a newer format, and leaves out, naming it, a record or an event of a newer `v`; a record without `v` comes from before the field and reads as 1.

## Layout

```text
.workz/
  lock                              held by the running launch
  state.json                        resume state: the record of every completed rule
  journal                           rules started and completed, for crash recovery
  launches/
    20261026T033653.780-bb9b10ee/   one directory per launch
      workflow                      the workflow file as it was read
      launch.json                   options and budget
      events.jsonl                  the event stream
      control                       commands from workz control
      summary.json                  the result, written at the end
      report.html                   the launch as one page, drawn again while it runs
      versions.json                 the output of each tool's version command
      versions/                     each version command's full output
      shared/                       service scripts and their standard error
      attempts/
        align_S1/
          001/                      one directory per attempt
            command.sh              the command as run
            request.json            the request
            stdout.log  stderr.log  the command's output
            record.json             what the attempt used and how it ended
            previous/               earlier outputs, moved aside before it ran
            failed/                 what an attempt that did not complete left at its output paths
            diagnostics/            tails of the rule's diagnostics files, kept when it failed
```

A launch directory is named by its UTC start time to the millisecond and four random bytes in hex, so sorting the names sorts the launches by time. Every launch that takes the lock gets one, including launches refused before any rule runs.

## state.json

`state.json` is the memory of the working directory: workz reads it at the start of every launch to decide what to reuse, and rewrites it, atomically, as rules complete. It is one line of JSON with a `format_version` and these fields:

- `rules`: for each completed rule, its key and the seven parts it was made from, its outputs with their identities and digests (`path`, `id`, `sha256`), its attempt directory, finish time and wall time.
- `files`: the last recorded identity of every input and output path, which `explain` compares against.
- `manifest`: the digests of input-manifest files, with the identity each was hashed at.
- `envs`: the keyed environment of each recorded rule, for `explain` to name what changed.

Paths inside the working directory are written relative to it, such as `"out/a.txt"` and `".workz/launches/..."`, so the records stay valid when the project moves ([Moving a project](Reuse-and-Resume.md#moving-a-project)); paths outside it stay absolute.

workz reads the state files of earlier versions, formats 1 to 4, and saves them as format 4, which workz 0.4.0 and earlier refuse. Deleting `state.json` makes the next launch run every rule; nothing else depends on it.

## Launch files

### launch.json

Written when the launch starts:

- `v`, `engine` (the version and the executable's SHA-256), `engine_key` and `launch`;
- `workflow` and `workflow_sha256`, and `workflow_name` and `workflow_version` from its `[workflow]` table;
- `workdir` and `started`;
- the budget: `max_threads`, `max_memory_mib` and `jobs`;
- the options: `isolation`, `keep_going`, `rerun`, `retry`, `timeout_s`, `input_manifest`, `pass_env`, `thread_overrides` (each `--threads STEP=N` as given) and `slice`;
- `selected`, the number of selected rules.

### versions.json

Written when the launch ends, if a rule that ran names a `version` command ([Writing workflows](Writing-Workflows.md#tool-versions)): `v` and `commands`, one entry for each image and command, with `command`, `container` (the image reference, or `null` on the host), `image` (its ID), `status` (`completed`, `failed`, `stopped` when the launch ended first, or `not run`), `exit_code` and `output`, the first 4 KiB of what it printed. `versions/` keeps each command's whole output.

### summary.json

Written when the launch ends, and printed by `workz run` as one line. From the demo launch in [Reports](Reports.md) (path and digest shortened, nested objects on one line):

```json
{
  "v": 1,
  "engine": "workz 0.5.0 sha256:...",
  "engine_key": 4,
  "launch": "20261027T224512.478-40c9943e",
  "status": "completed",
  "counts": { "completed": 25, "reused": 0, "failed": 0, "blocked": 0, "cancelled": 0, "not_started": 0, "running": 0, "waiting": 0, "pending": 0 },
  "selected": 25,
  "elapsed_s": 48.368567907,
  "finished": "2026-10-27T22:46:00.846Z",
  "error": null,
  "engine_cost": { "cpu_s": 0.111436, "max_rss_mib": 6.5546875 },
  "launch_dir": ".../.workz/launches/20261027T224512.478-40c9943e",
  "failures": [],
  "changed_outputs": [],
  "previous_bytes": 0
}
```

- `status` is `completed`, `failed`, `stopped` (rules were stopped with `workz control stop` and none failed), `interrupted` or `refused`.
- `error` holds the reason a launch was refused or stopped, or `null`.
- `engine_cost` is the CPU time and peak memory of the engine itself.
- A refused launch counts every selected rule as `not_started`.
- `running`, `waiting` and `pending` count only while a launch runs, in `status` off a terminal. For a launch whose engine ended without a summary, `status` prints the same fields with `"status": "unfinished"`.
- In that running summary, `not_started` counts the rules waiting and pending, `finished`, `error` and `engine_cost` are `null`, and `failures` holds the failures so far.
- `failures` lists each rule that failed, was blocked or was cancelled: `rule`, `status`, `reason`, and `stderr`, the path of its last attempt's standard error, or `null` when no attempt started, and `diagnostics`, the paths of the copies its last attempt kept ([Writing workflows](Writing-Workflows.md#diagnostics)).
- `changed_outputs` lists, for a launch refused because recorded outputs changed outside workz, each `path` and the `rule` that wrote it; `--rerun-rule` with those rules replaces them.
- `previous_bytes` counts the bytes of earlier outputs the launch moved into `previous/` and kept there, which stay until `workz clean --previous` removes them. Outputs put back after an attempt that did not complete are not counted.

## Attempt files

- `command.sh` is the script that ran: for a host rule, `set -euo pipefail` followed by the rule's `shell`.
- `request.json` holds `v`, `rule`, `attempt`, `shell`, `threads`, `memory_mib`, `groups`, `shared`, `input`, `output` and `timeout_s`.
- `stdout.log` and `stderr.log` are the command's output.
- `record.json` is written last, when the attempt ends. An attempt that could not start, such as one whose workdir link would replace a file, gets one too, with `started` `null`.
- `previous/` holds the earlier outputs moved aside before the attempt ran. When the attempt does not complete, workz moves them back to their paths, so the last result stays where its record says, and moves what the attempt left there into `failed/`.

`record.json` fields:

| Field                  | Meaning                                                    |
| ---------------------- | ---------------------------------------------------------- |
| `v`                    | record format, 1                                           |
| `rule`, `attempt`      | which attempt                                              |
| `status`, `reason`     | `completed`, `failed` or `cancelled`, and why              |
| `exit_code`, `signal`  | how the command ended                                      |
| `started`, `finished`  | UTC times; `started` is `null` if it never started         |
| `wall_s`, `cpu_s`      | elapsed and CPU seconds                                    |
| `cpu_source`           | `cgroup` or `rusage`                                       |
| `rusage`               | `cpu_s` and `maxrss_kib` of the process tree               |
| `cgroup`               | the attempt's cgroup counters, or `null` without isolation |
| `request`              | `threads`, `memory_mib`, `groups`, `shared`, `container`   |
| `request.reserved_mib` | memory admission reserved, a Podman client included        |
| `labels`               | `step`, `sample`, `category`, `tool`; `declared` for each  |
| `outputs`              | each output's `path`, `id` and `sha256`                    |
| `diagnostics`          | the diagnostics files it kept, as the workflow names them  |
| `image`                | the image ID a container rule ran, else `null`             |
| `version`              | the rule's version command, else `null`                    |
| `queue`                | `waited_s`, and `reasons`: each `reason` with its `seconds` |
| `key`                  | the rule key the attempt ran under                         |

The `cgroup` object holds:

- `memory_peak`, `memory_current`, `oom`, `oom_kill`, `memory_max_events` and `cpu_usage_usec`;
- `file`, the page cache still charged when the attempt ended;
- `anon_peak`, the largest anonymous memory (heap and stacks) that the run samples, every 5 s, saw while the attempt ran, or `null` for an attempt shorter than one sample;
- the pressure totals in microseconds: `cpu_some_us`, `memory_some_us`, `memory_full_us`, `io_some_us` and `io_full_us`.

## Events

`events.jsonl` holds one JSON object per line, appended as things happen. Every event has `v` (1), `time` (UTC, to the millisecond) and `event`:

```json
{"v":1,"time":"2026-10-26T03:36:53.792Z","event":"task_waiting","rule":"trim_S3","reason":"group:disk"}
{"v":1,"time":"2026-10-26T03:36:56.801Z","event":"task_finished","rule":"trim_S2","attempt":1,"status":"completed","wall_s":3.007621927,"cpu_s":2.981506,"maxrss_kib":3840,"memory_peak":1712128}
```

Launch events:

- `launch_started`: `launch`, `selected`, `rules`, `max_threads`, `max_memory_mib`, `jobs`, `isolation`, `cgroup`, `shared`, `checks_s`.
- `launch_refused`: `reason`.
- `launch_finished`: `status`, `counts`, `elapsed_s`, `error`; a refused launch counts every selected rule as `not_started`.
- `inputs_checked`: `manifest`, `files`, `files_read`, `bytes_read`, `seconds`, `ok`.
- `containers_checked`: `images`, `leftovers_removed`, `seconds`.
- `memory_protected`: `memory_low_mib`, `ok`.
- `sample`: `running`, `ready`, `threads_reserved`, `memory_reserved_mib` (with `shared_reserved_mib`, the part shared inputs hold), `memory_current`, `cpu_cores_used`.
- `control`: `command`, `rule`, `result`.
- `cancel_requested`: `signal`.

Rule events:

- `task_waiting`: `rule`, `reason`.
- `task_started`: `rule`, `attempt`, `pid`, `cgroup`, `directory`, `threads`, `memory_mib`, `waited_s`, `shared` (the shared inputs it holds).
- `task_finished`: `rule`, `attempt`, `status`, `wall_s`; then `cpu_s`, `maxrss_kib` and `memory_peak` for a completed attempt, or `reason`, `exit_code` and `signal` for a failed or cancelled one. A rule cancelled before its attempt started has only `rule`, a null `attempt`, `status` `cancelled` and `reason`.
- `task_retry`: `rule`, `next_attempt`.
- `task_failed`: `rule`, `attempt` (null when the rule failed before an attempt started) and `reason`.
- `task_blocked`, `task_reused`, `task_cancelling`: `rule`.
- `task_timeout`: `rule`, `attempt`.
- `output_preserved`: `rule`, `path`, `moved_to`, `bytes`.
- `output_restored`: `rule`, `path`, `moved_from`, `bytes`, for an earlier output put back after an attempt that did not complete.
- `output_failed`: `rule`, `path`, `moved_to`, `bytes`, for what an attempt that did not complete left at an output path, moved into its `failed/`.
- `output_changed`, `output_identity_refreshed`: `rule`, `path`.

Shared input events:

- `shared_loading`: `name`, `pid`, `cgroup`, and `path` and `bytes` for a file input, or `container`, `memory_mib` and `reserved_mib`, with its Podman client, for a service.
- `shared_loaded`: `name`, `bytes`, `holder_file_bytes`.
- `shared_released`: `name`, `memory_peak`, `cpu_s`, `users` (attempts that started using it while it was held) and `held_s`.
- `shared_retry`: `name`, `reason`, `next_start`.
- `shared_failed`: `name`, `reason`, `memory_peak`.
- `shared_timeout`: `name`.

- A `task_waiting` event is written only when a rule's wait reason changes.
- `sample` events are written about every 5 s while rules or shared inputs run; `memory_current` and `cpu_cores_used` are the run cgroup's, `null` without isolation.
- Readers should ignore events and fields they do not know.

## Cleaning up

Launch directories accumulate; each holds the output of every attempt. `workz clean` removes what the working directory does not need:

```sh
workz clean --keep 1 --dry-run
```

```text
would remove launch 20261026T034055.329-130819e8
would remove 0 container(s) and 1 launch(es), 0.0 MiB; kept 1 older launch(es) that hold recorded attempts
```

- Without options, `workz clean` removes only the containers earlier launches left behind.
- `--keep N` also removes all but the newest N launch directories, except launches that hold the recorded attempt of a rule, which `state.json` points to, and a launch whose engine was killed during an attempt: its `previous/` holds the only copy of that rule's earlier outputs until the next launch puts them back.
- `--previous` removes the `previous/` directory of every attempt in every launch: the earlier outputs that reruns replaced, which are often the largest files in `.workz/`. They are the only copy of those bytes; the rest of each launch stays. The `previous/` of an attempt a killed launch left unfinished stays too, for the next launch to put back.
- A launch directory is the only record of its launch: the workflow it ran, every attempt's output and measures, the replaced bytes in `previous/` and its `report.html`. Removing it removes them; copy what you want to keep first.
- `--dry-run` lists what would go.
- It takes the working directory's lock, so it never removes anything while a launch runs.

Removing `.workz/` entirely is safe when no launch runs; the next launch then runs every rule.

## Recording a run

To cite a run, in a lab notebook or a methods section, note its launch ID and keep its launch directory, or these files of it:

- `workflow`, the workflow file exactly as it ran.
- `launch.json`, the engine with the digest of its executable, the workflow file's digest, the budget and the options.
- `summary.json`, the outcome and the counts.
- `report.html`, the launch as one page.
- `attempts/RULE/NNN/`, each attempt's command, request, record, standard output and standard error.

`workz report --methods` turns these records into a description of what produced the results ([Reports](Reports.md#methods)); give each rule a `tool` label and a `version` command so it can name them. `workz report --format json` lists every attempt's measures in one file.

