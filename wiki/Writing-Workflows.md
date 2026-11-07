A kanit workflow is a flat list of concrete rules. This page covers how to structure one, how to write it from a pipeline template or a program, how to check it, and how to choose the requests and options that make it run well. The [workflow reference](Workflow-Reference.md) lists every key.

## Anatomy of a rule

```toml
[[rules]]
name = "align_s1"
input = ["trimmed/s1_1.fq.gz", "trimmed/s1_2.fq.gz"]
output = ["aligned/s1.bam"]
shell = """bowtie2 --mm -p $WORKZ_THREADS -x ref/bowtie2/genome \
  -1 trimmed/s1_1.fq.gz -2 trimmed/s1_2.fq.gz \
  | samtools view -b -o aligned/s1.bam -"""
priority = 10
log = "logs/align_s1.log"
benchmark = "benchmarks/align_s1.json"

[rules.resources]
threads = 8
memory = "2G"
shared = ["index"]
```

- `name` is unique in the workflow: letters, digits, `_`, `.` and `-`, starting with a letter or digit.
- `input` lists every file or directory the command reads, and `output` every file it writes. They are the only way rules connect, and the only files kanit watches for changes.
- `shell` is one command line, run in the rule's `workdir` or else the working directory, so relative paths start there. A host rule runs it with `bash -euo pipefail`, so a failing command anywhere in a pipeline fails the rule; a [container rule](Containers-and-Services.md) runs it with the image's `/bin/sh` and `set -eu`, with `pipefail` where that shell has it. A long command can be a TOML multi-line string, as here: a backslash at the end of a line joins the next line to it, without the line break or the indentation.
- `[rules.resources]` holds the request: `threads`, `memory`, units of resource groups, and the shared inputs the rule uses.
- `priority`, `log`, `benchmark` and the other keys are optional.

## Inputs and outputs

kanit runs a rule's command only after every rule that produces one of its inputs has completed, and it decides reuse by the identity of those files. Declare them completely:

- **Declare every file the command reads**, including scripts, reference files and configuration. An undeclared input is invisible: editing it never reruns the rule, and nothing orders the rule after its producer.
- **Declare every file the command must leave behind.** After the command exits 0, kanit checks that each output exists as a regular file; a missing one fails the attempt with `exited 0 without output <path>`. Temporary files need not be declared.
- **Outputs live inside the working directory**, as relative paths without `..`, and outside `.workz/`. Inputs may be anywhere.
- **Directories can be inputs.** A directory's identity covers every file and directory below it, so adding, removing or changing any of them reruns the rule. A rule cannot write inside its own directory input. An index such as `ref/bowtie2` is a natural directory input.
- **There are no wildcards.** Paths name files exactly; `*`, `?`, `[ ]` and `{ }` are errors. Inside `shell`, use whatever the shell allows.

kanit creates the directory of every output before an attempt starts, and moves any output already there into the attempt's `previous/` directory, so a command always starts from a clean slate and earlier bytes are never lost ([Reuse and resume](Reuse-and-Resume.md#previous-outputs)).

## Label every rule

