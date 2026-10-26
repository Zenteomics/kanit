# Changelog

Every user-visible change to workz, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may change the workflow format, the record files under `.workz/` and the command line; each such change is listed under **Upgrading**.

## Unreleased

### Upgrading

- Rules that use a shared file input count its path as an input, so each such rule runs once after the upgrade.
- Commands that find nothing recorded to show or act on exit with status 1, as `status` and `watch` did: `report`, `logs` and `control` without a launch or attempt, `control` on an ended launch, and `verify` or `clean` while a launch holds the lock. Option errors still exit with 2.
- On a terminal, `run` and `status` print a short readable summary instead of JSON. Standard output that goes to a file or a pipe still gets the JSON summary, and `--json` gives it on a terminal too.
- Recorded file identities no longer include the device number, so every rule runs once after the upgrade.

### Added

- `workz help COMMAND`, `workz COMMAND --help` and `-h` show a command's usage, options with their defaults, and examples; `workz help` lists the commands grouped by job.
- A mistyped command or option is named with the one probably meant, for example `unknown option '--max-thread' for run; did you mean '--max-threads'?`.
- On a terminal, `workz run` keeps a status line below its progress lines: a bar of the rules done, running, failed and waiting, the counts, the elapsed time and the rules running. A failure line shows the last lines of the attempt's standard error, rules blocked by a failure get a line, and the launch ends with a summary: the outcome, each failure with its last error line, the slowest rules of a launch that completed, and the commands to look further. `workz status` prints the same summary.
- `run --json` prints the JSON summary on a terminal, and `run --no-color` turns colors off, as `NO_COLOR=1` does for every command.
- `?` in the live view lists every key.

### Changed

- `build.zig.zon` pins z-toml by URL and hash, so a fresh clone builds with `zig build` alone.
- The live `watch` view shows the launch in gauges: a progress bar split by state, the threads and memory reserved against the budget beside the cores and memory in use, and for each running rule its CPU use against its threads and a memory bar against its request, yellow from 70% and red from 90%. The timeline has a time axis, the details view gauges, and the log view shows error lines in red and warnings in yellow. Long rule names are shortened in the middle, narrow terminals drop the least needed columns first, and colors follow `NO_COLOR` and `TERM=dumb`.
- `X` in the live view cancels the launch only when pressed a second time within 3 s.
- The selection in the live view stays on the top row as rules finish, until a key moves it.
- The HTML report opens with cards for the elapsed time, rules, attempts, CPU, memory and engine cost. Its timeline labels every attempt with its rule and has a time axis, the budget charts have axes and the budget line, what limited the launch is laid out as the critical path step by step and the time ready rules waited for each resource, the requests per kind of rule form a table with memory bars, and the attempt table scrolls under a fixed header. The page follows a light or dark color scheme and prints cleanly.

### Fixed

- A rule that uses a shared file input counts the input's path as an input, so rebuilding an index reruns the rules that read it.
- Reuse survives a reboot on btrfs, which numbers its subvolumes anew at each mount: recorded file identities and input-manifest stamps no longer compare the device number, which made every rule run again after a reboot.
- A `state.json` upgraded from an earlier version is saved with the current format version.
- A rule that never completed is estimated by the median wall time of its kind, as the reports compute it, when ready rules are ordered by their chain of work.
- A cycle error lists the rules on the cycle in order, `sort -> align -> sort`, instead of one rule that may only depend on it.
- A rule that fails because its shared input could not be loaded prints a failure line with the reason, like any other failure.
- An option given without its value says `--max-threads needs a value`, and a value that does not parse names what is expected, such as `use a size such as 512M or 60G`.
- `workz init` rejects options instead of writing a file named after them.
- The starter workflow from `workz init` describes a resource group as units that rules take, not as a limit on rules of a kind.
- `report --compare` shows `-` for a kind with no completed attempt on one side, and says on which side it did not run, instead of a change of -100%.
- `workz completion bash` completes every option of every command, including `report --suggest` and `--compare`, and the `control` commands with rule names after `stop` and `retry`.
- The HTML report shows kind names and request figures in full; they were cut off at the edge of the memory chart.

## 0.3.0 - 2026-10-25

Reports you can share and runs you can steer: an HTML report of a launch, launch comparisons and request suggestions, commands to stop, retry and inspect rules while a launch runs, per-rule work directories, and mounts for container images.

