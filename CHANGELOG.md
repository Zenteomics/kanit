# Changelog

Every user-visible change to workz, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may change the workflow format, the record files under `.workz/` and the command line; each such change is listed under **Upgrading**.

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
