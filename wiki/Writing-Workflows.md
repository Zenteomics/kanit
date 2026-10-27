A workz workflow is a flat list of concrete rules. This page covers how to structure one, how to generate it from a sample sheet, and how to choose the requests and options that make it run well. The [workflow reference](Workflow-Reference.md) lists every key.

## Anatomy of a rule

```toml
[[rules]]
name = "align_s1"
input = ["trimmed/s1_1.fq.gz", "trimmed/s1_2.fq.gz"]
output = ["aligned/s1.bam"]
shell = "bowtie2 --mm -p $WORKZ_THREADS -x ref/bowtie2/genome -1 trimmed/s1_1.fq.gz -2 trimmed/s1_2.fq.gz | samtools view -b -o aligned/s1.bam -"
priority = 10
log = "logs/align_s1.log"
benchmark = "benchmarks/align_s1.json"

[rules.resources]
threads = 8
memory = "2G"
shared = ["index"]
```

- `name` is unique in the workflow: letters, digits, `_`, `.` and `-`, starting with a letter or digit.
- `input` lists every file or directory the command reads, and `output` every file it writes. They are the only way rules connect, and the only files workz watches for changes.
- `shell` is one command line, run in the rule's `workdir` or else the working directory, so relative paths start there. A host rule runs it with `bash -euo pipefail`, so a failing command anywhere in a pipeline fails the rule; a [container rule](Containers-and-Services.md) runs it with the image's `/bin/sh` and `set -eu`, with `pipefail` where that shell has it.
- `[rules.resources]` holds the request: `threads`, `memory`, units of resource groups, and the shared inputs the rule uses.
- `priority`, `log`, `benchmark` and the other keys are optional.

## Inputs and outputs

workz runs a rule's command only after every rule that produces one of its inputs has completed, and it decides reuse by the identity of those files. Declare them completely:

- **Declare every file the command reads**, including scripts, reference files and configuration. An undeclared input is invisible: editing it never reruns the rule, and nothing orders the rule after its producer.
- **Declare every file the command must leave behind.** After the command exits 0, workz checks that each output exists as a regular file; a missing one fails the attempt with `exited 0 without output <path>`. Temporary files need not be declared.
- **Outputs live inside the working directory**, as relative paths without `..`, and outside `.workz/`. Inputs may be anywhere.
- **Directories can be inputs.** A directory's identity covers every file below it, so adding or changing any of them reruns the rule. An index such as `ref/bowtie2` is a natural directory input.
- **There are no wildcards.** Paths name files exactly; `*`, `?`, `[ ]` and `{ }` are errors. Inside `shell`, use whatever the shell allows.

workz creates the directory of every output before an attempt starts, and moves any output already there into the attempt's `previous/` directory, so a command always starts from a clean slate and earlier bytes are never lost ([Reuse and resume](Reuse-and-Resume.md#previous-outputs)).

## Label every rule

