Every `workz` command and option. `workz help COMMAND` shows the same for one command, and `workz completion bash` completes commands, options and rule names in bash.

```text
workz <command> [options]
```

## Common options

| Option              | Argument | Meaning                                          |
| ------------------- | -------- | ------------------------------------------------ |
| `-d`, `--workdir`   | DIR      | working directory, instead of the workflow's     |
| `-t`, `--target`    | RULE     | select RULE and its dependencies; repeatable     |

WORKFLOW defaults to `workflow.toml` in the current directory, the file `workz init` writes. The working directory is the directory of the workflow file, or `-d DIR`. Commands that only read records (`watch`, `status`, `logs`, `report`, `control`, `clean`) take the workflow path only to find that directory, and work without it from inside the working directory. `--target` applies to the commands that read the workflow.

## validate

```text
workz validate [WORKFLOW] [--inputs]
```

Checks the file, every key and value, and the graph ([what it checks](Workflow-Reference.md#what-validate-checks-and-what-it-does-not)). It reports every problem it finds, up to 50 and a count of the rest, each with its line where it has one ([Troubleshooting](Troubleshooting.md#workflow-errors)). Prints `valid: NAME (R rules, S selected, G groups, H shared)`, then a `note:` line for a shared input or resource group no selected rule uses, and for a rule without `sample` among rules of its step that have one, which the per-sample views leave out. Notes do not change the exit status. `--inputs` also lists every input that does not exist and that no rule writes, as `run` would refuse it, and exits 1 if there is one.

## plan

```text
workz plan [WORKFLOW] [--summary] [--budget] [--rerun] [--rerun-rule RULE] [--pass-env NAME] [--threads STEP=N]
```

Prints, for every selected rule, whether a run would run it or reuse it, and why ([reasons](Reuse-and-Resume.md#plan-explain-run)), then `R to run, U to reuse`. `dry-run` is another name for `plan`.

| Option          | Argument | Meaning                                         |
| --------------- | -------- | ----------------------------------------------- |
| `--summary`     |          | count the decisions by reason instead           |
| `--budget`      |          | check every request against the budget          |
| `--max-threads` | N        | the thread budget `--budget` checks             |
| `--max-memory`  | SIZE     | the memory budget `--budget` checks             |
| `--rerun`       |          | as `run --rerun` would                          |
| `--rerun-rule`  | RULE     | as `run --rerun-rule` would; repeatable         |
| `--pass-env`    | NAME     | as `run --pass-env` would; repeatable           |
| `--threads`     | STEP=N   | as `run --threads` would; repeatable            |

`--budget` then checks each selected rule's threads, and its memory with its shared inputs, each counted once, and a container rule's Podman client, against the budget a launch with the same `--max-threads` and `--max-memory` would have: it names each rule that does not fit and the largest need, and exits 1 when `run` would refuse the launch.

## explain

```text
workz explain [WORKFLOW] RULE [--rerun] [--rerun-rule RULE] [--pass-env NAME] [--threads STEP=N]
```

Shows one rule's decision. For a rule that has a record and whose producers do not run, it also shows each part of its key against the record: `command`, `environment`, `request`, `writes`, `inputs`, `producers` and `engine key`, each `same` or `changed`, then what changed: the environment variables, the request, the inputs with their old and new identities, or the producers that run. It takes the same options as `plan`, except `--summary`.

## graph

```text
workz graph [WORKFLOW] [options]
```

Shows the selected rules and what links them, in layers: as text on a terminal, Graphviz DOT when the output goes to a file or a pipe, or JSON ([Writing workflows](Writing-Workflows.md#seeing-the-graph)).

| Option     | Argument | Default | Meaning                                         |
| ---------- | -------- | ------- | ----------------------------------------------- |
| `--layer`  | LAYER    | `rules` | `rules`, `files`, `resources` or `all`          |
| `--by`     | `step`   |         | one node per step instead of per rule           |
| `--focus`  | EXPR     |         | a rule with its upstream or downstream rules    |
| `--why`    | FROM:TO  |         | one path of rules from FROM to TO               |
| `--users`  | NAME     |         | a shared input, its writers and its users       |
| `--format` | FORMAT   | text    | `text`, `dot` or `json`; `dot` off a terminal   |

- `rules` links each rule to the rules that read its outputs, naming the file; `files` puts the files between them, with each written file inside a directory input linked to it; `resources` adds each shared input, the rules that write what a service loads (`loads`) and the rules that map or join it, and each resource group with the units its rules take; `all` is `files` and `resources`.
- `--focus +RULE` keeps RULE and every rule it depends on, `RULE+` the rules depending on it, `+RULE+` both, and a number limits the levels: `2+RULE`, `RULE+1`.
- Give at most one of `--focus`, `--why` and `--users`. `--why` exits 1 when no path leads from FROM to TO.
- JSON follows the Cytoscape elements shape: `{"elements": {"nodes": [{"data": ...}], "edges": [{"data": ...}]}}`, each node with `id`, `kind` (`rule`, `step`, `file`, `shared`, `group`) and `label`, each edge with `source`, `target` and `kind` (`input`, `produces`, `consumes`, `within`, `maps`, `joins`, `loads`, `takes`).

## run

```text
workz run [WORKFLOW] [options]
```

Runs the selected rules that are not reusable. Progress goes to standard error and the summary to standard output: a short report on a terminal, one line of JSON otherwise ([Running workflows](Running-Workflows.md)).

| Option               | Argument | Default           | Meaning                                       |
| -------------------- | -------- | ----------------- | --------------------------------------------- |
| `--max-threads`      | N        | online CPUs       | thread budget                                 |
| `--max-memory`       | SIZE     | 3/4 of the memory | memory budget, such as `60G`                  |
| `-j`, `--jobs`       | N        | `--max-threads`   | most rules running at once                    |
| `-k`, `--keep-going` |          | off               | run independent rules after a failure         |
| `-r`, `--retry`      | N        | 0                 | retries of rules that set none, 0 to 3        |
| `--timeout`          | DURATION | none              | limit of rules that set none, such as `2h`    |
| `--rerun`            |          | off               | run every selected rule                       |
| `--rerun-rule`       | RULE     |                   | run RULE even if reusable; repeatable         |
| `--input-manifest`   | FILE     |                   | check external inputs against digests         |
| `--pass-env`         | NAME     |                   | pass and key a variable; repeatable           |
| `--threads`          | STEP=N   |                   | N threads for STEP's rules; repeatable        |
| `--grace`            | DURATION | 10s               | wait before killing a stopped rule            |
| `--slice`            | NAME     |                   | put the run's scope in the slice `NAME.slice` |
| `--no-isolation`     |          | off               | no scope, cgroups or network namespace        |
| `-q`, `--quiet`      |          | off               | no progress lines; failures still print       |
| `--json`             |          | off               | JSON summary, also on a terminal              |
| `--no-color`         |          | off               | no colors on a terminal                       |

- Sizes take `K`, `M`, `G` or `T`; a plain number is MiB. Durations take `s`, `m`, `h` and `d`; a plain number is seconds, and `--grace 0` kills at once.
- `--slice` takes the full unit name, ending in `.slice`.
- `--threads STEP=N` gives every rule of step STEP a request of N threads in this launch, for trying another thread count without editing the workflow. The request is part of each rule's key, so those rules run again with it, and again with the workflow's request in a launch without it ([Resources and scheduling](Resources-and-Scheduling.md#trying-another-thread-count)).
- The [input manifest](Reuse-and-Resume.md#input-manifests) is a JSON object of absolute paths to `"sha256:<hex>"` digests, or to a digest with a stamp.

## watch

```text
workz watch [WORKFLOW] [--once] [--interval MS] [--launch ID] [--no-color]
```

Shows the newest launch, or `--launch ID`. On a terminal it is interactive ([keys](Watching-a-Launch.md#keys)); otherwise it prints a plain view every interval until the launch ends, and with `--once` it prints one.

| Option       | Argument | Default | Meaning                          |
| ------------ | -------- | ------- | -------------------------------- |
| `--once`     |          | off     | print one plain view and exit    |
| `--interval` | MS       | 1000    | refresh period, at least 100     |
| `--launch`   | ID       | newest  | the launch to show               |
| `--no-color` |          | off     | no colors on a terminal          |

## status

```text
workz status [WORKFLOW] [--history [N]] [--json] [--launch ID] [--no-color]
```

Prints the summary of the newest launch, or `--launch ID`, once it has ended: on a terminal a short report of its outcome, failures and next steps, otherwise its `summary.json`. While the launch runs, it prints its plain view on a terminal, and otherwise the same JSON fields so far, with `"status": "running"` and counts of the rules `running`, `waiting` and `pending`.

| Option       | Argument | Default | Meaning                                      |
| ------------ | -------- | ------- | -------------------------------------------- |
| `--history`  | [N]      | 10      | one line for each of the last N launches     |
| `--json`     |          | off     | print `summary.json`, also on a terminal     |
| `--launch`   | ID       | newest  | the launch to summarize                      |
| `--no-color` |          | off     | no colors on a terminal                      |

`--history` prints text, so it takes neither `--json` nor `--launch`.

## logs

```text
workz logs [WORKFLOW] RULE [options]
```

Prints the standard output and error of the rule's newest attempt, then, without `--stdout` or `--stderr`, the [diagnostics](Writing-Workflows.md#diagnostics) it kept if it failed; `--follow` prints them once the attempt has ended.

| Option             | Argument | Meaning                                         |
| ------------------ | -------- | ----------------------------------------------- |
| `--stdout`         |          | standard output only                            |
| `--stderr`         |          | standard error only                             |
| `--launch`         | ID       | look in this launch                             |
| `--attempt`        | N        | this attempt instead of the newest              |
| `-f`, `--follow`   |          | keep printing until the attempt ends            |

Give `--stdout` or `--stderr`, not both; without either, `logs` prints both streams.

## control

```text
workz control [WORKFLOW] stop RULE
workz control [WORKFLOW] retry RULE
workz control [WORKFLOW] cancel
```

Sends a command to the running launch ([Steering a running launch](Running-Workflows.md#steering-a-running-launch)). It fails if the newest launch has ended, or if RULE is not one of the rules the launch runs.

## report

```text
workz report [WORKFLOW] [options]
```

Reports on the newest launch, or on `--launch ID` ([Reports](Reports.md)).

| Option           | Argument              | Default | Meaning                                 |
| ---------------- | --------------------- | ------- | --------------------------------------- |
| `--launch`       | ID                    | newest  | the launch to report on                 |
| `--format`       | `tsv`, `json`, `html` | `tsv`   | attempt table, or a self-contained page |
| `--json`         |                       |         | the same as `--format json`             |
| `-o`, `--output` | FILE                  | stdout  | write the report to FILE                |
| `--bottlenecks`  |                       |         | what limited the launch                 |
| `--suggest`      |                       |         | suggested threads and memory per step   |
| `--compare`      | OTHER                 |         | compare with another launch             |
| `--methods`      |                       |         | what produced the recorded results      |

`--compare` takes a launch ID, a launch directory, or a working directory for its newest launch. Give at most one of `--suggest`, `--compare`, `--bottlenecks` and `--methods`. `--methods` describes the results recorded in the working directory, whatever launches made them, so it takes no `--launch`; it prints text, or JSON with `--format json` ([Reports](Reports.md#methods)). `--format` applies to the attempt table and to `--suggest`, which prints a table on a terminal, and TSV, or JSON with `--format json`, to a file or a pipe; `--compare` and `--bottlenecks` print text. The HTML page is not printed onto a terminal: write it with `-o`, or redirect standard output.

## verify

```text
workz verify [WORKFLOW] [--content]
```

Checks that every recorded output of the selected rules still has its recorded identity. `--content` also compares each output's bytes with its stored digest, and stores a digest for every output that has none. Prints `missing`, `changed` or `content` lines for differences, an `unrecorded` line for each selected rule with no record to check, and a final count, such as `12 outputs checked: all match; 1 selected rule has no record to check`. Unrecorded rules are not differences: the exit status stays 0.

## clean

```text
workz clean [WORKFLOW] [--keep N] [--previous] [--dry-run]
```

Removes containers that earlier launches left behind. `--keep N` also removes all but the newest N launch directories, keeping every launch that holds a rule's recorded attempt. `--previous` removes the earlier outputs that attempts moved into `previous/`, in every launch, and keeps the rest of each launch. `--dry-run` names each launch whose `previous/` directories it would remove, with how many and their size, and counts the containers. A `previous/` that cannot be removed is named, the others are removed, and `clean` exits 1. While a launch runs, `clean` refuses with `a launch is running in DIR; clean after it ends`.

## prepare

```text
workz prepare [TEMPLATE] [-o WORKFLOW] [--check]
```

Writes the workflow a pipeline template describes ([Writing workflows](Writing-Workflows.md#prepare-from-a-template)): TEMPLATE defaults to `pipeline.toml` and WORKFLOW to `workflow.toml` beside it. The result is checked as `validate` would before it replaces WORKFLOW; one that is not valid is kept beside it as `WORKFLOW.prepare-tmp` to read, with exit status 2. `--check` writes nothing: it prints the rules the template would add, remove and change against WORKFLOW, and whether the other tables changed, and exits 1 if anything would.

## schema

```text
workz schema
```

Prints a JSON Schema of the workflow format: every table and key `validate` accepts, with its type and a line of help, and no other key ([Writing workflows](Writing-Workflows.md#editor-support)).


```text
workz init [FILE] [--template]
```

Writes a commented starter workflow to `FILE` (default `workflow.toml`). With `--template`, writes a commented pipeline template instead (default `pipeline.toml`) and a `samples.tsv` beside it, for `workz prepare`. It never overwrites an existing file.

## completion

```text
workz completion bash
```

Prints a bash completion script: `source <(workz completion bash)`. It completes the commands, the options of each command, the `control` commands, rule names after `--target` and `--rerun-rule` and for `explain`, `logs` and `control`, and launch IDs after `--launch` and `--compare`.

## help and version

```text
workz help [COMMAND]
workz COMMAND --help
```

`workz help` lists the commands grouped by job. `workz help COMMAND`, `workz COMMAND --help` and `workz COMMAND -h` show a command's usage, options with their defaults, and examples. `workz version` (or `--version`) prints the version, such as `workz 0.4.0`.

A mistyped command or option is named in the error with the one probably meant:

```text
workz: unknown option '--max-thread' for run; did you mean '--max-threads'?
Run 'workz help run' for its options.
```

## Exit statuses

- `0`: success. For `run`, no rule failed, was blocked or was left unstarted; a rule stopped with `workz control stop` that nothing depends on counts as `cancelled` and still allows 0.
- `1`: `run` had a failed or blocked rule, or was refused by changed outputs, an input manifest mismatch or another running launch; `verify` found a difference; or there is nothing recorded to show or act on: no launch for `watch`, `status`, `report` or `control`, no attempt for `logs`, a launch that has ended or a rule it does not run for `control`, a launch holding the lock for `verify` or `clean`.
- `2`: an invalid command line or workflow: an unknown command or option, a missing or invalid value, options that exclude each other, an argument the command does not take, a rule or target that does not exist, or a launch refused before it started because of the workflow or its budget.
- `130`: `run` was interrupted, or cancelled with `workz control cancel`.
