#!/usr/bin/env bash
# Release checks of kanit, run once before a version tag and never per
# commit. The unit tests in Debug and in the shipped mode run separately with
# zig build test; this script checks the binaries:
#   process   the process checks against the Debug build and the shipped
#             build;
#   leaks     every command once against the Debug build, whose allocator
#             reports each leak on stderr when the command ends;
#   mutations random edits to every file kanit reads: workflow files,
#             pipeline templates and sample sheets, state.json, the dispatch
#             journal, the event stream, launch, summary, version and attempt
#             records and input manifests, read by the shipped build, which
#             must exit 0, 1 or 2 and never panic; and mutated control lines
#             sent to a running engine;
#   scale     validate and plan of a generated graph of RULES rules, with
#             their time and peak memory, and a run of RUN_RULES rules;
#   kills     KILLS launches killed at a random moment and resumed, until a
#             last launch completes every rule, verify accepts them, and no
#             engine, task or cgroup of a killed launch is left.
# Usage: validation/release.sh KANIT_DEBUG KANIT_RELEASE OUT_DIR [SEED]
# Both binaries are named kanit. OUT_DIR must not exist. SEED fixes the
# random choices; without one the script picks a seed and prints it.
# MUTATIONS (default 2000), RULES (20000), RUN_RULES (2000) and KILLS (10)
# set the size of each part. Times and sizes go to OUT_DIR/results.tsv.
# Exit status: 0 when every check passed, 1 when one failed, 2 for a wrong
# argument, 3 when none failed but the process checks skipped some.
set -uo pipefail

