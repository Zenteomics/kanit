kanit compares recorded rule keys and output identities to decide what to reuse. This page explains those checks, what happens to outputs edited by hand, and how to force a rule to run. Dependencies that the workflow does not declare cannot participate in the check.

## Plan, explain, run

`kanit plan` prints the decision for every selected rule; `kanit explain` shows one rule's key part by part; `kanit run` acts on the same decisions. A rule is reused only for one reason, `unchanged`. It runs for any of these:

- `no completed record`: the rule has no retained successful record, for example because it never completed or the dispatch journal marks it unfinished after a crash. A failed rerun can retain an earlier successful record and restore its outputs.
- `producer NAME runs`: a rule it depends on runs first, so its inputs are about to change. With `; reused if its outputs repeat`, the producer sets `cutoff = true`, and this rule may still be reused once the producer has run ([Cutoff](#cutoff)).
- `inputs changed`, `command changed`, `resource request changed`, `declared outputs, log or benchmark changed`, `a producing rule changed`, `engine key changed`: the first part of the [rule key](#the-rule-key) that differs from the record.
- `environment changed: NAME, ...`: the keyed environment variables whose values differ.
- `input missing: PATH`: an external input does not exist. `run` refuses to start until it does.
- `output missing: PATH`: a recorded output was deleted.
- `output changed: PATH (run refuses without --rerun-rule or --rerun)`: a recorded output was changed outside kanit ([Changed outputs](#changed-outputs)).
- `rerun requested`: `--rerun` or `--rerun-rule` names the rule.

## The rule key

When a rule completes, kanit records its key, made of seven parts:

1. **Command**: the `shell` text, with the rule's `workdir` and `links`, and for container rules the image ID, mounts and joined service.
2. **Environment**: the values of `PATH`, `LANG`, `LC_ALL` and `TZ`, and of every name given with `--pass-env`.
3. **Request**: threads, memory, resource groups and shared inputs, as written.
4. **Writes**: the declared outputs, log and benchmark paths, as written.
5. **Inputs**: the identity of every input file, or its content digest where one is stored, under its path relative to the working directory when inside it ([Moving a project](#moving-a-project)).
6. **Producers**: the key of every rule that produces one of the inputs.
7. **Engine key**: a number raised only when a change to kanit can change what a rule produces.

A rule is reused when its key is the same as the recorded one and every recorded output still has the identity kanit recorded. `explain` names the parts that differ:

Here `LANG` differs from the launch that recorded the rule (paths shortened):

```text
rule gc_s1: runs (environment changed: LANG)
  recorded: 2026-11-07T06:10:54.961Z, attempt .../attempts/gc_s1/001
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

The engine key is 4. Rebuilding kanit reruns nothing: the executable's own digest is recorded in each launch, not in rule keys. Upgrading reruns rules only when the new version changes the engine key or what it records about inputs, and its changelog says so first, among the changes that need action.

## File identity

A file's identity is its inode, size, and modification and change times, which kanit reads with `statx`. An ordinary rewrite changes the change time even if it restores the modification time. This detects such edits without reading the contents, but cannot detect changed bytes when all recorded fields remain equal, for example a same-size rewrite within one filesystem timestamp tick. `verify --content` reads recorded outputs and compares stored digests; without an earlier digest, it records one rather than proving that the bytes never changed. The device number is left out because btrfs device numbers can change after remounting.

A directory's identity covers every entry below it: each file's identity, and each directory by name, so an empty directory counts. Adding, removing, renaming or editing any of them changes it. A dangling symlink counts as missing, so the identity changes when its target appears. A symlink to a directory below a directory input is refused, with its path: its target's contents would go unseen. Declare the directory it names as an input of its own. `.workz/` directories are left out, since kanit writes into them while rules run.

## Moving a project

Paths inside the working directory enter rule keys and `state.json` relative to it. Moving the whole directory with `.workz/` on the same filesystem can preserve reuse when file identities and the other key parts stay unchanged. Check the resulting plan:

```sh
mv ~/runs/rnaseq ~/projects/rnaseq-2026
kanit plan ~/projects/rnaseq-2026/workflow.toml
```

- An absolute path inside the project changes with it: a rule's `shell` that names one, a `PATH` entry under it, or an input written through a symlinked spelling of the project's directory. Write paths inside the project relative to it.
- A copy is not a move: `cp`, `rsync` or a move to another file system give every file a new identity, so the rules run again.
- A shared service's `command` names absolute paths, since it runs in `/tmp`; after a move it must be rewritten, and the rules that join it run again.
- Containers that a killed launch left behind carry the old path, so `kanit clean` in the new place does not find them; remove them with `podman rm`.

## Content digests

Some files are keyed on a SHA-256 digest of their bytes instead of their identity. Their identity then only tells kanit when to hash them again, so a file that is touched, copied back or rewritten with the same bytes keeps its consumers reused. Consumers are keyed on digests for two kinds of files: the outputs of cutoff rules and the inputs listed in an input manifest. ([`verify --content`](#verify-outputs) also stores digests of recorded outputs, which lets a launch accept an output whose identity changed but whose bytes did not.)

### Cutoff

`cutoff = true` on a rule hashes its outputs after it succeeds. Each consumer is keyed on the digests of the outputs it reads instead of the producer's key, so when the rule runs again and writes the same bytes, its consumers are reused, and when one output changes, only the rules that read it run. Here `sort_calls` sorts a table of calls and has `cutoff = true`; the input is rewritten with the same lines in another order:

```sh
kanit plan workflow.toml
```

```text
RULE        DECISION  WHY
sort_calls  run       inputs changed
report      run       producer sort_calls runs; reused if its outputs repeat
2 to run, 0 to reuse
```

```sh
kanit run workflow.toml --max-threads 2 --max-memory 1G
```

```text
kanit 0.9.0   cutoff   launch 20261108T121726.579-c84630ba
          plan         2 rules
          budget       2 threads, 1.0 GiB, 2 jobs, isolated
          records      .workz/latest/   log launch.log   page report.html

TIME      RULES  STATUS  STEP           TOOK             MEMORY      CPU  NOTE
05:17:27    0/2  START   sort_calls                 - /  64 MiB    - / 1
05:17:27    1/2  DONE    sort_calls     3 ms        - /  64 MiB    - / 1
```

`sort_calls` wrote the same sorted file, so `report` was reused without running. Use it on rules whose outputs often repeat byte for byte when their inputs change, such as sorting, filtering or format conversion. A file that embeds the time or the run directory never repeats, so cutoff only costs a hash there.

### Input manifests

`kanit run --input-manifest FILE` checks external inputs against known digests before anything runs. The manifest is a JSON object from absolute paths to digests:

```json
{
  "/data/run42/s1_1.fq.gz": "sha256:8f5c315a0c047803538f09c2e8375f50b1f0e79c5f905b60bc63855ae07c4afc",
  "/data/run42/s1_2.fq.gz": {
    "sha256": "sha256:bb41814ab351dd154603d028cb6477e3551723e0b1250886504a7b56bef4282e",
    "stamp": {
      "dev": 64769, "ino": 1311, "size": 2048117,
      "mtime_ns": 1792985370282059424, "ctime_ns": 1792985370282059424
    }
  }
}
```

- A plain digest makes kanit hash the file once and remember the digest with the file's identity; later launches hash it again only if the identity changed.
- A digest with a `stamp` carries the identity the manifest's writer saw when it hashed the file. If the file's inode, size and modification and change times match the stamp, kanit trusts the digest without reading the file; `dev` may be present and is not compared, since it changes with every mount on btrfs. Use stamps only from a program you trust to write them.
- A file that is missing or does not match refuses the launch before any rule starts, with exit status 1.

Inputs listed in the manifest are keyed on their digests, like the outputs of cutoff rules.

## Changed outputs

If a recorded output was changed outside kanit, for example edited by hand, the next launch refuses to run rather than overwrite it (paths shortened):

```text
kanit: output of completed rule make changed since it was recorded: .../edit/out.txt
kanit: a recorded output changed outside kanit (.../edit/out.txt); to run the rule that wrote it again, keeping the earlier bytes in previous/, run with --rerun-rule make, or with --rerun for every rule
```

If a digest is stored for the output (a cutoff rule, or `verify --content`) and the bytes still match it, kanit records the new identity and the rule stays reused. Otherwise run the rule again on purpose with `--rerun-rule RULE`, or restore the file.

## Force a rule to run

- `--rerun-rule RULE` (repeatable) runs the named rules even when they are reusable. Their consumers follow when the new outputs differ; with `cutoff = true`, identical bytes keep them reused. Use it after fixing a tool the key cannot see, such as a binary updated in place.
- `--rerun` runs every selected rule.

Both work with `plan` and `explain` too, so you can see the effect first. Combine them with `--target RULE` to limit the launch to a rule and the rules it depends on.

## Previous outputs

Before an attempt starts, kanit moves existing outputs into its `previous/` directory, named `<index>-<file name>`. If the command fails, is stopped or cannot start, it moves those files back and retains the earlier successful record when one exists. Replacement files left by the failed attempt move to `failed/`. The next launch also tries to recover preserved files from interrupted attempts, but those attempts have no reusable completion record. A completed rerun's previous bytes remain under `.workz/launches/<ID>/attempts/<rule>/<NNN>/previous/` until explicit cleanup ([Records](Records.md#cleaning-up)). Replacing large outputs repeatedly therefore grows the retained records.

Restoration depends on successful filesystem operations; it is not an atomic rollback across rules. After a crash, the journal invalidates an unfinished rule's success record even when its old files can be recovered, so it runs again. A separate end-of-launch check rejects completed results whose inputs changed during execution; that check invalidates reuse but does not automatically restore their previous outputs.

## Verify outputs

`kanit verify WORKFLOW` checks that every recorded output still has its recorded identity, and `--content` also compares the bytes with stored digests, storing a digest for every output that has none:

```text
4 outputs checked: all match
4 outputs checked by content, 4 digests stored: all match
```

Differences are listed as `missing`, `changed` or `content`, and the exit status is 1. Stored digests let a later launch accept an output whose identity changed but whose bytes did not.

## Resume after a crash

Run the same command again. kanit writes a dispatch journal entry before moving old outputs and marks the attempt done after its result is on disk: appended to `.workz/state.log`, which is synced at most once a second, and folded into `state.json` when the launch ends ([Records](Records.md#statelog)). An attempt without a durable completion can rerun even if its command finished. Saved results are reused only when their keys and outputs still match. Task cleanup depends on the run's isolation and keeper processes; see [Isolation](Running-Workflows.md#isolation) for the limits.
