# Changelog

Every user-visible change to workz, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may change the workflow format, the record files under `.workz/` and the command line; each such change is listed under **Upgrading**.

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
