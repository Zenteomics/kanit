While a launch runs, and after it ends, three commands show it: `watch` for the live view, `status` for its summary, and `logs` for a rule's output. They read only the records in `.workz/`, so they work from any terminal and never slow the launch down.

## The live view

Run `workz watch` in the working directory, or `workz watch path/to/workflow.toml` from elsewhere, while `workz run` works in another terminal:

![The workz watch view of a launch 18 seconds in: four rules running with their current and peak memory, six waiting for threads, eight completed and seven pending; the header shows 10 of 10 threads reserved and a shared genome index holding 601.6 MiB.](images/watch.png)

The header gives the launch ID, its status and elapsed time, how many rules are done, running, waiting, pending and failed, the threads and memory reserved against the budget, the CPU cores and memory the run uses, and one line for each shared input with the memory it holds. Below it is a table of every selected rule:

- **STATUS** and **RULE**: running rules first, then waiting, failed, done and pending ones.
- **ATT**: the attempt number.
- **TIME**: how long the rule has run, or how long it has waited to start.
- **MEM** and **PEAK**: the memory the running attempt uses now and its peak so far, read live from its cgroup; for finished rules, the recorded peak.
- **LAST OUTPUT / REASON**: the last line the running attempt wrote to standard error, or to standard output if it wrote nothing to standard error; for other rules, why the rule waits or failed.

The view stays open after the launch ends, so you can look through it; <kbd>q</kbd> leaves.

### Keys

- <kbd>j</kbd> and <kbd>k</kbd>, or the arrow keys, move the selection; <kbd>PgUp</kbd>, <kbd>PgDn</kbd>, <kbd>g</kbd> and <kbd>G</kbd> jump.
- <kbd>Enter</kbd> follows the selected attempt's standard error as it grows; <kbd>o</kbd> switches to standard output.
- <kbd>i</kbd> shows the selected rule in detail: its request, when it became ready and started, its CPU time and peak, and while it runs, its cgroup's current memory, near-limit events and stall times.
- <kbd>t</kbd> draws a timeline of the launch.
- <kbd>a</kbd> shows all rules, <kbd>r</kbd> running and retrying ones, <kbd>w</kbd> waiting and pending ones, <kbd>f</kbd> failed, blocked and cancelled ones, and <kbd>d</kbd> done ones.
- <kbd>/</kbd> searches rule names; <kbd>Enter</kbd> keeps the search and <kbd>Esc</kbd> clears it.
- <kbd>s</kbd> cycles the order: status, elapsed time, peak memory, name.
- <kbd>S</kbd> stops the selected rule, <kbd>R</kbd> retries it, and <kbd>X</kbd> cancels the launch, as [`workz control`](Running-Workflows.md#steering-a-running-launch) does. <kbd>X</kbd> asks no confirmation.
- <kbd>q</kbd> or <kbd>Esc</kbd> goes back, or leaves from the table; <kbd>Ctrl</kbd>+<kbd>C</kbd> leaves.

### Timeline

<kbd>t</kbd> draws every rule on one time axis: `.` while it waited to start, `>` while it runs, `=` when it ran and completed, `!` where it failed and `x` where it was cancelled.

![The timeline of the same launch after it ended: qc rules wait while align rules with a higher priority run, and each count rule follows its alignment.](images/watch-timeline.png)

Here the align rules, with `priority = 10`, start as soon as their trim is done, while the qc rules wait for threads until the alignments finish. The critical path ran through `trim_S4`, `align_S4` and `count_S4` to `report`.

### Off a terminal

When its output is not a terminal, or with `--once`, `watch` prints a plain view of the running rules instead, again at every refresh until the launch ends:

```text
launch 20261026T033653.780-bb9b10ee  elapsed 00:00:19
25 selected: 7 pending, 6 waiting, 4 running, 8 completed, 8 done
shared genome: ready

RUNNING                                      ATT  ELAPSED     MEM NOW  MEM PEAK  LAST OUTPUT
align_S1                                       1  00:00:13  202.6 Mi  403.8 Mi
align_S2                                       1  00:00:15  202.7 Mi  404.5 Mi
qc_S3                                          1  00:00:01  940.0 Ki    1.4 Mi
align_S3                                       1  00:00:05  203.5 Mi  403.6 Mi
```

Failed rules follow under `FAILED`, each with its reason and the path of its standard error. `--interval MS` sets the refresh period (default 1000 ms). A launch whose engine was killed never records its end, so the repeating view does not stop by itself; `watch --once` and `status` show such a launch, and `status --history` marks it `running?`. Each refresh reads only the events added since the last one, so watching a launch of thousands of rules costs little.

## status

`workz status` prints the newest launch's summary once it has ended, the content `workz run` ends with, as indented JSON ([summary.json](Records.md#summaryjson)); while it runs, it prints the plain view above once.

`workz status --history [N]` prints one line for each of the last N launches (default 10), newest first:

```text
LAUNCH                          STATUS        ELAPSED   DONE  FAILED  OTHER
20261026T033841.917-25bd675f    completed     00:00:43    25       0      0
20261026T033743.455-61b4e2d5    completed     00:00:24    25       0      0
20261026T033653.780-bb9b10ee    completed     00:00:48    25       0      0
```

`DONE` counts completed and reused rules, `FAILED` failed and blocked ones, and `OTHER` cancelled and unstarted ones. A launch that ended with an error shows it at the end of its line; one still running, or killed before it wrote its summary, shows `running?`.

## logs

`workz logs RULE` prints the standard output and error of the rule's newest attempt: in the newest launch that ran the rule, or else the attempt recorded for it. Here, the first attempt of a rule that failed once and then succeeded:

```sh
workz logs trim_S4 --attempt 1
```

```text
==> .../attempts/trim_S4/001/stdout.log <==
==> .../attempts/trim_S4/001/stderr.log <==
trim: temporary failure writing trimmed/S4.fq
```

- `--stderr` or `--stdout` prints one stream, without the headers.
- `--attempt N` picks attempt N in the newest launch that ran the rule, and `--launch ID` looks in that launch instead.
- `--follow` (`-f`) keeps printing a running attempt's output until it ends.

Every attempt's files stay in its attempt directory, `.workz/launches/<ID>/attempts/<rule>/<NNN>/`, until you remove the launch ([Records](Records.md)).
