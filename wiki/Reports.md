`workz report` turns a launch's records into answers: what each attempt used, what limited the launch, what each step should request, and how two launches differ. Every report reads `.workz/` only, so you can run it during a launch, after it, or on a launch from last week. The examples on this page come from one demo launch: six samples through qc, trim, align and count, then a report, 25 rules on a budget of 10 threads and 6 GiB, with a 600 MiB shared index. Every rule declares its step, sample, category and tool ([Concepts](Concepts.md#steps-samples-categories-and-tools)).

Reports look at a launch in two scopes:

- **The pipeline**: the latest completed run of every rule, whether this launch ran it or reused it from an earlier launch. Steps, time per category, tool and sample, request suggestions and comparisons use it, so a launch that reran one script still describes the whole pipeline.
- **The launch**: the attempts this launch started. The attempt table, the critical path, waiting for resources and the use of the budget use it.

## What each attempt used

`workz report` prints one row per attempt of the newest launch, or of `--launch ID`, as TSV:

```text
rule	attempt	status	wall_s	cpu_s	cpu_efficiency	threads	memory_mib	peak_mib	max_rss_mib	peak_per_request	oom_kills	limit_events	waited_s	wait_reason	cpu_stall	memory_stall	io_stall	delegated	reason	step	sample	category	tool
align_S1	1	completed	17.232	47.165	0.91	3	1500	403.9	401.8	0.27	0	0	0.000	-	0.002	0.000	0.000	false	-	align	S1	alignment	bowtie2
align_S2	1	completed	20.307	56.117	0.92	3	1500	405.1	402.8	0.27	0	0	0.183	loading shared inputs	0.002	0.000	0.000	false	-	align	S2	alignment	bowtie2
trim_S4	1	failed	0.003	0.002	0.46	2	512	1.1	4.0	0.00	0	0	5.031	group:disk	0.002	0.000	0.000	false	exited with status 1	trim	S4	trimming	fastp
trim_S4	2	completed	3.005	2.976	0.50	2	512	1.4	3.7	0.00	0	0	5.014	threads	0.001	0.000	0.000	false	-	trim	S4	trimming	fastp
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
| `delegated`        | boolean | work most likely ran outside workz         |
| `reason`           | text    | why the attempt failed, or `-`             |
| `step`, `sample`   | text    | the rule's step and sample, or `-`         |
| `category`, `tool` | text    | the rule's category and tool, or `-`       |

- Stalls come from the kernel's pressure counters for the attempt's cgroup: the share of time some of its processes waited for CPU, memory or I/O.
- A missing number is `NA`, which R and pandas read as missing; a missing text is `-`. For launches run with `--no-isolation`, `peak_mib`, `peak_per_request` and the stall columns are `NA`, and `oom_kills` and `limit_events` are 0.
- `--format json` prints the same attempts as a JSON array with the same field names, numbers unrounded and `null` for no value, and two more fields: `started_ns`, the start in nanoseconds since the Unix epoch, and `directory`, the attempt's record directory.
- `-o FILE` writes any report to a file instead of standard output.

## What limited the launch

`workz report --bottlenecks` reads the same records and the event stream and explains where the time went:

```text
launch 20261026T212300.580-b26da10c: 48.9 s elapsed; 26 attempts in this launch, 392 thread-seconds reserved

critical path (final attempts, from the first to the one that ended last)
  at   10.1 s  trim_S4                                  ran    3.0 s, waited    5.0 s, after 1 earlier attempt
  at   27.4 s  align_S4                                 ran   17.4 s, waited   14.4 s
  at   44.8 s  count_S4                                 ran    2.0 s, waited    0.0 s
  at   46.9 s  report                                   ran    2.0 s, waited    0.0 s
  4 rules: 24.4 s running, 19.4 s waiting for resources

waiting for resources (rule-seconds that ready attempts waited)
  threads                             2m 24s
  group:disk                          58.2 s
  loading shared inputs                0.2 s

resource groups (while their rules waited)
  disk                              58.2 s waited; in 100% of the samples a waiting rule fitted the free threads and memory: a higher max would have started it earlier

