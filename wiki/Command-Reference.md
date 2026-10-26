Every `workz` command and option. `workz help` prints a summary of the same, and `workz completion bash` completes commands, most options and rule names in bash.

```text
workz <command> [options]
```

## Common options

| Option              | Argument | Meaning                                          |
| ------------------- | -------- | ------------------------------------------------ |
| `-d`, `--workdir`   | DIR      | working directory, instead of the workflow's     |
| `-t`, `--target`    | RULE     | select RULE and its dependencies; repeatable     |

The working directory is the directory of the workflow file, or `-d DIR`. Commands that only read records (`watch`, `status`, `logs`, `report`, `control`, `clean`) take the workflow path only to find that directory, and work without it from inside the working directory. `--target` applies to the commands that read the workflow.

## validate

```text
workz validate WORKFLOW
```

Checks the file, every key and value, and the graph ([what it checks](Workflow-Reference.md#what-validate-checks-and-what-it-does-not)). Prints `valid: NAME (R rules, S selected, G groups, H shared)`.

## plan

```text
workz plan WORKFLOW [--summary] [--rerun] [--rerun-rule RULE] [--pass-env NAME]
```

Prints, for every selected rule, whether a run would run it or reuse it, and why ([reasons](Reuse-and-Resume.md#plan-explain-run)), then `R to run, U to reuse`. `dry-run` is another name for `plan`.

| Option         | Argument | Meaning                                         |
| -------------- | -------- | ----------------------------------------------- |
| `--summary`    |          | count the decisions by reason instead           |
| `--rerun`      |          | as `run --rerun` would                          |
| `--rerun-rule` | RULE     | as `run --rerun-rule` would; repeatable         |
| `--pass-env`   | NAME     | as `run --pass-env` would; repeatable           |

## explain

```text
workz explain WORKFLOW RULE [--rerun] [--rerun-rule RULE] [--pass-env NAME]
```

Shows one rule's decision. For a rule that has a record and whose producers do not run, it also shows each part of its key against the record: `command`, `environment`, `request`, `writes`, `inputs`, `producers` and `engine key`, each `same` or `changed`, then what changed: the environment variables, the request, the inputs with their old and new identities, or the producers that run. It takes the same options as `plan`, except `--summary`.

## graph

```text
workz graph WORKFLOW
```

Prints the selected rules and their dependencies in Graphviz DOT form, one box per rule and one edge per dependency, for Graphviz or any other DOT viewer to draw.

## run

```text
workz run WORKFLOW [options]
```

Runs the selected rules that are not reusable. Progress goes to standard error; the summary goes to standard output as one line of JSON ([Running workflows](Running-Workflows.md)).

| Option             | Argument  | Default            | Meaning                                       |
| ------------------ | --------- | ------------------ | --------------------------------------------- |
| `--max-threads`    | N         | online CPUs        | thread budget                                 |
| `--max-memory`     | SIZE      | 3/4 of the memory  | memory budget, such as `60G`                  |
| `-j`, `--jobs`     | N         | `--max-threads`    | most tasks at once                            |
| `-k`, `--keep-going` |         | off                | run independent rules after a failure         |
| `-r`, `--retry`    | N         | 0                  | retries of rules that set none, 0 to 3        |
| `--timeout`        | DURATION  | none               | limit of rules that set none, such as `2h`    |
| `--rerun`          |           | off                | run every selected rule                       |
| `--rerun-rule`     | RULE      |                    | run RULE even if reusable; repeatable         |
| `--input-manifest` | FILE      |                    | check external inputs against digests         |
| `--pass-env`       | NAME      |                    | pass and key a variable; repeatable           |
| `--grace`          | SECONDS   | 10                 | wait before killing a stopped task            |
| `--slice`          | NAME      |                    | put the run's scope in the slice `NAME.slice` |
| `--no-isolation`   |           | off                | no scope, cgroups or network namespace        |
| `-q`, `--quiet`    |           | off                | no progress lines; failures still print       |

- Sizes take `K`, `M`, `G` or `T`; a plain number is MiB. Durations take `s`, `m`, `h` and `d`.
- `--slice` takes the full unit name, ending in `.slice`.
- The [input manifest](Reuse-and-Resume.md#input-manifests) is a JSON object of absolute paths to `"sha256:<hex>"` digests, or to a digest with a stamp.

## watch

```text
workz watch [WORKFLOW] [--once] [--interval MS]
```

Shows the newest launch. On a terminal it is interactive ([keys](Watching-a-Launch.md#keys)); otherwise, or with `--once`, it prints a plain view.

| Option       | Argument | Default | Meaning                          |
| ------------ | -------- | ------- | -------------------------------- |
| `--once`     |          | off     | print one plain view and exit    |
| `--interval` | MS       | 1000    | refresh period, at least 100     |

## status

```text
workz status [WORKFLOW] [--history [N]]
```

Prints the newest launch's `summary.json`, or its plain view while it runs. `--history [N]` prints one line for each of the last N launches instead (default 10).

## logs

```text
workz logs [WORKFLOW] RULE [options]
```

Prints the standard output and error of the rule's newest attempt.

| Option             | Argument | Meaning                                         |
| ------------------ | -------- | ----------------------------------------------- |
| `--stdout`         |          | standard output only                            |
| `--stderr`         |          | standard error only                             |
| `--launch`         | ID       | look in this launch                             |
| `--attempt`        | N        | this attempt instead of the newest              |
| `-f`, `--follow`   |          | keep printing until the attempt ends            |

## control

```text
workz control [WORKFLOW] stop RULE
workz control [WORKFLOW] retry RULE
workz control [WORKFLOW] cancel
```

Sends a command to the running launch ([Steering a running launch](Running-Workflows.md#steering-a-running-launch)). It fails if the newest launch has ended.

## report

```text
workz report [WORKFLOW] [options]
```

Reports on the newest launch, or on `--launch ID` ([Reports](Reports.md)).

| Option          | Argument          | Default | Meaning                                       |
| --------------- | ----------------- | ------- | --------------------------------------------- |
| `--launch`      | ID                | newest  | the launch to report on                       |
| `--format`      | `tsv`, `json`, `html` | `tsv` | attempt table, or a self-contained page     |
| `--bottlenecks` |                   |         | what limited the launch                       |
| `--suggest`     |                   |         | suggested threads and memory per kind         |
| `--compare`     | OTHER             |         | compare with a launch ID or directory         |

`--suggest`, `--compare` and `--bottlenecks` each print one report; given together, the first in that order wins. `--suggest` accepts `--format json`.

## verify

```text
workz verify WORKFLOW [--content]
```

Checks that every recorded output of the selected rules still has its recorded identity. `--content` also compares each output's bytes with its stored digest, and stores a digest for every output that has none. Prints `missing`, `changed` or `content` lines for differences and a final count.

## clean

```text
workz clean [WORKFLOW] [--keep N] [--dry-run]
```

Removes containers that earlier launches left behind. `--keep N` also removes all but the newest N launch directories, keeping every launch that holds a rule's recorded attempt. `--dry-run` names the launches it would remove and counts the containers. While a launch runs, `clean` refuses with `a run holds .../.workz/lock; clean after it ends`.

## init

```text
workz init [FILE]
```

Writes a commented starter workflow to `FILE` (default `workflow.toml`) and never overwrites an existing file.

## completion

```text
workz completion bash
```

Prints a bash completion script: `source <(workz completion bash)`. It completes the commands, the options of each command, the `control` commands, and rule names after `--target` and `--rerun-rule` and for `explain`, `logs` and `control`.

## version and help

`workz version` (or `--version`) prints `workz 0.3.0`. `workz help` (or `--help`, `-h`) prints the command summary.

## Exit statuses

- `0`: success. For `run`, no rule failed, was blocked or was left unstarted; a rule stopped with `workz control stop` that nothing depends on counts as `cancelled` and still allows 0. `status --history` exits 0 even when there are no launches.
- `1`: `run` had a failed or blocked rule, or was refused by changed outputs, an input manifest mismatch or another running launch; `verify` found a difference; `watch` or `status` found no launch.
- `2`: an invalid command line or workflow, or another error, such as a launch refused before it started, a rule name that does not exist, or a `report`, `logs` or `control` with no launch to read.
- `130`: `run` was interrupted, or cancelled with `workz control cancel`.
