`workz report` turns a launch's records into answers: what each attempt used, what limited the launch, what each step should request, how two launches differ, and what produced the results, for a methods section. Every report reads `.workz/` only, so you can run it during a launch, after it, or on a launch from last week. The examples on this page come from one demo launch: six samples through qc, trim, align and count, then a report, 25 rules on a budget of 10 threads and 6 GiB, with a 600 MiB shared index. Every rule declares its step, sample, category and tool ([Concepts](Concepts.md#steps-samples-categories-and-tools)).

Reports look at a launch in two scopes:

- **The pipeline**: the latest completed run of every rule, whether this launch ran it or reused it from an earlier launch. Steps, time per category, tool and sample, request suggestions and comparisons use it, so a launch that reran one script still describes the whole pipeline.
- **The launch**: the attempts this launch started. The attempt table, the critical path, waiting for resources and the use of the budget use it.

The reports use these terms:

- **Attempt**: one run of a rule's command. A rule that is retried makes several in one launch.
- **Waiting once ready**: the time from a rule's last producer ending to its start, by what it waited for: `threads`, `memory`, `jobs`, a group, `loading shared:NAME`, or `starting` for the engine's own time after the budget had room.
- **Held**: on the critical path, the time a rule waited after the rule before it on the path ended, for its other producers.
- **Rule-seconds**: seconds added up over rules, so ten rules waiting for 3 s make 30 rule-seconds; divided by the elapsed time, the number of rules waiting on average.
- **Bound**: a time the launch could not be shorter than, given the work its attempts did, such as its critical path or its reserved thread-seconds over the thread budget.
- **CPU use**: CPU time over the thread-seconds reserved: 100% kept every requested thread busy.
- **Idle**: an attempt that ran for half a second or more on almost none of its request, waiting or handing its work to a process outside its cgroup; its counters size nothing.
- **Run sample**: what the engine records every 5 s while a launch runs: the threads and memory reserved, and the CPU and memory in use.

## What each attempt used

`workz report` prints one row per attempt of the newest launch, or of `--launch ID`, as TSV:

```text
rule	attempt	status	wall_s	cpu_s	cpu_efficiency	threads	memory_mib	peak_mib	max_rss_mib	peak_per_request	oom_kills	limit_events	waited_s	wait_reason	cpu_stall	memory_stall	io_stall	idle	reason	step	sample	category	tool
align_S1	1	completed	17.136	47.295	0.9200	3	1500	405.4	403.2	0.2703	0	0	0.000	-	0.001	0.000	0.000	false	-	align	S1	alignment	bowtie2
align_S2	1	completed	20.013	56.076	0.9340	3	1500	402.7	403.5	0.2684	0	0	0.199	loading shared:genome	0.001	0.000	0.000	false	-	align	S2	alignment	bowtie2
trim_S4	1	failed	0.002	0.003	0.5147	2	512	1.3	3.7	0.0024	0	0	5.053	group:disk	0.003	0.000	0.000	false	exited with status 1: trim: temporary failure writing trimmed/S4.fq	trim	S4	trimming	fastp
trim_S4	2	completed	3.073	2.980	0.4849	2	512	1.4	3.8	0.0027	0	0	5.008	threads	0.000	0.000	0.001	false	-	trim	S4	trimming	fastp
```

| Column             | Unit    | Meaning                                    |
| ------------------ | ------- | ------------------------------------------ |
| `wall_s`, `cpu_s`  | seconds | elapsed and CPU time of the attempt        |
| `cpu_efficiency`   | ratio   | CPU time over wall time times threads      |
| `threads`          | threads | request                                    |
| `memory_mib`       | MiB     | request                                    |
| `peak_mib`         | MiB     | cgroup peak, page cache included           |
| `max_rss_mib`      | MiB     | largest resident set of one process        |
| `peak_per_request` | ratio   | `peak_mib` over `memory_mib`               |
| `oom_kills`        | count   | out-of-memory kills in the cgroup          |
| `limit_events`     | count   | times the cgroup reached its limit         |
| `waited_s`         | seconds | ready but not started                      |
| `wait_reason`      | text    | what it waited for longest                 |
| `cpu_stall`        | ratio   | share of wall time stalled on CPU          |
| `memory_stall`     | ratio   | share of wall time stalled on memory       |
| `io_stall`         | ratio   | share of wall time stalled on I/O          |
| `idle`             | boolean | used almost none of its request            |
| `reason`           | text    | why the attempt failed, or `-`             |
| `step`, `sample`   | text    | the rule's step and sample, or `-`         |
| `category`, `tool` | text    | the rule's category and tool, or `-`       |

