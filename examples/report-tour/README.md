# A small report tour

Two tiny text inputs and three rules demonstrate run files, quoted paths, rule labels, HTML reports, reuse and recovery after a failed rerun. Nothing is downloaded. The run budget is two threads and 256 MiB; the isolated engine also has its usual 256 MiB headroom.

## Run

Use a built kanit binary, Bash, GNU coreutils, and the systemd user manager and cgroup v2 required by an isolated run. The script uses `zig-out/bin/kanit` by default; `WORKZ` can name another binary. It does not build or install anything.

From the repository root, choose a new output directory under an existing parent:

```sh
tour=$(mktemp -d /var/tmp/workz-tour.XXXXXX)
timeout 30s bash examples/report-tour/run.sh "$tour/run"
```

The default tour has no deliberate waits. For a live view and two resource samples, add `--live`:

```sh
live_tour=$(mktemp -d /var/tmp/workz-tour.XXXXXX)
timeout 30s bash examples/report-tour/run.sh "$live_tour/run" --live
```

Live mode adds two six-second waits: the two count rules wait concurrently, then the report rule waits. It normally takes about twelve seconds plus startup and reporting. The outer timeout caps the complete tour at thirty seconds. Each rule also has a ten-second timeout. The waits make the states visible; they are not a CPU or memory benchmark.

The script refuses an existing output directory and keeps every output and record. Use another new directory to repeat the tour.

## What happens

1. `prepare` reads `pipeline.toml`, `samples.tsv` and `run.toml`. The file `inputs/alpha reads.txt` demonstrates a path with a space handled by `{input:q}`. The explicit workflow contains `alpha__count`, `beta__count` and `report`.
2. The first launch writes counts of three and five lines. `reports/completed.html` shows the steps, samples, attempts and recorded resource figures.
3. An unchanged launch reuses all three rules. `reports/reused.html` shows those results with the earlier attempts that produced them.
4. The tour creates a control marker and forces the report rule to fail after writing a partial output. `reports/failed.html` shows that failure. The engine restores the last good `report.txt`; the script compares its bytes with the expected result.
5. After moving the marker aside, another launch can reuse the restored successful record. `reports/history.txt` and the JSON summaries retain each launch's outcome.

The failure marker deliberately simulates a transient command failure. It is not a data input; the script explicitly forces that attempt with `--rerun-rule report`.

## Explore the report

Open `reports/completed.html` in Firefox. Try the light and dark theme controls, follow the navigation links, and hover a rule cell or timeline bar for its values. Open `reused.html` and `failed.html` beside it to compare outcomes. All three are complete local files with no scripts or remote assets.

In live mode, the script prints a `kanit watch -d ...` command for another terminal. It also writes `reports/live.html` near the end of the live launch, then replaces it with the completed page. The live page reloads every fifteen seconds; reload it manually to see the final result sooner. The terminal view remains the faster way to follow this short demonstration.

Running rules have a steady outline, and print renders every section. CPU and memory figures remain five-second samples: changing the HTML refresh period does not change the measurements. The quick tour is too short for those charts; live mode normally records two samples, enough to show the chart but not to judge resource sizing.

## Files to keep

- `pipeline.toml`, `samples.tsv`, `run.toml` and `workflow.toml`: the authoring inputs and explicit graph.
- `report.txt`: the successful output, including after the forced failure.
- `reports/`: HTML pages, launch summaries, sizing suggestions, the failure log and history.
- `.workz/`: full launch and attempt records, including the failed attempt's partial output.

You can inspect an output directory with `kanit status -d DIR --history`, `kanit logs -d DIR report` and `kanit report -d DIR --format html`. The existing `.workz/` records and generated HTML retain the version and behavior of the binary that wrote them; use a fresh binary and new directory when checking a changed report.
