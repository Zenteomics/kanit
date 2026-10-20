# Changelog

Every user-visible change to workz, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may change the workflow format, the record files under `.workz/` and the command line; each such change is listed under **Upgrading**.

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
