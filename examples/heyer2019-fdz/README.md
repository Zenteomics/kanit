# Fusion calls on four Heyer 2019 samples

`prepare.sh` writes a kanit workflow, `main.toml`, that runs the fusion caller fdz on four samples of the Heyer 2019 data set with known fusions:

1. `subset_SAMPLE` takes the first PAIRS read pairs of each sample. It is a quick demonstration, not a random sample of the reads.
2. `classify_SAMPLE` classifies the read pairs against a refz reference.
3. `junctions_SAMPLE` searches the junctions of the pairs it kept.
4. `merge` merges the calls of the four samples.
5. `report` writes `expected.tsv`: for each sample, its known fusion and how many merged events name both of its genes as whole words.

It shows these workflow features:

- **Shared inputs.** The refz files that fdz maps are declared as [shared inputs](../../wiki/Resources-and-Scheduling.md#shared-inputs), loaded once and counted once in memory admission.
- **A resource group.** `decompress` lets two subsets read compressed FASTQ at once.
- **Priorities.** `junctions` and `classify` rules start before other ready rules.
- **Logs and benchmarks.** Each rule writes its own log and a benchmark file.

## Running it

It needs the fdz binary, the Heyer 2019 directory with its `samples.tsv`, and a refz reference directory with `refz.manifest`:

```sh
bash prepare.sh FDZ_BINARY HEYER2019_DIR REFZ_DIR PAIRS OUT_DIR
cd OUT_DIR
kanit plan main.toml
kanit run main.toml --max-threads 8 --max-memory 16G
kanit report --bottlenecks
```

The paths in `main.toml` are absolute, so the workflow runs only on the machine that prepared it.
