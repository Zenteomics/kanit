This page explains how kanit decides when a rule may start, what limits it runs under, and which ready rule goes first. Read it when you size requests, add resource groups or shared inputs, or want to know why a rule waited.

## The budget

A launch has three limits, set on the command line:

| Limit   | Option          | Default                          |
| ------- | --------------- | -------------------------------- |
| Threads | `--max-threads` | every online CPU                 |
| Memory  | `--max-memory`  | three quarters of the memory     |
| Jobs    | `-j`, `--jobs`  | the thread budget                |

Sizes take `K`, `M`, `G` or `T` (powers of 1024), up to `1024T`; a plain number is MiB. With isolation, the default, the run's systemd scope enforces the CPU budget and a memory limit of the task budget plus 256 MiB for engine headroom ([Isolation](Running-Workflows.md#isolation)).

A rule whose request alone exceeds the budget can never start, so the launch refuses to begin:

```text
kanit: rule assemble requests 32 threads; the run allows 8: raise --max-threads, or lower the rule's threads
```

The check covers the rules expected to run, decided as `kanit plan` decides them, and the shared inputs they use. A reused rule needs no task reservation. Shared inputs of other selected rules are also measured where possible, in case those rules need to run after all; unused inputs are not loaded. `kanit plan --budget` previews requests and reuse before a launch ([Command reference](Command-Reference.md#plan)).

## When a rule starts

A rule can become ready when its selected producers have completed or been reused and its own result cannot be reused. Admission requires all of these to fit, checked in this order:

1. Its threads fit in the threads not reserved by running rules.
2. Its memory, plus the memory of any of its shared inputs not already held for another rule, fits in the free memory. A container rule also reserves 32 MiB for its Podman client ([Containers](Containers-and-Services.md#container-rules)).
3. One more job fits under `--jobs`.
4. For each resource group it uses, its units fit in the group's free capacity.

The first check that fails is the reason it waits: `threads`, `memory`, `jobs` or `group:NAME`. A rule whose shared inputs are still loading waits with `loading shared:NAME`, naming the first that is not ready. Once the budget has room, the time until the engine starts the rule counts as `starting`, while the engine records attempts that ended and starts other rules; it shows when rules take only milliseconds. Each change of reason is recorded as a `task_waiting` event, and each attempt's record keeps the seconds it waited for every reason, which `kanit report` and the live view show.

Each admission pass considers every ready rule in scheduling order and admits those that fit. A rule that cannot fit does not block consideration of smaller ones. Admission is not instantaneous execution: a staged rule reserves resources while its shared inputs load, and process startup and record writes take time. The scheduler does not preempt tasks or reserve future capacity for a large waiter, so smaller tasks can keep delaying it. Reservations are declared requests, not measurements of CPU use; filling the budget does not guarantee a busy CPU.

When nothing is running and the ready rules still cannot start, nothing will ever free room for them, so the launch stops with an error that names the rule and what it waits for.

## Which rule starts first

When several ready rules fit, kanit starts them in this order:

1. Higher `priority` first (default 0).
2. Among equal priorities, the rule heading the longest estimated chain of remaining work. A rule's estimate is its wall time when it last completed, else the median wall time of completed rules of its [step](Concepts.md#steps-samples-categories-and-tools), else 1 s; a chain's length is the sum along its longest path to the end of the graph.
3. Then the rule that became ready first.
4. Then the rule that comes first in the file.

The second step favors long estimated chains. It can help when those estimates describe the work, but does not guarantee a shorter launch or an optimal schedule. `priority` takes precedence over the estimate.

## Limits on each attempt

Each attempt runs in its own cgroup inside the run's scope:

- **Memory.** The request is the cgroup's hard limit (`memory.max`). When the attempt's processes need more, the kernel kills all of them together, and the attempt fails with `out of memory: could not stay within its <N> MiB request`. The limit counts page cache too; the kernel reclaims cache at the limit, which can slow an attempt that writes large files under a small request, but does not kill it.
- **CPU.** The thread request becomes a CPU quota of that many CPUs (`cpu.max`). A tool that starts more threads than requested still gets only that much CPU time; pass `$WORKZ_THREADS` to it.
- **Counters.** With isolation, kanit records the cgroup's peak memory, CPU time, out-of-memory and limit events, and the time its processes stalled on CPU, memory and I/O (pressure), for every attempt.

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

At most `max` units are reserved at once across admitted rules, including those waiting for shared inputs; a rule whose units do not fit waits with reason `group:disk`. Use groups for limits the CPU and memory budget cannot express, such as concurrent disk-heavy tasks or a tool with a licence for two users. They count declared units, not measured bandwidth. A rule may take several units and several groups.

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

Before the first rule that uses it starts, kanit starts a holder process that maps every file of `path` and touches each page to populate the page cache. Its size, rounded up to whole pages, counts against the scheduling budget once, however many rules use it. Tools that map their index, such as `bowtie2 --mm`, can share those pages instead of loading private copies. This reservation is not a measurement of physical memory: pages already cached may be charged elsewhere, and memory pressure can reclaim them.

- The holder stays while a rule that has yet to run needs it, and stops after its last user. When a waiting rule needs memory that only an idle holder occupies, the holder gives way.
- With isolation, kanit requests a run-scope `MemoryLow` equal to the measured shared-input and service sizes and records whether the request succeeded. Protection is best-effort, depends on the cgroup hierarchy and memory pressure, and applies to the scope rather than pinning particular index pages.
- A shared input's path, a mapped file or a service's index, is also an input of every rule that uses it, so rebuilding the index reruns them; there is no need to list it in `input` as well.
- A shared input may not contain the output of a rule.

For an index a tool loads into System V shared memory, such as a STAR genome, use a [shared service](Containers-and-Services.md#shared-services) instead.

## Reading the waits

On the demo workflow from [Reports](Reports.md), with six samples through qc, trim, align and count on 6 threads, the bottleneck report shows where ready rules waited:

```text
waiting for resources (ready rules that waited, on average over the launch, and their rule-seconds)
  threads                             3.6 rules     4m 26s
  group:disk                          0.4 rules     30.2 s
  loading shared:genome              <0.1 rules      0.2 s
  starting                           <0.1 rules      56 ms
  starting: the budget had room; the engine was recording ended attempts and starting other rules

resource groups (while their rules waited)
  disk                              30.2 s waited; no run samples while they waited
```

Most of the waiting was for threads, between three and four ready rules at a time on average, and the same report says the thread budget limited this launch: more threads would help, if the machine has them. For each group, the report says whether the budget had room while the group's rules waited, which tells whether a larger `max` would start them earlier ([Reports](Reports.md#what-limited-the-launch)); here no run sample fell while the disk group's rules waited, so it gives no verdict.

## Trying another thread count

`kanit report --suggest` notes a step whose runs kept all their threads busy: it may run faster with more. To try that without editing a generated workflow, give the step a thread count for one launch, and compare:

```sh
kanit plan --threads align=16          # which rules would run with it
kanit run --threads align=16 --max-threads 32 --max-memory 120G
kanit report --compare PREVIOUS_LAUNCH_ID
```

- `--threads STEP=N` sets the request of every rule of the step; repeat it for several steps. A misspelled step is refused with the nearest step name.
- The request is part of the rule key, so the step's rules run again with it, and so do the rules that read their outputs, unless the step sets `cutoff = true` and its outputs come out byte for byte the same; their records keep the request they ran with. A later launch without `--threads` runs them again with the workflow's request.
- `launch.json` records the overrides, and `report --compare` notes a step whose thread request differs, `threads 8 against 16`, beside its wall and CPU time. When it helped, change the request where the workflow is written.