### Upgrading

- `state.json` records the keyed environment of each recorded rule. workz 0.3.0 reads the state of earlier versions and reruns nothing. workz 0.2.0 and earlier refuse a state file that 0.3.0 has written; to go back, delete `.workz/state.json`, and every rule runs again.
- Among ready rules of equal priority, the rule heading the longest chain of work starts first. If your workflow depends on file order to start rules in a particular order, give those rules a `priority`.

### Added

- `workz report --format html` writes one self-contained page for a launch: the summary, a timeline of every attempt with the critical path outlined, threads, cores and memory over the run, memory request against peak for each kind of rule, the bottleneck report, each failure with the end of its standard error, and the attempt table. The page has no scripts and loads nothing from elsewhere.
- `workz report --compare OTHER` compares a launch with another one, named by launch ID, launch directory or working directory: elapsed time, attempts and reserved thread-seconds, then the median wall time, largest peak and total CPU time of each kind of rule, with the change in percent.
- `workz report --suggest` prints the suggested threads and memory for each kind of rule as TSV, or as JSON with `--format json`, for a workflow generator to apply.
- `workz report --bottlenecks` says, for each resource group that held ready rules back, how often a waiting rule would have fitted the free threads and memory, and from 25% of the samples that a higher `max` would have started it earlier. It also lists the shared inputs with their starts, load time, declared memory and peak, and suggests a `memory` for services.
- `workz control stop RULE`, `retry RULE` and `cancel` steer the running launch. `stop` cancels a rule and blocks its dependents while the rest goes on; `retry` runs a failed or stopped rule again with its blocked dependents; `cancel` stops the launch like an interrupt. Every command is recorded as a `control` event.
- `workz logs RULE` prints the standard output and error of the rule's newest attempt. `--stdout` or `--stderr` keeps one stream, `--launch ID` and `--attempt N` pick an earlier attempt, and `--follow` streams a running one until it ends.
- `workz clean` removes containers that earlier launches left behind; `--keep N` also removes all but the newest N launch directories, keeping every launch that holds a rule's recorded attempt. `--dry-run` names the launches it would remove and counts the containers.
- `workz status --history [N]` prints one line for each of the last N launches: status, elapsed time, counts and any launch error.
- `workz init [FILE]` writes a commented starter workflow, and `workz completion bash` prints a completion script for commands, most options and rule names.
- `--rerun-rule RULE` on `run`, `plan` and `explain` runs the named rules even when they are reusable. Their consumers follow when the outputs change, and changed outputs of the named rules are moved to `previous/` instead of refusing the launch.
- `workz plan --summary` counts the decisions by reason, for example `449 run   a producer runs`.
- `plan` names the environment variables that changed (`environment changed: PATH`), and `explain` describes each change: entries added to or removed from a list such as `PATH`, or the old and new value.
- Workflow errors show the offending line of the file, and errors about a rule point at its `[[rules]]` line.
- `workdir` runs a rule's command in a directory below the working directory, made before each attempt, and `links` places symlinks to some of the rule's inputs there. Container rules get the work directory mounted read-write.
- `mounts` on a container rule or a shared service places host files or directories read-only over paths inside the image. On a rule, each source is also an input, so editing it runs the rule again.
- `timeout` on a shared service limits how long it may take to become ready, and `retries` (0 to 3) starts it again when it fails before it is ready.
- The interactive `watch` view lists every selected rule from the start, with a line for each shared input and the memory it holds. `i` shows a rule's request, times and live cgroup counters, `/` searches rule names, `s` changes the sort order, and `S`, `R` and `X` stop, retry or cancel.

### Changed

- Ready rules of equal priority start in critical-path order. Each rule is estimated by its last recorded wall time, else the middle wall time of its kind, else 1 s; priorities still come first.
- The launcher starts the run's scope without reading the workflow. The engine reads it once, inside the scope, and protects the memory of shared inputs from reclaim with the scope's `MemoryLow`, recorded as a `memory_protected` event.
- Task cgroups leave the swap limit to the run's scope, which allows no swap for any group below it.

### Fixed

