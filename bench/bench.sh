#!/usr/bin/env bash
# Measures kanit against an earlier kanit with zebrac on generated workflows:
# dispatch of many short rules from a fresh directory, with and without
# isolation; a resume in which every rule is reused; and validate and plan of
# a large graph. Each batch runs both binaries in interleaved rounds, so both
# see the same machine load; the first binary named is the baseline. Run it
# after the release checks pass.
# Usage: bench/bench.sh KANIT_BASELINE KANIT OUT_DIR
# DISPATCH (default 500), RESUME (5000) and PLAN (20000) set the number of
# rules of each workload. Each batch writes its JSON report to OUT_DIR.
set -euo pipefail
[ $# = 3 ] || { echo "usage: bench/bench.sh KANIT_BASELINE KANIT OUT_DIR" >&2; exit 2; }
old=$(realpath "$1") new=$(realpath "$2") out=$3
here=$(cd "$(dirname "$0")" && pwd)
[ -e "$out" ] && { echo "output directory exists: $out" >&2; exit 2; }
mkdir -p "$out"
out=$(realpath "$out")
cold="$here/cold.sh"
dispatch=${DISPATCH:-500} resume=${RESUME:-5000} plan=${PLAN:-20000}
budget="--max-threads 8 --max-memory 4G -j 8 -q"

t="$out/tpl-dispatch"
mkdir -p "$t" "$out/runs"
bash "$here/graph.sh" "$dispatch" "$dispatch" "$t/workflow.toml"
zebrac -w 1 -i 5 -a 5 --json "$out/dispatch-$dispatch.json" -- \
  "$cold $out/runs $t $old run workflow.toml $budget --no-isolation" \
  "$cold $out/runs $t $new run workflow.toml $budget --no-isolation"
zebrac -w 1 -i 5 -a 5 --json "$out/dispatch-$dispatch-isolated.json" -- \
  "$cold $out/runs $t $old run workflow.toml $budget" \
  "$cold $out/runs $t $new run workflow.toml $budget"

for b in old new; do
  mkdir -p "$out/resume-$b"
  bash "$here/graph.sh" "$resume" 100 "$out/resume-$b/workflow.toml"
done
"$old" run "$out/resume-old/workflow.toml" $budget --no-isolation > /dev/null
"$new" run "$out/resume-new/workflow.toml" $budget --no-isolation > /dev/null
zebrac -w 1 -i 3 -a 3 --json "$out/resume-$resume.json" -- \
  "$old run $out/resume-old/workflow.toml $budget --no-isolation" \
  "$new run $out/resume-new/workflow.toml $budget --no-isolation"

bash "$here/graph.sh" "$plan" 200 "$out/plan.toml"
zebrac -w 1 -i 3 -a 3 --json "$out/validate-$plan.json" -- \
  "$old validate $out/plan.toml" \
  "$new validate $out/plan.toml"
zebrac -w 1 -i 3 -a 3 --json "$out/plan-$plan.json" -- \
  "$old plan $out/plan.toml --summary" \
  "$new plan $out/plan.toml --summary"