steps (the latest completed run of every rule)
  STEP                            RUNS     MEDIAN  CPU USE  THREADS    REQUEST       USED       PEAK    SUGGEST  CHARACTER
  qc                                 6      3.0 s      99%        1    256 MiB    4.0 MiB    1.7 MiB     64 MiB  CPU-bound
  trim                               6      4.0 s      49%        2    512 MiB    4.0 MiB    1.9 MiB     64 MiB  mixed; requests 448 MiB more than the suggestion; uses about 1.0 of 2 threads
  align                              6     17.3 s      91%        3    1.5 GiB    405 MiB    405 MiB    512 MiB  CPU-bound; requests 988 MiB more than the suggestion
  count                              6      2.0 s      99%        1    256 MiB    4.0 MiB    1.7 MiB     64 MiB  CPU-bound
  report                             1      2.0 s      99%        1    256 MiB    4.0 MiB    1.6 MiB     64 MiB  CPU-bound
  USED: the largest resident memory of one process, or the cgroup peak for rules with shared inputs or containers
  PEAK: the memory charged to the rule's cgroup, page cache included; libraries already in memory count in USED only

time per category (the latest run of every rule)
  CATEGORY                       STEPS  RUNS       WALL        CPU  CPU SHARE
  alignment                          1     6     1m 44s     4m 44s        84%
  trimming                           1     6     24.1 s     23.8 s         7%
  qc                                 1     6     18.0 s     17.8 s         5%
  quantification                     1     6     12.0 s     11.9 s         4%
  report                             1     1      2.0 s      2.0 s         1%

time per tool (the latest run of every rule)
  TOOL                           STEPS  RUNS       WALL        CPU  CPU SHARE
  bowtie2                            1     6     1m 44s     4m 44s        84%
  fastp                              1     6     24.1 s     23.8 s         7%
  fastqc                             1     6     18.0 s     17.8 s         5%
  featureCounts                      1     6     12.0 s     11.9 s         4%
  multiqc                            1     1      2.0 s      2.0 s         1%

samples (the latest run of every rule), most CPU time first
  SAMPLE                         STEPS  RUNS       WALL        CPU  SLOWEST STEP
  S5                                 4     4     30.3 s     1m 06s  align 20.3 s
  S2                                 4     4     28.3 s     1m 04s  align 20.3 s
  S1                                 4     4     27.3 s     57.1 s  align 17.2 s
  S4                                 4     4     25.4 s     55.1 s  align 17.4 s
  S3                                 4     4     24.4 s     48.3 s  align 14.3 s
  S6                                 4     4     22.4 s     46.4 s  align 14.4 s

shared inputs
  NAME                           TYPE     STARTS       LOAD     MEMORY       PEAK    SUGGEST
  genome                         mapped        1      0.2 s    600 MiB    603 MiB          -

use of the budget (run samples every 5 s)
  threads reserved 8.2 of 10 on average; CPU cores in use 7.4 on average
  memory reserved 4.2 GiB of 6.0 GiB on average; the run's memory in use, page cache included, peaked at 1.3 GiB
