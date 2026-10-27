<!-- markdownlint-disable MD007 MD024 -->

# Changelog

All notable changes to workz will be documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may change the workflow format, the records under `.workz/` and the command line; each version says first what such a change needs from you.

## [Unreleased]

### Added

- **Failures you can read.** A rule may name `diagnostics`, files such as STAR's `Log.out` where a tool writes why it failed. A failed attempt keeps the last 64 KiB of each in its `diagnostics/` directory; the terminal, `status`, `workz logs` and the HTML page show them, and the failure reason quotes the first one when standard error is empty. `record.json` and the summary's `failures` list them.
- **Results you can cite.** `workz report --methods` describes what produced the results recorded in a working directory, across the launches that made them: the workflow file and its digest, the engine, each tool with its version, image reference and image ID, and each step's request and command, as text or JSON. A rule may name a `version` command, such as `STAR --version`, which runs once per launch for each image and command and is recorded in the launch's `versions.json`; each attempt's `record.json` adds the `image` ID it ran and its `version` command, and `launch.json` adds `workflow_name` and `workflow_version`.
- **Disk you can reclaim.** `workz clean --previous` removes the earlier outputs that reruns moved into attempts' `previous/` directories, often the largest files in `.workz/`, and keeps the rest of each launch. `run` and `status` say how much a launch kept, the summary counts it in `previous_bytes`, and the `output_preserved` event adds `bytes`.

### Changed

- **Projects you can move.** Rule keys and `state.json` name paths inside the working directory relative to it, so moving or renaming a project within one file system keeps every rule reused; paths outside it stay absolute. `state.json` moves to format 4, which 0.4.0 refuses, and the engine key to 3, so every rule runs once after the upgrade.
- **Containers inside the budget.** Each running container rule and service reserves 32 MiB of the memory budget for its Podman client and conmon, which run beside the container and take about 20 MiB; before, they shared the engine's 256 MiB of headroom, which 16 container rules at once outgrew. A container rule whose request is within 32 MiB of `--max-memory` is now refused before the launch, and fewer container rules may run at once on a tight budget. The refusal names what a rule's memory need includes.

### Removed

- `run` refuses `--resume-failed` and `--provenance`, which 0.4.0 accepted and ignored; remove them from command lines.
- A resource group no longer takes a `wait` key. Its only accepted value, `"queue"`, described how every group works; delete the line where a workflow has it.

## [0.4.0] - 2026-10-27

Rules can now say what they are, by step, sample, category and tool, and the reports and a rebuilt HTML page group by those labels; every launch keeps that page up to date while it runs. The terminal output is rebuilt too: `run` keeps a status line and ends with a summary, `watch` draws gauges, and every command explains itself with `--help`. Reports say what limited a launch from lower bounds its records support, and a launch that failed or was refused says what went wrong and the command that resolves it. A rule that cannot be set up, or a killed engine, no longer takes the rest of the launch with it, and reuse survives a reboot on btrfs.

Three changes need action:

- **Expect every rule to run once.** Recorded file identities no longer include the device number, and a rule that uses a shared file input now counts that file as an input. `state.json` moves to format 3, which 0.3.0 and earlier refuse; to go back, delete `.workz/state.json`, which reruns every rule.
- **Pass `--json` for the JSON summary on a terminal.** On a terminal, `run` and `status` print a short readable summary; standard output that goes to a file or a pipe still gets JSON.
- **Update scripts that read reports, events or exit statuses.**
  - `report --suggest` names its first column and JSON field `step` instead of `kind`, counts `runs` instead of `attempts`, and replaces `peak_mib` and `delegated` with `used_mib` (the memory it sizes), `used_basis` (`process` or `cgroup`), `peak_mib` (the cgroup peak) and `note` (`measured`, `idle` or `out_of_memory`). An idle step keeps its current request instead of a suggestion from memory it did not use.
  - An attempt's `record.json` drops `cgroup.anon` and `cgroup.file_mapped`, which read 0 once its processes had exited, and adds `cgroup.anon_peak`, the largest anonymous memory sampled while it ran.
  - `report` renames its TSV column and JSON field `delegated` to `idle`: an attempt that used almost none of its request waited, or handed its work outside its cgroup.
  - `report --suggest` adds a last column and JSON field, `at_thread_limit`.
  - `summary.json`, and `status` off a terminal, add `failures`, each failed, blocked or cancelled rule with its reason and standard error file, and `changed_outputs` for a launch refused over changed outputs. Their counts add `running`, `waiting` and `pending`, 0 once the launch ended, and a running launch's status has every key of the summary.
  - `report` writes the ratios `cpu_efficiency` and `peak_per_request` with four decimals instead of two, so a small value no longer reads as 0.00.
  - A launch in which rules were stopped with `workz control stop` and none failed has status `stopped`, not `completed` or `failed`; a cancelled attempt's reason says why: `stopped on request`, `cancelled: the launch was interrupted`, or `cancelled: the launch stopped after a failure`.
  - `report --format json` uses the TSV's field names (`memory_mib`, `max_rss_mib`, `oom_kills` and so on) and adds `started_ns` and `directory`.
  - `--compare` and `--bottlenecks` group by step, and a step's figures come from the latest run of every rule, this launch's or the one it reused.
  - Commands that find nothing recorded to show or act on exit with status 1, as `status` and `watch` did: `report`, `logs` and `control` without a launch or attempt, `control` on an ended launch, and `verify` or `clean` while a launch holds the lock. Option errors still exit with 2.
  - A rule cancelled before its attempt started is recorded as `task_finished` with status `cancelled`, not as `task_failed`, and `task_failed` always has an `attempt` field, null when no attempt started.
  - `status` off a terminal prints JSON for a running launch too, the summary's fields so far with status `running`, instead of the plain view.
  - A command refuses an argument it does not take, and options that exclude each other, with status 2 instead of ignoring them.

### Added