[ $# -ge 3 ] || { echo "usage: validation/release.sh KANIT_DEBUG KANIT_RELEASE OUT_DIR [SEED]" >&2; exit 2; }
debug=$(realpath "$1")
release=$(realpath "$2")
out=$3
seed=${4:-$(( $(date +%s%N) % 32768 ))}
here=$(cd "$(dirname "$0")" && pwd)
graph="$here/../bench/graph.sh"
for b in "$debug" "$release"; do [ "$(basename "$b")" = kanit ] || { echo "binary not named kanit: $b" >&2; exit 2; }; done
[ -e "$out" ] && { echo "output directory exists: $out" >&2; exit 2; }
mkdir -p "$out"
out=$(realpath "$out")
mutations=${MUTATIONS:-2000}
rules=${RULES:-20000}
run_rules=${RUN_RULES:-2000}
kills=${KILLS:-10}
RANDOM=$seed
export TZ=UTC LANG=C.UTF-8
pass=0
failed=0
ok() { pass=$((pass + 1)); printf 'pass  %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
result() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$out/results.tsv"; }
timed() { local name=$1; shift; /usr/bin/time -f '%e %M' -o "$out/time.tmp" "$@"; local rc=$?; read -r s kib < <(tail -1 "$out/time.tmp"); result "$name" "$s s" "$((kib / 1024)) MiB"; return $rc; }
printf 'part\tvalue\tmemory\n' > "$out/results.tsv"
result seed "$seed" -
echo "seed $seed"

# --- Process checks ---

bash "$here/process.sh" "$debug" "$out/process" > "$out/process.log" 2>&1
process_rc=$?
bash "$here/process.sh" "$release" "$out/process-release" > "$out/process-release.log" 2>&1
process_release_rc=$?
echo "process checks: Debug exit $process_rc ($(tail -1 "$out/process.log")), shipped exit $process_release_rc ($(tail -1 "$out/process-release.log"))"
leaked=$(grep -rlIE "memory address 0x[0-9a-f]+ leaked:" "$out/process" 2> /dev/null | head -5)
check "the process checks pass against the Debug build, and no captured stderr reports a leak" '[ $process_rc != 1 ] && [ $process_rc != 2 ] && [ -z "$leaked" ]'
check "the process checks pass against the shipped build" '[ $process_release_rc != 1 ] && [ $process_release_rc != 2 ]'

# --- Leaks ---

w="$out/leaks"
mkdir -p "$w" && cd "$w" || exit 2
leaks() { "$debug" "$@" > /dev/null 2>> "$w/stderr.log" < /dev/null; }
leaks init
mkdir data && seq 5 > data/S1.txt
leaks validate --inputs
leaks graph --format json
leaks graph --format dot --layer all
leaks plan --summary
leaks plan --budget
leaks explain report
leaks run --no-isolation -q
leaks run --no-isolation -q --rerun-rule report --json
leaks run -q --rerun --max-threads 2 --max-memory 1G
leaks status
leaks status --history
leaks watch --once
leaks report
leaks report --format json
leaks report --format html -o page.html
leaks report --bottlenecks
leaks report --suggest
leaks report --methods
leaks report --compare "$(ls .workz/launches | head -1)"
leaks logs report
leaks verify --content
leaks clean --keep 1 --dry-run
leaks clean --previous
leaks schema
leaks completion bash
leaks help run
leaks run --zzzz
mkdir tpl && (cd tpl && mkdir data && seq 3 > data/S1.txt && seq 4 > data/S2.txt && leaks init --template && leaks prepare && leaks prepare --check)
check "every command ends with no leak reported by the Debug allocator" '! grep -qE "memory address 0x[0-9a-f]+ leaked:" "$w/stderr.log"'

# --- Mutations ---

m="$out/mutations"
mkdir -p "$m/corpus" "$m/failures"
cd "$m/corpus" || exit 2
"$release" init > /dev/null
"$release" init --template > /dev/null
mkdir data && seq 5 > data/S1.txt && seq 3 > data/S2.txt
"$release" run --no-isolation -q > /dev/null
launch=$(ls -d .workz/launches/* 2> /dev/null | tail -1)
[ -n "$launch" ] || { echo "the mutation corpus has no launch: $release run failed in $m/corpus" >&2; exit 1; }
record=$(ls "$launch"/attempts/*/001/record.json | head -1)
printf 'dispatch\tS1__count\ndone\tS1__count\ndispatch\treport\n' > .workz/journal
printf '{"%s": "sha256:%s"}\n' "$PWD/data/S1.txt" "$(sha256sum data/S1.txt | cut -d" " -f1)" > manifest.json
targets=(workflow.toml pipeline.toml samples.tsv .workz/state.json .workz/journal "$launch/events.jsonl" "$record" "$launch/launch.json" "$launch/summary.json" "$launch/versions.json" manifest.json)
mkdir "$m/clean"
for t in "${targets[@]}"; do [ -f "$t" ] || { echo "the mutation corpus lacks $t" >&2; exit 1; }; done
for t in "${targets[@]}"; do cp "$t" "$m/clean/$(echo "$t" | tr / _)"; done
extremes=(0 -1 4294967296 18446744073709551616 1e309 '""' '"x"' '[]' '{}' true)
mutate() {
  local f=$1 size pos ins
  for _ in $(seq $((RANDOM % 4 + 1))); do
    size=$(stat -c %s "$f")
    [ "$size" -gt 0 ] || size=1
    pos=$(( (RANDOM * 32768 + RANDOM) % size ))
    case $((RANDOM % 6)) in
      0) printf "\\x$(printf %02x $((RANDOM % 256)))" | dd of="$f" bs=1 seek=$pos conv=notrunc status=none ;;
      1) { head -c $pos "$f"; tail -c +$((pos + 2 + RANDOM % 16)) "$f"; } > "$f.m" && mv "$f.m" "$f" ;;
      2) ins=""; for _ in $(seq $((RANDOM % 8 + 1))); do ins+="\\x$(printf %02x $((RANDOM % 256)))"; done
         { head -c $pos "$f"; printf "$ins"; tail -c +$((pos + 1)) "$f"; } > "$f.m" && mv "$f.m" "$f" ;;
      3) head -c $pos "$f" > "$f.m" && mv "$f.m" "$f" ;;
      4) { head -c $pos "$f"; tail -c +$((pos + 1)) "$f" | head -c $((RANDOM % 64 + 1)); tail -c +$((pos + 1)) "$f"; } > "$f.m" && mv "$f.m" "$f" ;;
      5) sed -E -i "$((RANDOM % $(wc -l < "$f" | awk '{ print $1 + 1 }') + 1))s/[0-9]+|\"[^\"]*\"|true|false/${extremes[$((RANDOM % ${#extremes[@]}))]}/" "$f" ;;
    esac
  done
}
reads() {
  local i=$1 target=$2
  shift 2
  timeout 20 "$release" "$@" > /dev/null 2> "$m/stderr.txt" < /dev/null
  local rc=$?
  case $rc in
    0|1|2) return 0 ;;
  esac
  local keep="$m/failures/$i-$(basename "$target")"
  mkdir -p "$keep"
  cp "$target" "$keep/input"
  cp "$m/stderr.txt" "$keep/stderr.txt"
  echo "$rc $*" > "$keep/command.txt"
  return 1
}
commands_for() {
  case $1 in
    workflow.toml) echo "validate workflow.toml|plan workflow.toml" ;;
    pipeline.toml|samples.tsv) echo "prepare --check pipeline.toml" ;;
    .workz/state.json|.workz/journal) echo "plan|verify|clean --keep 1 --dry-run" ;;
    */events.jsonl) echo "status|report --bottlenecks|report --format html|watch --once" ;;
    */record.json) echo "report|report --suggest|report --format html" ;;
    */launch.json) echo "status|report --format html|report --methods" ;;
    */summary.json) echo "status|status --history|report" ;;
    */versions.json) echo "report --methods|report --methods --format json" ;;
    manifest.json) echo "plan --input-manifest manifest.json" ;;
  esac
}
bad_cases=0
for i in $(seq "$mutations"); do
  target=${targets[$((RANDOM % ${#targets[@]}))]}
  mutate "$target"
  IFS='|' read -ra cmds <<< "$(commands_for "$target")"
  for c in "${cmds[@]}"; do
    read -ra words <<< "$c"
    reads "$i" "$target" "${words[@]}" || { bad_cases=$((bad_cases + 1)); break; }
  done
  cp "$m/clean/$(echo "$target" | tr / _)" "$target"
done
result mutations "$mutations" -

c="$m/control"
mkdir -p "$c" && cd "$c" || exit 2
{ printf '[workflow]\nname = "control"\nversion = "1"\n'
  printf '\n[[rules]]\nname = "a"\noutput = ["a.txt"]\nshell = "sleep 1; touch a.txt"\nmemory = "1M"\n'
  printf '\n[[rules]]\nname = "b"\ninput = ["a.txt"]\noutput = ["b.txt"]\nshell = "touch b.txt"\nmemory = "1M"\n'
} > wf.toml
controls=$(( mutations / 100 > 5 ? mutations / 100 : 5 ))
control_bad=0
for i in $(seq "$controls"); do
  printf 'stop a\nretry a\ncancel\nstop b\n' > line.txt
  mutate line.txt
  timeout 60 "$release" run wf.toml --no-isolation --rerun -q > /dev/null 2> run.err &
  engine=$!
  for _ in $(seq 50); do grep -qs task_started "$(ls -d .workz/launches/* 2> /dev/null | tail -1)/events.jsonl" && break; sleep 0.1; done
  cat line.txt >> "$(ls -d .workz/launches/* | tail -1)/control"
  wait $engine
  rc=$?
  case $rc in
    0|1|2|130) ;;
    *) control_bad=$((control_bad + 1)); mkdir -p "$m/failures/control-$i"; cp line.txt run.err "$m/failures/control-$i/"; echo "$rc" > "$m/failures/control-$i/status.txt" ;;
  esac
done
check "$mutations mutated input files and $controls mutated control lines to a running engine end with a documented status ($bad_cases and $control_bad kept in $m/failures)" '[ $bad_cases = 0 ] && [ $control_bad = 0 ]'

# --- Scale ---

s="$out/scale"
mkdir -p "$s" && cd "$s" || exit 2
bash "$graph" "$rules" 200 big.toml
timed "validate $rules rules" "$release" validate big.toml > /dev/null
vrc=$?
timed "plan $rules rules" "$release" plan big.toml --summary > /dev/null
prc=$?
mkdir run && cd run || exit 2
bash "$graph" "$run_rules" 100 wf.toml
timed "run $run_rules rules" "$release" run wf.toml --no-isolation -j 4 --max-threads 4 --max-memory 2G -q > first.json
rrc=$?
timed "resume $run_rules rules" "$release" run wf.toml --no-isolation -q > again.json
arc=$?
check "a generated graph of $rules rules validates and plans, and $run_rules rules run and resume" '[ $vrc = 0 ] && [ $prc = 0 ] && [ $rrc = 0 ] && [ "$(jq -r .counts.completed first.json)" = "$run_rules" ] && [ $arc = 0 ] && [ "$(jq -r .counts.reused again.json)" = "$run_rules" ]'

# --- Kills ---

k="$out/kills"
mkdir -p "$k" && cd "$k" || exit 2
bash "$graph" 120 12 wf.toml 'echo $$ >> pids.txt; sleep 0.$((RANDOM % 4)); echo {output} > {output}'
engines=()
for i in $(seq "$kills"); do
  mode=(--no-isolation)
  [ $((i % 2)) = 0 ] && mode=(--max-threads 4 --max-memory 2G)
  "$release" run wf.toml "${mode[@]}" -j 4 -q > "kill-$i.json" 2>> kill.err &
  engine=$!
  engines+=("$engine")
  sleep "$((RANDOM % 3)).$((RANDOM % 10))"
  kill -KILL $engine 2> /dev/null
  wait $engine 2> /dev/null
done
"$release" run wf.toml --no-isolation -j 4 -q > last.json 2>> kill.err
lrc=$?
"$release" verify wf.toml > verify.txt
vrc=$?
complete=1
for n in $(seq 0 119); do [ "$(cat "o_$n.txt" 2> /dev/null)" = "o_$n.txt" ] || complete=0; done
left=0
for _ in $(seq 50); do
  left=0
  for p in "${engines[@]}" $(cat pids.txt 2> /dev/null); do [ -d "/proc/$p" ] && ! grep -q '^State:.*Z' "/proc/$p/status" 2> /dev/null && left=$((left + 1)); done
  for cg in $(jq -r 'select(.event == "launch_started") | .cgroup // empty' .workz/launches/*/events.jsonl 2> /dev/null); do [ -d "$cg" ] && left=$((left + 1)); done
  [ $left = 0 ] && break
  sleep 0.1
done
result "kills" "$kills" -
check "after $kills killed launches, the next completes every rule with the right bytes, verify accepts them, and no engine, task or cgroup is left" '[ $lrc = 0 ] && [ $vrc = 0 ] && [ $complete = 1 ] && [ $left = 0 ]'

echo
echo "$pass passed, $failed failed (seed $seed; results in $out/results.tsv)"
[ $failed = 0 ] || exit 1
[ $process_rc = 3 ] || [ $process_release_rc = 3 ] && exit 3
exit 0