```

Read it from the top:

- **Critical path.** The final attempts of this launch that ended last, traced back through the producer that ended last, listed from the first. `at` is when each started, `waited` how long it was ready before it started, and `after N earlier attempts` marks a rule that failed first: here the first attempt of `trim_S4` failed. The path waited 19.4 s for resources against 24.4 s running, so a larger budget could save up to 19 s. When a critical path waits little, only faster rules or a shorter chain make the launch shorter.
- **Waiting for resources.** The waits of all ready attempts, added up by what they waited for, so the total can exceed the elapsed time. Threads dominate: more threads would shorten this launch if the machine has them.
- **Resource groups.** For each group that held rules back, the share of run samples in which a rule waiting for the group would have fitted the free threads and memory, counted per waiting rule. From 25%, the report says a higher `max` would have started them earlier; below that, it says the budget was full and a higher `max` would not help much. Here it was 100%: the group alone held them back.
- **Steps.** Each [step](Concepts.md#steps-samples-categories-and-tools) in the order of the workflow's graph: its runs, median wall time, CPU use (CPU time over wall time times threads, at most 100%), thread and memory request, memory used, cgroup peak, suggested memory request and character. `USED` is what the suggestion sizes. `PEAK` can be smaller than `USED` for small commands: shared libraries already in memory count in a process's resident memory but are charged to the cgroup that loaded them. Notes after the character flag out-of-memory kills, a request more than twice the suggestion and at least 256 MiB above it, a step that reached its limit through page cache without being killed, and a step that uses under half the threads it reserves.
- **Time per category and per tool.** The steps, runs, wall time and CPU time of each category and each tool, most CPU time first, with its share of all CPU time. Here alignment took 84% of it: a faster aligner would save the most.
- **Samples.** Each sample's steps, runs, wall time and CPU time, most CPU time first, and the step it spent longest in. When that step took at least 1.5 times its median and 2 s more, the line says how many times the median: that sample is the one to look at. Here S5 and S2 aligned for 20.3 s against a median of 17.3 s, which is not enough to be marked.
- **Shared inputs.** Each shared input's type, starts, load time, declared memory and peak. Services get a suggested `memory` ([Sizing a service](Containers-and-Services.md#sizing-a-service)).
- **Use of the budget.** The average threads and memory reserved, the CPU cores in use, and the run's peak memory in use, from the samples taken every 5 s while rules run.

The character names what a step spent its time on, judged from its stall shares and CPU use: `memory-throttled` (stalled on memory at least 20% of the time), `I/O-bound` (on I/O at least 30%), `CPU-starved` (waiting for CPU at least 30%, usually more threads than its quota), `CPU-bound` (CPU use at least 70%), `mostly waiting` (CPU use under 30%), or `mixed`. Without stall data, in launches run with `--no-isolation`, it is `CPU-bound` at a CPU use of 70% or more and `-` otherwise.

An attempt that completed after at least half a second while using under a tenth of its CPU request, and less memory than a twentieth of its request or 64 MiB, whichever is larger, is counted as **delegated**: its command most likely handed the work to another supervisor, such as a systemd service or a container runtime outside workz. Its counters do not describe the work. A note counts the delegated attempts, and when most runs of a step are delegated, the steps section shows no memory for it and gives no sizing advice.

## Request sizing

`workz report --suggest` prints the suggested request for each step, for a workflow generator to apply:

```text
step	runs	threads	threads_used	suggest_threads	memory_mib	used_mib	used_basis	peak_mib	suggest_mib	note
qc	6	1	0.99	1	256	4	process	2	64	measured
trim	6	2	0.99	1	512	4	process	2	64	measured
align	6	3	2.76	3	1500	405	cgroup	405	512	measured
count	6	1	0.99	1	256	4	process	2	64	measured
report	1	1	0.99	1	256	4	process	2	64	measured
```

- `runs` counts the step's rules with a completed run, the latest of each.
- `threads_used` is the largest CPU time over wall time of any run. `suggest_threads` rounds it up, ignoring a surplus under 0.05, and never exceeds the current request.
- `used_mib` is the largest memory any run used, as `used_basis` says: `process` is the largest resident memory of one process; `cgroup` is the cgroup peak, for rules that use shared inputs or containers, whose work the processes' resident memory misses.
- `peak_mib` is the largest cgroup peak, page cache included.
- `suggest_mib` is `used_mib` plus 20%, rounded up to a multiple of 64 MiB, and at least 64 MiB.
- `note` is `measured`; `out_of_memory` when an attempt was killed for exceeding its memory, and the suggestion is then at least half again the request it exceeded; or `delegated` when most runs handed their work outside workz, and the suggestion keeps the current request.
- `--format json` prints the same as a JSON array.

Here `trim` reserves 2 threads and 512 MiB but used 1 thread and 4 MiB, and `align` reserves 1500 MiB for 405 MiB used. Applying the suggestions lets more rules run at once on the same budget. Suggestions come from what the measured inputs needed; size for the largest input you expect, not the smallest you measured.

## Comparing launches

`workz report --compare OTHER` compares the newest launch, or `--launch ID`, with another one, named by launch ID, by launch directory, or by a working directory for its newest launch. Here the demo ran again with `--rerun` on 14 threads instead of 10 (paths shortened):

```text
baseline .../.workz/launches/20261026T212300.580-b26da10c
launch   .../.workz/launches/20261026T212349.502-401d88e4

                            BASELINE     LAUNCH   CHANGE
  elapsed s                     48.9       45.1     -8%
  attempts                        26         25
  thread-seconds reserved        392        396      1%

per step (latest run of every rule)
                                       WALL S, MEDIAN            PEAK MiB, LARGEST           CPU S, TOTAL
  STEP                           RUNS  BASELINE  LAUNCH CHANGE  BASELINE  LAUNCH CHANGE  BASELINE  LAUNCH CHANGE
  qc                                6      3.00    3.01      0%         2       2      0%      17.8    17.7     -1%
  trim                              6      4.01    4.01      0%         2       2      0%      23.8    23.8      0%
  align                             6     17.31   17.66      2%       405     404      0%     283.5   282.5      0%
  count                             6      2.00    2.00      0%         2       2      0%      11.9    11.9      0%
  report                            1      2.01    2.01      0%         2       2      0%       2.0     2.0      0%