- Stalls come from the kernel's pressure counters for the attempt's cgroup: the share of time some of its processes waited for CPU, memory or I/O.
- Times have three decimals, in seconds; ratios four; memory one, in MiB. `--format json` keeps full precision.
- A missing number is `NA`, which R and pandas read as missing; a missing text is `-`. For launches run with `--no-isolation`, `peak_mib`, `peak_per_request` and the stall columns are `NA`, and `oom_kills` and `limit_events` are 0.
- `--format json` prints the same attempts as a JSON array with the same field names, numbers unrounded and `null` for no value, and two more fields: `started_ns`, the start in nanoseconds since the Unix epoch, and `directory`, the attempt's record directory.
- `-o FILE` writes any report to a file instead of standard output.

## What limited the launch

`workz report --bottlenecks` reads the same records and the event stream and explains where the time went:

```text
launch 20261027T224512.478-40c9943e: 48.4 s elapsed; 26 attempts in this launch, 388 thread-seconds reserved
the thread budget limited this launch: it took 48.4 s, 25% more than its rules' thread requests need at that limit

what limited the launch (the attempts it made could not take less than any of these)
    critical path                   29.3 s  4 rules in a chain of work
  > threads                         38.8 s  8.0 of 10 threads reserved on average
    CPU time                        33.9 s  7.0 of 10 cores busy on average
    memory                          32.4 s  4.0 GiB of 6.0 GiB reserved on average
    group disk                      21.1 s  0.9 of 2 units held on average
    engine                           0.1 s  the engine's own CPU time: checks, scheduling and records

critical path (the longest chain of work in this launch, and when each rule waited once ready)
  at    5.1 s  trim_S5                                  ran    5.0 s, waited    5.1 s
  at   22.2 s  align_S5                                 ran   20.3 s, waited   12.1 s
  at   42.5 s  count_S5                                 ran    2.0 s, waited     0 ms
  at   46.3 s  report                                   ran    2.0 s, waited     0 ms, held 1.8 s for producers off the path
  4 rules: 29.3 s of work, 17.2 s waiting once ready, 1.9 s held for producers off the path

waiting for resources (ready rules that waited, on average over the launch, and their rule-seconds)
  threads                             3.0 rules     2m 23s
  group:disk                          1.2 rules     58.7 s
  loading shared:genome              <0.1 rules      0.2 s
  starting                           <0.1 rules      54 ms
  starting: the budget had room; the engine was recording ended attempts and starting other rules

resource groups (while their rules waited)
  disk                              58.7 s waited; 1 run sample while they waited, too few to judge

steps (the latest completed run of every rule)
  STEP                            RUNS     MEDIAN  CPU USE  THREADS    REQUEST       USED       PEAK    SUGGEST  CHARACTER
  qc                                 6      3.0 s      99%        1    256 MiB    4.1 MiB    1.9 MiB     64 MiB  CPU-bound; kept its thread busy: it may use more if given them
  trim                               6      4.0 s      49%        2    512 MiB    4.0 MiB    1.9 MiB     64 MiB  runs fewer threads; requests 448 MiB more than the suggestion; uses about 1.0 of 2 threads
  align                              6     17.1 s      92%        3    1.5 GiB    405 MiB    405 MiB    512 MiB  CPU-bound; requests 988 MiB more than the suggestion; kept all 3 of its threads busy: it may use more if given them
  count                              6      2.0 s      99%        1    256 MiB    4.8 MiB    1.9 MiB     64 MiB  CPU-bound; kept its thread busy: it may use more if given them
  report                             1      2.0 s      99%        1    256 MiB    4.8 MiB    1.5 MiB     64 MiB  CPU-bound; kept its thread busy: it may use more if given them
  USED: the largest resident memory of one process, or the cgroup peak for rules with shared inputs or containers
  PEAK: the memory charged to the rule's cgroup, page cache included; libraries already in memory count in USED only

time per category (the latest run of every rule)
  CATEGORY                       STEPS  RUNS       WALL        CPU  CPU SHARE
  alignment                          1     6     1m 43s     4m 44s        84%
  trimming                           1     6     24.1 s     23.8 s         7%
  qc                                 1     6     18.0 s     17.9 s         5%
  quantification                     1     6     12.0 s     11.9 s         4%
  report                             1     1      2.0 s      2.0 s         1%

time per tool (the latest run of every rule)
  TOOL                           STEPS  RUNS       WALL        CPU  CPU SHARE
  bowtie2                            1     6     1m 43s     4m 44s        84%
  fastp                              1     6     24.1 s     23.8 s         7%
  fastqc                             1     6     18.0 s     17.9 s         5%
  featureCounts                      1     6     12.0 s     11.9 s         4%
  multiqc                            1     1      2.0 s      2.0 s         1%

samples (the latest run of every rule), most CPU time first
  SAMPLE                         STEPS  RUNS       WALL        CPU  SLOWEST STEP
  S5                                 4     4     30.3 s     1m 06s  align 20.3 s
  S2                                 4     4     28.0 s     1m 04s  align 20.0 s
  S1                                 4     4     27.1 s     57.2 s  align 17.1 s
  S4                                 4     4     25.1 s     55.2 s  align 17.1 s
  S3                                 4     4     24.1 s     48.2 s  align 14.1 s
  S6                                 4     4     22.1 s     46.3 s  align 14.1 s

shared inputs
  NAME                           TYPE     STARTS  USERS       LOAD       HELD     MEMORY       PEAK    SUGGEST
  genome                         mapped        1      6      0.2 s     41.3 s    600 MiB    602 MiB          -

use of the budget (run samples every 5 s)
  threads reserved 8.2 of 10 on average; CPU cores in use 7.5 on average
  memory reserved 4.2 GiB of 6.0 GiB on average; the run's memory in use, page cache included, peaked at 1.2 GiB
```

