<!-- markdownlint-disable MD007 MD024 -->

# Changelog

All notable changes to kanit are documented in this file. Versions up to 0.6.0 were released under the name workz. Versions follow [Semantic Versioning](https://semver.org/): before 1.0, a minor version may change the workflow format, the records under `.workz/` and the command line, and each version says first what such a change needs from you.

## [Unreleased]

The run log becomes one aligned table by tool, step and sample, and `run`, `status` and `watch` share its columns and summary. Large workflows run in about a quarter less time and a third less memory.

Two changes need action:

- **Add `--json` where a script reads `kanit run` or `kanit status`.** Both print text wherever their output goes.
- **Read the new layouts, or `events.jsonl`.** The progress lines of `run` and the text of `plan`, `verify`, `clean` and `status --history` changed.

### Added

- **Steps and samples**
  - Every command and option that takes a rule also takes its step and sample as `STEP/SAMPLE`, such as `kanit logs align/S2` for the rule `S2__align`, and bash completion offers both.
  - `plan` prints one row per step, and `plan --rules` one row per rule by step and sample.
  - The summary that `run` ends with, and that `status` prints, shows samples by steps, names the failure behind each blocked rule, and ends with the commands to type next.
- **Tools**
  - The run log names each rule's tool, and the launch's header lists each step's tool, version and rule count.
  - The summary lists every tool's version.
  - A host rule without a `tool` label takes the program its `version` command runs, also in reports.
- **Logs**
  - Each launch keeps its run log in `launch.log`, with the summary at its end, and `.workz/latest` links to the newest launch.
  - `kanit logs` without a rule prints the newest launch's failed attempts, each stream headed by the rule, attempt, outcome and size, and `-n N` prints the last N lines.
  - `run -v` keeps a line for every rule that starts on a terminal.
- `plan --json`, `verify --json` and `status --history --json` print JSON.

### Changed

- **The run log**
  - It is one table of the time, the rules done, a tag (`START`, `DONE`, `RETRY`, `FAIL`, `BLOCK`, `STOP`, `INFO` or `WARN`), the tool, step and sample, the time taken, memory and CPU against the request, and a note.
  - Its columns are sized from every selected rule when the launch starts, and on a terminal no line is wider than the window.
  - It opens with the launch's steps, tools and samples, names each failure's reason with the command that shows its output, and reports the rules a failure blocks once.
  - On a terminal a footer shows each step's progress in place of `START` rows; off a terminal the step table follows an `INFO` row of the counts every five minutes.
  - `-q` keeps the column header above the failures it prints, and the summary counts the rules done, reused, failed, blocked and stopped.
- **Speed and memory**
  - On a workflow of 20,000 rules, a launch takes about a quarter less time and a third less memory, and `validate` and `plan` a third less time and a fifth less memory.
  - On a launch of 20,000 rules, `status` takes about a third less time, `watch` a fifth less, and `report --bottlenecks`, `report --format html` and a rerun that reuses every rule a tenth less.
  - With isolation, on 2,000 short rules, the engine uses about 5% less CPU and a fifth less memory and records the same counters.
- `kanit watch` shows the run log's columns, tags and units: the step table, then a row per rule whose note says what a waiting rule waits for and which failure blocked a rule; `watch --once`, and a watch off a terminal, print it as text.
- The text tables of `report --bottlenecks`, `report --compare` and the sizing suggestions make their name columns as wide as the longest name, up to 30 columns.
- Version commands run before the first rule, at most four at a time, for every selected rule; kanit waits at most 5 s for them, and takes a container's version that an earlier launch recorded for the same image ID.
- A launch appends each completed rule to `.workz/state.log`, synced at most once a second, and rewrites `state.json` when it ends; kanit 0.7.0 ignores the log and reruns the rules recorded only there.

### Fixed

- `kanit watch` counts blocked rules as blocked, not as failed, and a view started before its launch wrote its records shows the launch's names once they are written.
- `report --format html` and the launch page draw a launch whose `launch_started` event selects none of the rules that ran, instead of stopping on an index out of bounds.

## [0.7.0] - 2026-11-06

workz becomes kanit. Pipeline templates gain run files, sample-sheet defaults and quoted placeholders, reports use about half the memory, and a Zig program can follow a running launch.

Three changes need action:

- **Call `kanit` instead of `workz`.** Records stay in `.workz/`, task variables keep `WORKZ_`, and the Zig module stays `workz`.
- **Rename resource groups with other characters.** Group names take letters, digits, `_`, `.` and `-`, as rule names do.
- **Prepare templates again.** `${name}` in `shell` stays the shell's variable, so rules whose command changes run again.

### Added

- **Pipeline templates**
  - Run files: `kanit prepare TEMPLATE --params FILE` takes a run's name, params and samples from a file beside it.
  - Sample-sheet defaults fill empty cells and missing columns.
  - `{name:q}`, `{input:q}` and `{output:q}` quote a value as one shell word.
- `model.Live` follows a running launch from Zig, reading only what was written since its last refresh.
- `examples/report-tour/` shows completion, reuse and a failed rerun with three rules and no downloads.

### Changed

- Reports and the HTML page use about half the memory on a launch of 3,000 attempts.
- The live HTML page uses steady outlines instead of animation, and reloads at most every 15 s.

### Fixed

- **Reports**
  - A launch's report reads its own copy of the workflow, so moved outputs no longer hide its graph.
  - A launch whose engine was killed shows as `unfinished` instead of running forever.
  - An unreadable record is named, and the report exits 1.
  - A command's peak memory that is the engine's own is marked `<=`.
- **Cleaning up**
  - `clean --keep` goes on past a launch it cannot remove.
  - `clean --previous` never follows a symlink.
- **Templates**
  - `prepare` notes an unknown `{name}` a typo away from a known one.
  - An empty `samples.names` is refused.
- Isolated runs work on systemd releases before 254, such as Debian 12, RHEL 9 and Ubuntu 22.04.

## [0.6.0] - 2026-10-31

Reuse and records hold where 0.5.0 could mislead: directory inputs count their whole shape, a failed rerun keeps the last result, a dead service fails its users, and damaged records are named instead of shown.

Three changes need action:

- **Expect every rule to run once.** A directory's identity covers its subdirectories, so the engine key moves to 4.
- **Fix the paths validation refuses.** Writes or inputs through a symlinked directory, a rule writing inside its own directory input, and sizes with a sign or `_`.
- **Update scripts that read records.** Record files carry a `v` version, `.workz/` is readable by its owner alone, and `plan` and `verify` exit 1 where `run` would refuse or a record is missing.

### Changed

- A consumer of a cutoff rule reruns only when an output it reads changed.
- Reports find reused runs faster: 15 ms instead of 54 ms for 200 rules after 100 launches.

### Fixed

- **Reuse and recovery**
  - A failed rerun puts the earlier outputs back and keeps the rule's record.
  - A directory input notices empty directories and dangling symlinks.
  - A rule whose input changed while it ran fails instead of completing.
- **Shared services**
  - A service that dies after it was ready fails the rules using it.
  - Files mounted into a service are inputs of the rules that join it.
- **Planning**
  - A fully reusable launch runs under any budget, and `plan --budget` counts only the rules that will run.
  - `plan` and `explain` take `--input-manifest`, so they decide as `run` does.
- **Records**
  - A damaged record is named with its path, never shown as data.
  - `.workz/` is private, since it records `--pass-env` values, and a container receives them by name only.
  - `status`, `watch`, `control` and `logs --follow` see that a killed launch has ended.
- A tool keeps its grace period after a timeout, `control stop`, cancel or interrupt.
- A `control` command sent while a launch is starting is applied instead of erased.

## [0.5.0] - 2026-10-27

Writing pipelines and seeing them: `prepare` writes the explicit workflow from a template over a sample sheet, `graph` shows it in layers, `report --methods` says what produced the results, and `plan --budget` checks a launch before it starts.

Four changes need action:

- **Expect every rule to run once.** Rule keys name paths relative to the working directory, so the engine key moves to 3, and `state.json` moves to format 4.
- **Remove what is no longer accepted.** A resource group's `wait` key, and `--resume-failed` and `--provenance` on `run`.
- **Budget 32 MiB more per container rule.** Its Podman client now has a reservation of its own.
- **Update scripts that read records or output.** Records and events add fields, workflow errors come one line per problem, and `graph` prints text on a terminal.

### Added

- **Pipeline templates**
  - `prepare` writes one labelled rule per sample from a template and a sample sheet.
  - `prepare --check` shows the rules an edit would add, remove and change.
  - `init --template` writes a starter template and sheet.
- **Graph**
  - `graph --layer` adds files, shared inputs and resource groups to the rules.
  - `--by step`, `--focus`, `--why` and `--users` narrow it to one question.
- **Methods**
  - `report --methods` names the workflow, engine, each tool with its version and image, and each step's request and command.
  - A rule's `version` command records its tool's version.
- **Authoring**
  - `schema` prints a JSON Schema of the format for editors.
  - `validate --inputs` lists the inputs that exist nowhere and that no rule writes.
  - `validate` notes shared inputs and groups that no rule uses.
- `diagnostics` keeps the files a tool writes its errors to, such as STAR's `Log.out`, from a failed attempt.
- `plan --budget` checks every rule against the budget as `run` would.
- `run --threads STEP=N` gives a step's rules N threads for one launch.
- `clean --previous` removes the earlier outputs that reruns kept.

### Changed

- A workflow with several problems reports them all, up to 50, each with its line.
- Moving a project within one file system keeps every rule reused.
- A shared service's index is an input of every rule that joins it.

### Removed

- A resource group's `wait` key, and `run --resume-failed` and `--provenance`, which changed nothing.

### Fixed

- A rule that reads a directory waits for every rule writing inside it.
- A shared input that fails to start fails its rule instead of crashing the engine.
- `explain` and `--rerun-rule` suggest the closest rule name.

## [0.4.0] - 2026-10-26

Rules say what they are, by step, sample, category and tool. Reports and a rebuilt HTML page group by those labels, every launch keeps its page current while it runs, and `run` keeps a status line and ends with a readable summary.

Three changes need action:

- **Expect every rule to run once.** File identities leave out the device number, shared file inputs count as inputs, and `state.json` moves to format 3.
- **Pass `--json` for JSON on a terminal.** `run` and `status` print a readable summary there; files and pipes still get JSON.
- **Update scripts that read reports or exit statuses.** `report --suggest` renames its columns, `delegated` becomes `idle`, and commands with nothing to show exit 1.

### Added

- **Rule labels**
  - `step`, `sample`, `category` and `tool` say what a rule is, without entering its key.
  - `report --bottlenecks` adds the CPU time per category and tool, and each sample's slowest step.
- **Terminal output**
  - `run` keeps a status line under its progress.
  - A failure shows the last lines of its standard error.
  - A launch ends with a summary of its outcome and where to look next.
- **Help**
  - Every command has `--help` with its options, defaults and examples.
  - A mistyped command or option names the one meant.
- Every launch writes `report.html` as it starts and keeps it current while it runs.
- `report -o FILE` writes any report to a file.

### Changed

- **HTML report**
  - One engineering sheet: the pipeline, CPU time, samples by step, steps, timeline, budget and limits.
  - It follows the reader's color scheme, prints on A4 and loads nothing from elsewhere.
- **Live view**
  - Gauges show progress, threads and memory against the budget.
  - Each running rule shows its CPU and memory against its request.
- `report --bottlenecks` answers what limited a launch from lower bounds on its elapsed time.
- Durations and sizes read the same in every view and report, such as `1m 27s` and `203 MiB`.
- `build.zig.zon` pins z-toml by URL and hash, so a fresh clone builds with `zig build` alone.

### Fixed

- **Reuse**
  - Reuse survives a reboot on btrfs, which numbers its subvolumes anew.
  - Rebuilding a shared file input reruns the rules that read it.
- **Planning**
  - `plan`, `explain` and `verify` predict what `run` does.
  - `explain` names the inputs that changed, and a `PATH` change entry by entry.
- **Reports**
  - The text reports and the HTML page compute each figure from the same records.
  - A step killed for its memory is suggested half again the request it exceeded.
  - CPU use and character are judged only on runs that add up to a second or more.
- A rule that cannot be set up fails alone instead of ending the launch.
- A cycle error lists its rules in order, such as `sort -> align -> sort`.

## [0.3.0] - 2026-10-25

Reports you can share and runs you can steer: an HTML report, launch comparisons and request suggestions, commands to stop and retry rules while a launch runs, work directories and image mounts.

Two changes may need action:

- **Give rules a `priority` if their start order matters.** Among ready rules of equal priority, the one heading the longest chain of work starts first, not the first in the file.
- **Delete `.workz/state.json` to go back to 0.2.0.** 0.2.0 refuses the state this version writes.

### Added

- **Reports**
  - `report --format html` writes one self-contained page of a launch.
  - `report --compare` compares two launches step by step.
  - `report --suggest` prints each step's suggested threads and memory.
- **Steering a launch**
  - `control stop`, `retry` and `cancel` act on the rules of a running launch.
  - `logs` prints or follows a rule's standard output and error.
- **Rules**
  - `workdir` and `links` give a rule a directory of its own.
  - `mounts` places host files over paths in an image.
  - A shared service takes `timeout` and `retries`.
- **Records**
  - `clean` removes leftover containers and old launch directories.
  - `status --history` lists past launches.
- `--rerun-rule` runs named rules again even when they are reusable.
- `plan --summary` counts the decisions by reason.
- `init` writes a starter workflow, and `completion bash` a completion script.

### Changed

- Ready rules of equal priority start in critical-path order.
- The run's scope protects the pages of shared inputs from reclaim.
- Reading a workflow takes time linear in its size.

### Fixed

- A killed engine ends the tasks of a run without isolation.
- Output redirected to a log that other commands also write is appended instead of overwriting it.
- A launch in which no ready rule can ever start stops with an error naming the rule.

## [0.2.0] - 2026-10-21

Containers: rules can run in local images through rootless Podman, a shared service can hold a large index in memory once for many rules, and `watch` becomes an interactive terminal view.

### Added

- **Containers**
  - `container = "IMAGE"` runs a rule in a local image through rootless Podman, inside the attempt's cgroup.
  - A container has no network, no capabilities and a read-only root.
  - A shared service holds an index such as a STAR genome in shared memory, counted once against the budget.
- `watch` on a terminal is an interactive view with filters, live output and a timeline.

### Changed

- Rules run in a user and network namespace made for the run, without bubblewrap.

### Fixed

- A killed engine ends every task, container and service of its run.
- The containers of failed attempts are removed.

## [0.1.1] - 2026-10-20

Large prepared workflows: input manifests that skip rehashing, refused launches that leave a record, and inputs keyed on their content.

One change needs action:

- **Expect every rule to run once.** The engine key is now 2.

### Added

- An `--input-manifest` stamp skips reading a file whose identity matches it.
- A refused launch keeps its directory, its events and a summary of the reason.
- `run --slice NAME` places the run's scope in a slice of the caller.
- The summary records the engine's own CPU time and peak memory.

### Changed

- Files with a stored digest are keyed on their bytes, so a touched file keeps its consumers reused.

### Fixed

- `report --bottlenecks` marks attempts whose work ran outside their cgroup, and does not size from them.

## [0.1.0] - 2026-10-19

The first release: an engine for prepared graphs of file-producing rules on one Linux workstation.

### Added

- Workflow format 1 in TOML: an explicit graph of rules, each with its inputs, outputs, shell command and request.
- `validate`, `plan`, `explain`, `graph`, `run`, `watch`, `status`, `verify` and `report`.
- **Reuse**
  - A rule key covers the command, keyed environment, request, declared writes, input identities and producers' keys.
  - `cutoff = true` keeps the consumers of an output regenerated with the same bytes reused.
- **Scheduling and isolation**
  - Rules are admitted by threads, memory, jobs, resource groups and shared inputs, with priorities, retries and timeouts.
  - The run is in a systemd scope with a private network, and each task in a cgroup with its limits.
  - Shared inputs are mapped once and counted once against the budget.
- **Records and reports**
  - Every attempt keeps its logs, request, result and cgroup counters.
  - `report` prints one row per attempt, and `report --bottlenecks` the critical path, waits and request sizing.
