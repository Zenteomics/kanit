Every table and key workz reads in a workflow file, with its type, default and limits. The guide pages explain what each one is for; this page is for looking things up. workz reads workflow format 1.

## Example

<details>
<summary>A workflow that uses every table</summary>

```toml
[workflow]
name = "example"
version = "2026.10"
format_version = 1

[defaults]
threads = 1
memory = "1G"

[resource_groups.disk]
max = 2

[shared.index]
path = "ref/bowtie2"

[shared.genome]
path = "ref/star"
container = "quay.io/biocontainers/star:2.7.11b--h5ca1c30_8"
command = "STAR --genomeDir /data/project/ref/star --genomeLoad LoadAndExit --outFileNamePrefix /tmp/"
memory = "32G"
timeout = "30m"
retries = 1

[[rules]]
name = "align_s1"
step = "align"
sample = "s1"
category = "alignment"
tool = "bowtie2 2.5.4"
input = ["trimmed/s1_1.fq.gz", "trimmed/s1_2.fq.gz"]
output = ["aligned/s1.bam"]
shell = "bowtie2 --mm -p $WORKZ_THREADS -x ref/bowtie2/genome -1 trimmed/s1_1.fq.gz -2 trimmed/s1_2.fq.gz | samtools view -b -o aligned/s1.bam -"
priority = 10
retries = 1
timeout = "2h"
log = "logs/align_s1.log"
benchmark = "benchmarks/align_s1.json"
cutoff = false

[rules.resources]
threads = 8
memory = "2G"
groups = { disk = 1 }
shared = ["index"]

[[rules]]
name = "star_s1"
input = ["ref/star", "reads/s1_1.fq.gz", "reads/s1_2.fq.gz"]
output = ["star/s1/Aligned.out.bam"]
container = "quay.io/biocontainers/star:2.7.11b--h5ca1c30_8"
workdir = "star/s1"
links = { "r1.fq.gz" = "reads/s1_1.fq.gz", "r2.fq.gz" = "reads/s1_2.fq.gz" }
shell = "STAR --genomeDir /data/project/ref/star --genomeLoad LoadAndKeep --runThreadN $WORKZ_THREADS --readFilesCommand zcat --readFilesIn r1.fq.gz r2.fq.gz --outSAMtype BAM Unsorted"

[rules.resources]
threads = 8
memory = "4G"
shared = ["genome"]
```

</details>

## Conventions

- **Unknown keys are errors**, in every table. The message names the line and, when one is close, the key you probably meant.
- **Names** of rules and shared inputs have 1 to 161 characters: letters, digits, `_`, `.` and `-`, starting with a letter or digit.
- **Paths** name files or directories explicitly. They cannot be empty, contain control characters, `*`, `?`, `[`, `]`, `{` or `}`, contain `://`, or start with `gh:`. Relative paths resolve against the working directory.
- **Sizes** are strings: a whole number with an optional suffix `K`, `M`, `G` or `T`, in either case, in powers of 1024. A plain number is MiB, so `"512"` and `"512M"` are equal. `K` values below `1024K` are too small, and the size must be above 0.
- **Durations** are strings: a whole number of seconds, or numbers with the units `s`, `m`, `h` and `d`, such as `"90s"`, `"30m"`, `"2h"` or `"1h30m"`. They must be above 0.

## [workflow]

| Key              | Type    | Default  | Meaning                    |
| ---------------- | ------- | -------- | -------------------------- |
| `name`           | string  | required | names the workflow         |
| `version`        | string  | `""`     | your version label         |
| `description`    | any     | none     | for readers; workz ignores |
| `author`         | any     | none     | for readers; workz ignores |
| `format_version` | integer | 1        | must be 1 when given       |

## [defaults]

| Key       | Type    | Default | Meaning                        |
| --------- | ------- | ------- | ------------------------------ |
| `threads` | integer | 1       | threads of rules that set none |
| `memory`  | size    | none    | memory of rules that set none  |

## [resource_groups.NAME]

| Key   | Type    | Default  | Meaning                  |
| ----- | ------- | -------- | ------------------------ |
| `max` | integer | required | capacity, 1 to 1,000,000 |

A rule takes units with `groups = { NAME = count }` in its resources; a count must be between 1 and the group's `max`. See [Resource groups](Resources-and-Scheduling.md#resource-groups).

## [shared.NAME]

A shared entry without `container` is a file input, held in memory by a holder process:

| Key    | Type | Default  | Meaning                   |
| ------ | ---- | -------- | ------------------------- |
| `path` | path | required | file or directory to hold |

An entry with `container` is a service:

