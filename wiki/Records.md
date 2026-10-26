Everything workz writes for itself lives in `.workz/` in the working directory. This page describes every file there, for scripts that read the records and for anyone who wants to know where an answer comes from. The JSON files carry a format version, so a reader can check what it parses.

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
      shared/                       service scripts and their standard error
      attempts/
        align_S1/
          001/                      one directory per attempt
            command.sh              the command as run
            request.json            the request
            stdout.log  stderr.log  the command's output
            record.json             what the attempt used and how it ended
            previous/               earlier outputs, moved aside before it ran
```

A launch directory is named by its UTC start time to the millisecond and four random bytes in hex, so sorting the names sorts the launches by time. Every launch that takes the lock gets one, including launches refused before any rule runs.

## state.json

`state.json` is the memory of the working directory: workz reads it at the start of every launch to decide what to reuse, and rewrites it, atomically, as rules complete. It is one line of JSON with a `format_version` and these fields:

- `rules`: for each completed rule, its key and the seven parts it was made from, its outputs with their identities and digests (`path`, `id`, `sha256`), its attempt directory, finish time and wall time.
- `files`: the last recorded identity of every input and output path, which `explain` compares against.
- `manifest`: the digests of input-manifest files, with the identity each was hashed at.
- `envs`: the keyed environment of each recorded rule, for `explain` to name what changed.

workz 0.3.0 reads the state of earlier versions. Deleting `state.json` makes the next launch run every rule; nothing else depends on it.

## Launch files

### launch.json

Written when the launch starts: `engine` (version and the executable's SHA-256), `engine_key`, `launch`, `workflow` and `workflow_sha256`, `workdir`, `started`, the budget (`max_threads`, `max_memory_mib`, `jobs`), and the options `isolation`, `keep_going`, `rerun`, `retry`, `timeout_s`, `input_manifest`, `pass_env` and `slice`, and the number of `selected` rules.

### summary.json

Written when the launch ends, and printed by `workz run` as one line. From the demo launch (path shortened, nested objects on one line):

```json
{
  "engine": "workz 0.3.0 sha256:85d277095e9e014cb55b3a60c6cc8767e10bf763c3b78e9b78b8a68b2809fac8",
  "engine_key": 2,
  "launch": "20261026T033653.780-bb9b10ee",
  "status": "completed",
  "counts": { "completed": 25, "reused": 0, "failed": 0, "blocked": 0, "cancelled": 0, "not_started": 0 },
  "selected": 25,
  "elapsed_s": 48.578034531,
  "finished": "2026-10-26T03:37:42.358Z",
  "error": null,
  "engine_cost": { "cpu_s": 0.085095, "max_rss_mib": 6.28515625 },
  "launch_dir": ".../.workz/launches/20261026T033653.780-bb9b10ee"
}
```

- `status` is `completed`, `failed`, `interrupted` or `refused`.
- `error` holds the reason a launch was refused or stopped, or `null`.
- `engine_cost` is the CPU time and peak memory of the engine itself.
- A refused launch counts every selected rule as `not_started`.

## Attempt files

- `command.sh` is the script that ran: for a host rule, `set -euo pipefail` followed by the rule's `shell`.
- `request.json` holds `rule`, `attempt`, `shell`, `threads`, `memory_mib`, `groups`, `shared`, `input`, `output` and `timeout_s`.
- `stdout.log` and `stderr.log` are the command's output.
- `record.json` is written last, when the attempt ends.

`record.json` fields:

| Field                  | Meaning                                                    |
| ---------------------- | ---------------------------------------------------------- |
| `v`                    | record format, 1                                           |
| `rule`, `attempt`      | which attempt                                              |
| `status`, `reason`     | `completed`, `failed` or `cancelled`, and why              |
| `exit_code`, `signal`  | how the command ended                                      |
| `started`, `finished`  | UTC times                                                  |
| `wall_s`, `cpu_s`      | elapsed and CPU seconds                                    |
| `cpu_source`           | `cgroup` or `rusage`                                       |
| `rusage`               | `cpu_s` and `maxrss_kib` of the process tree               |
| `cgroup`               | the attempt's cgroup counters, or `null` without isolation |
| `request`              | `threads`, `memory_mib`, `groups`, `shared`, `container`   |
| `labels`               | `step`, `sample`, `category`, `tool`; `declared` for each  |
| `outputs`              | each output's `path`, `id` and `sha256`                    |
| `queue`                | `waited_s`, and seconds per wait reason                    |
| `key`                  | the rule key the attempt ran under                         |

The `cgroup` object holds `memory_peak`, `memory_current`, `oom`, `oom_kill` and `memory_max_events`, `cpu_usage_usec`, the `anon`, `file` and `file_mapped` memory, and the pressure totals in microseconds: `cpu_some_us`, `memory_some_us`, `memory_full_us`, `io_some_us` and `io_full_us`.

## Events

`events.jsonl` holds one JSON object per line, appended as things happen. Every event has `v` (1), `time` (UTC, to the millisecond) and `event`:

```json
{"v":1,"time":"2026-10-26T03:36:53.792Z","event":"task_waiting","rule":"trim_S3","reason":"group:disk"}
{"v":1,"time":"2026-10-26T03:36:56.801Z","event":"task_finished","rule":"trim_S2","attempt":1,"status":"completed","wall_s":3.007621927,"cpu_s":2.981506,"maxrss_kib":3840,"memory_peak":1712128}
```

Launch events:

- `launch_started`: `launch`, `selected`, `rules`, `max_threads`, `max_memory_mib`, `jobs`, `isolation`, `cgroup`, `shared`, `checks_s`.
- `launch_refused`: `reason`.
- `launch_finished`: `status`, `counts`, `elapsed_s`, `error`; a refused launch has no `counts`.
- `inputs_checked`: `manifest`, `files`, `files_read`, `bytes_read`, `seconds`, `ok`.
- `containers_checked`: `images`, `leftovers_removed`, `seconds`.
- `memory_protected`: `memory_low_mib`, `ok`.
- `sample`: `running`, `ready`, `threads_reserved`, `memory_reserved_mib`, `memory_current`, `cpu_cores_used`.
- `control`: `command`, `rule`, `result`.
- `cancel_requested`: `signal`.

Rule events:

- `task_waiting`: `rule`, `reason`.
- `task_started`: `rule`, `attempt`, `pid`, `cgroup`, `directory`, `threads`, `memory_mib`, `waited_s`.
- `task_finished`: `rule`, `attempt`, `status`, `wall_s`; then `cpu_s`, `maxrss_kib` and `memory_peak` for a completed attempt, or `reason`, `exit_code` and `signal` for a failed or cancelled one. A rule cancelled before its attempt started has only `rule`, a null `attempt`, `status` `cancelled` and `reason`.
- `task_retry`: `rule`, `next_attempt`.
- `task_failed`: `rule`, `attempt` (null when the rule failed before an attempt started) and `reason`.
- `task_blocked`, `task_reused`, `task_cancelling`: `rule`.
- `task_timeout`: `rule`, `attempt`.
- `output_preserved`: `rule`, `path`, `moved_to`.
- `output_changed`, `output_identity_refreshed`: `rule`, `path`.

Shared input events:

- `shared_loading`: `name`, `pid`, `cgroup`, and `path` and `bytes` for a file input, or `container` and `memory_mib` for a service.
- `shared_loaded`: `name`, `bytes`, `holder_file_bytes`.
- `shared_released`: `name`, `memory_peak`, `cpu_s`.
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
- `--keep N` also removes all but the newest N launch directories, except launches that hold the recorded attempt of a rule, which `state.json` points to.
- `--dry-run` lists what would go.
- It takes the run lock, so it never removes anything while a launch runs.

Removing `.workz/` entirely is safe when no launch runs; the next launch then runs every rule.
