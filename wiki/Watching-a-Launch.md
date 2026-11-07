While a launch runs, and after it ends, three commands show it: `watch` for the live view, `status` for its summary, and `logs` for a rule's output. They read the records in `.workz/` from a separate process. Reading and drawing still use CPU, memory and I/O shared with the launch.

## The live view

Run `kanit watch` in the working directory, or `kanit watch path/to/workflow.toml` from elsewhere, while `kanit run` works in another terminal:

![The kanit watch view of a launch 15 seconds in: a progress bar at 6 of 25 rules done, gauges for 6 of 6 threads reserved and 2.2 of 6.0 GiB of memory, a shared genome index holding 602 MiB, and a table with three running rules first, each with its CPU use and a memory bar against its request, then the rules waiting for threads.](images/watch.png)

The header holds four gauges:

- **progress**: a bar of the selected rules, split into done, running, waiting and failed, with the count of each.
- **threads**: the threads reserved against the budget, and the CPU cores the run keeps busy.
- **memory**: the memory reserved against the budget, and the memory the run uses.
- **shared**: one line for each shared input, with its state, the memory it holds, and how many rules have used it.

Below it is a table of every selected rule, running rules first, then waiting, failed, done and pending ones:

- **STATUS** and **RULE**: a long name is shortened in the middle, so `align_sample_0042_lane_3` keeps both of its ends.
- **ATT**: the attempt number.
- **TIME**: how long the rule has run, or how long it has waited to start.
- **CPU**: the cores the attempt uses against the threads it requested, such as `2.9/3`; for a finished rule, the average over its run.
- **MEMORY**: for a running rule, a bar and the memory its cgroup uses now against its request, such as `203M/1.5G`; the bar turns yellow from 70% of the request and red from 90%. For a finished rule, its recorded peak against its request.
- **LAST OUTPUT / REASON**: the last line the running attempt wrote to standard error, or to standard output if it wrote nothing to standard error; for other rules, why the rule waits or failed.

On a narrow terminal the memory bar goes first, then the CPU column, then the memory value. The selection stays on the top row until you move it, so the busiest rule stays selected as rules finish. The view stays open after the launch ends, so you can look through it; <kbd>q</kbd> leaves.

> [!TIP]
> Set `NO_COLOR=1`, or use a terminal with `TERM=dumb`, for a view without colors: bars are then drawn with characters, `#` for done and `>` for running.

### Keys

<kbd>?</kbd> shows every key in the view itself.

