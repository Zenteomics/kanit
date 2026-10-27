This page explains how workz decides when a rule may start, what limits it runs under, and which ready rule goes first. Read it when you size requests, add resource groups or shared inputs, or want to know why a rule waited.

## The budget

A launch has three limits, set on the command line:

| Limit   | Option          | Default                          |
| ------- | --------------- | -------------------------------- |
| Threads | `--max-threads` | every online CPU                 |
| Memory  | `--max-memory`  | three quarters of the memory     |
| Jobs    | `-j`, `--jobs`  | the thread budget                |

Sizes take `K`, `M`, `G` or `T` (powers of 1024); a plain number is MiB. With isolation, the default, the run's systemd scope enforces the budget itself, so the whole run stays inside what you gave it even if a rule misbehaves ([Isolation](Running-Workflows.md#isolation)).

A rule whose request alone exceeds the budget can never start, so the launch refuses to begin:

```text
workz: rule assemble requests 32 threads; the run allows 8: raise --max-threads, or lower the rule's threads
```

## When a rule starts

A rule is ready when every rule that produces one of its inputs has completed. A ready rule starts when all of these fit, checked in this order:

1. Its threads fit in the threads not reserved by running rules.
2. Its memory, plus the memory of any of its shared inputs not yet loaded, fits in the free memory.
3. One more job fits under `--jobs`.
4. For each resource group it uses, its units fit in the group's free capacity.

The first check that fails is the reason it waits: `threads`, `memory`, `jobs` or `group:NAME`. A rule whose shared inputs are still loading waits with `loading shared inputs`. Once the budget has room, the time until the engine starts the rule counts as `starting`: the engine was recording the attempts that ended and starting the rules before it, which shows when rules take only milliseconds. Each change of reason is recorded as a `task_waiting` event, and each attempt's record keeps the seconds it waited for every reason, which `workz report` and the live view show.

Every ready rule that fits starts at once, so a large rule waiting for room never holds back a small rule behind it, and the machine stays busy. The other side of that choice: nothing is reserved for a waiting rule, so a large rule can keep waiting while smaller ones take the room as it frees. Its waiting time shows in the reports, and a smaller request or a resource group around the small rules lets it in sooner.

When nothing is running and the ready rules still cannot start, nothing will ever free room for them, so the launch stops with an error that names the rule and what it waits for.

## Which rule starts first

When several ready rules fit, workz starts them in this order:

1. Higher `priority` first (default 0).
2. Among equal priorities, the rule heading the longest estimated chain of remaining work. A rule's estimate is its wall time when it last completed, else the median wall time of completed rules of its [step](Concepts.md#steps-samples-categories-and-tools), else 1 s; a chain's length is the sum along its longest path to the end of the graph.
3. Then the rule that became ready first.
4. Then the rule that comes first in the file.

The second step starts the critical path as early as it can, which shortens a launch whose length is set by one long chain. `priority` always wins, so you can still force an order.

## Limits on each attempt

Each attempt runs in its own cgroup inside the run's scope:

- **Memory.** The request is the cgroup's hard limit (`memory.max`). When the attempt's processes need more, the kernel kills all of them together, and the attempt fails with `out of memory: could not stay within its <N> MiB request`. The limit counts page cache too; the kernel reclaims cache at the limit, which can slow an attempt that writes large files under a small request, but does not kill it.
- **CPU.** The thread request becomes a CPU quota of that many CPUs (`cpu.max`). A tool that starts more threads than requested still gets only that much CPU time; pass `$WORKZ_THREADS` to it.
- **Counters.** With isolation, workz records the cgroup's peak memory, CPU time, out-of-memory and limit events, and the time its processes stalled on CPU, memory and I/O (pressure), for every attempt.

With `--no-isolation` there are no cgroups: requests still reserve the budget, but nothing enforces them ([Running workflows](Running-Workflows.md#without-isolation)).

## Resource groups

A resource group is a named counter with a capacity. Declare it once and take units of it in a rule's request:

```toml
[resource_groups.disk]
max = 2

[[rules]]
name = "trim_s1"
# ...
[rules.resources]
threads = 4
memory = "2G"
groups = { disk = 1 }
```

At most `max` units are taken at once across all running rules; a rule whose units do not fit waits with reason `group:disk`. Use groups for limits the CPU and memory budget cannot express: rules that read from the same disk, a tool with a licence for two users, or a web service that allows a few connections. A rule may take several units, and several groups.

`workz report --bottlenecks` says, for each group that held rules back, whether the budget had room for them while they waited, which means a larger `max` would have started them earlier ([Reports](Reports.md#what-limited-the-launch)).

## Shared inputs

A shared input is a large read-only file or directory, usually an index, that many rules read at the same time:

```toml
[shared.index]
path = "ref/bowtie2"

[[rules]]
name = "align_s1"
input = ["trimmed/s1_1.fq.gz", "trimmed/s1_2.fq.gz"]
# ...
[rules.resources]
threads = 8
memory = "2G"
shared = ["index"]
```

Before the first rule that uses it starts, workz starts a holder process that maps every file of `path` and touches each page, so the files sit in memory once, charged to the holder. Its size, rounded up to whole pages, counts against the memory budget once, however many rules use it. Tools that map their index, such as `bowtie2 --mm`, then share those pages instead of each loading a copy.

- The holder stays while a rule that has yet to run needs it, and stops after its last user. When a waiting rule needs memory that only an idle holder occupies, the holder gives way.
- With isolation, workz sets the run scope's `MemoryLow` at the start of the launch to the total size of its shared inputs and services, so other work on the machine does not push an index out of memory.
- A shared file input is also an input of every rule that uses it, so rebuilding the index reruns them; there is no need to list it in `input` as well.
- A shared input may not contain the output of a rule.

For an index a tool loads into System V shared memory, such as a STAR genome, use a [shared service](Containers-and-Services.md#shared-services) instead.

## Reading the waits

On the demo workflow from [Reports](Reports.md), with six samples through qc, trim, align and count on 10 threads, the bottleneck report shows where ready rules waited:

```text
waiting for resources (ready rules that waited, on average over the launch, and their rule-seconds)
  threads                             3.0 rules     2m 24s
  group:disk                          1.2 rules     58.2 s
  loading shared inputs              <0.1 rules      0.2 s

resource groups (while their rules waited)
  disk                              58.2 s waited; 1 run sample while they waited, too few to judge
```

Most of the waiting was for threads, three ready rules at a time on average, and the same report says the thread budget limited this launch: more threads would help, if the machine has them. The waits for the `disk` group held only one run sample, taken every 5 s, so the report does not judge them. From three samples on, it gives the share in which a waiting rule would have fitted the free threads and memory: from 25%, a larger `max` for the group would help, if the disk can take it; below that, the budget was full and a higher `max` would not help much.