Give each rule its `step`, its `sample` when it works on one, and a `category` and `tool` where they help ([Concepts](Concepts.md#steps-samples-categories-and-tools)). The labels are what the reports group by:

- `workz report --suggest` turns six `align` rules into one row with their request, the most memory any of them used, and a suggested request.
- The HTML report draws the pipeline step by step, a table of samples by steps that points at the sample a step was slow on, and colors every attempt by its category.
- The scheduler estimates a rule that has never run from the other rules of its step.

Labels are not part of the rule key, so adding them to a workflow that already ran reruns nothing. Rules that declare none are labelled from their names, as [Concepts](Concepts.md#steps-samples-categories-and-tools) describes: `align_s1` is the step `align`, and `s1__ALIGN` is the step `ALIGN` of the sample `s1`.

## Generate the file

Real workflows have one rule per sample and step, so they are written by a program, not by hand. Any language works; the file is plain TOML. This bash script reads a sample sheet and writes a trim, align and count workflow:

`samples.tsv`

```text
s1	reads/s1_1.fq.gz	reads/s1_2.fq.gz
s2	reads/s2_1.fq.gz	reads/s2_2.fq.gz
s3	reads/s3_1.fq.gz	reads/s3_2.fq.gz
```

`make-workflow.sh`

```bash
#!/usr/bin/env bash
# Writes workflow.toml: trim and align every sample in samples.tsv, then count reads per gene.
set -euo pipefail
bams=()
{
  printf '[workflow]\nname = "rnaseq"\n\n'
  printf '[resource_groups.disk]\nmax = 2\n\n'
  printf '[shared.index]\npath = "ref/bowtie2"\n\n'
  while IFS=$'\t' read -r s r1 r2; do
    cat <<EOF
[[rules]]
name = "trim_$s"
step = "trim"
sample = "$s"
category = "trimming"
tool = "fastp"
input = ["$r1", "$r2"]
output = ["trimmed/${s}_1.fq.gz", "trimmed/${s}_2.fq.gz"]
shell = "fastp -w \$WORKZ_THREADS -i $r1 -I $r2 -o trimmed/${s}_1.fq.gz -O trimmed/${s}_2.fq.gz"
log = "logs/trim_$s.log"

[rules.resources]
threads = 4
memory = "2G"
groups = { disk = 1 }

[[rules]]
name = "align_$s"
step = "align"
sample = "$s"
category = "alignment"
tool = "bowtie2"
input = ["trimmed/${s}_1.fq.gz", "trimmed/${s}_2.fq.gz"]
output = ["aligned/$s.bam"]
shell = "bowtie2 --mm -p \$WORKZ_THREADS -x ref/bowtie2/genome -1 trimmed/${s}_1.fq.gz -2 trimmed/${s}_2.fq.gz | samtools view -b -o aligned/$s.bam -"
priority = 10
log = "logs/align_$s.log"
benchmark = "benchmarks/align_$s.json"

[rules.resources]
threads = 8
memory = "2G"
shared = ["index"]

EOF
    bams+=("aligned/$s.bam")
  done < samples.tsv
  quoted=$(printf '"%s", ' "${bams[@]}")
  cat <<EOF
[[rules]]
name = "count_genes"
step = "count_genes"
category = "quantification"
tool = "featureCounts"
input = ["ref/genes.gtf", ${quoted%, }]
output = ["counts.tsv"]
shell = "featureCounts -T \$WORKZ_THREADS -p --countReadPairs -s 2 -a ref/genes.gtf -o counts.tsv ${bams[*]}"
threads = 4
memory = "4G"
EOF
} > workflow.toml
```

`-s 2` counts reverse-stranded reads, as dUTP library kits produce; set the strandedness your library has, since featureCounts counts unstranded by default.

```sh
bash make-workflow.sh
workz validate workflow.toml
workz plan workflow.toml --summary
```

```text
valid: rnaseq (7 rules, 7 selected, 1 groups, 1 shared)
     4 run   a producer runs
     3 run   no completed record
7 to run, 0 to reuse
```

Some choices in this script are worth copying:

- `\$WORKZ_THREADS` stays a variable in the file and expands when the rule runs, to the threads the rule requested. Passing it to every multithreaded tool keeps the tool's threads equal to its CPU quota.
- The bowtie2 index is a [shared input](Resources-and-Scheduling.md#shared-inputs): workz loads it once for all alignments, and counts it as an input of each, so rebuilding the index reruns them.
- `bowtie2 --mm` maps the index instead of reading it, so the alignments share one copy of it in memory, which is what makes a shared input pay off.
- The `disk` group lets at most two trims read from disk at once, while alignments with `priority = 10` start before trims that become ready at the same time.
- Every rule says what it is: its step, sample, category and tool. The script knows them, so the reports can group by them, and `count_genes` stays the step `count_genes` instead of being read as `count`.
- Regenerating the file is safe. Rules whose command, request and inputs did not change are reused.

## Choose requests

A request is both a reservation and a limit, so it pays to size it from measurements:

1. Start generous: enough memory that nothing is killed, and the threads you want each tool to use.
2. Run the workflow, or a few samples of it.
3. Ask workz what each step used: `workz report --suggest` prints the largest peak and a suggested request for each step, and `workz report --bottlenecks` says which requests are far above their peaks ([Reports](Reports.md#request-sizing)).
4. Apply the suggestions in the generator, and run again.

Memory requests cover what the kernel charges to the attempt's cgroup, which includes page cache for the files it writes. An attempt that writes a large file under a small request is slowed by reclaim, not killed; one whose own memory exceeds the request is killed as out of memory, with every process of the attempt. Threads become a CPU quota of that many CPUs: a tool that starts more threads than requested is throttled to the quota.

`resources.threads` and `resources.memory` may also be written directly on the rule, and `[defaults]` gives both for rules that set neither. Every rule needs a memory request, from one of these places.

## Logs and benchmarks

Every attempt's standard output and error are always kept in its attempt directory under `.workz/`. Two optional keys copy them where your pipeline expects them:

- `log = "logs/align_s1.log"` writes the attempt's standard output and then its standard error into one file after the attempt ends, under the headings `=== stdout ===` and `=== stderr ===`.
- `benchmark = "benchmarks/align_s1.json"` writes a JSON summary of a completed attempt: `rule`, `wall_time_secs`, `cpu_seconds`, `max_rss_mb`, `memory_peak_mb`, `memory_limit_mb` and `retries`. The three memory fields are in MiB.

Log and benchmark paths follow the rules for outputs, but they are not outputs: no rule may read them.

## Diagnostics

Some tools write the reason they failed to a log of their own, not to standard error: STAR writes it to `Log.out`. Name such files in `diagnostics`, and a failed attempt keeps them:

```toml
[[rules]]
name = "align_s1"
output = ["aligned/s1/Aligned.sortedByCoord.out.bam"]
diagnostics = ["aligned/s1/Log.out"]
shell = "STAR --outFileNamePrefix aligned/s1/ ..."
```

- When an attempt fails, the last 64 KiB of each listed file that exists is copied into the attempt's `diagnostics/` directory, so the next attempt cannot overwrite it.
- The failure line on a terminal shows the last lines of each, `workz logs` prints them after the two streams, and the HTML page shows them under the failure.
- When standard error is empty, the failure reason quotes the last line of the first diagnostics file that has one.
- Only regular files that resolve inside the working directory and outside `.workz/` are read; a missing file is skipped, and listing one file twice is an error. Diagnostics are not outputs and not part of the rule key: adding one reruns nothing.

## Order, retries and time limits

- `priority` (default 0) orders ready rules; higher starts first. Among equal priorities, the rule heading the longest chain of remaining work starts first ([Resources and scheduling](Resources-and-Scheduling.md#which-rule-starts-first)).
- `retries` (0 to 3) runs a failed attempt again. Use it for steps that fail for reasons outside the workflow, such as a busy network share; a deterministic failure fails again.
- `timeout` (`90s`, `30m`, `2h`, `1h30m`) stops an attempt that runs longer and fails it with `timed out after <N> s`.

`workz run --retry N` and `--timeout DURATION` apply to rules that set neither.

## Reuse identical outputs

`cutoff = true` hashes a rule's outputs after it succeeds. When the rule runs again and writes the same bytes, its consumers stay reused instead of running again. It pays off on rules whose outputs repeat byte for byte when their inputs change in ways that do not matter, such as a sorted or filtered file; files that embed a date or a run path gain nothing ([Reuse and resume](Reuse-and-Resume.md#cutoff)).

## Tools that write into the current directory

Some tools write fixed file names into their current directory, or expect their inputs next to them. `workdir` runs the command in a directory of its own, made before each attempt, and `links` places symlinks to some of the rule's inputs there:

```toml
[[rules]]
name = "qc_s1"
input = ["trimmed/s1_1.fq.gz"]
output = ["qc/s1/report.html"]
workdir = "qc/s1"
links = { "reads.fq.gz" = "trimmed/s1_1.fq.gz" }
shell = "qc-tool reads.fq.gz"
```

Paths in `input`, `output`, `log` and `benchmark` stay relative to the working directory; only the command runs in `workdir`. A link replaces an earlier link of the same name but never a regular file.

## Containers

A rule with `container = "IMAGE"` runs its command inside a local image through rootless Podman, and container rules can share one loaded index through a service. [Containers and services](Containers-and-Services.md) covers both.

## Checklist

- Every file the command reads is in `input`; every file it must leave is in `output`.
- Rule names follow `step_sample` or `sample__STEP`.
- Multithreaded tools take `$WORKZ_THREADS`.
- Requests come from a measured run, via `workz report --suggest`.
- Large read-only indexes are shared inputs, and inputs too.
- `workz validate` and `workz plan` pass before the first `workz run`.