Give each rule its `step`, its `sample` when it works on one, and a `category` and `tool` where they help: the reports, the launch page and the graph group by them, and the scheduler estimates a new rule from its step ([Concepts](Concepts.md#steps-samples-categories-and-tools)). A template labels its rules itself. Labels are not part of the rule key, so adding them to a workflow that already ran reruns nothing; rules that declare none are labelled from their names: `align_s1` is the step `align`, and `s1__ALIGN` is the step `ALIGN` of the sample `s1`.

## Prepare from a template

Real workflows have one rule per sample and step. Write each step once in a pipeline template, list the samples in a sheet, and `kanit prepare` writes the explicit workflow, with every rule spelled out: the file the engine runs and you review and diff.

`samples.tsv`, a header line and one row per sample:

```text
sample	r1	r2
s1	reads/s1_1.fq.gz	reads/s1_2.fq.gz
s2	reads/s2_1.fq.gz	reads/s2_2.fq.gz
```

`pipeline.toml`:

```toml
[workflow]
name = "rnaseq"

[samples]
sheet = "samples.tsv"

[[steps]]
name = "trim"
for_each = "sample"
input = ["{r1}", "{r2}"]
output = ["trimmed/{sample}_1.fq.gz", "trimmed/{sample}_2.fq.gz"]
shell = """fastp -i {r1} -I {r2} -w {threads} \
  -o trimmed/{sample}_1.fq.gz -O trimmed/{sample}_2.fq.gz"""
threads = 4
memory = "2G"

[[steps]]
name = "report"
input = ["trimmed/{sample}_1.fq.gz"]
output = ["report.tsv"]
shell = "for f in {input}; do echo $f; done > {output}"
memory = "256M"
```

```sh
kanit prepare
```

```text
wrote .../workflow.toml: 3 rules from 2 steps. Next: kanit graph --by step, then kanit plan
```

- A step with `for_each = "sample"` becomes one rule per row, named `SAMPLE__STEP` (`s1__trim`) and labelled with its `step` and `sample`, so every report and view groups by them. A step without it is one rule, named as the step.
- `{name}` takes a column of the sheet, a `[params]` value, or `{step}`; the values of `[workflow]`, `[defaults]`, `[resource_groups]` and `[shared]` may name params. In `shell`, `{input}` and `{output}` are the rule's own inputs and outputs (space-separated), and `{threads}` becomes `${WORKZ_THREADS}`, the threads the rule gets when it runs, so a `--threads` override reaches the tool.
- A value goes into `shell` as written, so a path with a space or a quote would split or break the command. `{name:q}` quotes the value as one shell word, and `{input:q}` and `{output:q}` quote each path: with `r1` set to `my reads.fq`, `fastp -i {r1:q}` becomes `fastp -i 'my reads.fq'`. A value that needs no quotes stays as it is.
- In a step without `for_each`, a list element naming a sheet column becomes one element per sample: the report above reads every sample's file.
- `[samples] defaults = { adapter = "CTGTC" }` gives a column a value for rows that leave it empty, and for every row when the sheet has no such column, so a sheet lists only what differs. An empty cell of a column without a default is refused.
- Only those names are replaced. Other braces stay as written, so awk's `{print $1}` needs no escaping, and a brace after `$` is always the shell's: `${HOME}` and `${sample}` reach the shell as written; anywhere but `shell` and a service's `command`, an unknown `{name}` is an error, and so is a column used outside a `for_each` step.
- The workflow is checked as `validate` would before it replaces `workflow.toml`; one that is not valid is left beside it to read, and `workflow.toml` is unchanged.
- A pipeline kept apart from its runs: `kanit prepare /path/pipeline.toml --params run.toml` reads the run file's `[workflow]` keys (the run's name), `[params]` (its references and tools) and `[samples]` (its sheet, beside the run file) in place of the template's, and writes `workflow.toml` beside the run file. The template's steps stay one file for every run ([run files](Workflow-Reference.md#run-files)).
- `kanit prepare --check` prints the rules an edit would add, remove and change, and exits 1 if any, without writing: review it before a long launch.
- `kanit init --template` writes a commented starter template and sample sheet. The format is in the [workflow reference](Workflow-Reference.md#pipeline-templates).

## Generate the file

When a template cannot express a pipeline, a program can write the workflow file instead; any language works, since the file is plain TOML. This bash script reads a sample sheet and writes a trim, align and count workflow:

`samples.tsv`

```text
s1	reads/s1_1.fq.gz	reads/s1_2.fq.gz
s2	reads/s2_1.fq.gz	reads/s2_2.fq.gz
s3	reads/s3_1.fq.gz	reads/s3_2.fq.gz
```

`make-workflow.sh`

```bash
#!/usr/bin/env bash
# Writes workflow.toml: trim and align each sample in samples.tsv, then count reads per gene.
set -euo pipefail
bams=()
{
  printf '[workflow]\nname = "rnaseq"\n\n'
  printf '[resource_groups.disk]\nmax = 2\n\n'
  printf '[shared.index]\npath = "ref/bowtie2"\n\n'
  while IFS=$'\t' read -r s r1 r2; do
    t1="trimmed/${s}_1.fq.gz" t2="trimmed/${s}_2.fq.gz"
    align="bowtie2 --mm -p \$WORKZ_THREADS -x ref/bowtie2/genome -1 $t1 -2 $t2"
    cat <<EOF
[[rules]]
name = "trim_$s"
step = "trim"
sample = "$s"
category = "trimming"
tool = "fastp"
input = ["$r1", "$r2"]
output = ["$t1", "$t2"]
shell = "fastp -w \$WORKZ_THREADS -i $r1 -I $r2 -o $t1 -O $t2"
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
input = ["$t1", "$t2"]
output = ["aligned/$s.bam"]
shell = "$align | samtools view -b -o aligned/$s.bam -"
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
  count="featureCounts -T \$WORKZ_THREADS -p --countReadPairs -s 2 -a ref/genes.gtf"
  cat <<EOF
[[rules]]
name = "count_genes"
step = "count_genes"
category = "quantification"
tool = "featureCounts"
input = ["ref/genes.gtf", ${quoted%, }]
output = ["counts.tsv"]
shell = "$count -o counts.tsv ${bams[*]}"
threads = 4
memory = "4G"
EOF
} > workflow.toml
```

`-s 2` counts reverse-stranded reads, as dUTP library kits produce; set the strandedness your library has, since featureCounts counts unstranded by default.

With the reads, `ref/genes.gtf` and the index in `ref/bowtie2/` in place:

```sh
bash make-workflow.sh
kanit validate workflow.toml
kanit plan workflow.toml --summary
```

```text
valid: rnaseq (7 rules, 7 selected, 1 groups, 1 shared)
     4 run   a producer runs
     3 run   no completed record
7 to run, 0 to reuse
```

Some choices in this script are worth copying:

- `\$WORKZ_THREADS` stays a variable in the file and expands when the rule runs, to the threads the rule requested. Passing it to every multithreaded tool keeps the tool's threads equal to its CPU quota.
- The bowtie2 index is a [shared input](Resources-and-Scheduling.md#shared-inputs): kanit loads it once for all alignments, and counts it as an input of each, so rebuilding the index reruns them.
- `bowtie2 --mm` maps the index instead of reading it, so the alignments share one copy of it in memory, which is what makes a shared input pay off.
- The `disk` group lets at most two trims read from disk at once, while alignments with `priority = 10` start before trims that become ready at the same time.
- Every rule says what it is: its step, sample, category and tool. The script knows them, so the reports can group by them.
- Regenerating the file is safe. Rules whose command, request and inputs did not change are reused.

## Check before running

Four commands read the workflow and run nothing:

- `kanit validate` checks every key, value and path, and the graph, and lists every problem at once with its line. It also notes what is valid but likely a mistake: a shared input or resource group no selected rule uses, or a rule without `sample` among rules of its step that have one.
- `kanit validate --inputs` also lists the inputs that no rule writes and that do not exist, and exits 1 if there are any.
- `kanit graph` shows what the file declares, in layers.
- `kanit plan --budget` says what would run and whether every rule fits the budget with its shared inputs; `run` refuses a launch in which one does not.

On a small pipeline with two samples, an index built by a rule and loaded once by a service, and a disk group, here is the resources layer by step:

```sh
kanit graph --layer resources --by step
```

```text
index (1 rule)  8 threads, 32.0 GiB
  before align
trim (2 rules)  1 thread, 1.0 GiB
  before align
  takes 1 of group disk
align (2 rules)  1 thread, 2.0 GiB
  after index, trim
  before report
  joins shared genome
report (1 rule)  1 thread, 1.0 GiB
  after align
shared genome  service, 30.0 GiB held once, ref/star
  loaded from index
  used by align
group disk  max 2
  taken by trim
```

Questions you can ask it:

- Who writes and who uses a shared input: `kanit graph --users genome`.
- Why one rule waits for another: `kanit graph --why s1__trim:report` prints the path and the file each rule reads.
- What a rule needs, or what needs it: `--focus +report`, `--focus index+`, or `--focus 1+report` for one level.
- Every file between the rules: `--layer files`; everything at once: `--layer all`.

Off a terminal it prints Graphviz DOT, so `kanit graph --layer resources --by step > graph.dot` draws with `dot -Tsvg graph.dot > graph.svg`: rules and steps as boxes, files as notes, shared inputs as cylinders with their memory, groups as hexagons. `--format json` gives the same graph to other tools ([Command reference](Command-Reference.md#graph)).

The same workflow on a 32 GiB budget, where each alignment needs its 2 GiB, the 30 GiB service and the Podman client:

```sh
kanit plan --budget --summary --max-threads 16 --max-memory 32G
```

```text
     3 run   input missing
     3 run   a producer runs
6 to run, 0 to reuse

budget: 16 threads, 32.0 GiB
shared genome: 30.0 GiB held once, with its Podman client
does not fit: s1__align needs 1 thread and 32.1 GiB
does not fit: s2__align needs 1 thread and 32.1 GiB
largest: s1__align needs 1 thread and 32.1 GiB with its shared inputs
2 rules do not fit: run would refuse the launch
```

That is standard output. Standard error names what `run` would also refuse, here the three missing inputs, and `plan` exits 1.

## Choose requests

A request is both a reservation and a limit, so it pays to size it from measurements:

1. Start generous: enough memory that nothing is killed, and the threads you want each tool to use.
2. Run the workflow, or a few samples of it.
3. Ask kanit what each step used: `kanit report --suggest` prints the largest peak and a suggested request for each step, and `kanit report --bottlenecks` says which requests are far above their peaks ([Reports](Reports.md#request-sizing)).
4. Apply the suggestions in the template or generator, and run again.

The memory request is a hard limit that counts page cache, and the thread request a CPU quota ([Limits on each attempt](Resources-and-Scheduling.md#limits-on-each-attempt)): size memory for the largest input you expect, and pass `$WORKZ_THREADS` to every multithreaded tool.

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
- The failure line on a terminal shows the last lines of each, `kanit logs` prints them after the two streams, and the HTML page shows them under the failure.
- When standard error is empty, the failure reason quotes the last line of the first diagnostics file that has one.
- Only regular files that resolve inside the working directory and outside `.workz/` are read; a missing file is skipped, and listing one file twice is an error. Diagnostics are not outputs and not part of the rule key: adding one reruns nothing.

## Tool versions

A methods section names each tool's version. Give a rule `version`, a command that prints it, and kanit records what it prints:

```toml
[[rules]]
name = "align_s1"
container = "community.wave.seqera.io/library/htslib_samtools_star_gawk:ae438e9a604351a4"
version = "STAR --version"
shell = "STAR --runThreadN 8 ..."
```

- The command runs once per launch for each image and command, when the first rule that names it starts: in the rule's image, with no network and nothing of the working directory mounted, or on the host for a host rule. Version commands run one at a time beside the rules, outside the budget, so keep them short; when the rules have ended, kanit waits at most 10 s for those still queued or running, and stops the rest.
- What it prints, the first 4 KiB of its standard output and error, goes to the launch's `versions.json`, with whether it completed; a command that failed records no version. Each attempt's `record.json` names its `version` command and its `image` ID.
- A launch that reuses every rule runs none: the launch that ran them recorded their versions.
- `version` is not part of the rule key: adding one reruns nothing, and the next launch that runs the rule records it.
- `kanit report --methods` lists each tool with its version and image ([Reports](Reports.md#methods)).

## Order, retries and time limits

- `priority` (default 0) orders ready rules; higher starts first. Among equal priorities, the rule heading the longest chain of remaining work starts first ([Resources and scheduling](Resources-and-Scheduling.md#which-rule-starts-first)).
- `retries` (0 to 3) runs a failed attempt again. Use it for steps that fail for reasons outside the workflow, such as a busy network share; a deterministic failure fails again.
- `timeout` (`90s`, `30m`, `2h`, `1h30m`) stops an attempt that runs longer and fails it with `timed out after <N> s`.

`kanit run --retry N` and `--timeout DURATION` apply to rules that set neither.

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

## Editor support

`kanit schema` prints a JSON Schema of the format, made from the same key lists `validate` checks. An editor that validates TOML against a schema then completes keys, shows each key's help, and marks a misspelled key as you type. With the Even Better TOML extension, or any editor using the Taplo language server, put this in `.taplo.toml` at the top of your project:

```toml
[[rule]]
include = ["**/workflow.toml"]
[rule.schema]
path = "./kanit.schema.json"
```

and write the schema next to it with `kanit schema > kanit.schema.json`.

## Checklist

- Every file the command reads is in `input`; every file it must leave is in `output`.
- Rule names follow `step_sample` or `sample__STEP`.
- Multithreaded tools take `$WORKZ_THREADS`.
- Requests come from a measured run, via `kanit report --suggest`.
- Large read-only indexes are shared inputs, which count as inputs of the rules using them.
- `kanit validate --inputs` and `kanit plan --budget` pass, and `kanit graph` shows the links you meant, before the first `kanit run`.
