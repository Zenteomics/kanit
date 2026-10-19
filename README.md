# workz

workz runs a prepared graph of file-producing rules on one Linux workstation. It admits work by CPU, memory, named groups and shared inputs, reuses only work whose recorded identity still matches, enforces each task's memory request, and keeps a complete record of every attempt.

Version 0.1.0. Linux x86-64 with cgroup v2, a systemd user manager and bubblewrap. Zig 0.16.0 builds it.

## Build

```sh
zig build -Doptimize=ReleaseSafe
zig build test --summary all
```

The executable is `zig-out/bin/workz`. TOML is read with [z-toml](THIRD_PARTY.md), found through `build.zig.zon`.

## A workflow

```toml
[workflow]
name = "example"
version = "1"

[resource_groups.disk]
max = 2

[shared.reference]
path = "/data/reference/index"

[[rules]]
name = "align_s1"
input = ["reads/s1.fastq"]
output = ["aligned/s1.bam"]
shell = "aligner --index /data/reference/index reads/s1.fastq > aligned/s1.bam"
priority = 10
log = "logs/align_s1.log"
benchmark = "metrics/align_s1.json"
retries = 1
timeout = "2h"

[rules.resources]
threads = 4
memory = "8G"
groups = { disk = 1 }
shared = ["reference"]
```

Each rule names its input files, its output files, one shell command and a resource request. A rule runs after the rules that produce its inputs. Samples and parameters are expanded by whatever prepares the file; workz reads an explicit graph. Unknown keys are errors that name their line and the closest known key.

- `threads` and `memory` (`K`, `M`, `G` or `T`) are reserved while the rule runs and enforced through the task's cgroup: private memory above the request ends every process of the attempt as out of memory. Page cache from the files a task reads and writes is not reserved; the kernel reclaims it at the limit, which can slow large writes under a small request.
- `groups` limits how many rules of a kind run together; `resource_groups.NAME.max` is the capacity.
- `shared` names large read-only inputs. Before their first user starts, a holder maps each file once, and memory admission counts its size once however many rules use it.
- `retries` (0-3) and `timeout` (`90s`, `30m`, `2h`, `1h30m`) apply to each attempt.

## Commands

| Command        | Purpose                     |
| -------------- | --------------------------- |
| `validate`     | check the file and graph    |
| `plan`         | what would run or be reused |
| `explain RULE` | why a rule would run        |
| `graph`        | print DOT                   |
| `run`          | run the selected rules      |
| `watch`        | live view of a run          |
| `status`       | summary of the newest run   |
| `verify`       | check recorded outputs      |

- Select rules with `--target RULE` (repeatable); a target brings its dependencies.
- `run` options: `--jobs`, `--max-threads`, `--max-memory`, `--keep-going`, `--retry`, `--timeout`, `--rerun`, `--input-manifest FILE`, `--pass-env NAME`, `--grace SECONDS`, `--no-isolation`, `--quiet`.
- Exit status: 0 success, 1 a rule or check failed, 2 invalid command line or workflow, 130 interrupted.

`run` starts in a transient systemd user scope limited to the run's memory and CPU budget, inside a bubblewrap network namespace: rules have no network. Each attempt runs in its own process group and cgroup; a timeout, a failure elsewhere or an interrupt stops the whole group, and processes that left the group end with the cgroup. `--no-isolation` runs without the namespace and the cgroups.

Ready rules start in priority order, then by the time they became ready, then by file order; every rule that fits the free CPU, memory, group and job capacity starts, so a rule waiting for room never holds back a smaller one.

## Reuse

A rule is reused when its command, keyed environment (`PATH`, `LANG`, `LC_ALL`, `TZ` and names given with `--pass-env`), resource request, written paths, input identities, producing rules and engine key are unchanged, and each recorded output still has its recorded identity. The engine key is a version number raised only when a change to workz can change what a rule produces, so rebuilding or upgrading workz does not by itself rerun work; `launch.json` records the executable's digest. A file's identity is its device, inode, size, and modification and change times. A rewrite that restores the modification time still changes the change time, which programs cannot set back.

File contents are read only when asked: `--input-manifest` checks external inputs against `sha256:` digests (re-reading a file only when its identity changed), and `verify --content` hashes recorded outputs. An output changed outside workz stops the next run until `--rerun` runs the rule again; earlier bytes are kept.

## Records

Everything workz writes for itself lives in `.workz/` in the working directory:

```text
.workz/state.json                      resume state, format_version 1
.workz/launches/<time>-<id>/
  workflow  launch.json  events.jsonl  summary.json
  attempts/<rule>/<NNN>/
    command.sh  request.json  stdout.log  stderr.log  record.json  previous/
```

`events.jsonl` is an append-only stream of typed events. Each attempt keeps its complete standard output and error, its request, its exit status, `wait4` resource usage and the cgroup's peak memory, OOM events and CPU time. `record.json` is written last. Nothing is deleted: a rerun moves earlier outputs into the attempt's `previous/`.

`watch` reads these files from any terminal and shows each running task with its elapsed time, current and peak memory, and last line of output.

## License

Apache-2.0. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY.md).
