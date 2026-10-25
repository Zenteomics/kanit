`workz report` turns a launch's records into answers: what each attempt used, what limited the launch, what each kind of rule should request, and how two launches differ. Every report reads `.workz/` only, so you can run it during a launch, after it, or on a launch from last week. The examples on this page come from one demo launch: six samples through qc, trim, align and count, then a report, 25 rules on a budget of 10 threads and 6 GiB, with a 600 MiB shared index.

## What each attempt used

`workz report` prints one row per attempt of the newest launch, or of `--launch ID`, as TSV:

```text
rule	attempt	status	wall_s	cpu_s	cpu_efficiency	threads	memory_mib	peak_mib	max_rss_mib	peak_per_request	oom_kills	limit_events	waited_s	wait_reason	cpu_stall	memory_stall	io_stall	delegated	reason
align_S1	1	completed	17.153	47.169	0.92	3	1500	403.8	403.2	0.27	0	0	0.000	-	0.001	0.000	0.000	false	-
align_S2	1	completed	20.373	56.331	0.92	3	1500	404.5	402.0	0.27	0	0	0.223	loading shared inputs	0.001	0.000	0.000	false	-
trim_S4	1	failed	0.002	0.002	0.52	2	512	1.0	3.7	0.00	0	0	5.026	group:disk	0.005	0.000	0.000	false	exited with status 1
trim_S4	2	completed	3.005	2.967	0.49	2	512	1.9	3.7	0.00	0	0	5.006	threads	0.001	0.000	0.000	false	-
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

- Stalls come from the kernel's pressure counters for the attempt's cgroup: the share of time some of its processes waited for CPU, memory or I/O.
- For launches run with `--no-isolation`, `peak_mib`, `peak_per_request` and the stall columns are `NA`, and `oom_kills` and `limit_events` are 0.
- `--format json` prints the same attempts as a JSON array, with times unrounded and a few more fields, such as the attempt directory.

## What limited the launch

`workz report --bottlenecks` reads the same records and the event stream and explains where the time went:

```text
launch 20261026T033653.780-bb9b10ee: 48.6 s elapsed, 26 attempts, 159.8 task-seconds

critical path (last task back to the start)
  at     10.0 s  trim_S4                                      ran      3.0 s, waited   10.0 s
  at     27.3 s  align_S4                                     ran     17.2 s, waited   14.3 s
  at     44.5 s  count_S4                                     ran      2.0 s, waited    0.0 s
  at     46.5 s  report                                       ran      2.0 s, waited    0.0 s
  4 steps: 24.2 s running, 24.3 s waiting for resources

waiting for resources (ready but not started)
  threads                              143.6 s
  group:disk                            58.3 s
  loading shared inputs                  0.2 s

resource groups (while their rules waited)
  disk                                58.3 s waited; in 100% of the samples a waiting rule fitted the free threads and memory: a higher max would have started it earlier

requests per kind of rule (completed attempts)
  KIND                             N   WALL S   MEM REQ  MAX RSS   PEAK  SUGGEST  THREADS  CPU EFF  CHARACTER
  align                            6    103.7     1500M     404M    405M     512M        3     0.91  CPU-bound; requests 988M more than its peak needs
  count                            6     12.0      256M       4M      2M      64M        1     0.99  CPU-bound
  qc                               6     18.0      256M       4M      2M      64M        1     0.99  CPU-bound
  report                           1      2.0      256M       4M      2M      64M        1     0.99  CPU-bound
  trim                             6     24.0      512M       4M      2M      64M        2     0.49  mixed; requests 448M more than its peak needs; uses about 1.0 of 2 threads

shared inputs
  NAME                           KIND     STARTS   LOAD S   MEMORY     PEAK  SUGGEST
  genome                         mapped        1      0.2     600M     603M        -

utilization (run samples every 5 s)
  threads reserved 8.0 of 10 on average; CPU in use 7.5 cores
  memory reserved 4208 of 6144 MiB on average; run cgroup peaked at 1282 MiB