```

Each step compares the median wall time of its runs, the largest cgroup peak and the total CPU time, each with the baseline's value, the launch's and the change. Four more threads saved 8% of the elapsed time while every step ran as before, so the gain came from scheduling alone. The bottleneck report of the second launch shows the next limits: waiting for `group:disk` grew from 58 s to 1m 36s, and ready rules now also waited 57.6 s for memory.

- A step whose work ran outside workz in either launch shows `-` for its memory and CPU changes and says in which launch.
- A step with no completed run on one side shows `-` for that side and says which.
- A step reused in the launch compares the run it reused, and says so.

## The HTML report

`workz report --format html -o report.html` writes the launch as one self-contained page, with no scripts and nothing loaded from elsewhere, to open in a browser or attach to a message. The page is drawn as an engineering sheet: grid paper in a light color scheme, a blueprint in a dark one, following the reader's setting. It prints cleanly.

![The top of an HTML report: a title block with the status stamp, elapsed time, rules done, the pipeline's samples and steps, CPU and memory against the budget and the engine's cost; FIG. 1, the pipeline as boxes for qc, trim, align, count and report wired in graph order, each with a filled cell per rule; and FIG. 2, the CPU time split by category, then per tool.](images/report.png)

The sheet holds, in order:

1. **Title block.** The launch's name, status, ID, start time and engine; the elapsed time and how much of the critical path waited; the rules done, ran and reused; the pipeline's samples by steps; the CPU cores in use and peak memory against the budget; and the engine's own CPU time and memory. A launch error follows it.
2. **FIG. 1, Pipeline.** A box for each step, in columns by graph depth, wired at right angles to the steps it reads from. Each box gives the step's tool, median wall time and rules done, and a cell for each rule in its state: done, reused, running, waiting for resources, not run, failed, blocked or cancelled. Hovering a cell names the rule.
3. **FIG. 2, Where the CPU time went.** The CPU time as one bar split by category, or by step when no rule declares a category, then per tool.
4. **FIG. 3, Samples by step**, when rules have samples. A row per sample and a column per step in pipeline order, with each sample's CPU time. Each cell is shaded by the run's wall time against the median of its step, so a dark cell is a slow sample in any column. `!` marks a run at least 1.5 times its median and 2 s longer, `x` a failed rule and `/` a blocked one. Rules without a sample share the last row.
5. **TABLE 1, Steps.** Each step with its category, tool and samples, its runs and median wall time, the spread of its wall times, the cores it used of the threads it requested, the memory it used and the page cache in its peak against its request, and the suggested request.
6. **FIG. 4, Timeline.** One labelled row per attempt: the wait for resources as a thin bar, then the run in the color of its category, or red if it failed, with the critical path outlined. A dimension line gives the elapsed time.
7. **FIG. 5, Use of the budget.** Threads reserved against CPU cores in use, and memory reserved against memory in use, over the launch, with the budget as a dashed line.
8. **FIG. 6, What limited the launch.** The critical path rule by rule, the rule-seconds that ready attempts waited for each resource, and the resource groups.
9. **TABLE 2, Failures.** Every failed or cancelled attempt with the last 40 lines of its standard error, marked when a later attempt completed.
10. **TABLE 3, Attempts.** Every attempt with its step and sample, which scrolls under a fixed header.

Figures 1 to 3 and Table 1 cover the pipeline, so a launch that reused rules still shows every sample and step, with each reused rule hatched; the rest cover the launch itself. Each category, or each step when no rule declares a category, keeps one color across the sheet, on the left edge of its pipeline box, its timeline bars and its matrix column. Up to eight get a color each, in pipeline order; with more, the first seven keep theirs and the rest share gray as "other". Hovering a cell, dot or bar gives its numbers.

Every launch also keeps this page as `report.html` in its launch directory: `run` draws it as the launch starts, every 5 s while it runs, and once more at the end ([Running workflows](Running-Workflows.md#starting-a-launch)). While the launch runs, the page reloads itself every 5 s, its title block says RUNNING, the timeline measures the time so far, and running attempts are open bars; the last page stops reloading. `workz report --format html` draws the same page on demand, for any launch.
