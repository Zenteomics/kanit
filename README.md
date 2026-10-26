# workz

workz runs a prepared graph of file-producing rules on one Linux workstation. It starts every rule whose inputs are ready as long as the machine's CPU and memory budget allows, enforces each rule's memory and CPU request with its own cgroup, reuses work only when nothing it depends on has changed, and keeps a complete record of every attempt.

![The workz watch view of a running launch: gauges for progress, threads and memory against the budget, then every rule, with the running ones first showing their CPU use and a memory bar against their request.](wiki/images/watch.png)

- **Explicit graphs.** A TOML file lists rules with their inputs, outputs, command and request; a script generates it for any number of samples.
- **Fits the machine.** Rules start in critical-path order within a thread, memory and job budget, with resource groups for limits such as disk bandwidth.
- **Enforced requests.** Each attempt runs in its own cgroup inside a systemd scope, with no network; a rule that exceeds its memory is stopped, not the machine.
- **Exact reuse.** A rule runs again only when its command, environment, request, outputs, inputs or producers changed, or when you ask, and a changed output is never silently overwritten.
- **Shared indexes.** A large index is loaded once and counted once in memory, as mapped files or as a container service such as a STAR genome in shared memory.
- **Containers.** Rules can run in local images through rootless Podman, inside the same limits and records.
- **Answers, not logs.** A live terminal view, per-attempt reports, the critical path, waiting by reason, request suggestions, launch comparisons and a self-contained HTML report.

## Requirements

Linux on x86-64 with cgroup v2 and a systemd user manager. Container rules and shared services also need rootless Podman. Building needs Zig 0.16.0, which downloads the one library workz uses; [Installation](wiki/Installation.md) has the details.

## Quick start

```sh
zig build -Doptimize=ReleaseSafe
export PATH="$PWD/zig-out/bin:$PATH"

mkdir demo && cd demo
workz init                          # writes a commented workflow.toml
mkdir data && seq 1000 > data/reads.txt
workz plan workflow.toml            # what would run, and why
workz run workflow.toml             # run it
cat out/report.txt                  # reads: 1000
workz report --bottlenecks          # what limited the run
```

Then follow [Getting started](wiki/Getting-Started.md), which builds, runs and changes a small workflow step by step.

## Documentation

The [user guide](wiki/Home.md) covers writing workflows, scheduling, reuse, containers, running, watching and reports, with a [workflow reference](wiki/Workflow-Reference.md), a [command reference](wiki/Command-Reference.md) and [troubleshooting](wiki/Troubleshooting.md). [CHANGELOG.md](CHANGELOG.md) lists the changes in every version.

## Status

workz 0.3.0. Before 1.0, a minor version may change the workflow format, the records under `.workz/` and the command line; the changelog lists each such change under Upgrading.

## License

Apache-2.0, see [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY.md](THIRD_PARTY.md).
