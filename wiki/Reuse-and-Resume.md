workz runs a rule again only when something that can change its outputs changed. This page explains what workz compares, how it notices changes without reading every file, what happens to outputs edited by hand, and how to force a rule to run.

## Plan, explain, run

`workz plan` prints the decision for every selected rule; `workz explain` shows one rule's key part by part; `workz run` acts on the same decisions. A rule is reused only for one reason, `unchanged`. It runs for any of these:

- `no completed record`: the rule never completed in this working directory, or its last attempt failed.
- `producer NAME runs`: a rule it depends on runs first, so its inputs are about to change. With `; reused if its outputs repeat`, the producer sets `cutoff = true`, and this rule may still be reused once the producer has run ([Cutoff](#cutoff)).
- `inputs changed`, `command changed`, `resource request changed`, `declared outputs, log or benchmark changed`, `a producing rule changed`, `engine key changed`: the first part of the [rule key](#the-rule-key) that differs from the record.
- `environment changed: NAME, ...`: the keyed environment variables whose values differ.
- `input missing: PATH`: an external input does not exist. `run` refuses to start until it does.
- `output missing: PATH`: a recorded output was deleted.
- `output changed: PATH (run refuses without --rerun)`: a recorded output was changed outside workz ([Changed outputs](#changed-outputs)).
- `rerun requested`: `--rerun` or `--rerun-rule` names the rule.

## The rule key

When a rule completes, workz records its key, made of seven parts:

1. **Command**: the `shell` text, with the rule's `workdir` and `links`, and for container rules the image ID, mounts and joined service.
2. **Environment**: the values of `PATH`, `LANG`, `LC_ALL` and `TZ`, and of every name given with `--pass-env`.
3. **Request**: threads, memory, resource groups and shared inputs, as written.
4. **Writes**: the declared outputs, log and benchmark paths.
5. **Inputs**: the identity of every input file, or its content digest where one is stored.
6. **Producers**: the key of every rule that produces one of the inputs.
7. **Engine key**: a number raised only when a change to workz can change what a rule produces.

A rule is reused when its key is the same as the recorded one and every recorded output still has the identity workz recorded. `explain` names the parts that differ:

Here `LANG` differs from the launch that recorded the rule (paths shortened):

```text
rule gc_s1: runs (environment changed: LANG)
  recorded: 2026-10-26T03:40:55.293Z, attempt .../attempts/gc_s1/001
  command    same
  environment changed
  request    same
  writes     same
  inputs     same
  producers  same
  engine key same
    LANG: was 'en_US.UTF-8', now 'C.UTF-8'
```

For a colon-separated list such as `PATH` it names the entries added or removed, `PATH: added /opt/samtools-1.21/bin`, or says `same entries in another order`.

No other variable is part of the key. Host rules also receive `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` and `TERM`, but a change to one of them reruns nothing; name a variable with `--pass-env` to pass it and key it. Everything else stays out of rules ([Running workflows](Running-Workflows.md#what-a-command-sees)).

The engine key is 2 in workz 0.3.0. Rebuilding workz reruns nothing: the executable's own digest is recorded in each launch, not in rule keys. Upgrading reruns rules only when the new version changes the engine key or what it records about inputs, and its changelog says so first, among the changes that need action; the version after 0.3.0 reruns every rule once, because file identities no longer include the device number.

## File identity

A file's identity is its inode, size, and modification and change times, which workz reads with one `statx` call. A rewrite changes them even when it restores the old modification time, because programs cannot set the change time. workz therefore notices every edit without reading the file. The device number is left out: btrfs numbers its subvolumes anew at each mount, so it would change with every reboot.

A directory's identity covers every file below it, so adding, removing or editing any of them changes it.

## Content digests

Some files are keyed on a SHA-256 digest of their bytes instead of their identity. Their identity then only tells workz when to hash them again, so a file that is touched, copied back or rewritten with the same bytes keeps its consumers reused. Consumers are keyed on digests for two kinds of files: the outputs of cutoff rules and the inputs listed in an input manifest. ([`verify --content`](#verify-outputs) also stores digests of recorded outputs, which lets a launch accept an output whose identity changed but whose bytes did not.)

### Cutoff

`cutoff = true` on a rule hashes its outputs after it succeeds. Consumers are keyed on those digests instead of the producer's key, so when the rule runs again and writes the same bytes, its consumers are reused. Here `sort_calls` sorts a table of calls and has `cutoff = true`; the input is rewritten with the same lines in another order:

```sh
workz plan workflow.toml
```

```text
run   sort_calls  (inputs changed)
run   report  (producer sort_calls runs; reused if its outputs repeat)
2 to run, 0 to reuse
```

```sh
workz run workflow.toml
```

```text
[0/2] page .workz/launches/.../report.html, drawn again every 5 s while the launch runs
[0/2] started sort_calls (attempt 1)
[1/2] completed sort_calls (0.0 s)
```

`sort_calls` wrote the same sorted file, so `report` was reused without running. Use it on rules whose outputs often repeat byte for byte when their inputs change, such as sorting, filtering or format conversion. A file that embeds the time or the run directory never repeats, so cutoff only costs a hash there.

### Input manifests

`workz run --input-manifest FILE` checks external inputs against known digests before anything runs. The manifest is a JSON object from absolute paths to digests:

```json
{
  "/data/run42/s1_1.fq.gz": "sha256:8f5c315a0c047803538f09c2e8375f50b1f0e79c5f905b60bc63855ae07c4afc",
  "/data/run42/s1_2.fq.gz": {
    "sha256": "sha256:bb41814ab351dd154603d028cb6477e3551723e0b1250886504a7b56bef4282e",
    "stamp": { "dev": 64769, "ino": 1311, "size": 2048117, "mtime_ns": 1792985370282059424, "ctime_ns": 1792985370282059424 }
  }
}
```

- A plain digest makes workz hash the file once and remember the digest with the file's identity; later launches hash it again only if the identity changed.
- A digest with a `stamp` carries the identity the manifest's writer saw when it hashed the file. If the file's inode, size and modification and change times match the stamp, workz trusts the digest without reading the file; `dev` may be present and is not compared, since it changes with every mount on btrfs. Use stamps only from a program you trust to write them.
- A file that is missing or does not match refuses the launch before any rule starts, with exit status 1.

Inputs listed in the manifest are keyed on their digests, like the outputs of cutoff rules.

## Changed outputs

If a recorded output was changed outside workz, for example edited by hand, the next launch refuses to run rather than overwrite it (paths shortened):

```text
workz: output of completed rule make changed since it was recorded: .../edit/out.txt
workz: a recorded output changed outside workz (.../edit/out.txt); run again with --rerun-rule for the affected rules, or --rerun for all (earlier bytes are kept in previous/)
```

If a digest is stored for the output (a cutoff rule, or `verify --content`) and the bytes still match it, workz records the new identity and the rule stays reused. Otherwise run the rule again on purpose with `--rerun-rule RULE`, or restore the file.

## Force a rule to run

- `--rerun-rule RULE` (repeatable) runs the named rules even when they are reusable. Their consumers follow when the new outputs differ; with `cutoff = true`, identical bytes keep them reused. Use it after fixing a tool the key cannot see, such as a binary updated in place.
- `--rerun` runs every selected rule.

Both work with `plan` and `explain` too, so you can see the effect first. Combine them with `--target RULE` to limit the launch to a rule and the rules it depends on.

## Previous outputs

Before an attempt starts, workz moves every output that already exists into the attempt's `previous/` directory, named `<index>-<file name>`. A rule therefore never sees its own old outputs, and the bytes a rerun replaces are kept in `.workz/launches/<ID>/attempts/<rule>/<NNN>/previous/` until that launch directory is removed ([Records](Records.md#cleaning-up)).

## Verify outputs

`workz verify WORKFLOW` checks that every recorded output still has its recorded identity, and `--content` also compares the bytes with stored digests, storing a digest for every output that has none:

```text
4 outputs checked: all match
4 outputs checked by content, 4 digests stored: all match
```

Differences are listed as `missing`, `changed` or `content`, and the exit status is 1. Stored digests let a later launch accept an output whose identity changed but whose bytes did not.

## Resume after a crash

There is nothing special to do: run the same command again. workz writes a journal entry before each attempt starts and after its result is saved in `state.json`, which happens at most once a second. A rule that was running when the engine, the session or the machine went down has no completed record and runs again, as does a rule that completed in the last second before the crash; every rule whose result was saved is reused. Running attempts end with the engine ([Running workflows](Running-Workflows.md#isolation)), so nothing from the crashed launch keeps writing behind the new one.
