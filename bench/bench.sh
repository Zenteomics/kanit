#!/usr/bin/env bash
# Measures workz against oxo-local and Nextflow with zebrac. Each batch runs
# its engines in interleaved rounds, so all see the same machine load.
# Usage: bench/bench.sh WORKZ OXO_LOCAL_BINARY NEXTFLOW RNAFUSION_RUN OUT_DIR
set -euo pipefail
workz=$(realpath "$1") oxo=$(realpath "$2") nextflow=$(realpath "$3") run=$(realpath "$4") out=$5
here=$(cd "$(dirname "$0")" && pwd)
[ -e "$out" ] && { echo "output directory exists: $out" >&2; exit 2; }
mkdir -p "$out"
out=$(realpath "$out")
cold="$here/cold.sh"

# Dispatch: 32 independent tasks that each write their number.
t="$out/tpl-dispatch"; mkdir -p "$t"
{ printf '[workflow]\nname = "dispatch"\nversion = "1"\n'
  for i in $(seq 0 31); do printf '\n[[rules]]\nname = "w%s"\ninput = []\noutput = ["%s.txt"]\nshell = "echo %s > %s.txt"\n[rules.resources]\nthreads = 1\nmemory = "64M"\n' $i $i $i $i; done
} > "$t/main.oxoflow"
n="$out/tpl-nextflow"; mkdir -p "$n"
cat > "$n/main.nf" <<'NF'
nextflow.enable.dsl=2
process WRITE {
    cpus 1
    memory '64 MB'
    input:
    val item
    output:
    path "${item}.txt"
    script:
    """
    printf '%s\n' '${item}' > '${item}.txt'
    """
}
workflow { WRITE(Channel.fromList((0..31).toList())) }
NF
printf "executor { name='local'; cpus=4; memory='2 GB'; queueSize=4 }\n" > "$n/nextflow.config"
mkdir -p "$out/runs"
export NXF_OFFLINE=true NXF_HOME="$out/nextflow-home" NXF_ANSI_LOG=false
zebrac -w 1 -i 5 -a 5 --json "$out/dispatch-32.json" -- \
  "$cold $out/runs $t $workz run main.oxoflow -j 4 --max-threads 4 --max-memory 2G -q" \
  "$cold $out/runs $t $workz run main.oxoflow -j 4 --max-threads 4 --max-memory 2G -q --no-isolation" \
  "$cold $out/runs $t $oxo run main.oxoflow -d . -j 4 --max-threads 4 --max-memory 2048" \
  "$cold $out/runs $n $nextflow run main.nf -c nextflow.config"

# The real rnaFusion graph, with each command replaced by one that creates its outputs.
r="$out/tpl-replay"; mkdir -p "$r"
bash "$here/replay.sh" "$run" "$r/main.oxoflow"
zebrac -w 1 -i 5 -a 5 --json "$out/replay-561-cold.json" -- \
  "$cold $out/runs $r $workz run main.oxoflow --max-threads 8 --max-memory 20G -q" \
  "$cold $out/runs $r $workz run main.oxoflow --max-threads 8 --max-memory 20G -q --no-isolation"

# Full resume of the replay: every rule reusable. The warmup round
# completes each directory with the binary being measured.
for e in iso noiso oxo; do mkdir -p "$out/resume-$e"; cp "$r/main.oxoflow" "$out/resume-$e/"; done
zebrac -w 1 -i 3 -a 3 --json "$out/replay-561-resume.json" -- \
  "$workz run $out/resume-iso/main.oxoflow --max-threads 8 --max-memory 20G -q" \
  "$workz run $out/resume-noiso/main.oxoflow --max-threads 8 --max-memory 20G -q --no-isolation" \
  "$oxo run $out/resume-oxo/main.oxoflow -d $out/resume-oxo -j 8 --max-threads 8 --max-memory 20480"
