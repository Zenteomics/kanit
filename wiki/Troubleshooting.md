The errors you are most likely to meet, what each means, and what to do about it. Messages are quoted as kanit prints them; `NAME`, `PATH`, `DIR` and `N` stand for the values in yours.

## Starting a run

- `systemd-run not found; isolation needs a systemd user manager (or use --no-isolation)`: kanit isolates a run in a systemd user scope. Run it in a session with a systemd user manager, or use `--no-isolation` and give up per-attempt limits ([Without isolation](Running-Workflows.md#without-isolation)).

- `the run's scope cannot create cgroups for attempts: delegate the cpu, memory and pids controllers to the systemd user manager (see Installation), or use --no-isolation`: The run's scope did not get the `cpu`, `memory` and `pids` controllers. Delegate them to the user manager as shown in [Installation](Installation.md#check-isolation).

- `cannot create the run's network namespace: ...`: Unprivileged user namespaces are disabled or restricted on this system. Check `sysctl user.max_user_namespaces`, ask your administrator, or use `--no-isolation`.

- `another launch is running in DIR; watch it with kanit watch, or run again after it ends`: Only one launch runs in a working directory at a time. Watch it with `kanit watch`, stop it with `kanit control cancel`, or wait for it to end. `verify` and `clean` refuse while it runs with `a launch is running in DIR; verify after it ends`, or `clean after it ends`.

- `the workflow has container rules but podman is not on PATH`: Install rootless Podman, or put it on the `PATH` of the shell that runs kanit.

- `container image NAME is not available locally; kanit does not pull images`: Pull the image with `podman pull NAME`, then run again.

## Workflow errors

Every error in a workflow file names its line and shows it:

```text
kanit: typo.toml: line 9: unknown key 'memroy' in a rule; did you mean 'memory'?
  9 | memroy = "64M"
```

A file with several problems gets them all at once, up to 50 and a count of the rest, each with its line where it has one, and the first shown:

```text
kanit: workflow.toml: 4 problems
  line 5: resource_groups.disk.max must be between 1 and 1000000
  line 9: unknown key 'outputs' in a rule; did you mean 'output'?
  line 7: rule a must declare output files
  line 13: rule b: invalid memory 'lots'
  5 | max = 0
```

- Each rule, resource group and shared input reports every unknown key and its first bad value, in that order, so a rule's lines need not follow the file. A misspelled required key also reports the key as missing, as `outputs` does here. Checks between rules, such as two rules writing one file or a rule using an undeclared group, run once every rule reads well and report every item at fault, so fixing the first list can show a second.
- A file that is not valid TOML, or that lacks its `[workflow]` table, stops at that one problem.

- `rule NAME must declare output files`: Every rule writes at least one file that kanit can check. A rule that only has side effects can write a marker file, such as `touch done/NAME`.

- `rules A and B both produce 'PATH'`: Two rules declare the same output. Give each its own file.

- `the rule graph has a cycle: A -> B -> A (each rule writes an input of the next)`: These rules depend on each other in a loop, so none of them can start. Break the loop: usually one rule declares, as an input, a file that a later step writes.

- `rule NAME: input 'PATH' must be an explicit local path`: Paths cannot contain wildcards, braces, URLs or control characters. List the files explicitly; a script that generates the workflow can expand them.

- `rule NAME: 'PATH' must be a relative path inside the working directory`: Outputs, logs and benchmarks are written inside the working directory. Use a relative path without `..`, or run with `-d` set to a directory that contains them.

- `rule NAME: declare the producer path instead of the symlink 'PATH'`: The input reaches another rule's output, or a directory it writes into, through a symlink. Use the output's own path, so the dependency is visible to kanit.

- `rule NAME: input 'PATH' names another file than it spells: a '..' follows a symlink; write the path without '..'`: A directory before the `..` is a symlink, so the kernel steps up from where the link points, not from where the path seems to be. Write the path to the file itself.

- `rule NAME: 'PATH' passes through a symlinked directory; name it by its real path`: An output, log, benchmark or workdir is written through a symlink to a directory, or through a symlink that points nowhere. Write the path the symlink points to.

- `rule NAME: 'PATH' is inside its directory input 'DIR'; write it outside that directory`: The rule would change its own input while it runs. Write the output, log, benchmark or workdir beside the directory, or name the input files one by one.

- `cannot read input DIR: DIR/LINK is a symlink to a directory; declare the directory it names as an input of its own`: A directory input holds a symlink to a directory, whose contents kanit would not see. Declare the linked directory as an input too, or name the inputs below the link explicitly.

- `rule NAME must declare memory` and `rule NAME: invalid memory 'TEXT'`: Every rule needs a memory request, as a string such as `"512M"` or `"4G"`, on the rule, in its resources or in `[defaults]`. A size is digits and a unit, without a sign or `_`. `defaults: invalid memory 'TEXT'` is the same for the default, which is checked even when every rule sets its own.

- `rule NAME uses undeclared resource group 'G'`, `rule NAME uses undeclared shared input 'S'` (with `; did you mean 'X'?` when a declared one is close): Declare the group under `[resource_groups.G]` or the input under `[shared.S]`, or fix the name.

- `rule NAME: 'PATH' needs 'DIR' to be a directory, but rule OTHER writes that path as a file`: Two declarations cannot both hold: `DIR` cannot be a file and the directory `PATH` lies in. Rename one of them.

- `rule NAME: a log or benchmark is a hard link to a log or benchmark of rule OTHER`: Both would write the same file. Remove the extra link, or give each rule its own file.

- `step NAME: input must be a list of paths` (or `output`): A template step writes `input` and `output` as lists, such as `input = ["in.txt"]`.

- `PATH is not valid JSON`: A record in `.workz/` is damaged, so the command leaves it out, names it, and exits 1. A `summary.json` that cannot be read leaves the launch's result unknown; its events and attempt records remain.

- `rule NAME lists shared input 'S' twice`: A shared input is held and counted once for a rule. List it once.

- `input manifest entry is not a regular file: PATH`: A manifest digest covers one file's bytes. List the files inside a directory one by one.

- `rule NAME uses the shared service 'S'; only container rules can join a service`: Services share memory through a container's IPC namespace, so the rule needs a `container`.

## Refused launches

A refused launch stops before any rule runs. It still leaves a launch directory and a summary with status `refused` and the reason, which `kanit status` shows.

- `rule NAME requests N threads; the run allows M` and `rule NAME needs N MiB; the run allows M MiB`, which says `with its shared inputs` or `with its Podman client` where they count: One rule's request alone is larger than the budget, so it could never start. Raise `--max-threads` or `--max-memory`, or lower the request; `kanit plan --budget` finds every such rule before a launch.

- `missing input of rule NAME: PATH`: An input that no rule produces does not exist. Create it, fix the path, or add the rule that makes it.

- `shared input NAME (PATH): FILE is not a regular file, and a shared input maps every file it holds`: A file input holds a FIFO, socket or device, which cannot be mapped and could block the holder. Move it out of the shared directory.

- `output of completed rule NAME changed since it was recorded: PATH`: A recorded output was changed outside kanit, and kanit will not overwrite it silently. Run the rule again with `--rerun-rule NAME`, which keeps the changed bytes in `previous/`, or restore the file ([Changed outputs](Reuse-and-Resume.md#changed-outputs)). The launch exits with status 1.

- `input does not match its manifest digest: PATH` and `input manifest file is missing: PATH`: An input differs from the input manifest. Fix the input or the manifest. The launch exits with status 1.

- `cannot read input manifest PATH: ...` or `input manifest PATH must be a JSON object of absolute paths`, then `the input manifest cannot be used`: The file given with `--input-manifest` is missing or not a manifest. The launch exits with status 2.

- `PATH has a format version this kanit cannot read` or `PATH cannot be read: it is not a valid kanit state`, for `.workz/state.json`: The resume state was written by another version of kanit, usually a newer one, or is damaged. Use the kanit that wrote it, or move the file aside: the next launch runs every rule, and the launch directories keep every earlier attempt. A `.workz/state.log` of a newer version, or with a damaged complete line, gives the same messages, naming `state.json`: moving `state.json` aside also makes kanit ignore the log. `run` refuses with exit status 2; `plan` exits 1.

## Rules that fail

The run log names a failure's reason in a few words, quotes the last lines of its standard error, and names the `kanit logs` command that prints its output; the attempt's record, `kanit status` and the summary keep the reasons below. `kanit logs NAME` or `kanit logs STEP/SAMPLE` prints the attempt's output, and `kanit status` lists every failed rule of the newest launch.

- `exited with status N: LINE` (in the log, `exit N after TIME`): The command failed, and LINE is the last line of its standard error, which usually says why; `kanit logs NAME` prints the rest. A tool that writes its errors to a log of its own, such as STAR's `Log.out`, can name that log in `diagnostics` ([Writing workflows](Writing-Workflows.md#diagnostics)); then its last line is quoted when standard error is empty, and its tail is kept with the attempt.

- `out of memory: could not stay within its N MiB request` (in the log, `out of memory at its N MiB`): The attempt needed more memory than it requested, and the kernel killed all of its processes. Raise `memory`, guided by `kanit report --suggest` on attempts that completed.

- `timed out after N s` (in the log, `timed out at TIME`): The attempt ran longer than its `timeout` or `--timeout`. Raise the limit, or find out why the command hangs.

- `exited 0 without output PATH`: The command succeeded but did not write a declared output; often a typo in the command or the declaration, or a tool that names its output differently. Paths are case-sensitive.

- `killed by signal N` (in the log, the signal's name, such as `killed by SIGSEGV after TIME`): Something outside kanit killed the command, or, without isolation, the system's out-of-memory killer did.

- `status 125: the container engine failed, or the command exited 125: ...`: Podman could not start the container, or the command itself exited 125. The quoted line says which.

- `the command could not run in the container (status N): ...`, with N 126 or 127: The command is not in the image, or not executable there. The image's `PATH` applies inside the container, not yours.

- `shared input NAME could not be loaded: ...`: A shared service or file holder failed, so the rules that need it fail too. For a service, its standard error is in `.workz/launches/<ID>/shared/`.

- `it needs a rule that did not complete`: The rule is blocked because a rule it depends on failed. Fix that one; with `--keep-going`, the rest of the launch ran on.

- `inputs of rule NAME changed during the run`: Something modified a rule's input while the launch ran, so the rule's result cannot be trusted and it is not recorded as completed. Find what writes into the inputs, and run again.

## Rules that wait

- `rule NAME cannot start: it waits for REASON with nothing running`: No rule runs, and this one still does not fit, so it never would. Requests that can never fit the budget or a group are refused before a launch starts, so this is a safety stop for a combination that slipped past those checks; the `task_waiting` events of the launch show what the rule waited for. Lower its request or raise the budget.

When rules wait long but do start, `kanit report --bottlenecks` shows what they waited for and whether a larger group or budget would help ([Reports](Reports.md#what-limited-the-launch)).

## Rules that rerun unexpectedly

`plan` gives the reason, and `explain` the detail.

- `environment changed: PATH`: Your `PATH`, `LANG`, `LC_ALL`, `TZ` or a name given with `--pass-env` differs from the launch that recorded the rule, for example after activating another environment. `explain` shows the entries added or removed. Run kanit from a shell with the same environment, or rerun on purpose.

- `inputs changed` when the bytes are the same: A file was touched, copied or rewritten with the same content, which changes its identity. Use `cutoff = true` on the rule that produces it, or an [input manifest](Reuse-and-Resume.md#input-manifests) for external files.

- Every rule runs after an upgrade: The new version changed what a rule key covers, as the changelog says at the top of that version. It happens once.

## Rules that do not rerun when they should

The key covers what kanit can see. If you change something it cannot see, such as a tool binary updated in place or a file the command reads without declaring it, run the affected rules with `--rerun-rule NAME`. To make such changes visible for good, declare the file as an input; a tool's executable or its configuration can be an input like any other file.
