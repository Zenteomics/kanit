#!/usr/bin/env bash
# Runs a three-rule report tour in a new directory; --live adds two six-second waits.
# Usage: timeout 30s bash run.sh OUTPUT_DIR [--live]
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || { [ "$#" = 2 ] && [ "$2" != --live ]; }; then
  echo 'usage: timeout 30s bash run.sh OUTPUT_DIR [--live]' >&2
  exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
workz=$(realpath "${WORKZ:-$here/../../zig-out/bin/kanit}")
[ -x "$workz" ] || { echo "kanit binary is not executable: $workz" >&2; exit 2; }
out=$(realpath -m "$1")
if [ -e "$out" ] || [ -L "$out" ]; then
  echo "output directory already exists: $out" >&2
  exit 2
fi
pause=0
[ "${2:-}" != --live ] || pause=6
mkdir -m 700 "$out"
mkdir "$out/inputs" "$out/reports"
cp "$here/pipeline.toml" "$here/samples.tsv" "$out/"
printf 'A\nC\nG\n' > "$out/inputs/alpha reads.txt"
printf 'A\nC\nG\nT\nN\n' > "$out/inputs/beta.txt"
printf '[workflow]\nname = "report-tour"\n[params]\npause = "%s"\n' "$pause" > "$out/run.toml"
cd "$out"
runner=''
finish() {
  if [ -n "$runner" ]; then
    kill -TERM "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
  fi
}
trap finish EXIT
trap 'exit 130' INT TERM
budget=(--max-threads 2 --max-memory 256M --jobs 2 --grace 1s --json)

printf 'Preparing three rules from two samples and a run file.\n'
"$workz" prepare pipeline.toml --params run.toml
"$workz" validate --inputs
"$workz" plan --budget --max-threads 2 --max-memory 256M

printf '\nFirst launch. Reports stay in %s/reports/\n' "$out"
"$workz" run "${budget[@]}" > reports/first.json &
runner=$!
if [ "$pause" != 0 ]; then
  printf 'Live view from another terminal: %q watch -d %q\n' "$workz" "$out"
  sleep 11
  "$workz" report --format html -o reports/live.html
  printf 'Live page: %s/reports/live.html\n' "$out"
fi
wait "$runner"
runner=''
"$workz" status
printf '3\n5\n' > reports/expected.txt
cmp reports/expected.txt report.txt
"$workz" report --format html -o reports/completed.html
if [ "$pause" != 0 ]; then
  "$workz" report --format html -o reports/live.html
fi
"$workz" report --bottlenecks > reports/bottlenecks.txt
"$workz" report --suggest > reports/suggest.tsv

printf '\nUnchanged launch: all three rules should be reused.\n'
"$workz" run "${budget[@]}" > reports/reused.json
"$workz" status
"$workz" report --format html -o reports/reused.html

printf '\nA forced report failure: the last good output must come back.\n'
printf 'fail the next forced report\n' > fail-report
rc=0
"$workz" run "${budget[@]}" --rerun-rule report > reports/failed.json || rc=$?
[ "$rc" = 1 ] || { echo "expected failure status 1, got $rc" >&2; exit 1; }
"$workz" status
cmp reports/expected.txt report.txt
"$workz" report --format html -o reports/failed.html
"$workz" logs report --stderr > reports/failure.log

printf '\nThe failure is gone: the restored successful result can be reused.\n'
mv fail-report failure-demonstrated
"$workz" run "${budget[@]}" > reports/restored.json
"$workz" status
cmp reports/expected.txt report.txt
"$workz" status --history > reports/history.txt
printf '\nTour complete: %s/reports/completed.html\n' "$out"
printf 'Compare completed.html, reused.html and failed.html; report.txt still contains 3 and 5.\n'