- **Rule labels.** `step`, `sample`, `category` and `tool` say what a rule is ([Concepts](wiki/Concepts.md#steps-samples-categories-and-tools)).
  - Each attempt records them, and they are not part of the rule key, so adding or changing one reruns nothing.
  - Rules without them are labelled from their names and images, as the reports grouped them before.
- **Reports by label.**
  - `report --bottlenecks` adds the CPU time per category and per tool, and each sample's slowest step, marked when it took at least 1.5 times the step's median.
  - The TSV and JSON attempt reports carry each attempt's labels.
- **A page for every launch.** `run` writes `report.html` in the launch directory as the launch starts and prints its path.
  - The engine draws the page again every 5 s while the launch runs, and the page reloads itself, so a browser follows the pipeline rule by rule.
  - On a large launch the page waits longer between updates, so that drawing it takes at most a twentieth of the engine's time.
  - The page is drawn once more when the launch ends and then stops reloading; the summary names it.
- **`report --suggest` on a terminal** prints a table with units and notes, such as a step that kept its threads busy or a suggestion from one run; to a file or a pipe it prints the TSV.
- **`report -o FILE`** writes the report to a file; `--format html` refuses to print the page onto a terminal and says to use it.
- **Fewer words to type.**
  - `report --json` prints JSON, as `run --json` and `status --json` do; it is the same as `--format json`.
  - A command given no WORKFLOW reads `workflow.toml` in the current directory, the file `workz init` writes.
  - `watch` and `status` take `--launch ID` for an earlier launch, and `--no-color`.
  - `--grace` takes a duration such as `30s` or `1m`, as `--timeout` does.
  - Bash completion offers launch IDs after `--launch` and `--compare`.
- **Run output on a terminal.**
  - The first line gives the launch's budget, and says when it is the default, every CPU and three quarters of the memory, which a shared machine should not give one launch.
  - `run` keeps a status line under its progress lines: a bar of the rules done, running, failed and waiting, the counts, the elapsed time and the rules running.
  - A failure line shows the last lines of the attempt's standard error, and each rule blocked by a failure gets a line.
  - The launch ends with a summary: the outcome, each failure with its last error line, the slowest rules of a launch that completed, and the commands to look further. `status` prints the same summary.
  - `run --json` prints the JSON summary on a terminal, and `--no-color` turns colors off, as `NO_COLOR=1` does for every command.
- **Help.**
  - Every help text fits in 80 columns.
  - `workz help COMMAND`, `workz COMMAND --help` and `-h` show a command's usage, its options with their defaults, and examples; `workz help` lists the commands by job.
  - A mistyped command or option names the one probably meant: `unknown option '--max-thread' for run; did you mean '--max-threads'?`.
  - `?` in the live view lists every key.

### Changed

- **The HTML report** is drawn as one engineering sheet: ink on grid paper in light, a charcoal sheet in dark.
  - A title block gives the status, elapsed time, rules done, the pipeline's samples and steps, CPU and memory against the budget, and the engine's own cost.
  - FIG. 1 draws the pipeline: a box for each step in the order of the workflow's graph, wired to the steps it reads from, with a cell for each rule showing whether it is done, reused, running, waiting, failed or blocked.
  - Further figures show where the CPU time went, each sample's run of each step, the steps with their suggested requests, the timeline, the use of the budget and what limited the launch.
  - Tables list the failures and every attempt.
  - The pipeline, CPU, samples and steps figures cover the latest run of every rule, so a launch that reused rules still shows the whole pipeline; the rest cover the launch itself.
  - A page written while the launch runs reloads itself every 5 s.
  - The timeline names its rows up to 250 attempts, and marks the critical path with a heavier edge; FIG. 6's legend shows a running bar in its category's color, the CPU and memory axes label their zero with its unit, and the samples matrix aligns its CPU time header with its figures.
  - The page prints its colors, on A4 in landscape. On a narrow screen the title block leaves no cell alone on its row, and a figure wider than the screen shades the edge it scrolls past.
  - Text and marks meet contrast levels in both themes: muted labels 5.2:1 on the light sheet, text on the matrix shades and on failed cells at least 5:1, cancelled and not-ready marks and the dark frames at least 3:1, and the dark sheet stands apart from its paper.
  - Rule states are drawn in ink, by form: done solid, reused hatched, running outlined and pulsing, waiting dashed, a stopping rule grey. No state takes a category's hue, so a category drawn in blue is never read as running; a slow run is an ink ring and its `!`, and bars of memory and the run dots are a neutral ink.
  - The page follows the reader's color scheme, and a theme tag at its corner picks auto, light or dark without a script. It prints in light and loads nothing from elsewhere.
- **The live view** shows the launch in gauges.
  - A progress bar is split by state, and the threads and memory reserved against the budget sit beside the cores and memory in use.
  - Each running rule shows its CPU use against its threads and a memory bar against its request, yellow from 70% and red from 90%.
  - The timeline has a time axis, the details view has gauges, and the log view shows errors in red and warnings in yellow.
  - Long rule names are shortened in the middle, narrow terminals drop the least needed columns first, and colors follow `NO_COLOR` and `TERM=dumb`.
  - `X` cancels the launch only when pressed twice within 3 s, and the selection stays on the top row as rules finish, until a key moves it.
  - The key hints put `?` second, so a narrow terminal still shows it, and the table's hints name `S`, `R` and `X`.
- **What limited a launch** is answered from lower bounds on the elapsed time of the attempts it made: the longest chain of work, the work each limit of the budget carried (threads, memory, jobs and every resource group), the CPU time its rules used, and the engine's own CPU time. A launch shorter than 2 s is not judged.
  - `report --bottlenecks` and the HTML page name the largest bound and how far the launch ran over it, such as `the thread budget limited this launch: it took 1m 32s, 5% more than its rules' thread requests need at that limit; they kept 66% of the threads they reserved busy`.
  - The critical path is the longest chain of work, the chain the scheduler ranks rules by, instead of the chain that ended last, which in a launch held back by its budget followed whichever rule started last.
  - Each rule on the critical path shows the time it waited once ready, the time it was held for producers off the path and the time between its attempts; with the time from the end of the path to the end of the launch, these add up to the elapsed time.
  - Waiting for resources is shown as the ready rules that waited on average, beside the rule-seconds.
- **Plain views and summaries** write durations and sizes as the reports do, such as `1m 27s` and `203 MiB`.
  - Durations under a tenth of a second print in milliseconds, `42 ms`, instead of `0.0 s`, and one just under a minute as `1m 00s`, not `60.0 s`.
  - Long rule names are cut in the middle, `align_sam...ule_name`, in the plain view and the text reports as in the live view, never silently at their end; the live view ends a cut output or reason with `...` and shows its column header only as whole words.
  - The plain view of a launch that has ended drops its empty running table.
  - Failure lines off a terminal give the path of standard error relative to the current directory.
  - A rule being stopped is `stopping` and, once it has ended, `cancelled`, in every view and summary.
  - `run`, `verify` and `clean` refuse a running launch's directory alike, naming it and what to do: `another launch is running in PATH; watch it with workz watch, or run again after it ends`, or `a launch is running in PATH; verify after it ends`.
- **Build.** `build.zig.zon` pins z-toml by URL and hash, so a fresh clone builds with `zig build` alone.

### Fixed

- **Reuse.**
  - Reuse survives a reboot on btrfs, which numbers its subvolumes anew at each mount; every rule used to run again after a reboot.
  - A rule that uses a shared file input counts the input's path as an input, so rebuilding an index reruns the rules that read it.
  - A `state.json` from an earlier version is saved with the current format version.
- **`plan`, `explain` and `verify` predict what `run` does.**
  - An output whose bytes still match its stored digest counts as intact, as `run` treats it, instead of "output changed".
  - `explain` names the inputs that changed for the rule itself, and the inputs added or removed, from the inputs recorded with the rule.
  - `explain` describes a change to a list such as `PATH` entry by entry in both directions.
  - `plan --summary` counts the rules that a cutoff producer may leave reused on a line of their own.
  - `verify` says how many selected rules have no record, instead of ending with "all match" after listing them.
- **A rule that cannot be set up fails alone.** A rule whose `log` or `benchmark` file cannot be written, whose earlier output cannot be moved into `previous/`, or whose attempt cannot be prepared (a full disk, a cgroup limit that cannot be set) fails with that reason and keeps its record, and `--keep-going` runs the rest; the launch used to end with the bare error.
- **Isolation.** A run started directly by `systemd-run --scope` gets a scope of its own, instead of failing because its scope's name was taken.
- **Replacing the workz binary during a launch**, as a rebuild does, no longer keeps the launch from starting a shared input's holder or the guard of `--no-isolation` tasks: they start from the running file.
- **Shared inputs.** A directory of many files no longer risks failing to start its holder, and a holder that cannot start fails its rules with the reason instead of ending the launch.
- **Stopping and control.**
  - An attempt being stopped can no longer time out and push its kill back.
  - A shared input's holder ends with a killed engine under `--no-isolation`, as tasks do, instead of holding its pages until killed by hand; a second interrupt kills holders as well as tasks.
  - Every complete `workz control` line is applied, however many arrive at once; a line too long to be a command is skipped with a notice.
  - The engine says when `workz control` cannot reach a launch, or when the guard of `--no-isolation` tasks cannot start.
- **Containers.**
  - `plan` and `clean` give Podman the environment `run` gives it.
  - Removing the container of a failed attempt no longer holds up the engine: `podman rm` runs beside it, and the launch waits for it only at its end.
  - A mount below another mount is left out even when a sibling directory sorts between them.
- **Start order.** A rule that never completed is estimated by the median wall time of its step, as the reports compute it.
- **Labels.** A rule named with a trailing `__` keeps its whole name as its step.
- **Reports agree.** The text reports and the HTML page compute each figure once, from the same records.
  - A step whose attempt was killed for exceeding its memory is suggested at least half again the request it exceeded, not the memory it reached before the kill, and its note says so.
  - Memory sizing names its basis, process memory or cgroup peak, and the HTML steps table shows page cache apart, so a suggestion no longer sits below the peak printed beside it.
  - `--bottlenecks` shows each step's median wall time, as `--compare` and the HTML page do, instead of a total under the same name.
  - The HTML page marks a failure that a later attempt recovered from, and counts blocked rules apart from failed attempts.
  - A launch without a summary takes its elapsed time from its events, and reused rules whose records were cleaned up are counted.
  - A reused rule whose run took more than four attempts, after `workz control retry`, is found with that run.
  - Reports and the launch page read a launch's records without a stat of every file below them, a fifth faster on 2000 rules.
- **Reports lead with the answer.**
  - `--bottlenecks` says what limited the launch on its second line, under the launch line, before the bounds it rests on.
  - The HTML page of a launch that did not complete says why under its status: the reason it was refused or stopped, or its first failure. A launch that ran no attempt no longer reads `Every attempt of this launch completed`.
  - `report` on a launch without attempts says on standard error why, and for the newest launch which launch last ran some.
- **Reports claim only what the records show.**
  - CPU shares are left out when all the CPU time adds up to less than a second.
  - A resource group's advice counts each run sample once, however many rules waited at it, says how many samples it rests on, and calls fewer than three too few to judge.
  - A step's CPU use is its CPU time over the thread-seconds its runs reserved, so a long run weighs more than a short one; runs adding up to less than a second show no CPU use or character.
  - A step busy on fewer cores than it reserved is `runs fewer threads`, and one that used little CPU is `mostly idle` only where stall shares show it was not working; without them it reads `-`.
  - A step whose runs kept nine tenths or more of their threads busy is noted as possibly needing more: its request capped what it could use. The HTML page says when a suggestion rests on fewer than three runs.
  - A ready rule's wait for threads, memory, jobs or a group ends when the budget last got some of it back; the time until the engine starts the rule counts as `starting`. A launch of rules that take milliseconds no longer shows the engine's own work as a wait for threads.
  - A rule that waits while its threads and the job count are both full waits for `threads`, not `jobs`, as with one-thread rules under the default `--jobs`.
- **Damaged records.**
  - A record or event with a value that cannot be true, such as a number too large for its field, a number that is not finite or a negative count, reads as missing instead of stopping `report`, `watch` or the launch page.
  - An event that is not about a task no longer adds a rule to the views.
  - The reports say why a launch's workflow snapshot cannot be read, with its line, instead of only that it cannot.
- **Comparisons.**
  - `--compare` prints both launches' budgets and notes when the budgets, the workflow file or the engine differ, gives no change where a value is under 0.1 s or 8 MiB, and notes a step whose median wall time moved less than its runs differ among themselves.
  - `report --compare` computes each change from the values it prints, so two values that print alike show 0%, not a rounding change such as 16% between two 2 MiB peaks.
  - A step with no completed run on one side shows `-` and says on which side, instead of a change of -100%; a step reused in the launch compares the run it reused.
  - Each metric has its own BASELINE, LAUNCH and CHANGE columns.
- **Messages.**
  - A cycle error lists the rules on the cycle in order, `sort -> align -> sort`, instead of one rule that may only depend on it.
  - A rule that fails because its shared input could not be loaded prints a failure line with the reason.
  - A failed command's recorded reason quotes the last line of its standard error, `exited with status 3: align: reference index is truncated`, in its record, the summary, `status` and the reports.
  - A blocked rule's recorded reason reads as its line on the terminal does: `it needs a rule that did not complete`.
  - An option without its value says `--max-threads needs a value`, and a value that does not parse names what is expected, such as `use a size such as 512M or 60G`.
  - A run whose scope cannot create cgroups for its attempts names the controllers to delegate, and other cgroup errors name the error.
  - The refusal for an output changed outside workz gives its advice once.
  - A launch refused because recorded outputs changed names the `--rerun-rule` options for the rules that wrote them, and `status` prints that command as its next step.
  - A refusal for a request larger than the budget says which option to raise; one for a missing input names the directory input paths are relative to.
  - A command with no launch to show, and `control` on a launch that has ended, say that `workz run` starts one.
  - `plan` and `explain` show `input missing: PATH` for a rule whose input no selected rule makes and does not exist, as documented, instead of `no completed record`; `init` says that its starter reads `data/reads.txt`, which it does not create.
  - A group count below 1 names the count, an output listed twice in one rule says so, and a rule that writes into the path of the service it joins says so.
  - `workz graph` escapes quotes in the workflow name.
- **`workz init`** rejects options instead of writing a file named after them, and its starter workflow describes a resource group as units that rules take.
- **`workz completion bash`** completes every option of every command, the `control` commands, and rule names after `control stop` and `control retry`, also after `-d DIR`; file and directory names complete as bash completes them, a directory with its slash, and the hidden `dry-run` alias of `plan` is no longer offered.
- **Command line.**
  - `control stop` and `control retry` refuse a rule that the launch does not run.
  - `logs` says when the launch or attempt it was given does not exist, instead of blaming the rule, and refuses `--stdout` with `--stderr`.
  - `status --history 3x` is refused instead of showing 10 launches, and `--history` with `--json` or `--launch` is refused.
  - `status --history` names its last column `CANCELLED`, the rules a launch stopped or never started, and shows `running` for the newest launch while a run holds the working directory's lock and `unfinished` for a launch whose engine ended without recording its end, where both showed `running?`.
  - `run`'s status line counts blocked rules apart from failed ones, and it and the event lines give times as the reports do, `1m 05s` or `4 ms`.
  - `status` no longer accepts `watch`'s `--once` and `--interval`, and `watch --interval` under 100 is refused instead of raised.
  - An option is never taken as the value of the one before it: `report --launch --format html` says `--launch needs a value`.
  - A WORKFLOW that does not exist is refused with status 2 instead of standing for its directory, so `status --history x` says so instead of showing launches.
  - An unknown `--target` names the rule probably meant.

## [0.3.0] - 2026-10-25

Reports you can share and runs you can steer: an HTML report of a launch, launch comparisons and request suggestions, commands to stop, retry and inspect rules while a launch runs, per-rule work directories, and mounts for container images.

Two changes may need action:

- **Give rules a `priority` if their start order matters.** Among ready rules of equal priority, the one heading the longest chain of work now starts first, not the first in the file.
- **Delete `.workz/state.json` to go back to 0.2.0.** `state.json` now records each rule's keyed environment. workz 0.3.0 reads the state of earlier versions and reruns nothing, but 0.2.0 and earlier refuse a state file that 0.3.0 wrote; without one, every rule runs again.

### Added

- **Reports.**
  - `report --format html` writes one self-contained page for a launch: the summary, a timeline of every attempt with the critical path outlined, threads, cores and memory over the run, memory request against peak for each kind of rule, the bottleneck report, each failure with the end of its standard error, and the attempt table. It has no scripts and loads nothing from elsewhere.
  - `report --compare OTHER` compares a launch with another, named by launch ID, launch directory or working directory: elapsed time, attempts and reserved thread-seconds, then each kind of rule's median wall time, largest peak and total CPU time, with the change in percent.
  - `report --suggest` prints the suggested threads and memory for each kind of rule, as TSV or, with `--format json`, as JSON, for a workflow generator to apply.
  - `report --bottlenecks` says, for each resource group that held ready rules back, how often a waiting rule would have fitted the free threads and memory, and from 25% of the samples that a higher `max` would have started it earlier. It also lists the shared inputs with their starts, load time, declared memory and peak, and suggests a `memory` for services.
- **Steering a running launch.**
  - `control stop RULE` cancels a rule and blocks its dependents while the rest goes on, `control retry RULE` runs a failed or stopped rule again with its blocked dependents, and `control cancel` stops the launch like an interrupt. Each is recorded as a `control` event.
  - `logs RULE` prints the standard output and error of the rule's newest attempt. `--stdout` or `--stderr` keeps one stream, `--launch ID` and `--attempt N` pick an earlier attempt, and `--follow` streams a running one until it ends.
  - The interactive `watch` view lists every selected rule from the start, with a line for each shared input and the memory it holds. `i` shows a rule's request, times and live cgroup counters, `/` searches rule names, `s` changes the sort order, and `S`, `R` and `X` stop, retry or cancel.
- **Planning.**
  - `--rerun-rule RULE` on `run`, `plan` and `explain` runs the named rules even when they are reusable. Their consumers follow when the outputs change, and their changed outputs are moved to `previous/` instead of refusing the launch.
  - `plan --summary` counts the decisions by reason, for example `449 run   a producer runs`.
  - `plan` names the environment variables that changed (`environment changed: PATH`), and `explain` describes each change: entries added to or removed from a list such as `PATH`, or the old and new value.
  - Workflow errors show the offending line of the file, and errors about a rule point at its `[[rules]]` line.
- **Rules and services.**
  - `workdir` runs a rule's command in a directory below the working directory, made before each attempt, and `links` places symlinks to some of the rule's inputs there. Container rules get the work directory mounted read-write.
  - `mounts` on a container rule or a shared service places host files or directories read-only over paths in the image. On a rule, each source is also an input, so editing it runs the rule again.
  - `timeout` on a shared service limits how long it may take to become ready, and `retries` (0 to 3) starts it again when it fails before it is ready.
- **Records.**
  - `clean` removes containers that earlier launches left behind. `--keep N` also removes all but the newest N launch directories, keeping every launch that holds a rule's recorded attempt, and `--dry-run` names the launches it would remove and counts the containers.
  - `status --history [N]` prints one line for each of the last N launches: status, elapsed time, counts and any launch error.
- **Setup.** `init [FILE]` writes a commented starter workflow, and `completion bash` prints a completion script for commands, most options and rule names.

### Changed

- **Start order.** Ready rules of equal priority start in critical-path order. A rule is estimated by its last recorded wall time, else the middle wall time of its kind, else 1 s; priorities still come first.
- **Run scope.** The launcher starts the run's scope without reading the workflow. The engine reads it once, inside the scope, and protects the memory of shared inputs from reclaim with the scope's `MemoryLow`, recorded as a `memory_protected` event.
- **Swap.** Task cgroups leave the swap limit to the run's scope, which allows no swap for any group below it.
- **Speed.**
  - `validate` and every command that reads a workflow take time linear in its size.
  - Resuming a launch reads the workflow once, examines each input path once, and checks for inputs changed during the run only on the rules that ran.

### Fixed

- **Tasks of a killed engine end with it under `--no-isolation`.** A guard process holds their process groups and kills them when the engine's end of its pipe closes.
- **Redirected output.** Output of workz redirected to a file that other commands also write (`>>`, or `> log 2>&1`) is appended instead of overwriting earlier lines.
- **Container sizing.** `report --bottlenecks` sizes container rules by their cgroup peak, not by the memory of the Podman client, and measures elapsed time as the launch summary does.
- **Leftover containers.** A launch after a crash checks that the leftover containers it removed are gone, and removes them again while Podman still lists them.
- **Stuck launches.** When no ready rule can ever start and nothing is running, the launch stops with an error that names the rule and the resource it waits for.
- **Older state.** A launch records the environment of the rules it reuses, so state written by earlier versions gains it without a rerun.

## [0.2.0] - 2026-10-21

Containers: rules can run in local images through rootless Podman, a shared service can hold a large index in memory once for many rules, and `watch` becomes an interactive terminal view.

### Added

- **Container rules.** `container = "IMAGE"` runs a rule's command with `/bin/sh` inside a local image through rootless Podman.
  - Images are never pulled; each is resolved to its image ID, which is part of the rule key.
  - The container runs in the attempt's cgroup, so the memory limit, the out-of-memory kill and the counters cover the tool.
  - It has no network, no capabilities and a read-only root. The working directory and outside inputs are mounted read-only, output directories read-write.
- **Shared services.** A `[shared.NAME]` entry with `container`, `command` and `memory` runs a container whose IPC namespace container rules join, for example a STAR genome loaded once into shared memory.
  - Its memory counts once against the budget.
  - It stays up while a rule that has yet to run needs it, and gives way when a waiting rule needs its memory.
- **Interactive `watch`.** On a terminal, `watch` shows a table of rules with filters, the selected attempt's standard error or output as it grows, and a timeline of the launch.

### Changed

- **Isolation without bubblewrap.** Shell rules run in one user and network namespace created for the run, with only loopback, and `systemd-run --scope` starts the engine directly.

### Fixed

- **A killed engine ends its run.** Every task, container and service of the run ends with it: the holder of the run's network namespace kills the run's cgroup when the engine's end of its pipe closes.
- **Containers of failed attempts** are removed, including one stopped before it started.

## [0.1.1] - 2026-10-20

Large prepared workflows: input manifests that skip rehashing, refused launches that leave a record, and inputs keyed on their content.

One change needs action:

- **Expect every rule to run once.** The engine key is now 2.

### Added

- **Manifest stamps.** An `--input-manifest` entry may carry the file's identity (a stamp) beside its digest; a file whose identity matches the stamp is not read again.
- **Records of refused launches.** A refused launch keeps its launch directory, its events and a summary with the reason. The input check is recorded as an `inputs_checked` event.
- **`run --slice NAME`** places the run's scope in a slice of the caller.
- **Engine cost.** The summary records the engine's own CPU time and peak memory.

### Changed

- **Content keys.** Files with a stored digest, the input-manifest inputs and the outputs of `cutoff = true` rules, are keyed on their content: a touched or restored file with the same bytes keeps its consumers reused.

### Fixed

- **Work outside workz.** `report --bottlenecks` marks attempts whose work ran outside workz's cgroups, and gives no sizing advice for a kind of rule whose attempts mostly ran that way.
- **Waits on the critical path** come from event times, so attempts without queue records show their wait.

## [0.1.0] - 2026-10-19

The first release: an engine for prepared graphs of file-producing rules on one Linux workstation.

### Added

- **Workflow format 1** in TOML: an explicit graph of rules, each with its inputs, outputs, shell command and resource request. Unknown keys are errors that name the line and the closest known key.
- **Commands:** `validate`, `plan`, `explain`, `graph`, `run`, `watch`, `status`, `verify` and `report`.
- **Reuse by rule key:** the command, the keyed environment, the request, the declared writes, the identities of the inputs and the keys of the producers. A changed recorded output refuses the launch unless `--rerun` is given, and `--rerun` keeps the earlier bytes.
- **Scheduling** by threads, memory, jobs, resource groups and shared inputs, with priorities, retries, timeouts and a dispatch journal for crash recovery.
- **Isolation:** the run in a systemd scope with a private network, and each task in a cgroup with its memory and CPU limits. An out-of-memory kill ends every process of the task.
- **Shared inputs**, mapped once by a holder and counted once against the memory budget.
- **`cutoff = true`:** consumers of an output regenerated with the same bytes stay reused.
- **A record of every attempt:** logs, the request, the result and the cgroup counters including pressure. Events record why ready rules waited, and the run is sampled every 5 s.
- **Reports.** `report` prints one row per attempt as TSV or JSON, and `report --bottlenecks` shows the critical path, waiting by reason, request sizing per kind of rule, stall character and utilization.
