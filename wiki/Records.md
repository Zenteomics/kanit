Everything kanit writes for itself lives in `.workz/` in the working directory, which only its owner can read: it holds every attempt's output and the values of the variables passed with `--pass-env`. This page describes every file there, for scripts that read the records and for anyone who wants to know where an answer comes from. The JSON files carry a format version, `v`: `state.json` its `format_version`, the others `v`, 1 in this version. kanit refuses a state of a newer format, and leaves out, naming it, a record or an event of a newer `v`; a record without `v` comes from before the field and reads as 1.

## Layout

```text
.workz/
  lock                              held by the running launch
  state.json                        resume state: the record of every completed rule
  state.log                         rules completed since state.json was written
  journal                           rules started and completed, for crash recovery
  latest                            a link to the newest launch directory
  launches/
    20261107T060905.136-0b96682a/   one directory per launch
      workflow                      the workflow file as it was read
      launch.json                   options and budget
      events.jsonl                  the event stream
      launch.log                    the run log as text, every row kanit run printed and its START rows
      control                       commands from kanit control
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

A launch directory is named by its UTC start time to the millisecond and four random bytes in hex, so sorting the names sorts the launches by time. Every launch that takes the lock gets one, including launches refused before any rule runs, and `latest` is replaced to point at it when it is made.

`launch.log` is the [run log](Running-Workflows.md#starting-a-launch) of the launch: the lines `kanit run` prints, with the `START` rows and the `INFO` rows of the five-minute heartbeat, whole and without color. Its times are local wall-clock times. Programs read `events.jsonl` instead; the text of `launch.log` is for people and may change between versions.

## state.json

`state.json` is the memory of the working directory: kanit reads it, with `state.log`, at the start of every launch to decide what to reuse, and rewrites it, atomically, when a launch ends. It is one line of JSON with a `format_version` and these fields:

- `rules`: for each completed rule, its key and the seven parts it was made from, its outputs with their identities and digests (`path`, `id`, `sha256`), its attempt directory, finish time and wall time.
- `files`: the last recorded identity of every input and output path, which `explain` compares against.
- `manifest`: the digests of input-manifest files, with the identity each was hashed at.
- `envs`: the keyed environment of each recorded rule, for `explain` to name what changed.

Paths inside the working directory are written relative to it, such as `"out/a.txt"` and `".workz/launches/..."`, so the records stay valid when the project moves ([Moving a project](Reuse-and-Resume.md#moving-a-project)); paths outside it stay absolute.

kanit reads the state files of earlier versions, formats 1 to 4, and saves them as format 4, which workz 0.4.0 and earlier refuse. Deleting `state.json` makes the next launch run every rule; nothing else depends on it.

## state.log

While a launch runs, kanit appends each completed rule to `state.log` instead of rewriting `state.json`, and syncs the file to disk at most once a second, before it marks the rules done in the journal. A launch therefore writes about a kilobyte per completed rule however large the state is. Every command that reads the state applies `state.log` on top of `state.json`.

The first line names the log's version, `v`, 1 in this version, and the `state.json` it extends, by its identity (`base`). Each later line holds one rule's record (`rule` and `entry`, as in `rules` above), one file identity (`file` and `id`) or one keyed environment (`env` and `text`), with paths written as in `state.json`. A last line cut short by a crash is ignored, and the next save writes over it.

When a launch ends, or when the log grows past twice the size of `state.json` and at least 1 MiB, kanit rewrites `state.json` with everything and removes the log. A log whose `base` names another `state.json`, such as one replaced by an earlier kanit, which does not read `state.log`, is ignored. Deleting `state.json` makes kanit ignore the log too.

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

Written when the launch ends, and printed by `kanit run` as one line. From the demo launch in [Reports](Reports.md) (path and digest shortened):

```json
{
  "v": 1,
  "engine": "kanit 0.8.0 sha256:...",
  "engine_key": 4,
  "launch": "20261107T060905.136-0b96682a",
  "status": "completed",
  "counts": {
    "completed": 25,
    "reused": 0,
    "failed": 0,
    "blocked": 0,
    "cancelled": 0,
    "not_started": 0,
    "running": 0,
    "waiting": 0,
    "pending": 0
  },
  "selected": 25,
  "elapsed_s": 73.10328057,
  "finished": "2026-11-07T06:10:18.239Z",
  "error": null,
  "engine_cost": {
    "cpu_s": 0.08044,
    "max_rss_mib": 6.51953125
  },
  "launch_dir": ".../.workz/launches/20261107T060905.136-0b96682a",
  "failures": [],
  "changed_outputs": [],
  "previous_bytes": 0
}
```

- `status` is `completed`, `failed`, `stopped` (rules were stopped with `kanit control stop` and none failed), `interrupted` or `refused`.
- `error` holds the reason a launch was refused or stopped, or `null`.
- `engine_cost` is the CPU time and peak memory of the engine itself.
- A refused launch counts every selected rule as `not_started`.
- `running`, `waiting` and `pending` count only while a launch runs, in `status` off a terminal. For a launch whose engine ended without a summary, `status` prints the same fields with `"status": "unfinished"`.
- In that running summary, `not_started` counts the rules waiting and pending, `finished`, `error` and `engine_cost` are `null`, and `failures` holds the failures so far.
- `failures` lists each rule that failed, was blocked or was cancelled: `rule`, `status`, `reason`, and `stderr`, the path of its last attempt's standard error, or `null` when no attempt started, and `diagnostics`, the paths of the copies its last attempt kept ([Writing workflows](Writing-Workflows.md#diagnostics)).
- `changed_outputs` lists, for a launch refused because recorded outputs changed outside kanit, each `path` and the `rule` that wrote it; `--rerun-rule` with those rules replaces them.
- `previous_bytes` counts the bytes of earlier outputs the launch moved into `previous/` and kept there, which stay until `kanit clean --previous` removes them. Outputs put back after an attempt that did not complete are not counted.

## Attempt files

- `command.sh` is the script that ran: for a host rule, `set -euo pipefail` followed by the rule's `shell`.
- `request.json` holds `v`, `rule`, `attempt`, `shell`, `threads`, `memory_mib`, `groups`, `shared`, `input`, `output` and `timeout_s`.
- `stdout.log` and `stderr.log` are the command's output.
- `record.json` is written last, when the attempt ends. An attempt that could not start, such as one whose workdir link would replace a file, gets one too, with `started` `null`.
- `previous/` holds the earlier outputs moved aside before the attempt ran. When the attempt does not complete, kanit moves them back to their paths, so the last result stays where its record says, and moves what the attempt left there into `failed/`.

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
| `rusage`               | `cpu_s`, `maxrss_kib` and `engine_maxrss_kib`              |
| `cgroup`               | the attempt's cgroup counters, or `null` without isolation |
| `request`              | `threads`, `memory_mib`, `groups`, `shared`, `container`   |
| `request.reserved_mib` | memory admission reserved, a Podman client included        |
| `labels`               | `step`, `sample`, `category`, `tool`; `declared` for each  |
| `outputs`              | each output's `path`, `id` and `sha256`                    |
| `diagnostics`          | the diagnostics files it kept, as the workflow names them  |
| `image`                | the image ID a container rule ran, else `null`             |
| `image_digests`        | that image's registry digests, else `null`                 |
| `version`              | the rule's version command, else `null`                    |
| `queue`                | `waited_s`, and `reasons`: each `reason` with its `seconds` |
| `key`                  | the rule key the attempt ran under                         |

`image_digests` lists the image's digests as `podman image inspect` gives them in `RepoDigests`, such as `quay.io/biocontainers/arriba@sha256:...`: a digest a registry serves, so the same image can be pulled by it. A locally built image lists its own `localhost/NAME@sha256:...`, which no registry serves, and an image may list none, or one for each registry it came from.

`rusage.engine_maxrss_kib` is the engine's own peak resident memory when the attempt started. A process started from the engine counts that much as its own peak, so a `maxrss_kib` no larger only says the command used at most that much; reports mark such a figure `<=`.

The `cgroup` object holds:

- `memory_peak`, `memory_current`, `oom`, `oom_kill`, `memory_max_events` and `cpu_usage_usec`;
- `file`, the page cache still charged when the attempt ended;
- `anon_peak`, the largest anonymous memory (heap and stacks) that the run samples, every 5 s, saw while the attempt ran, or `null` for an attempt shorter than one sample;
- the pressure totals in microseconds: `cpu_some_us`, `memory_some_us`, `memory_full_us`, `io_some_us` and `io_full_us`.

## Events

`events.jsonl` holds one JSON object per line, appended as things happen. Every event has `v` (1), `time` (UTC, to the millisecond) and `event`:

```json
{"v":1,"time":"2026-11-07T06:09:05.146Z","event":"memory_protected","memory_low_mib":600,"ok":true}
{"v":1,"time":"2026-11-07T06:09:15.196Z","event":"task_retry","rule":"trim_S4","next_attempt":2}
```

Launch events:

- `launch_started`: `launch`, `selected`, `rules`, `max_threads`, `max_memory_mib`, `jobs`, `isolation`, `cgroup`, `shared`, `checks_s`.
- `launch_refused`: `reason`.
- `launch_ending`: no fields. Every rule has ended, and the launch writes its records; `control` commands sent from here on are answered with `the launch is ending` and not applied.
- `launch_finished`: `status`, `counts`, `elapsed_s`, `error`; a refused launch counts every selected rule as `not_started`.
- `inputs_checked`: `manifest`, `files`, `files_read`, `bytes_read`, `seconds`, `ok`.
- `containers_checked`: `images`, `leftovers_removed`, `seconds`.
- `memory_protected`: `memory_low_mib`, `ok`.
- `sample`: `running`, `ready`, `threads_reserved`, `memory_reserved_mib` (with `shared_reserved_mib`, the part shared inputs hold), `memory_current`, `cpu_cores_used`.
- `control`: `command`, `rule`, `result`.
- `cancel_requested`: `signal`.
- `network_holder_ended`, `guard_ended`: `exit_code`, `signal`. The engine's child that holds the run's private network, or guards the tasks of a run without isolation, ended before the engine; the rules go on, but a killed engine would no longer end them.

Rule events:

- `task_waiting`: `rule`, `reason`, `threads`, `memory_mib`.
- `task_started`: `rule`, `attempt`, `pid`, `cgroup`, `directory`, `threads`, `memory_mib`, `waited_s`, `shared` (the shared inputs it holds).
- `task_finished`: `rule`, `attempt`, `status`, `wall_s`; then `cpu_s`, `maxrss_kib` and `memory_peak` for a completed attempt, or `reason`, `exit_code` and `signal` for a failed or cancelled one. A rule cancelled before its attempt started has only `rule`, a null `attempt`, `status` `cancelled` and `reason`.
- `task_retry`: `rule`, `next_attempt`.
- `task_failed`: `rule`, `attempt` and `reason`, for a rule that failed outside a `task_finished`: before an attempt started (`attempt` null, such as a missing input), while its attempt was set up, or after its attempt completed when its inputs changed during the run. A command that fails is reported by `task_finished` alone.
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

Launch directories accumulate; each holds the output of every attempt. `kanit clean` removes what the working directory does not need:

```sh
kanit clean --keep 1 --dry-run
```

```text
would remove launch 20261107T060905.136-0b96682a
would remove 0 containers and 1 launch, 0.2 MiB
```

- Without options, `kanit clean` removes only the containers earlier launches left behind.
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

`kanit report --methods` turns these records into a description of what produced the results ([Reports](Reports.md#methods)); give each rule a `tool` label and a `version` command so it can name them. `kanit report --format json` lists every attempt's measures in one file.