```

Read it from the top:

- **Critical path.** The chain of rules that ended last, traced back to the start. Here it spent as long waiting for resources (24.3 s) as running (24.2 s), so the launch was limited by the budget, not by the length of its longest chain. When a critical path waits little, only faster rules or a shorter chain make the launch shorter.
- **Waiting for resources.** The total time ready rules waited, by reason. Threads dominate: more threads would shorten this launch if the machine has them.
- **Resource groups.** For each group that held rules back, the share of run samples in which a rule waiting for the group would have fitted the free threads and memory, counted per waiting rule. From 25%, the report says a larger `max` would have started them earlier; below that, it says the budget was full and a larger group would not help much. Here it was 100%: the group alone held them back.
- **Requests per kind of rule.** For each [kind](Concepts.md#kinds-of-rules): attempts, total wall time, memory request, largest process RSS and cgroup peak, suggested request, thread request, mean CPU efficiency, and a character. Notes after the character flag out-of-memory kills, requests far above the peak, a kind that reached its limit through page cache without being killed, and a kind that uses under half the threads it reserves.
- **Shared inputs.** Each shared input's starts, load time, declared memory and peak. Services get a suggested `memory`.
- **Utilization.** The average threads and memory reserved, the CPU cores in use, and the run cgroup's peak, from the samples taken every 5 s while rules run.

The character names what a kind of rule spent its time on, judged from its stall shares and CPU efficiency: `memory-throttled` (stalled on memory at least 20% of the time), `I/O-bound` (on I/O at least 30%), `CPU-starved` (waiting for CPU at least 30%, usually more threads than its quota), `CPU-bound` (CPU efficiency at least 0.7), `mostly waiting` (efficiency under 0.3), or `mixed`. Without stall data, in launches run with `--no-isolation`, it is `CPU-bound` at efficiency 0.7 or more and `-` otherwise.

An attempt that completed after at least half a second while using under a tenth of its CPU request, and less memory than a twentieth of its request or 64 MiB, whichever is larger, is counted as **delegated**: its command most likely handed the work to another supervisor, such as a systemd service or a container runtime outside workz. Its counters do not describe the work. A note counts the delegated attempts, and when most attempts of a kind are delegated, the report gives no sizing advice for that kind.

## Request sizing

`workz report --suggest` prints the suggested request for each kind of rule, for a workflow generator to apply:

```text
kind	attempts	threads	threads_used	suggest_threads	memory_mib	peak_mib	suggest_mib	delegated
align	6	3	2.77	3	1500	405	512	false
count	6	1	0.99	1	256	4	64	false
qc	6	1	0.99	1	256	4	64	false
report	1	1	0.99	1	256	4	64	false
trim	6	2	0.99	1	512	4	64	false
```

- `peak_mib` is the largest memory any completed attempt of the kind used: its process RSS, or its cgroup peak for rules that use shared inputs or containers, where the RSS misses the work.
- `suggest_mib` is that peak plus 20%, rounded up to a multiple of 64 MiB, and at least 64 MiB.
- `threads_used` is the largest CPU time over wall time of any completed attempt. `suggest_threads` rounds it up, ignoring a surplus under 0.05, and never exceeds the current request.
- `--format json` prints the same as a JSON array.

Here `trim` reserves 2 threads and 512 MiB but used 1 thread and 4 MiB, and `align` reserves 1500 MiB for a 405 MiB peak. Applying the suggestions lets more rules run at once on the same budget. Suggestions come from what the measured inputs needed; size for the largest input you expect, not the smallest you measured.

## Comparing launches

`workz report --compare OTHER` compares the newest launch, or `--launch ID`, with another one, named by launch ID, by launch directory, or by a working directory for its newest launch. Here the demo ran again with `--rerun` on 14 threads instead of 10 (paths shortened):

```text
baseline .../.workz/launches/20261026T033653.780-bb9b10ee
launch   .../.workz/launches/20261026T033841.917-25bd675f

                          BASELINE     LAUNCH   CHANGE
  elapsed s                   48.6       43.8    -10%
  attempts                      26         25
  reserved thread-s            391        392      0%

per kind of rule (completed attempts)
  KIND                             N   WALL S (MEDIAN)          PEAK MiB (MAX)           CPU S (TOTAL)
  align                            6    17.16   17.40      1%      405     405     -0%    284.1   284.4      0%
  count                            6     2.00    2.00      0%        2       2      0%     11.9    11.9      0%
  qc                               6     3.00    3.00      0%        2       2      0%     17.9    17.8     -0%
  report                           1     2.01    2.01      0%        2       2     -0%      2.0     2.0      0%
  trim                             6     4.01    4.01      0%        2       2     -1%     23.8    23.8     -0%
```

Four more threads saved 10% of the elapsed time, while every kind of rule ran exactly as before, so the gain came from scheduling alone. The bottleneck report of the second launch shows the next limit: waiting for `group:disk` grew from 58 to 72 s.

Kinds whose work ran outside workz in either launch are marked, and their memory and CPU comparisons do not describe the work. A kind that was reused in the newer launch has no completed attempts there, so it shows `0` and a change of `-100%`; compare launches that ran the same rules, for example with `--rerun`.

## The HTML report

`workz report --format html > report.html` writes the launch as one self-contained page, with no scripts and nothing loaded from elsewhere, to open in a browser or attach to a message:

![The top of an HTML report: launch facts, a timeline of every attempt with waiting shown before each bar and the critical path outlined, and charts of threads and memory reserved against cores and memory in use.](images/report.png)

The page holds, in order:

1. The launch's status, elapsed time, rule counts, the engine's own cost, the budget and the number of attempts.
2. A timeline with one bar per attempt, waiting drawn before it, colored by result, the critical path outlined; hovering a bar names its rule.
3. Threads reserved against CPU cores used, and memory reserved against memory in use, over the launch.
4. Memory request against largest peak for each kind of rule, with the suggested request.
5. The bottleneck report, as above.
6. Every failed or cancelled attempt with the last 40 lines of its standard error.
7. The attempt table.