| Key         | Type     | Default  | Meaning                          |
| ----------- | -------- | -------- | -------------------------------- |
| `container` | image    | required | local image to run               |
| `command`   | string   | required | loads the index, then exits 0    |
| `memory`    | size     | required | memory the service holds         |
| `path`      | path     | none     | mounted read-only in the service |
| `timeout`   | duration | none     | time allowed to become ready     |
| `retries`   | integer  | 0        | restarts before ready, 0 to 3    |
| `mounts`    | table    | none     | host path = path in the image    |

- A file input is also an input of every rule that uses it. It may not hold the output of a rule; a service's `path` may, if every rule that joins it depends on that rule.
- `command`, `memory`, `timeout`, `retries` and `mounts` belong to services only.
- See [Shared inputs](Resources-and-Scheduling.md#shared-inputs) and [Shared services](Containers-and-Services.md#shared-services).

## [[rules]]

| Key           | Type     | Default                | Meaning                             |
| ------------- | -------- | ---------------------- | ----------------------------------- |
| `name`        | string   | required               | unique rule name                    |
| `input`       | paths    | `[]`                   | files and directories it reads      |
| `output`      | paths    | required               | files it writes, at least one       |
| `shell`       | string   | required               | the command line                    |
| `threads`     | integer  | `[defaults]`, else 1   | 1 to 4096                           |
| `memory`      | size     | `[defaults]`           | required from one of the two        |
| `priority`    | integer  | 0                      | higher starts first                 |
| `retries`     | integer  | `--retry`, else 0      | extra attempts, 0 to 3              |
| `timeout`     | duration | `--timeout`, else none | limit per attempt                   |
| `log`         | path     | none                   | copy of stdout and stderr           |
| `benchmark`   | path     | none                   | JSON summary of a completed attempt |
| `diagnostics` | paths    | `[]`                   | files kept when an attempt fails    |
| `cutoff`      | boolean  | `false`                | key consumers on output bytes       |
| `workdir`     | path     | none                   | directory the command starts in     |
| `links`       | table    | none                   | link name = input, in `workdir`     |
| `container`   | image    | none                   | run in this local image             |
| `mounts`      | table    | none                   | host path = path in the image       |
| `step`        | string   | from `name`            | pipeline step it is an instance of  |
| `sample`      | string   | from `name`            | data it works on                    |
| `category`    | string   | none                   | group of steps it belongs to        |
| `tool`        | string   | from `container`       | program it runs                     |
| `resources`   | table    | none                   | the request, below                  |

- `priority` is between -1,000,000 and 1,000,000.
- `output`, `log` and `benchmark` are relative paths inside the working directory, without `..` and outside `.workz/`. If an output already exists, it must be a regular file. `input` paths may lie anywhere.
- A rule may not read its own output, two rules may not write the same file, and no rule may read another rule's log or benchmark.
- `diagnostics` are relative paths inside the working directory, without `..` and outside `.workz/`. They are only read, after a failed attempt; they are not outputs, and not part of the rule key.
- An input that is a symlink to another rule's output is an error: declare the output's own path, so the dependency is visible.
- `workdir` is a directory below the working directory, made before each attempt. `links` needs a `workdir`, and each link points at one of the rule's inputs; link names are plain file names.
- `mounts` needs a `container`. Each source is also an input of the rule. Targets are absolute paths in the image other than `/`, without `..`, `:` or `,`.
- `step`, `sample`, `category` and `tool` are labels of 1 to 200 characters without control characters. They are not part of the rule key, so changing one reruns nothing. [Concepts](Concepts.md#steps-samples-categories-and-tools) defines them and says how undeclared ones are derived.

## [rules.resources]

Written as a table after the rule, or inline as `resources = { ... }`:

| Key       | Type    | Default        | Meaning                        |
| --------- | ------- | -------------- | ------------------------------ |
| `threads` | integer | rule, defaults | overrides the rule's `threads` |
| `memory`  | size    | rule, defaults | overrides the rule's `memory`  |
| `groups`  | table   | none           | group name = units             |
| `shared`  | names   | `[]`           | shared inputs it uses          |

- Every group and shared input named must be declared.
- Only container rules can use a service, and a rule can use one service.

## What validate checks, and what it does not

`workz validate` checks everything above and the graph: every key, every value, every name, unique outputs, and the absence of cycles. Some things are checked only when a launch starts, because they depend on the machine and the files, and only for the selected rules:

- An input that no rule produces must exist; otherwise `workz run` refuses with `missing input of rule NAME: PATH`, naming the directory input paths are relative to, and `workz plan` shows `input missing: PATH`.
- The path of every shared file input must exist and be readable; otherwise `workz run` refuses with `shared input NAME (PATH): ...`.
- Every container image must be available locally; otherwise `workz run` refuses with `container image NAME is not available locally; workz does not pull images`.
- Every rule's request must fit the budget of the launch; otherwise `workz run` refuses with `rule NAME requests N threads; the run allows M`, or `rule NAME needs N MiB; the run allows M MiB`, which names what N includes beside the request: shared inputs, and the Podman client of a container rule.