- With `--no-isolation`, the running tasks of a killed engine end with it: a guard process holds their process groups and kills them when the engine's end of its pipe closes.
- Output of workz redirected to a file that other commands also write (`>>`, or `> log 2>&1`) is appended instead of overwriting earlier lines.
- `report --bottlenecks` sizes container rules by their cgroup peak, not by the memory of the Podman client, and measures elapsed time as the launch summary does.
- A launch after a crash checks that the leftover containers it removed are gone, and removes them again while Podman still lists them.
- When no ready rule can ever start and nothing is running, the launch stops with an error that names the rule and the resource it waits for.
- A launch records the environment of the rules it reuses, so state written by earlier versions gains it without a rerun.

### Performance

- `validate` and every command that reads a workflow take time linear in its size.
- Resuming a launch reads the workflow once, examines each input path once, and checks for inputs changed during the run only on the rules that ran.

## 0.2.0 - 2026-10-21

Containers: rules can run in local images through rootless Podman, a shared service can hold a large index in memory once for many rules, and `watch` becomes an interactive terminal view.

### Added

- `container = "IMAGE"` runs a rule's command with `/bin/sh` inside a local image through rootless Podman. Images are never pulled; each is resolved to its image ID, which is part of the rule key. The container runs in the attempt's cgroup, so the memory limit, the out-of-memory kill and the counters cover the tool. It has no network, no capabilities and a read-only root; the working directory and outside inputs are mounted read-only, output directories read-write.
- Shared services: a `[shared.NAME]` entry with `container`, `command` and `memory` runs a container whose IPC namespace container rules join, for example a STAR genome loaded once into shared memory. Its memory counts once against the budget. It stays up while a rule that has yet to run needs it, and gives way when a waiting rule needs its memory.
- On a terminal, `watch` is interactive: a table of rules with filters, the selected attempt's standard error or output as it grows, and a timeline of the launch.

### Changed

- Shell rules run in one user and network namespace created for the run, with only loopback. `systemd-run --scope` starts the engine directly; bubblewrap is not needed.

### Fixed

- If the engine is killed, every task, container and service of the run ends with it: the holder of the run's network namespace kills the run's cgroup when the engine's end of its pipe closes.
- The container of every failed attempt is removed, including one stopped before it started.

## 0.1.1 - 2026-10-20

Large prepared workflows: input manifests that skip rehashing, refused launches that leave a record, and inputs keyed on their content.

### Upgrading

- The engine key is 2, so the first run after upgrading runs every rule once.

### Added

- An `--input-manifest` entry may carry the file's identity (a stamp) beside its digest; a file whose identity matches the stamp is not read again.
- A refused launch keeps its launch directory, its events and a summary with the reason. The input check is recorded as an `inputs_checked` event.
- `run --slice NAME` places the run's scope in a slice of the caller. The summary records the engine's own CPU time and peak memory.

### Changed

- Files with a stored digest, which are input-manifest inputs and the outputs of `cutoff = true` rules, are keyed on their content. A touched or restored file with the same bytes keeps its consumers reused.

### Fixed

- `report --bottlenecks` marks attempts whose work ran outside workz's cgroups, and gives no sizing advice for a kind of rule whose attempts mostly ran that way.
- Waiting on the critical path is derived from event times, so attempts without queue records show their wait.

## 0.1.0 - 2026-10-19

First release: an engine for prepared graphs of file-producing rules on one Linux workstation.

### Added

- Workflow format 1 in TOML: an explicit graph of rules, each with its inputs, outputs, shell command and resource request. Unknown keys are errors that name the line and the closest known key.
- Commands `validate`, `plan`, `explain`, `graph`, `run`, `watch`, `status`, `verify` and `report`.
- Reuse by rule key: the command, the keyed environment, the request, the declared writes, the identities of the inputs and the keys of the producers. A changed recorded output refuses the launch unless `--rerun` is given, and `--rerun` keeps the earlier bytes.
- Scheduling by threads, memory, jobs, resource groups and shared inputs, with priorities, retries, timeouts and a dispatch journal for crash recovery.
- Isolation: the run in a systemd scope with a private network, and each task in a cgroup with its memory and CPU limits. An out-of-memory kill ends every process of the task.
- Shared inputs, mapped once by a holder and counted once against the memory budget.
- `cutoff = true`: consumers of an output regenerated with the same bytes stay reused.
- A complete record of every attempt: logs, the request, the result and the cgroup counters including pressure. Events record why ready rules waited, and the run is sampled every 5 s.
- `workz report` prints one row per attempt as TSV or JSON, and `report --bottlenecks` shows the critical path, waiting by reason, request sizing per kind of rule, stall character and utilization.