Read it from the top:

- **What limited the launch.** Lower bounds on the elapsed time of the attempts the launch made, failed ones included. The launch could not be shorter than:
  - its critical path, the longest chain of work through the graph;
  - the work a limit of the budget carried divided by that limit, such as reserved thread-seconds over the thread budget, with memory counting shared inputs while they are held;
  - the CPU time its rules used over the threads;
  - the engine's own CPU time, as the engine works on one thread.

  The use column says how full each limit was on average. `>` marks the largest bound, and the line under the launch line says how far the launch ran over it; under the thread budget it also says how much of the reserved threads the rules kept busy, and which step left the most of its threads unused. A launch shorter than 2 s is not judged: starting and recording rules weigh too much in it. A launch close to a budget bound needs a larger budget, or less work, to finish sooner; one close to its critical path needs faster rules on the path; one far over every bound lost time to waits that the order of rules caused, as the critical path then shows.

- **Critical path.** The rules of the longest chain of work, each weighing every attempt it made, as retries run one after another; this is the chain the scheduler ranks rules by. `at` is when a rule first started, `waited` how long it was ready before it started, and `held` how long it waited, after the rule before it on the path ended, for producers off the path; a rule retried after a pause shows the time between its attempts. The summary line adds the time from the end of the path to the end of the launch, while rules off the path still ran: work, waits, holds, the time between attempts and that last stretch make up the elapsed time.
- **Waiting for resources.** How many ready rules waited for each resource, on average over the launch, and the rule-seconds they waited added up, which can exceed the elapsed time.
- **Resource groups.** For each group that held rules back, the share of the run samples, taken every 5 s while some rule waited for the group, in which the free threads and memory had room for one of the waiting rules; each sample counts once. With fewer than three samples it says they are too few to judge. From 25%, the report says a higher `max` would have started them earlier; below that, it says the budget was full and a higher `max` would not help much. Here the waits for `disk` held only one sample, too few to judge.
- **Steps.** Each [step](Concepts.md#steps-samples-categories-and-tools) in the order of the workflow's graph: its runs, median wall time, CPU use (CPU time over wall time times threads, at most 100%), thread and memory request, memory used, cgroup peak, suggested memory request and character. `USED` is what the suggestion sizes. `PEAK` can be smaller than `USED` for small commands: shared libraries already in memory count in a process's resident memory but are charged to the cgroup that loaded them. Notes after the character flag out-of-memory kills, a request more than twice the suggestion and at least 256 MiB above it, a step that reached its limit through page cache without being killed, and a step that uses under half the threads it reserves, or one that kept all of them busy.
- **Time per category and per tool.** The steps, runs, wall time and CPU time of each category and each tool, most CPU time first, with its share of all CPU time. Here alignment took 84% of it: a faster aligner would save the most.
- **Samples.** Each sample's steps, runs, wall time and CPU time, most CPU time first, and the step it spent longest in. When that step took at least 1.5 times its median and 2 s more, the line says how many times the median: that sample is the one to look at. Here S5 and S2 aligned for 20 s against a median of 17.1 s, which is not enough to be marked.
- **Shared inputs.** Each shared input's type, starts, the rules that used it, load time, time held from loading to release, declared memory and peak. Services get a suggested `memory` ([Sizing a service](Containers-and-Services.md#sizing-a-service)).
- **Use of the budget.** The average threads and memory reserved, the CPU cores in use, and the run's peak memory in use, from the samples taken every 5 s while rules run.

The character names what a step spent its time on, judged from its stall shares and its CPU use, its CPU time over the thread-seconds its runs reserved. The first that applies:

- `memory-throttled`: stalled on memory at least 20% of the time.
- `I/O-bound`: stalled on I/O at least 30% of the time.
- `CPU-starved`: waiting for CPU at least 30% of the time, usually with more threads than its quota.
- `CPU-bound`: CPU use at least 70%.
- `runs fewer threads`: busy on at least 0.7 cores but under 60% of the two or more threads it reserved.
- `mostly idle`: CPU use under 30%.
- `mixed`: anything else.

Without stall data, in launches run with `--no-isolation`, `mostly idle` and `mixed` read `-`, as stalls alone tell waiting from work. Runs adding up to less than a second show `-` for CPU use and character: too little to judge.

An attempt that completed after at least half a second while using under a tenth of its CPU request, and less memory than a twentieth of its request or 64 MiB, whichever is larger, is counted as **idle**: its command waited (a sleep, the network, a lock) or handed the work to a process outside its cgroup, such as a systemd service. Either way its counters size nothing. A note counts the idle attempts, and when most runs of a step are idle, the steps section shows no memory for it and gives no sizing advice.

## Request sizing

`workz report --suggest` prints the suggested request for each step: on a terminal as a table with units, and to a file or a pipe as this TSV, for a workflow generator to apply:

```text
step	runs	threads	threads_used	suggest_threads	memory_mib	used_mib	used_basis	peak_mib	suggest_mib	note	at_thread_limit
qc	6	1	0.99	1	256	4	process	2	64	measured	true
trim	6	2	0.99	1	512	4	process	2	64	measured	false
align	6	3	2.80	3	1500	405	cgroup	405	512	measured	true
count	6	1	0.99	1	256	5	process	2	64	measured	true
report	1	1	0.99	1	256	5	process	2	64	measured	true
```

- `runs` counts the step's rules with a completed run, the latest of each. A suggestion from one or two runs covers only the inputs those runs had; the HTML page says how many runs it rests on.
- `threads_used` is the largest CPU time over wall time of any run. `suggest_threads` rounds it up, ignoring a surplus under 0.05, and never exceeds the current request.
- `used_mib` is the largest memory any run used, as `used_basis` says: `process` is the largest resident memory of one process; `cgroup` is the cgroup peak, for rules that use shared inputs or containers, whose work the processes' resident memory misses.
- `peak_mib` is the largest cgroup peak, page cache included.
- `suggest_mib` is `used_mib` plus 20%, rounded up to a multiple of 64 MiB, and at least 64 MiB.
- `note` is `measured`; `out_of_memory` when an attempt was killed for exceeding its memory, and the suggestion is then at least half again the request it exceeded; or `idle` when most runs were idle, and the suggestion keeps the current request.
- `at_thread_limit` is `true` when the runs kept nine tenths or more of their threads busy over their time: the request capped them, so `suggest_threads` cannot be more than the request, and the program may use more threads if given them. The steps section notes it after the character.
- `--format json` prints the same as a JSON array.

Here `trim` reserves 2 threads and 512 MiB but used 1 thread and 4 MiB, and `align` reserves 1500 MiB for 405 MiB used. Applying the suggestions lets more rules run at once on the same budget. Suggestions come from what the measured inputs needed; size for the largest input you expect, not the smallest you measured.

## Comparing launches

`workz report --compare OTHER` compares the newest launch, or `--launch ID`, with another one, named by launch ID, by launch directory, or by a working directory for its newest launch. Here the demo ran again with `--rerun` on 14 threads instead of 10 (paths shortened):

```text
baseline .../.workz/launches/20261027T224512.478-40c9943e
launch   .../.workz/launches/20261027T224738.820-a4bc8528
budget   10 threads, 6.0 GiB, 10 jobs against 14 threads, 6.0 GiB, 14 jobs
note: the budgets differ, so the elapsed time compares the budgets as well as the work

                            BASELINE     LAUNCH   CHANGE
  elapsed s                     48.4       44.3     -8%  budgets differ
  attempts                        26         25
  thread-seconds reserved        388        388      0%

per step (latest run of every rule)
                                       WALL S, MEDIAN            PEAK MiB, LARGEST           CPU S, TOTAL
  STEP                           RUNS  BASELINE  LAUNCH CHANGE  BASELINE  LAUNCH CHANGE  BASELINE  LAUNCH CHANGE
  qc                                6      3.00    3.00      0%         2       2       -      17.9    17.9      0%  wall time within its runs' spread
  trim                              6      4.04    4.01     -1%         2       2       -      23.8    23.9      0%  wall time within its runs' spread
  align                             6     17.10   17.09      0%       405     404      0%     283.6   283.6      0%  wall time within its runs' spread
  count                             6      2.00    2.00      0%         2       2       -      11.9    11.9      0%
  report                            1      2.00    2.01      0%         2       2       -       2.0     2.0      0%
```

- The lines above the table give both budgets; notes say when the budgets, the workflow file or the engine differ, as the elapsed time then compares those too.
- Each step compares the median wall time of its runs, the largest cgroup peak and the total CPU time: the baseline's value, the launch's and the change.
- A change is left out where either value is too small to compare: under 0.1 s of wall or CPU time, under 8 MiB of memory.
- A step with three or more runs on a side whose median moved less than its runs differ among themselves (half their range over the median) says its wall time is within its runs' spread: one launch on each side cannot show such a change.
- A step whose runs were mostly idle in either launch shows `-` for its memory and CPU changes and says in which launch.
- A step with no completed run on one side shows `-` for that side and says which.
- A step reused in the launch compares the run it reused, and says so.

Here four more threads saved 8% of the elapsed time while every step ran as before: the gain came from the larger budget and the order it allowed. The bottleneck report of the second launch shows why no more was gained: the memory budget limits it, with the 600 MiB shared index held the whole time, and waiting for `group:disk` grew from 58.7 s to 1m 36s.

## Methods

`workz report --methods` describes what produced the results in the working directory, for the methods section of a paper or a lab notebook. It reads `state.json` and the records of the attempts it points to, so it covers every recorded rule, whichever launch ran it, including a rule since removed from the workflow whose record remains. A small workflow whose `join` step was rerun in a second launch:

```text
Results in .../methods: 3 rules, finished from 2026-10-27T22:48:50.487Z to 2026-10-27T22:48:50.827Z

workflow
  methods 2.1, file sha256:06a779f6e3ef44eb3afd039a8b6a5757592592fd880b33f9e5e1ab1c0dcd9436
engine
  workz 0.5.0 sha256:19706d99a048b684dba6ede34e8292c8d2f987b773d9226b030297e1c2e5c726
launches
  20261027T224850.478-ecfdb505 (2 rules)
  20261027T224850.818-1786a936 (1 rule)

tools
  upper: upper 1.4.2
    host
    version  echo upper 1.4.2
    steps    up (2 rules)
  (no tool label)
    host
    steps    join (1 rule)

steps
  up: 2 rules, 1 thread and 64 MiB each
    up_s1: echo one > s1.txt
  join: 1 rule, 1 thread and 64 MiB
    join: cat s1.txt s2.txt > all.txt
```

- **workflow**, **engine** and **launches** list each workflow file (its `[workflow]` name and version, and the digest of its bytes), engine and launch that made the results, with their rules when there are several.
- **tools** groups rules by their `tool` label, image and version command. A container rule's tool names its image reference and the image ID it ran; a host rule's says `host`. The version is the first line its rule's `version` command printed when it exited 0 ([Writing workflows](Writing-Workflows.md#tool-versions)); `(no version recorded)` follows a command that failed, did not run, or ran in a launch since removed.
- **steps** lists each step in the order its rules first finished, with its requests and the command of its first rule by name; `request not recorded` marks a step whose attempt records are gone.
- `--format json` gives the same as one JSON object, and `-o FILE` writes it to a file.

## The HTML report

`workz report --format html -o report.html` writes the launch as one self-contained page, with no scripts and nothing loaded from elsewhere, to open in a browser or attach to a message. The page is drawn as an engineering sheet, ink on grid paper in light and a charcoal sheet in dark. It follows the reader's color scheme until the theme tag at its corner picks auto, light or dark, and it always prints in light.

![The top of an HTML report: a theme tag at the corner set to auto, a title block with the status stamp, elapsed time, rules done, the pipeline's samples and steps, CPU and memory against the budget and the engine's cost; FIG. 1, the pipeline as boxes for qc, trim, align, count and report wired in graph order, each with a filled cell per rule; and FIG. 2, the CPU time split by category, then per tool.](images/report.png)

The sheet holds, in order:

1. **Title block.** The launch's name, status, ID, start time and engine, with, under the status of a launch that did not complete, the reason it was refused or stopped or its first failure; the elapsed time and what limited it; the rules done, ran and reused; the pipeline's samples by steps; the CPU cores in use and peak memory against the budget; and the engine's own CPU time and memory. A launch error follows it.
2. **FIG. 1, Pipeline.** A box for each step, in columns by graph depth, wired at right angles to the steps it reads from. Each box gives the step's tool, median wall time and rules done, and a cell for each rule in its state: done, reused, running, waiting for resources, not run, failed, blocked or cancelled. Hovering a cell names the rule. Below the steps, each shared input is a box with the memory it holds once and its users: a dashed wire runs into each step that maps or joins it, and a dotted wire from the step writing what a service loads. A checkbox above the figure hides that layer; print shows it.
3. **FIG. 2, Where the CPU time went.** The CPU time as one bar split by category, or by step when no rule declares a category, then per tool.
4. **FIG. 3, Samples by step**, when rules have samples. A row per sample and a column per step in pipeline order, with each sample's CPU time. Each cell is shaded by the run's wall time against the median of its step, so a dark cell is a slow sample in any column. `!` marks a run at least 1.5 times its median and 2 s longer, `x` a failed rule and `/` a blocked one. Rules without a sample share the last row.
5. **TABLE 1, Steps.** Each step with its category, tool and samples, its runs and median wall time, the spread of its wall times, the cores it used of the threads it requested, the memory it used and the page cache in its peak against its request, and the suggested request.
6. **FIG. 4, Timeline.** One labelled row per attempt: the wait for resources as a thin bar, then the run in the color of its category, or red if it failed, with the critical path outlined. A dimension line gives the elapsed time.
7. **FIG. 5, Use of the budget.** Threads reserved against CPU cores in use, and memory reserved against memory in use, over the launch, with the budget as a dashed line; the memory that shared inputs hold, once, is its own band at the bottom of the reserved memory.
8. **FIG. 6, What limited the launch.** The bounds on the elapsed time against it, with the largest marked and a sentence on what limited the launch; the critical path rule by rule, with when each was held for producers off the path, waited for resources and ran; the ready rules that waited for each resource; and the resource groups.
9. **TABLE 2, Failures.** Every failed or cancelled attempt with the last 40 lines of its standard error, marked when a later attempt completed.
10. **TABLE 3, Attempts.** Every attempt with its step and sample, which scrolls under a fixed header.

Figures 1 to 3 and Table 1 cover the pipeline, so a launch that reused rules still shows every sample and step, with each reused rule hatched; the rest cover the launch itself. Each category, or each step when no rule declares a category, keeps one color across the sheet, on the left edge of its pipeline box, its timeline bars and its matrix column. Up to eight get a color each, in pipeline order; with more, the first seven keep theirs and the rest share gray as "other". Hovering a cell, dot or bar gives its numbers.

Every launch also keeps this page as `report.html` in its launch directory: `run` draws it as the launch starts, every 5 s while it runs, and once more at the end ([Running workflows](Running-Workflows.md#starting-a-launch)). On a large launch it waits longer between drawings, so that drawing takes at most a twentieth of the engine's time. While the launch runs, the page reloads itself every 5 s, its title block says RUNNING, the timeline measures the time so far, and running attempts are open bars; the last page stops reloading. `workz report --format html` draws the same page on demand, for any launch. A theme picked on a page that reloads itself lasts only while the browser keeps the page's form state; the reader's color scheme is the lasting choice.