- <kbd>j</kbd> and <kbd>k</kbd>, or the up and down arrows, move the selection; <kbd>Space</kbd> and <kbd>b</kbd>, or <kbd>PgDn</kbd> and <kbd>PgUp</kbd>, move it a page; <kbd>g</kbd> and <kbd>G</kbd>, or <kbd>Home</kbd> and <kbd>End</kbd>, jump to the first and last rule.
- <kbd>Enter</kbd>, <kbd>l</kbd> or the right arrow follows the selected attempt's standard error as it grows, with lines that mention an error in red and a warning in yellow; <kbd>o</kbd> switches to standard output.
- <kbd>i</kbd> shows the selected rule in detail: its request, the rules it reads from (`after`) and that read from it (`before`), the shared inputs it holds, when it became ready and started, gauges of its CPU and memory against the request, how often it reached its memory limit, its stall times, and its last lines of output.
- <kbd>t</kbd> draws a timeline of the launch.
- <kbd>a</kbd> shows all rules, <kbd>r</kbd> running and retrying ones, <kbd>w</kbd> waiting and pending ones, <kbd>f</kbd> failed, blocked and cancelled ones, and <kbd>d</kbd> done ones.
- <kbd>/</kbd> searches rule names; <kbd>Enter</kbd> keeps the search and <kbd>Esc</kbd> clears it.
- <kbd>s</kbd> cycles the order: status, elapsed time, peak memory, name.
- <kbd>S</kbd> stops the selected rule and <kbd>R</kbd> retries it, as [`kanit control`](Running-Workflows.md#steering-a-running-launch) does. <kbd>X</kbd> cancels the launch when pressed a second time within 3 s.
- <kbd>q</kbd> or <kbd>Esc</kbd> goes back, or leaves from the table; <kbd>h</kbd> or the left arrow goes back to the table; <kbd>Ctrl</kbd>+<kbd>C</kbd> leaves.

### Timeline

<kbd>t</kbd> draws every rule on one time axis, with ticks such as `30s`, `1m` and `1m30s`. A dotted stretch is the time a rule waited to start; then a bar shows its run, green when it completed, cyan while it runs, red where it failed and magenta where it was cancelled. Without colors the bar is drawn with `=`, `>`, `!` and `x`.

![The timeline of the same launch after it ended: the qc and trim rules run first, each align rule waits for three free threads, and each count rule follows its alignment.](images/watch-timeline.png)

Here the qc and trim rules, which need one or two threads, run first. Each align rule, with `priority = 10`, starts before any other ready rule once three threads are free, so the alignments wait for threads while smaller rules fill the gaps. The critical path ran through `trim_S5`, `align_S5` and `count_S5` to `report`.

### Off a terminal

When its output is not a terminal, `watch` prints a plain view of the running rules instead, again at every refresh until the launch ends; `--once` prints it once (one long last output shortened):

```text
launch 20261107T060905.136-0b96682a  running for 19.0 s
25 selected: 8 pending, 4 waiting, 3 running, 10 completed, 10 done
shared genome: ready

RUNNING                                      ATT   ELAPSED   MEM NOW  MEM PEAK  LAST OUTPUT
align_S2                                       1    15.8 s   203 MiB   403 MiB  Mapping reads: 3 threads
trim_S4                                        2     0.9 s   1.1 MiB   1.6 MiB  Read1 before filterin...
qc_S6                                          1     0.9 s   1.4 MiB   1.6 MiB  Started analysis of S6.fq
```

- The second line counts the selected rules in each state; `done` adds the completed and reused ones.
- Failed rules follow under `FAILED`, each with its reason and the path of its standard error; once the launch has ended, the view drops the running table.
- `--interval MS` sets the refresh period (default 1000 ms, at least 100), and `--launch ID` shows an earlier launch instead of the newest.
- If the engine ends without a final summary, the plain repeating view reports the unfinished launch and exits with failure. The interactive view marks it unfinished.
- The tracker reads newly appended events between refreshes; drawing the task table and reading resource counters and log tails still take work.

## status

`kanit status` prints the newest launch's summary once it has ended, or with `--launch ID` an earlier launch's. On a terminal it is the same short report `kanit run` ends with: the outcome and counts, each failed rule with its reason, which quotes the last line of its error output, the launch's page, and the commands to look further:

```text
  failed   after 3.0 s: 2 completed, 0 reused, 1 failed, 1 blocked
 failures  align_S1  exited with status 3: align: reference index is truncated
 blocked   count_S1
 page      .workz/launches/20261107T060918.810-57b00e74/report.html
 next      kanit logs align_S1   the output of the failed attempt
           run the same command again: rules that completed are reused
```

A launch that completed lists its three slowest rules instead of failures. Off a terminal, or with `--json`, `status` prints the launch's [summary.json](Records.md#summaryjson) as written.

While the launch runs, `status` prints the plain view above once on a terminal. Off it, or with `--json`, it prints the summary's fields so far, with `"status": "running"`, so a script can poll one command whatever the launch's state (shortened here):

```json
{"engine":"kanit 0.7.0 sha256:...",...,"status":"running","counts":{"completed":10,...},...}
```

`kanit status --history [N]` prints one line for each of the last N launches (default 10), newest first:

```text
LAUNCH                          STATUS         ELAPSED  DONE  FAILED  CANCELLED
20261107T061157.192-d1b5ca16    completed       1m 00s    25       0          0
20261107T060905.136-0b96682a    completed       1m 13s    25       0          0
```

`DONE` counts completed and reused rules, `FAILED` failed and blocked ones, and `CANCELLED` the rules it stopped or never started. A launch that ended with an error shows it at the end of its line. The newest launch shows `running` while a run holds the working directory's lock; a launch whose engine ended without recording its end, as when killed, shows `unfinished`.

## logs

`kanit logs RULE` prints the standard output and error of the rule's newest attempt: in the newest launch that ran the rule, or else the attempt recorded for it. Here, the first attempt of a rule that failed once and then succeeded:

```sh
kanit logs trim_S4 --attempt 1
```

```text
==> .../attempts/trim_S4/001/stdout.log <==
==> .../attempts/trim_S4/001/stderr.log <==
trim: temporary failure writing trimmed/S4.fq
```

- `--stderr` or `--stdout` prints one stream, without the headers.
- `--attempt N` picks attempt N in the newest launch that ran the rule, and `--launch ID` looks in that launch instead.
- `--follow` (`-f`) prints the output as it grows until the attempt ends, or its launch stops running.

Every attempt's files stay in its attempt directory, `.workz/launches/<ID>/attempts/<rule>/<NNN>/`, until you remove the launch ([Records](Records.md)).
