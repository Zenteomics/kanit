#!/usr/bin/env bash
# Process checks of the kanit binary: what only real child processes, cgroups,
# signals, containers, terminals and the filesystem can show. Decisions and
# text that need no process are unit tests in tests/.
# Usage: validation/process.sh KANIT OUT_DIR [SECTION...]
# OUT_DIR must not exist; every check gets its own working directory there.
# Without a SECTION every section runs. The sections are reuse, cutoff,
# containers, services, failures, termination, admission, inputs, commands,
# monitoring and terminal.
# Container and service checks need rootless Podman with the local images
# named below (kanit never pulls), the terminal checks need tmux and the
# network checks python3; without them those checks are skipped. Run one
# suite at a time: suites share the names of temporary Podman images.
# Exit status: 0 when every check passed, 1 when one failed, 2 for a wrong
# argument or an existing OUT_DIR, 3 when none failed but some were skipped.
set -uo pipefail

all="reuse cutoff containers services failures termination admission inputs commands monitoring terminal"
[ $# -ge 2 ] || { echo "usage: validation/process.sh KANIT OUT_DIR [SECTION...]" >&2; exit 2; }
kanit=$(realpath "$1")
out=$2
shift 2
for name in "$@"; do
  [[ " $all " == *" $name "* ]] || { echo "no section named $name; the sections are: $all" >&2; exit 2; }
done
selected=" ${*:-$all} "
want() { [[ $selected == *" $1 "* ]]; }
[ -e "$out" ] && { echo "output directory exists: $out" >&2; exit 2; }
mkdir -p "$out"
out=$(realpath "$out")
export TZ=UTC LANG=C.UTF-8
pass=0
failed=0
skipped=0

ok() { pass=$((pass + 1)); printf 'pass  %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
skip() { skipped=$((skipped + 1)); printf 'skip  %s\n' "$1"; }
wait_until() { local n=$1; for _ in $(seq "$n"); do eval "$2" && return 0; sleep 0.1; done; return 1; }
new() { local d="$out/$1"; mkdir -p "$d"; cd "$d" || exit 2; }
rule() {
  printf '[[rules]]\nname = "%s"\ninput = %s\noutput = %s\nshell = %s\n%s\n[rules.resources]\nthreads = 1\nmemory = "64M"\n\n' \
    "$1" "$2" "$3" "$4" "${5:-}"
}
header() { printf '[workflow]\nname = "%s"\nversion = "1"\n\n' "$1"; }
status_of() { jq -r ".counts.$2" "$1"; }
last_launch() { ls -d .workz/launches/* | tail -1; }
alive() { [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
iso=(--max-threads 4 --max-memory 2G)

img=community.wave.seqera.io/library/coreutils_grep_gzip_lbzip2_pruned:838ba80435a629f8
star=community.wave.seqera.io/library/htslib_samtools_star_gawk:ae438e9a604351a4
img2=$star
have_images() { command -v podman > /dev/null && podman image exists "$@" 2> /dev/null; }
leftovers() { podman ps --all --quiet --filter "label=workz.workdir=$PWD" | wc -l; }
drop_alias() {
  local id
  id=$(podman image inspect --format '{{.Id}}' localhost/workz-check:alias 2> /dev/null) || return 0
  podman untag "$id" localhost/workz-check:alias
}
crule() { rule "$1" "$2" "$3" "$4" "container = \"${5:-$img}\"
${6:-}"; }
srule() { crule "$1" "$2" "$3" "$4"; printf 'shared = ["%s"]\n\n' "$5"; }
service() { printf '[shared.%s]\ncontainer = "%s"\ncommand = %s\nmemory = "%s"\n\n' "$1" "$img" "$2" "$3"; }
loads() { jq -c 'select(.event == "shared_loading")' "$(last_launch)/events.jsonl" | wc -l; }
no_cgroups() { ! ls -d /sys/fs/cgroup$(jq -r 'select(.event == "launch_started") | .cgroup' "$(last_launch)/events.jsonl" | sed 's|^/sys/fs/cgroup||')/{task,shared}-* 2> /dev/null; }

# --- Reuse ---

if want reuse; then
new reuse
echo hello > in.txt
{ header reuse
  rule a '["in.txt"]' '["a.txt"]' '"cat in.txt > a.txt"'
  rule b '["a.txt"]' '["b.txt"]' '"cat a.txt a.txt > b.txt"'
  rule c '["in.txt"]' '["c.txt"]' '"wc -c < in.txt > c.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
"$kanit" run wf.toml "${iso[@]}" -q --json > s2.json
check "a second run reuses every rule the first completed" '[ "$(status_of s1.json completed)" = 3 ] && [ "$(status_of s2.json reused)" = 3 ]'
printf 'HELLO\n' > in.txt.new
cp -p in.txt in.txt.ref
cat in.txt.new > in.txt
touch -r in.txt.ref in.txt
"$kanit" run wf.toml "${iso[@]}" -q --json > s3.json
check "a same-size rewrite with its mtime restored reruns its consumers" '[ "$(status_of s3.json completed)" = 3 ]'
sed -i 's/cat a.txt a.txt > b.txt/cat a.txt a.txt a.txt > b.txt/' wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s4.json
check "a command change reruns only that rule" '[ "$(status_of s4.json completed)" = 1 ] && [ "$(status_of s4.json reused)" = 2 ]'
echo tampered > a.txt
"$kanit" run wf.toml "${iso[@]}" -q --json > s5.json 2> err5.txt
rc=$?
"$kanit" report -d . > /dev/null 2> refused.err
check "a changed recorded output refuses the launch, whose summary names it and its rule, and report says why it has no attempts" '[ $rc = 1 ] && grep -q "changed since it was recorded" err5.txt && jq -e ".status == \"refused\" and .changed_outputs == [{\"rule\": \"a\", \"path\": \"$PWD/a.txt\"}]" s5.json > /dev/null && grep -q "has no attempts; it was refused: a recorded output changed" refused.err && grep -q "the newest launch that ran attempts is .*: kanit report --launch " refused.err'
"$kanit" run wf.toml "${iso[@]}" -q --rerun -t a --json > s6.json
check "--rerun keeps the earlier bytes in previous/, and the summary counts them" 'grep -rq tampered "$(last_launch)/attempts/a/001/previous/" && jq -e ".previous_bytes == $(cat "$(last_launch)"/attempts/a/001/previous/* | wc -c)" s6.json > /dev/null'
"$kanit" clean wf.toml --previous --dry-run > prev-dry.txt
kept_prev=$(find .workz -type d -name previous | wc -l)
mkdir -p "$(last_launch)/attempts/a/001/previous/ro/sub" && touch "$(last_launch)/attempts/a/001/previous/ro/sub/f" && chmod 555 "$(last_launch)/attempts/a/001/previous/ro/sub" "$(last_launch)/attempts/a/001/previous/ro"
"$kanit" clean wf.toml --previous > prev.txt
check "clean --previous lists, then removes, every previous/ and nothing else, read-only directories included" 'grep -q "^would remove previous/ of 1 attempt in launch " prev-dry.txt && [ "$kept_prev" -ge 1 ] && [ -z "$(find .workz -type d -name previous)" ] && grep -qE "previous/ of $kept_prev attempts?[ ,]" prev.txt && [ -f "$(last_launch)/attempts/a/001/record.json" ] && [ -f a.txt ]'
"$kanit" run wf.toml "${iso[@]}" -q > /dev/null
"$kanit" verify wf.toml --content > /dev/null
cp a.txt a.copy && mv a.copy a.txt
"$kanit" run wf.toml "${iso[@]}" -q --json > restored.json
restored_events="$(last_launch)/events.jsonl"
cp a.txt a.copy && echo extra >> a.copy && mv a.copy a.txt
"$kanit" run wf.toml "${iso[@]}" -q --json > changed.json 2> /dev/null
rc=$?
check "an output copied back with its stored bytes is accepted and its consumer reruns; other bytes are refused" 'grep -q sha256 .workz/state.json && [ "$(status_of restored.json reused)" = 2 ] && [ "$(status_of restored.json completed)" = 1 ] && grep -q output_identity_refreshed "$restored_events" && [ $rc = 1 ] && jq -e ".status == \"refused\"" changed.json > /dev/null'

new rerun-rule
echo x > in.txt
{ header rerun-rule
  rule a '["in.txt"]' '["a.txt"]' '"cat in.txt > a.txt"'
  rule b '["a.txt"]' '["b.txt"]' '"date +%s%N > b.txt"'
  rule c '["b.txt"]' '["c.txt"]' '"cat b.txt > c.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
echo tampered > b.txt
"$kanit" run wf.toml "${iso[@]}" --rerun-rule b -q --json > s2.json
check "--rerun-rule runs the rule and its consumers, keeping a changed output in previous/" '[ "$(status_of s2.json completed)" = 2 ] && [ "$(status_of s2.json reused)" = 1 ] && grep -rq tampered "$(last_launch)/attempts/b/001/previous/"'

new threads-override
{ header threads-override
  rule work_s1 '[]' '["s1.txt"]' '"echo one > s1.txt"'
  rule work_s2 '[]' '["s2.txt"]' '"echo two > s2.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
"$kanit" run wf.toml "${iso[@]}" --threads work=2 -q --json > s2.json
l2=".workz/launches/$(jq -r .launch s2.json)"
printf '[workflow]\nname = "t"\n[[steps]]\nname = "count"\noutput = ["n.txt"]\nshell = "echo {threads} > n.txt"\nmemory = "1M"\n' > pipeline.toml
"$kanit" prepare -o prepared.toml > /dev/null
"$kanit" run prepared.toml "${iso[@]}" --threads count=3 -q --json > s3.json
check "--threads reruns a step's rules with that thread count, which a prepared {threads} receives" '[ "$(status_of s2.json completed)" = 2 ] && [ "$(jq .request.threads "$l2/attempts/work_s1/001/record.json")" = 2 ] && [ "$(cat n.txt)" = 3 ]'

new workdir
mkdir data && echo hello > data/in.txt
{ header workdir
  rule a '["data/in.txt"]' '["work/a/out.txt"]' '"cat in.txt > out.txt; pwd > where.txt"' 'workdir = "work/a"
links = { "in.txt" = "data/in.txt" }'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
"$kanit" run wf.toml "${iso[@]}" -q --json > s2.json
check "a rule runs in its workdir with links to its inputs, which a rerun keeps" '[ "$(cat work/a/out.txt)" = hello ] && [ -L work/a/in.txt ] && [ "$(cat work/a/where.txt)" = "$PWD/work/a" ] && [ "$(status_of s2.json reused)" = 1 ]'
rm work/a/in.txt && echo real > work/a/in.txt
"$kanit" run wf.toml "${iso[@]}" --rerun -q --json > s3.json 2> /dev/null
check "a link never replaces a file that is not a link" '[ "$(status_of s3.json failed)" = 1 ] && [ "$(cat work/a/in.txt)" = real ] && jq -r "select(.event == \"task_failed\") | .reason" "$(last_launch)/events.jsonl" | grep -q "would replace a file"'
fi

# --- Early cutoff ---

if want cutoff; then
new cutoff
echo data > in.txt
{ header cutoff
  rule up '["in.txt"]' '["up.txt"]' '"tr a-z A-Z < in.txt > up.txt"' 'cutoff = true'
  rule down '["up.txt"]' '["down.txt"]' '"cat up.txt up.txt > down.txt"'
  rule plain '["in.txt"]' '["plain.txt"]' '"tr a-z A-Z < in.txt > plain.txt"'
  rule after '["plain.txt"]' '["after.txt"]' '"cat plain.txt plain.txt > after.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > c1.json
digest_len=$(jq -r ".outputs[0].sha256 | length" "$(last_launch)/attempts/up/001/record.json")
rm up.txt plain.txt
"$kanit" run wf.toml "${iso[@]}" -q --json > c2.json
down_reused=$(jq -c 'select(.event == "task_reused") | select(.rule == "down")' "$(last_launch)/events.jsonl" | wc -l)
echo other > in.txt
"$kanit" run wf.toml "${iso[@]}" -q --json > c3.json
check "a cutoff rule records its output digests; the same bytes keep its consumer reused, other bytes rerun it" '[ "$(status_of c1.json completed)" = 4 ] && [ "$digest_len" = 64 ] && [ "$(status_of c2.json completed)" = 3 ] && [ "$down_reused" = 1 ] && [ "$(status_of c3.json completed)" = 4 ]'
fi

# --- Containers ---

if want containers; then
if have_images "$img"; then
trap drop_alias EXIT

new container
mkdir out && echo hello > in.txt
{ header container
  crule up '["in.txt"]' '["out/up.txt"]' '"tr a-z A-Z < in.txt > out/up.txt; echo to-stdout; head -c 60000000 /dev/zero | gzip -1 > /dev/null; if touch rogue.txt 2>/dev/null; then echo writable; else echo read-only; fi; if (exec 3<>/dev/tcp/1.1.1.1/53) 2>/dev/null; then echo net; else echo no-net; fi"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
a="$(last_launch)/attempts/up/001"
check "a container rule writes its output, owned by the user, and logs its stdout" '[ "$(cat out/up.txt)" = HELLO ] && [ "$(stat -c %u out/up.txt)" = "$(id -u)" ] && head -1 "$a/stdout.log" | grep -q to-stdout'
check "a container sees a read-only working directory and no network" 'grep -q read-only "$a/stdout.log" && grep -q no-net "$a/stdout.log" && [ ! -e rogue.txt ]'
check "the attempt counters cover the container, not only the podman client" 'jq -e ".cpu_source == \"cgroup\" and .cpu_s > .rusage.cpu_s and .cpu_s > 0.1" "$a/record.json" > /dev/null'
check "a finished container is removed" '[ "$(leftovers)" = 0 ]'
podman tag "$img" localhost/workz-check:alias
{ header container; crule up '["in.txt"]' '["out/up.txt"]' '"tr a-z A-Z < in.txt > out/up.txt; echo to-stdout; head -c 60000000 /dev/zero | gzip -1 > /dev/null; if touch rogue.txt 2>/dev/null; then echo writable; else echo read-only; fi; if (exec 3<>/dev/tcp/1.1.1.1/53) 2>/dev/null; then echo net; else echo no-net; fi"' localhost/workz-check:alias; } > alias.toml
"$kanit" run alias.toml "${iso[@]}" -q --json > s3.json
drop_alias
check "a retagged image with the same ID keeps its rule reused" '[ "$(status_of s3.json reused)" = 1 ]'
if have_images "$img2"; then
podman tag "$img2" localhost/workz-check:alias
"$kanit" plan alias.toml --rules > plan.txt
check "a tag that now names another image reruns its rule" 'grep -qE "^up +run +command changed$" plan.txt'
drop_alias
else skip "a tag naming another image (needs the image $img2)"; fi
"$kanit" run alias.toml "${iso[@]}" -q --json > s4.json 2> err4.txt
rc=$?
check "a missing image refuses the launch without pulling" '[ $rc = 2 ] && jq -e ".status == \"refused\" and (.error | test(\"not available locally\"))" s4.json > /dev/null'

new container-records
{ header container-records; crule w '[]' '["top.txt"]' '"if touch .workz/planted 2> /dev/null; then echo wrote; else echo denied; fi > top.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
check "a container rule writing at the top of the working directory cannot write the records" '[ "$(cat top.txt)" = denied ] && [ ! -e .workz/planted ]'

new container-secret
{ header container-secret; crule s '[]' '["s.txt"]' '"sleep 2; printf %s \"$PASSED_SECRET\" > s.txt"'; } > wf.toml
PASSED_SECRET=passed-secret-value "$kanit" run wf.toml "${iso[@]}" --pass-env PASSED_SECRET -q --json > s.json &
runner=$!
bash -c 'sleep 3; :' passed-secret-value &
decoy=$!
wait_until 40 'grep -qa "passed-secre[t]-value" "/proc/$decoy/cmdline" 2> /dev/null'
control=0
found=$(grep -la "passed-secre[t]-value" /proc/[0-9]*/cmdline 2> /dev/null)
[[ $found == *"/proc/$decoy/"* ]] && control=1
kill $decoy
wait $decoy 2> /dev/null
seen=0
for _ in $(seq 25); do [ -n "$(grep -la "passed-secre[t]-value" /proc/[0-9]*/cmdline 2> /dev/null)" ] && seen=1; sleep 0.1; done
wait $runner
check "a passed variable reaches a container rule without its value in Podman's arguments" '[ $control = 1 ] && [ "$(status_of s.json completed)" = 1 ] && [ "$(cat s.txt)" = passed-secret-value ] && [ $seen = 0 ]'

new container-workdir
echo inside > in.txt
{ header container-workdir; crule c '["in.txt"]' '["work/c/o.txt"]' '"tr a-z A-Z < in.txt > o.txt"' "" 'workdir = "work/c"
links = { "in.txt" = "in.txt" }'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
check "a container rule runs in its workdir with its links" '[ "$(cat work/c/o.txt)" = INSIDE ] && [ "$(leftovers)" = 0 ]'

new container-sizing
{ header container-sizing; crule big '[]' '["b.txt"]' '"x=$(head -c 200000000 /dev/zero | tr \"\\\\0\" a); touch b.txt"'; } > wf.toml
sed -i 's/memory = "64M"/memory = "1G"/' wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
"$kanit" report -d . --suggest --format json > suggest.json
check "a container rule is sized by its cgroup peak, not by the client's RSS" 'jq -e ".[0].step == \"big\" and .[0].used_basis == \"cgroup\" and .[0].used_mib > 300 and .[0].suggest_mib >= .[0].used_mib" suggest.json > /dev/null'

new container-mounts
echo "workz-check release" > os-release
{ header container-mounts; crule m '[]' '["m.txt"]' '"cat /etc/os-release > m.txt"' "" 'mounts = { "os-release" = "/etc/os-release" }'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
check "a mount places a host file over a path in the image" '[ "$(cat m.txt)" = "workz-check release" ]'

new container-failures
{ header container-failures
  crule hog '[]' '["h.txt"]' '"x=$(head -c 400000000 /dev/zero | tr \"\\\\0\" a); touch h.txt"'
  crule slow '[]' '["s.txt"]' '"sleep 30; touch s.txt"' "" 'timeout = "1s"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -k --grace 2 -q --json > s.json 2> err.txt
check "a container above its memory request is killed as out of memory" 'grep -qE "failed +hog +out of memory at its" err.txt && jq -e ".cgroup.oom_kill >= 1" "$(last_launch)/attempts/hog/001/record.json" > /dev/null'
check "a timed-out container is stopped" 'grep -qE "failed +slow +timed out at 1.0 s" err.txt'
check "failed containers leave no container and no cgroup behind" '[ "$(leftovers)" = 0 ] && ! ls -d /sys/fs/cgroup$(jq -r "select(.event == \"launch_started\") | .cgroup" "$(last_launch)/events.jsonl" | sed "s|^/sys/fs/cgroup||")/task-* 2> /dev/null'

new container-interrupt
{ header container-interrupt; crule long '[]' '["l.txt"]' '"sleep 60; touch l.txt"'; } > wf.toml
setsid "$kanit" run wf.toml "${iso[@]}" --grace 1 -q --json > s.json 2> err.txt &
launcher=$!
wait_until 100 '[ "$(leftovers)" = 1 ]'
kill -INT -- -$launcher
wait $launcher
rc=$?
check "an interrupt stops a running container and removes it" '[ $rc = 130 ] && [ "$(status_of s.json cancelled)" = 1 ] && [ "$(leftovers)" = 0 ]'

new container-crash
{ header container-crash; crule long '[]' '["l.txt"]' '"sleep 60; touch l.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json 2>/dev/null &
engine=$!
wait_until 100 '[ "$(leftovers)" = 1 ]'
kill -KILL $engine
wait $engine 2>/dev/null
{ header container-crash; crule long '[]' '["l.txt"]' '"touch l.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s2.json
check "a container left by a killed engine is removed by the next launch" 'jq -e "select(.event == \"containers_checked\") | select(.leftovers_removed >= 1)" "$(last_launch)/events.jsonl" > /dev/null && [ "$(leftovers)" = 0 ] && [ "$(status_of s2.json completed)" = 1 ]'
{ header container-crash; crule long '[]' '["l.txt"]' '"sleep 60; touch l.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" --rerun -q --json > s3.json 2>/dev/null &
engine=$!
wait_until 100 '[ "$(leftovers)" = 1 ]'
kill -KILL $engine
wait $engine 2>/dev/null
"$kanit" clean -d . > clean.txt
check "clean removes a container left by a killed engine" 'grep -q "removed 1 container and " clean.txt && [ "$(leftovers)" = 0 ]'

new container-version
{ header container-version
  crule c1 '[]' '["c1.txt"]' '"touch c1.txt"' "$img" 'version = "sort --version | head -1"'
  crule c2 '[]' '["c2.txt"]' '"touch c2.txt"' "$img" 'version = "sort --version | head -1"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
l=".workz/launches/$(jq -r .launch s.json)"
check "a version command runs once per image in the image, and the record names the image ID" 'jq -e ".v == 1 and (.commands | length) == 1 and (.commands[0].output | startswith(\"sort (GNU coreutils)\")) and .commands[0].image == \"$(jq -r .image "$l/attempts/c1/001/record.json")\"" "$l/versions.json" > /dev/null'
else skip "container rules (needs rootless Podman with $img)"; fi
fi

# --- Shared services ---

if want services; then
if have_images "$img"; then
new service
{ header service
  service seg '"ipcmk -M 67108864; echo loaded"' 128M
  srule u1 '[]' '["u1.txt"]' '"ipcs -m > u1.txt"' seg
  srule u2 '[]' '["u2.txt"]' '"ipcs -m > u2.txt"' seg
  srule u3 '["u1.txt", "u2.txt"]' '["u3.txt"]' '"ipcs -m > u3.txt"' seg
} > wf.toml
"$kanit" run wf.toml --max-threads 4 --max-memory 360M -q --json > s1.json
log=$(ls "$(last_launch)"/shared/seg-1.stderr.log)
check "rules joining a service see the System V segment it created" '[ "$(status_of s1.json completed)" = 3 ] && grep -q " 67108864 " u1.txt && grep -q " 67108864 " u2.txt && grep -q " 67108864 " u3.txt'
check "a service is loaded once for its users and counts its memory once, so two users fit beside it" '[ "$(loads)" = 1 ] && ! grep -q "\"reason\":\"memory\"" "$(last_launch)/events.jsonl"'
check "the service command's output goes to its log, not the readiness line" 'grep -q "Shared memory id" "$log" && grep -q loaded "$log"'
check "a released service leaves no container and no cgroup behind" '[ "$(leftovers)" = 0 ] && no_cgroups'
"$kanit" run wf.toml --max-threads 4 --max-memory 360M -q --json > s2.json
check "rules joining a service are reused without starting it" '[ "$(status_of s2.json reused)" = 3 ] && [ "$(loads)" = 0 ]'

if have_images "$star"; then
new service-star
awk 'BEGIN { srand(7); printf ">chr1\n"; for (i = 0; i < 2000000; i++) { g = g substr("ACGT", int(rand() * 4) + 1, 1); if (i % 80 == 79) { print g; s = s g; g = "" } }
  for (r = 0; r < 2; r++) { f = "r" r ".fq"; for (k = 0; k < 20000; k++) { p = int(rand() * (length(s) - 100)) + 1; printf "@r%d\n%s\n+\n%s\n", k, substr(s, p, 100), sprintf("%100s", "") > f } } }' > genome.fa
sed -i '/^+$/{n;s/ /I/g}' r0.fq r1.fq
star_rule() {
  printf '[[rules]]\nname = "%s"\ninput = ["genome/SA", "r%s.fq"]\noutput = ["%s/%s/Aligned.out.sam"]\ncontainer = "%s"\nshell = "STAR --genomeDir genome --genomeLoad %s --readFilesIn r%s.fq --outFileNamePrefix %s/%s/ --outSAMtype SAM"\n[rules.resources]\nmemory = "400M"\n%s\n' \
    "$1" "$2" "$4" "$2" "$star" "$3" "$2" "$4" "$2" "${5:-}"
}
{ header service-star
  printf '[shared.genome]\npath = "genome"\ncontainer = "%s"\ncommand = "STAR --genomeDir %s/genome --genomeLoad LoadAndExit --outFileNamePrefix /tmp/"\nmemory = "200M"\n\n' "$star" "$PWD"
  printf '[[rules]]\nname = "index"\ninput = ["genome.fa"]\noutput = ["genome/SA"]\ncontainer = "%s"\nshell = "STAR --runMode genomeGenerate --genomeDir genome --genomeFastaFiles genome.fa --genomeSAindexNbases 9 --outFileNamePrefix genome/"\n[rules.resources]\nmemory = "1G"\n\n' "$star"
  star_rule shared0 0 LoadAndKeep shared 'shared = ["genome"]'
  star_rule shared1 1 LoadAndKeep shared 'shared = ["genome"]'
  star_rule own0 0 NoSharedMemory own
  star_rule own1 1 NoSharedMemory own
} > wf.toml
mkdir -p genome shared/0 shared/1 own/0 own/1
timeout 120 "$kanit" run wf.toml "${iso[@]}" -q --json > s.json
check "STAR aligns against a genome its service loaded once, with the same alignments" '[ "$(status_of s.json completed)" = 5 ] && [ "$(loads)" = 1 ] && grep -q "Found genome in shared memory" shared/0/Log.out && cmp -s <(grep -v "^@" shared/0/Aligned.out.sam) <(grep -v "^@" own/0/Aligned.out.sam) && cmp -s <(grep -v "^@" shared/1/Aligned.out.sam) <(grep -v "^@" own/1/Aligned.out.sam)'
svc_peak=$(jq -r 'select(.event == "shared_released") | .memory_peak' "$(last_launch)/events.jsonl")
check "the genome is charged to the service's cgroup" '[ "$svc_peak" -ge "$(stat -c %s genome/SA)" ] && [ "$(leftovers)" = 0 ]'
else skip "STAR with a shared genome service (needs the image $star)"; fi

new service-gap
{ header service-gap
  service seg '"ipcmk -M 1048576"' 128M
  srule u1 '[]' '["u1.txt"]' '"touch u1.txt"' seg
  rule big '["u1.txt"]' '["big.txt"]' '"touch big.txt"'
  srule u2 '["big.txt"]' '["u2.txt"]' '"touch u2.txt"' seg
} > wf.toml
sed -i '/name = "big"/,/memory/ s/memory = "64M"/memory = "128M"/' wf.toml
timeout 60 "$kanit" run wf.toml --max-threads 4 --max-memory 270M -q --json > s.json
check "an idle service gives its memory to a rule that needs it, and starts again later" '[ "$(status_of s.json completed)" = 3 ] && [ "$(loads)" = 2 ] && [ "$(leftovers)" = 0 ]'

new service-index
{ header service-index
  rule build '[]' '["idx/data"]' '"echo v1 > idx/data"'
  printf '[shared.ix]\npath = "idx"\ncontainer = "%s"\ncommand = "cat %s/idx/data > /dev/null"\nmemory = "64M"\n\n' "$img" "$PWD"
  srule use '[]' '["u.txt"]' '"cat idx/data > u.txt"' ix
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
sed -i 's/echo v1/echo v2/' wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s2.json
ev="$(last_launch)/events.jsonl"
check "a rebuilt service index runs the rules that join it again, after the rule that writes it" '[ "$(status_of s1.json completed)" = 2 ] && [ "$(status_of s2.json completed)" = 2 ] && [ "$(cat u.txt)" = v2 ]'
check "records name the shared input each attempt held and the attempts each holder served" 'jq -e "select(.event == \"task_started\" and .rule == \"use\") | .shared == [\"ix\"]" "$ev" > /dev/null && jq -e "select(.event == \"shared_released\") | .users == 1 and .held_s > 0" "$ev" > /dev/null'

new service-retry
{ header service-retry
  service seg '"ipcmk -M 1048576"' 64M
  srule flaky '[]' '["r.txt"]' '"if [ -f tried ]; then touch r.txt; else touch tried; exit 1; fi"' seg
} > wf.toml
sed -i 's/^name = "flaky"/&\nretries = 1/' wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
check "a retried rule keeps its service instead of loading it again" '[ "$(status_of s.json completed)" = 1 ] && [ -f tried ] && [ "$(loads)" = 1 ]'

new service-failures
{ header service-failures
  service broken '"echo cannot load >&2; exit 3"' 64M
  service fat '"x=$(head -c 200000000 /dev/zero | tr \"\\\\0\" a)"' 32M
  srule b1 '[]' '["b1.txt"]' '"touch b1.txt"' broken
  rule p '[]' '["p.txt"]' '"sleep 0.5; touch p.txt"'
  srule b2 '["p.txt"]' '["b2.txt"]' '"touch b2.txt"' broken
  srule f1 '[]' '["f1.txt"]' '"touch f1.txt"' fat
} > wf.toml
timeout 60 "$kanit" run wf.toml "${iso[@]}" -k -q --json > s.json 2> err.txt
rc=$?
reason() { jq -r "select(.event == \"task_failed\") | select(.rule == \"$1\") | .reason" "$(last_launch)/events.jsonl"; }
check "a service that fails before it is ready fails its rules, also one admitted later, with the service's last line" '[ $rc = 1 ] && [ "$(reason b1)" = "shared input broken could not be loaded: exited with status 3 before it was ready: cannot load" ] && [ "$(reason b2)" = "$(reason b1)" ] && [ "$(status_of s.json completed)" = 1 ] && grep -qE "failed +b1 +shared input broken could not be loaded" err.txt && grep -qE "failed +b2 +shared input broken could not be loaded" err.txt'
check "a service above its memory is reported as out of memory, and failed services leave nothing behind" 'reason f1 | grep -q "^shared input fat could not be loaded: out of memory" && [ "$(leftovers)" = 0 ] && no_cgroups'

new service-dies
{ header service-dies
  service seg '"ipcmk -M 1048576"' 64M
  srule u '[]' '["u.txt"]' '"sleep 20; touch u.txt"' seg
} > wf.toml
timeout 60 "$kanit" run wf.toml "${iso[@]}" --grace 1 -q --json > s.json 2> /dev/null &
launcher=$!
wait_until 100 'jq -e "select(.event == \"task_started\")" "$(last_launch)/events.jsonl" > /dev/null 2>&1'
podman kill "$(podman ps --quiet --filter "label=workz.workdir=$PWD" --filter name=-shared-seg-)" > /dev/null
wait $launcher
rc=$?
check "a service that dies after it was ready fails the rule running against it" '[ $rc = 1 ] && [ "$(status_of s.json failed)" = 1 ] && [ "$(status_of s.json completed)" = 0 ] && [ ! -e u.txt ] && jq -r ".failures[0].reason" s.json | grep -q "^shared service seg failed while the rule used it: " && [ "$(jq -r ".rules | length" .workz/state.json)" = 0 ]'

new service-timeout
{ header service-timeout
  service slow '"sleep 30"' 64M | sed 's/^memory = "64M"$/&\ntimeout = "1s"/'
  srule u '[]' '["u.txt"]' '"touch u.txt"' slow
} > wf.toml
timeout 60 "$kanit" run wf.toml "${iso[@]}" --grace 1 -q --json > s.json
check "a service that is not ready within its timeout fails its users and is removed" '[ "$(jq -r "select(.event == \"task_failed\") | .reason" "$(last_launch)/events.jsonl")" = "shared input slow could not be loaded: did not become ready within 1 s" ] && [ "$(leftovers)" = 0 ]'

new service-retry-start
echo mounted-ok > flag.txt
{ header service-retry-start
  service seg '"case $WORKZ_SERVICE_STOP in *-1.stop) echo first start fails >&2; exit 3 ;; esac; cat /etc/workz-flag >&2; ipcmk -M 1048576"' 64M | sed 's/^memory = "64M"$/&\nretries = 1\nmounts = { "flag.txt" = "\/etc\/workz-flag" }/'
  srule u '[]' '["u.txt"]' '"ipcs -m > u.txt"' seg
} > wf.toml
timeout 60 "$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> /dev/null
check "a service that fails before it is ready starts again within its retries, with its mounts" '[ "$(status_of s.json completed)" = 1 ] && [ "$(loads)" = 2 ] && jq -e "select(.event == \"shared_retry\")" "$(last_launch)/events.jsonl" > /dev/null && grep -q " 1048576 " u.txt && grep -q mounted-ok "$(last_launch)/shared/seg-2.stderr.log"'

new service-interrupt
{ header service-interrupt
  service slow '"sleep 60"' 64M
  srule u '[]' '["u.txt"]' '"touch u.txt"' slow
} > wf.toml
setsid "$kanit" run wf.toml "${iso[@]}" --grace 1 -q --json > s.json 2> err.txt &
launcher=$!
wait_until 100 '[ "$(leftovers)" = 1 ]'
kill -INT -- -$launcher
wait $launcher
rc=$?
check "an interrupt stops a loading service and removes it" '[ $rc = 130 ] && [ "$(status_of s.json cancelled)" = 1 ] && [ "$(leftovers)" = 0 ]'

new service-crash
{ header service-crash
  service seg '"true"' 64M
  srule u '[]' '["u.txt"]' '"sleep 60; touch u.txt"' seg
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json 2> /dev/null &
engine=$!
wait_until 100 '[ "$(leftovers)" = 2 ]'
kill -KILL $engine
wait $engine 2> /dev/null
run_cg=$(jq -r 'select(.event == "launch_started") | .cgroup' "$(last_launch)/events.jsonl")
wait_until 50 '[ ! -d "$run_cg" ]'
check "a killed engine's service and container rules end with it" '[ ! -d "$run_cg" ]'
else skip "shared services (needs rootless Podman with $img)"; fi
fi

# --- Failures ---

if want failures; then
new failure
{ header failure
  rule bad '[]' '["bad.txt"]' '"echo boom >&2; exit 3"'
  rule child '["bad.txt"]' '["child.txt"]' '"cat bad.txt > child.txt"'
  rule slow '[]' '["slow.txt"]' '"sleep 1; echo ok > slow.txt"' 'priority = -1'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" --max-threads 1 -q --json > s1.json 2> err1.txt
rc=$?
check "a failure stops the run with status 1, names the exit status and keeps stderr" '[ $rc = 1 ] && [ "$(status_of s1.json failed)" = 1 ] && [ "$(status_of s1.json blocked)" = 1 ] && grep -qE "failed +bad +exit 3 after" err1.txt && grep -q boom "$(last_launch)/attempts/bad/001/stderr.log"'
check "the summary lists each failed and blocked rule with its reason" 'jq -e "[.failures[] | [.rule, .status, .reason]] == [[\"bad\", \"failed\", \"exited with status 3: boom\"], [\"child\", \"blocked\", \"it needs a rule that did not complete\"]] and (.failures[0].stderr | endswith(\"/attempts/bad/001/stderr.log\"))" s1.json > /dev/null'
"$kanit" run wf.toml "${iso[@]}" -k -q --json > s2.json
check "--keep-going completes independent rules" '[ "$(status_of s2.json completed)" = 1 ] && [ -f slow.txt ]'

new outputs
{ header outputs
  rule quiet '[]' '["never.txt"]' '"true"'
  rule link '[]' '["s.txt"]' '"ln -s wf.toml s.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -k -q --json > s.json 2> err.txt
check "exit 0 without a declared output, or with one written as a symlink, fails the attempt" 'grep -qE "failed +quiet +exited 0 without output never.txt" err.txt && jq -r ".failures[].reason" s.json | grep -q "^exited 0, but its output s.txt is not a regular file$"'

new diagnostics
echo not-for-the-records > ../diagnostics-secret
{ header diagnostics
  rule align '[]' '["a/s1.bam"]' '"mkdir -p a/s1; printf \"loaded\\nFATAL ERROR: genome too large\\n\" > a/s1/Log.out; ln -sf ../../../diagnostics-secret a/s1/leak.log; exit 4"' 'diagnostics = ["a/s1/Log.out", "a/s1/absent.log", "a/s1/leak.log"]'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> err.txt
"$kanit" logs align > logs.txt
d="$(last_launch)/attempts/align/001"
check "a failed rule keeps the tail of its diagnostics, quoted when stderr is empty, and logs shows them" 'grep -qE "failed +\S+ +exit 4 after" err.txt && grep -qE "^ +[|│] FATAL ERROR: genome too large" err.txt && [ "$(jq -c .diagnostics "$d/record.json")" = "[\"a/s1/Log.out\"]" ] && grep -q loaded "$d/diagnostics/a/s1/Log.out" && jq -e ".failures[0].diagnostics == [\"$PWD/$d/diagnostics/a/s1/Log.out\"]" s.json > /dev/null && grep -qE "^diagnostics a/s1/Log.out  align  attempt 1  failed, exit 4  " logs.txt'
check "diagnostics never copy a file from outside the working directory" '! grep -rq not-for-the-records "$d"'

new versions
{ printf '[workflow]\nname = "versions"\nversion = "2.1"\n\n'
  rule up_s1 '[]' '["s1.txt"]' '"echo one > s1.txt"' $'step = "up"\ntool = "upper"\nversion = "echo upper 1.4.2"'
  rule up_s2 '[]' '["s2.txt"]' '"echo two > s2.txt"' $'step = "up"\ntool = "upper"\nversion = "echo upper 1.4.2"'
  rule join '["s1.txt", "s2.txt"]' '["all.txt"]' '"cat s1.txt s2.txt > all.txt"'
  rule t '[]' '["t.txt"]' '"touch t.txt"' $'tool = "t"\nversion = "no_such_tool_xyz --version"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
"$kanit" run wf.toml "${iso[@]}" -q --rerun-rule join --json > s2.json
v1=".workz/launches/$(jq -r .launch s1.json)/versions.json"
check "a version command runs once per launch, a failing one records no version, and none runs for reused rules" '[ "$(jq -c "[.commands[] | select(.status != \"failed\") | .output]" "$v1")" = "[\"upper 1.4.2\"]" ] && jq -e "[.commands[] | select(.status == \"failed\") | .exit_code] == [127]" "$v1" > /dev/null && [ ! -e "$(last_launch)/versions.json" ]'

new prepare
mkdir reads && echo one > reads/a.txt && echo two > reads/b.txt
printf 'sample\treads\nA\treads/a.txt\nB\treads/b.txt\n' > samples.tsv
cat > pipeline.toml <<'TOML'
[workflow]
name = "prepared"
[defaults]
memory = "64M"
[samples]
sheet = "samples.tsv"
[[steps]]
name = "upper"
for_each = "sample"
input = ["{reads}"]
output = ["up/{sample}.txt"]
shell = "awk '{print toupper($0)}' {input} > {output}"
[[steps]]
name = "join"
input = ["up/{sample}.txt"]
output = ["all.txt"]
shell = "cat {input} > {output}"
TOML
"$kanit" prepare > prep.txt
"$kanit" prepare --check > check1.txt
crc1=$?
"$kanit" run "${iso[@]}" -q --json > s.json
check "prepare writes a workflow that runs, and --check finds it unchanged" 'grep -q "^wrote .*/workflow.toml: 3 rules from 2 steps" prep.txt && [ "$(status_of s.json completed)" = 3 ] && [ "$(cat all.txt)" = "$(printf "ONE\nTWO")" ] && [ $crc1 = 0 ]'
cp workflow.toml before.toml
printf '[[steps]]\nname = "again"\noutput = ["all.txt"]\nshell = "true"\n' >> pipeline.toml
"$kanit" prepare --check 2> badc.txt
bcrc=$?
[ -e workflow.toml.prepare-tmp ] && kept_c=1 || kept_c=0
"$kanit" prepare 2> bad.txt
brc=$?
mkdir valid valid/own-tmp
printf '[workflow]\nname = "p"\n[[steps]]\nname = "a"\noutput = ["a.txt"]\nshell = "touch a.txt"\nmemory = "1M"\n' > valid/pipeline.toml
(cd valid && TMPDIR=$PWD/own-tmp "$kanit" prepare --check > chk.out 2>&1)
check "a template that does not validate leaves the workflow alone and keeps its draft to read; --check leaves no file behind" '[ $brc = 2 ] && cmp -s before.toml workflow.toml && [ -e workflow.toml.prepare-tmp ] && [ $bcrc = 2 ] && [ $kept_c = 0 ] && grep -q "prepare would write 1 rule from 1 step" valid/chk.out && [ -z "$(ls valid/own-tmp)" ]'

new setup-failure
{ header setup-failure
  rule logged '[]' '["l.txt"]' '"touch l.txt"' 'log = "logs/l.log"'
  rule moved '[]' '["ro/m.txt"]' '"touch ro/m.txt"'
  rule other '[]' '["o.txt"]' '"sleep 0.5; touch o.txt"'
} > wf.toml
touch logs
mkdir ro && touch ro/m.txt && chmod 555 ro
"$kanit" run wf.toml "${iso[@]}" -k -q --json > s.json 2> err.txt
chmod 755 ro
check "a log that cannot be written or an output that cannot be moved aside fails its rule, which keeps its record, and the launch goes on" '[ "$(jq -r .reason "$(last_launch)/attempts/logged/001/record.json")" = "cannot write its log or benchmark file: a part of the path is not a directory" ] && grep -qE "failed +moved +cannot move its earlier output ro/m.txt into previous/: permission denied, or a read-only file system" err.txt && [ "$(status_of s.json failed)" = 2 ] && [ "$(status_of s.json completed)" = 1 ] && jq -e ".error == null" s.json > /dev/null'

new failed-rerun
{ header failed-rerun; rule r '[]' '["out.txt"]' '"echo A > out.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
sed -i 's|"echo A > out.txt"|"echo partial > out.txt; exit 3"|' wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s2.json 2> /dev/null
"$kanit" verify wf.toml > /dev/null
vrc=$?
check "a failed rerun puts the last result back with its record, and keeps what it wrote in failed/" '[ "$(status_of s2.json failed)" = 1 ] && [ "$(cat out.txt)" = A ] && [ $vrc = 0 ] && [ "$(cat "$(last_launch)/attempts/r/001/failed/0-out.txt")" = partial ] && jq -e "select(.event == \"output_restored\")" "$(last_launch)/events.jsonl" > /dev/null'

new failed-fresh
echo s > src.txt
{ header failed-fresh; rule make '["src.txt"]' '["o.txt"]' '"if [ -f fail ]; then echo partial > o.txt; exit 1; fi; cat src.txt > o.txt"'; } > wf.toml
"$kanit" run wf.toml --no-isolation -q --json > s1.json
rm o.txt && touch fail
"$kanit" run wf.toml --no-isolation -q --json > s2.json 2> /dev/null
check "a failed attempt's partial output with no earlier copy goes to failed/" '[ ! -e o.txt ] && [ "$(cat "$(last_launch)/attempts/make/001/failed/0-o.txt")" = partial ] && jq -e "select(.event == \"output_failed\")" "$(last_launch)/events.jsonl" > /dev/null'

new mutate-input
echo 1 > in.txt
{ header mutate-input; rule r '["in.txt"]' '["out.txt"]' '"cat in.txt > out.txt; echo 2 >> in.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> /dev/null
rc=$?
check "a rule whose input changed while it ran counts as failed, with the reason" '[ $rc = 1 ] && [ "$(status_of s.json completed)" = 0 ] && [ "$(status_of s.json failed)" = 1 ] && [ "$(jq -r ".failures[0].reason" s.json)" = "its inputs changed while the launch ran; run it again" ]'

new start-record
echo x > in.txt && mkdir work && echo file > work/i
{ header start-record; rule w '["in.txt"]' '["work/o.txt"]' '"true"' 'workdir = "work"
links = { "i" = "in.txt" }'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> /dev/null
timeout 10 "$kanit" logs w --follow > f.txt
frc=$?
check "an attempt that cannot start ends with its record, and logs --follow returns" 'r="$(last_launch)/attempts/w/001/record.json"; [ "$(jq -r .status "$r")" = failed ] && [ "$(jq -r .started "$r")" = null ] && [ $frc = 0 ]'
sed -i 's/^workdir = "work"$/&\nretries = 1/' wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s2.json 2> /dev/null
check "an attempt that cannot start uses the rule's retries, and each attempt keeps its record" 'l="$(last_launch)/attempts/w"; [ "$(status_of s2.json failed)" = 1 ] && [ "$(jq -r .status "$l/001/record.json")" = failed ] && [ "$(jq -r .status "$l/002/record.json")" = failed ] && jq -e "select(.event == \"task_retry\")" "$(last_launch)/events.jsonl" > /dev/null'
echo ref > ref.txt
printf '[workflow]\nname = "start-record"\nversion = "1"\n\n[shared.ref]\npath = "ref.txt"\n\n[[rules]]\nname = "w"\ninput = ["in.txt"]\noutput = ["work/o.txt"]\nshell = "true"\nworkdir = "work"\nlinks = { "i" = "in.txt" }\nretries = 1\n[rules.resources]\nmemory = "64M"\nshared = ["ref"]\n' > shared.toml
"$kanit" run shared.toml "${iso[@]}" -q --json > s3.json 2> /dev/null
check "a retry after a failed start keeps its shared input loaded" '[ "$(status_of s3.json failed)" = 1 ] && [ "$(grep -c "\"shared_loaded\"" "$(last_launch)/events.jsonl")" = 1 ] && [ -f "$(last_launch)/attempts/w/002/record.json" ]'

new retry
{ header retry
  rule fail_once '[]' '["out.txt"]' '"echo partial > out.txt; if test ! -f attempted; then touch attempted; echo intentional >&2; exit 23; fi; echo recovered > out.txt"'
  rule child '["out.txt"]' '["child.txt"]' '"cat out.txt > child.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" --retry 1 -q --json > s.json 2> err.txt
check "a retry keeps both attempts, and the first keeps its partial output in failed/" '[ "$(status_of s.json completed)" = 2 ] && [ -f "$(last_launch)/attempts/fail_once/002/record.json" ] && grep -rq partial "$(last_launch)/attempts/fail_once/001/failed/" && [ "$(cat child.txt)" = recovered ]'

new failed-branch
echo fail > flag
{ header failed-branch
  rule fail '["flag"]' '["out.txt"]' '"test \"$(cat flag)\" = pass; echo good > out.txt"'
  rule child '["out.txt"]' '["child.txt"]' '"cat out.txt > child.txt"'
  rule independent '[]' '["other.txt"]' '"echo good > other.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -k -q --json > s1.json 2> /dev/null
echo pass > flag
"$kanit" run wf.toml "${iso[@]}" -q --json > s2.json
check "after a fixed failure, independent work is reused and the branch runs" '[ "$(status_of s1.json blocked)" = 1 ] && [ "$(status_of s2.json reused)" = 1 ] && [ "$(status_of s2.json completed)" = 2 ]'

new logs-wait
write_logs() { { header logs-wait; rule a '[]' '["a.txt"]' "\"$1; echo a > a.txt\""; rule b '["a.txt"]' '["b.txt"]' "\"echo $2 >&2; touch b.txt\""; } > wf.toml; }
write_logs "true" first-b
"$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
write_logs "sleep 2" second-b
"$kanit" run wf.toml "${iso[@]}" -q --json > s2.json &
engine=$!
wait_until 100 '[ "$(ls .workz/launches | wc -l)" = 2 ]'
timeout 30 "$kanit" logs b --follow > f.txt 2> f.err
frc=$?
wait $engine
check "logs --follow waits for the running launch to start the rule and follows that attempt" '[ $frc = 0 ] && grep -q second-b f.txt && ! grep -q first-b f.txt'

new logs-size
{ header logs-size
  rule verbose '[]' '["out.txt"]' '"printf START; head -c 200000 /dev/zero | tr \"\\\\0\" x; echo END; head -c 200000 /dev/zero | tr \"\\\\0\" y >&2; echo good > out.txt"' 'log = "logs/verbose.log"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
a="$(last_launch)/attempts/verbose/001"
check "complete separate logs and the combined log are retained" 'head -c 5 "$a/stdout.log" | grep -q START && [ $(stat -c %s "$a/stdout.log") -gt 200000 ] && [ $(stat -c %s "$a/stderr.log") -ge 200000 ] && [ $(stat -c %s logs/verbose.log) -gt 400000 ]'
fi

# --- Termination ---

if want termination; then
new timeout
{ header timeout
  rule sleeper '[]' '["s.txt"]' '"sleep 30; touch s.txt"' 'timeout = "1s"'
  rule stubborn '[]' '["t.txt"]' '"trap \"\" TERM; while true; do sleep 0.2; done"' 'timeout = "1s"'
} > wf.toml
start=$(date +%s)
"$kanit" run wf.toml "${iso[@]}" -k --grace 2 -q --json > s.json 2> err.txt
took=$(( $(date +%s) - start ))
check "timeouts end both tasks, one ignoring SIGTERM, after the grace period ($took s)" '[ "$(status_of s.json failed)" = 2 ] && [ $took -le 20 ] && grep -qE "failed +\S+ +timed out at 1.0 s" err.txt'
{ header timeout; rule quick '[]' '["q.txt"]' '"touch q.txt"' 'timeout = "18446744073709551615"'; } > far.toml
"$kanit" run far.toml "${iso[@]}" --grace 18446744073709551615 -q --json > f.json 2> f.err
check "the largest timeout and grace end a launch with its summary" '[ "$(status_of f.json completed)" = 1 ] && [ ! -s f.err ]'

new grace-children
printf '%s\n' "trap 'sleep 1; echo tidied > \"\$1\"; exit 0' TERM" 'while :; do sleep 0.1; done' > tool.sh
{ header grace-children; rule tidy '[]' '["t.txt"]' '"bash tool.sh tidied.txt; touch t.txt"' 'timeout = "1s"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" --grace 5 -q --json > s.json 2> err.txt
{ header grace-children; rule tidy '[]' '["t.txt"]' '"bash tool.sh bare.txt; touch t.txt"' 'timeout = "1s"'; } > bare.toml
"$kanit" run bare.toml --no-isolation --grace 5 -q --json > b.json 2> /dev/null
check "a stopped rule's tool gets the grace period after its shell exits, with and without isolation" '[ "$(status_of s.json failed)" = 1 ] && grep -qE "failed +\S+ +timed out at 1.0 s" err.txt && [ "$(cat tidied.txt 2>/dev/null)" = tidied ] && [ "$(status_of b.json failed)" = 1 ] && [ "$(cat bare.txt 2>/dev/null)" = tidied ]'

new escaped
{ header escaped
  rule leaver '[]' '["l.txt"]' '"setsid sleep 300 < /dev/null > /dev/null 2>&1 & echo $! > ../escaped.pid; echo ok > l.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
pid=$(cat ../escaped.pid)
wait_until 50 '[ -z "$pid" ] || ! alive "$pid"'
check "a process that leaves the task's session is ended with its cgroup" '[ -n "$pid" ] && ! alive $pid'

new oom
{ header oom; rule hog '[]' '["h.txt"]' '"dd if=/dev/zero of=/dev/null bs=300M count=1 2> /dev/null; touch h.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> err.txt
check "a task above its memory request is OOM-killed as a whole, shell included, and reported" 'grep -qE "failed +hog +out of memory at its 64 MiB" err.txt && jq -e ".cgroup.oom_kill >= 1 and .signal == 9 and .exit_code == null" "$(last_launch)/attempts/hog/001/record.json" > /dev/null'
{ header oom; rule swap '[]' '["s.txt"]' '"cg=$(sed -n \"s/^0:://p\" /proc/self/cgroup); cat /sys/fs/cgroup${cg%/*}/memory.swap.max > s.txt"'; } > swap.toml
"$kanit" run swap.toml "${iso[@]}" -q --json > swap.json
check "the run's scope allows tasks no swap" '[ "$(cat s.txt)" = 0 ]'

new interrupt
{ header interrupt
  rule long1 '[]' '["l1.txt"]' '"sleep 60; touch l1.txt"'
  rule long2 '[]' '["l2.txt"]' '"trap \"\" TERM INT; while true; do sleep 0.2; done"'
} > wf.toml
setsid "$kanit" run wf.toml "${iso[@]}" --grace 1 --json > s.json 2> err.txt &
launcher=$!
wait_until 100 '[ "$(grep -hs task_started .workz/launches/*/events.jsonl | wc -l)" -ge 2 ]'
kill -INT -- -$launcher
wait $launcher
rc=$?
check "an interrupt cancels running tasks, exits 130 and leaves no task process" '[ $rc = 130 ] && [ "$(status_of s.json cancelled)" = 2 ] && ! pgrep -s $launcher > /dev/null'

new terminate
{ header terminate; rule slow '[]' '["done.txt"]' '"sleep 8 & echo $! > child.pid; echo started > started.txt; wait; echo late > done.txt"'; } > wf.toml
"$kanit" run wf.toml --max-threads 2 --max-memory 256M -q --json > s.json 2> err.txt &
launcher=$!
wait_until 100 '[ -f started.txt ]'
kill -TERM $launcher
wait $launcher
rc=$?
child=$(cat child.pid)
wait_until 50 '[ -z "$child" ] || ! alive "$child"'
{ header terminate; rule slow '[]' '["done.txt"]' '"echo resumed > done.txt"'; } > wf.toml
"$kanit" run wf.toml --max-threads 2 --max-memory 256M -q --json > s2.json
check "SIGTERM to the launcher stops the run and its children, and a later run completes the rule" '[ $rc = 130 ] && [ -n "$child" ] && ! alive $child && [ "$(cat done.txt)" = resumed ]'

new crash
{ header crash
  rule first '[]' '["1.txt"]' '"echo 1 > 1.txt"'
  rule second '["1.txt"]' '["2.txt"]' '"echo $$ > ../crash-task.pid; sleep 30; echo 2 > 2.txt"'
} > wf.toml
"$kanit" run wf.toml --no-isolation -q --json > s1.json &
engine=$!
wait_until 100 'jq -e .rules.first .workz/state.json > /dev/null 2>&1'
"$kanit" plan wf.toml > live.txt 2> live.err
"$kanit" report -d . > live-report.tsv 2> live-report.err
kill -KILL $engine
wait $engine 2>/dev/null
wait_until 20 '[ ! -d /proc/"$(cat ../crash-task.pid)" ]'
check "without isolation, a task ends with a killed engine" '[ -s ../crash-task.pid ] && [ ! -d /proc/"$(cat ../crash-task.pid)" ]'
"$kanit" status -d . --json > st.json 2> st.err
src=$?
"$kanit" control -d . cancel > ctl.txt 2> ctl.err
crc=$?
timeout 10 "$kanit" watch -d . --interval 200 > w.txt 2> w.err
wrc=$?
check "status, control and watch see that a killed engine's launch did not finish; plan and report saw it running" '[ $src = 1 ] && [ "$(jq -r .status st.json)" = unfinished ] && grep -q "did not finish" st.err && [ $crc = 1 ] && grep -q "no engine runs it" ctl.err && [ $wrc = 1 ] && grep -q "did not finish" w.err && grep -q "a launch is running in" live.err && grep -q "is still running; its attempts that have not ended have no record yet" live-report.err'
"$kanit" plan wf.toml --rules > plan.txt 2> plan.err
check "after a killed engine, finished rules are reused and the interrupted one runs again" 'grep -qE "^first +reuse " plan.txt && grep -qE "^second +run " plan.txt && ! grep -q "a launch is running" plan.err'

new crash-isolated
{ header crash-isolated; rule long '[]' '["l.txt"]' '"echo $$ > pid.txt; sleep 30; touch l.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> /dev/null &
engine=$!
wait_until 50 '[ -s pid.txt ]'
kill -KILL $engine
wait $engine 2> /dev/null
wait_until 20 '[ ! -d /proc/"$(cat pid.txt)" ]'
check "an isolated task ends with a killed engine" '[ -s pid.txt ] && [ ! -d /proc/"$(cat pid.txt)" ]'

new crash-previous
{ header crash-previous; rule r '[]' '["out.txt"]' '"echo A > out.txt"'; } > wf.toml
"$kanit" run wf.toml --no-isolation -q --json > s1.json
sed -i 's|"echo A > out.txt"|"sleep 30; echo B > out.txt"|' wf.toml
"$kanit" run wf.toml --no-isolation -q --json > s2.json 2> /dev/null &
engine=$!
wait_until 50 '[ ! -e out.txt ]'
kill -KILL $engine
wait $engine 2> /dev/null
moved=$([ -e out.txt ] && echo no || echo yes)
"$kanit" clean -d . --keep 0 > ck.txt
"$kanit" clean -d . --previous > cp.txt
copy=$(cat "$(last_launch)/attempts/r/001/previous/0-out.txt" 2> /dev/null)
check "clean keeps the only copy of an output a killed launch moved aside" '[ $moved = yes ] && [ "$copy" = A ] && grep -q "hold outputs a killed launch moved aside" ck.txt && grep -q "it holds outputs the next launch puts back" cp.txt'
sed -i 's|"sleep 30; echo B > out.txt"|"echo partial > out.txt; exit 3"|' wf.toml
"$kanit" run wf.toml --no-isolation -q --json > s3.json 2> /dev/null
"$kanit" clean -d . --keep 1 > /dev/null
check "a killed launch's earlier output comes back before the next launch, and survives clean --keep" '[ "$(cat out.txt)" = A ] && [ "$(jq -c "select(.event == \"output_restored\")" "$(last_launch)/events.jsonl" | wc -l)" = 2 ]'

new crash-holder
mkdir ref && head -c $((1024 * 1024)) /dev/urandom > ref/index.bin
{ header crash-holder
  printf '[shared.ref]\npath = "ref"\n\n[[rules]]\nname = "use"\ninput = ["ref/index.bin"]\noutput = ["u.txt"]\nshell = "sleep 30; touch u.txt"\n[rules.resources]\nthreads = 1\nmemory = "64M"\nshared = ["ref"]\n'
} > wf.toml
"$kanit" run wf.toml --no-isolation -q --json > s.json 2> /dev/null &
engine=$!
wait_until 50 'grep -qs task_started .workz/launches/*/events.jsonl'
holder=$(jq -r 'select(.event == "shared_loading") | .pid' .workz/launches/*/events.jsonl)
kill -KILL $engine
wait $engine 2> /dev/null
wait_until 20 '! alive "$holder"'
check "without isolation, a shared input's holder ends with a killed engine" '[ -n "$holder" ] && ! alive "$holder"'
[ -n "$holder" ] && alive "$holder" && kill -KILL "$holder"

new cancel-interrupt
{ header cancel-interrupt; rule t '[]' '["t.txt"]' '"trap \"\" TERM; sleep 4; touch t.txt"'; } > wf.toml
"$kanit" run wf.toml --no-isolation --grace 3 --json > s.json 2> err.txt &
engine=$!
wait_until 50 'jq -e "select(.event == \"task_started\")" "$(last_launch)/events.jsonl" > /dev/null 2>&1'
"$kanit" control -d . cancel > /dev/null
sleep 1.2
kill -INT $engine
wait $engine
check "an interrupt after control cancel keeps the grace period" 'grep -q "the launch is already stopping" err.txt && ! grep -q "killing running tasks" err.txt'

new control-startup
{ header control-startup; rule s '[]' '["s.txt"]' '"sleep 3; touch s.txt"'; } > wf.toml
"$kanit" run wf.toml --no-isolation -q --json > s.json 2> /dev/null &
engine=$!
for _ in $(seq 400); do "$kanit" control -d . cancel > /dev/null 2>&1 && break; done
wait $engine
check "a cancel sent while the launch starts is applied" '[ ! -e s.txt ] && [ "$(jq -r .status s.json)" = interrupted ]'

new control-ending
{ header control-ending; rule v '[]' '["v.txt"]' '"touch v.txt"' 'version = "sleep 3; echo v1"'; } > wf.toml
"$kanit" run wf.toml --no-isolation -q --json > s.json 2> /dev/null &
engine=$!
wait_until 50 'jq -e "select(.event == \"launch_ending\")" .workz/launches/*/events.jsonl > /dev/null 2>&1'
"$kanit" control -d . cancel > c.out 2> c.err
crc=$?
echo "stop v" >> "$(last_launch)/control"
wait $engine
check "a command sent while the launch ends is refused or answered, never applied" '[ $crc = 1 ] && grep -q "the newest launch is ending and applies no more commands" c.err && [ "$(jq -r .status s.json)" = completed ] && jq -e "select(.event == \"control\" and .command == \"stop\" and .result == \"the launch is ending\")" "$(last_launch)/events.jsonl" > /dev/null'

new replaced-binary
mkdir ref && head -c $((1024 * 1024)) /dev/urandom > ref/index.bin
{ header replaced-binary
  rule first '[]' '["w.txt"]' '"sleep 1; touch w.txt"'
  printf '[shared.ref]\npath = "ref"\n\n[[rules]]\nname = "use"\ninput = ["ref/index.bin", "w.txt"]\noutput = ["u.txt"]\nshell = "touch u.txt"\n[rules.resources]\nthreads = 1\nmemory = "64M"\nshared = ["ref"]\n'
} > wf.toml
cp "$kanit" ./kanit
./kanit run wf.toml --no-isolation --max-threads 1 --max-memory 1G -q --json > s.json 2> err.txt &
engine=$!
wait_until 50 'grep -qs task_started .workz/launches/*/events.jsonl'
cp ./kanit ./kanit.new && mv ./kanit.new ./kanit
wait $engine
check "a launch whose binary is replaced while it runs still starts its guard and holders" '[ "$(status_of s.json completed)" = 2 ] && [ ! -s err.txt ]'

new keeper-ends
{ header keeper-ends; rule a '[]' '["a.txt"]' '"sleep 2; touch a.txt"'; } > wf.toml
for mode in netns guard; do
  if [ $mode = netns ]; then "$kanit" run wf.toml "${iso[@]}" -q --json > $mode.json 2> $mode.err &
  else "$kanit" run wf.toml --no-isolation --rerun -q --json > $mode.json 2> $mode.err & fi
  engine=$!
  keeper=""
  for _ in $(seq 50); do keeper=$(ps -o pid=,args= --ppid $engine | awk -v want="__$mode" '$3 == want {print $1}'); [ -n "$keeper" ] && break; sleep 0.1; done
  [ -n "$keeper" ] && kill -KILL "$keeper"
  wait $engine
  echo "$keeper" > $mode.pid
done
check "a run notes that its network holder or guard ended, and its rule goes on" '[ -s netns.pid ] && [ "$(status_of netns.json completed)" = 1 ] && grep -q "network holder ended" netns.err && [ -s guard.pid ] && [ "$(status_of guard.json completed)" = 1 ] && grep -q "guard of tasks without isolation ended" guard.err && [ "$(grep -c "\"event\":\"\(network_holder\|guard\)_ended\"" .workz/launches/*/events.jsonl | awk -F: "{ n += \$2 } END { print n }")" = 2 ]'

new lock
{ header lock; rule slow '[]' '["done.txt"]' '"echo started > started.txt; sleep 2; echo done > done.txt"'; } > wf.toml
"$kanit" run wf.toml --max-threads 1 --max-memory 128M -q --json > first.json &
first=$!
wait_until 100 '[ -f started.txt ]'
"$kanit" run wf.toml --max-threads 1 --max-memory 128M -q --json > second.json 2> err.txt
rc=$?
"$kanit" clean -d . --keep 0 > /dev/null 2> clean.err
clean_rc=$?
wait $first
check "a second run and clean are refused while a launch holds the lock" '[ $rc = 1 ] && grep -q "another launch is running in" err.txt && [ $clean_rc != 0 ] && grep -q "a launch is running in" clean.err && [ "$(status_of first.json completed)" = 1 ]'
fi

# --- Admission ---

if want admission; then
new groups
{ printf '[workflow]\nname = "groups"\nversion = "1"\n\n[resource_groups.disk]\nmax = 1\n\n'
  for i in 1 2 3; do
    printf '[[rules]]\nname = "g%s"\ninput = []\noutput = ["g%s.txt"]\nshell = "date +%%s.%%N > g%s.txt; sleep 0.3; date +%%s.%%N >> g%s.txt"\n[rules.resources]\nthreads = 1\nmemory = "64M"\ngroups = { disk = 1 }\n\n' $i $i $i $i
  done
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
overlap=$(cat g1.txt g2.txt g3.txt | paste - - | sort -n | awk 'NR > 1 && $1 < prev { o = 1 } { prev = $2 } END { print o + 0 }')
waited=$(jq -r '[.queue.reasons[] | select(.reason == "group:disk") | .seconds] | add // 0' "$(last_launch)"/attempts/g*/001/record.json | awk '{ s += $1 } END { print (s > 0.5) }')
check "real processes of a group of size 1 never overlap, and the wait is recorded with its reason" '[ "$overlap" = 0 ] && [ "$(status_of s.json completed)" = 3 ] && [ "$waited" = 1 ] && grep -q "\"reason\":\"group:disk\"" "$(last_launch)/events.jsonl"'

new budget
{ header toolarge; rule big '[]' '["b.txt"]' '"true"'; } | sed 's/memory = "64M"/memory = "8G"/' > big.toml
"$kanit" run big.toml --max-memory 1G -q > /dev/null 2> err.txt
rc=$?
"$kanit" plan big.toml --budget --max-memory 1G > pb-big.txt
pbig=$?
{ header reuse-budget; rule big '[]' '["b.txt"]' '"touch b.txt"' 'threads = 8'; } | sed 's/^threads = 1$//; s/memory = "64M"/memory = "1G"/' > wf.toml
"$kanit" run wf.toml --no-isolation --max-threads 8 --max-memory 2G -q --json > s1.json
"$kanit" plan wf.toml --budget --max-threads 1 --max-memory 100M > pb-reused.txt
preused=$?
"$kanit" run wf.toml --no-isolation --max-threads 1 --max-memory 100M -q --json > s2.json
rrc=$?
{ header sizes; rule r '[]' '["r.txt"]' '"touch r.txt"'; } > small.toml
"$kanit" run small.toml --no-isolation --max-memory 1024T -q --json > s3.json
mrc=$?
check "a rule larger than the budget is refused before the run and fails plan --budget; a reusable launch fits any budget in both; a 1024T budget runs" '[ $rc = 2 ] && grep -q "needs 8192 MiB" err.txt && [ $pbig = 1 ] && [ $preused = 0 ] && [ $rrc = 0 ] && [ "$(status_of s2.json reused)" = 1 ] && [ $mrc = 0 ]'

new shared-sizes
{ header shared-sizes
  printf '[shared.ref]\npath = "missing-ref"\n\n[shared.spare]\npath = "absent-spare"\n\n'
  rule r '[]' '["r.txt"]' '"touch r.txt"'; echo 'shared = ["ref"]'
  rule u '[]' '["u.txt"]' '"touch u.txt"'
} > wf.toml
"$kanit" run wf.toml --no-isolation --target u -q --json > su.json 2> /dev/null
urc=$?
check "a launch measures only the shared inputs its rules use" '[ $urc = 0 ] && [ "$(status_of su.json completed)" = 1 ]'

new dispatch
{ header dispatch; for i in $(seq 30); do rule "t$i" '[]' "[\"t$i.txt\"]" "\"touch t$i.txt\""; done; } > wf.toml
"$kanit" run wf.toml --max-threads 2 --max-memory 1G -q --json > s.json
cat "$(last_launch)"/attempts/*/001/record.json | jq -s '[.[] | .queue.reasons | map({(.reason): .seconds}) | add // {}]' > waits.json
check "a wait for threads ends when a thread is free; the engine's own time after it counts as starting" '[ "$(status_of s.json completed)" = 30 ] && jq -e "map(select(.threads)) | length > 0 and all(.starting > 0)" waits.json > /dev/null'

new shared
mkdir ref && head -c $((64 * 1024 * 1024)) /dev/urandom > ref/index.bin
sync ref/index.bin && dd if=ref/index.bin iflag=nocache count=0 status=none
{ printf '[workflow]\nname = "shared"\nversion = "1"\n\n[shared.ref]\npath = "ref"\n\n'
  for i in 1 2; do
    printf '[[rules]]\nname = "use%s"\ninput = ["ref/index.bin"]\noutput = ["u%s.txt"]\nshell = "cksum ref/index.bin > u%s.txt; cg=$(sed -n \\"s/^0:://p\\" /proc/self/cgroup); cat /sys/fs/cgroup${cg%%/*}/memory.low > u%s.low; sleep 0.5"\n[rules.resources]\nthreads = 1\nmemory = "100M"\nshared = ["ref"]\n\n' $i $i $i $i
  done
} > wf.toml
"$kanit" run wf.toml --max-threads 4 --max-memory 300M -q --json > s.json
ev="$(last_launch)/events.jsonl"
both=$(jq -r 'select(.event == "task_started") | .rule' "$ev" | wc -l)
check "a shared input is loaded once and both users fit when it is counted once" '[ "$(status_of s.json completed)" = 2 ] && [ "$(grep -c shared_loaded "$ev")" = 1 ] && [ "$both" = 2 ]'
held=$(jq -r 'select(.event == "shared_loaded") | .holder_file_bytes' "$ev")
peak=$(jq -r '.cgroup.file' "$(last_launch)/attempts/use1/001/record.json")
check "the holder group carries the shared page cache, not the user tasks" '[ "$held" -ge $((60 * 1024 * 1024)) ] && [ "$peak" -lt $((8 * 1024 * 1024)) ]'
check "the run's scope protects the shared input's size from reclaim" 'jq -e "select(.event == \"memory_protected\") | select(.ok and .memory_low_mib == 64)" "$ev" > /dev/null && [ "$(cat u1.low)" = $((64 * 1024 * 1024)) ]'
mkdir piped && echo x > piped/a.txt && mkfifo piped/pipe
printf '[workflow]\nname = "shared"\nversion = "1"\n\n[shared.piped]\npath = "piped"\n\n[[rules]]\nname = "p"\noutput = ["p.txt"]\nshell = "touch p.txt"\n[rules.resources]\nmemory = "64M"\nshared = ["piped"]\n' > fifo.toml
timeout 20 "$kanit" run fifo.toml "${iso[@]}" -q --json > f.json 2> f.err
frc=$?
check "a FIFO in a shared input refuses the launch with its path, without waiting for a writer" '[ $frc = 2 ] && grep -q "shared input piped (piped): $PWD/piped/pipe is not a regular file" f.err'

new samples
{ header samples; rule busy '[]' '["b.txt"]' '"x=$(head -c 100M /dev/zero | tr -c a a); timeout 6 sh -c \"while :; do :; done\" || true; touch b.txt"' | sed 's/memory = "64M"/memory = "512M"/'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
check "run samples show the CPU in use, and the record keeps the pressure totals and the largest anonymous memory sampled while it ran" 'jq -e "select(.event == \"sample\") | select(.cpu_cores_used > 0.5)" "$(last_launch)/events.jsonl" > /dev/null && jq -e ".cgroup.cpu_some_us != null and .cgroup.io_some_us != null" "$(last_launch)/attempts/busy/001/record.json" > /dev/null && jq -e ".cgroup.anon_peak >= 90 * 1048576 and (.cgroup | has(\"anon\") | not)" "$(last_launch)/attempts/busy/001/record.json" > /dev/null'

new idle
{ header idle; rule hand '[]' '["h.txt"]' '"systemd-run --user --wait -q timeout 1.5 sh -c \"while :; do :; done\" || true; touch h.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
"$kanit" report -d . --bottlenecks > b.txt
check "work handed to another supervisor is reported as idle" '[ "$(status_of s.json completed)" = 1 ] && grep -q "handed its work to a process outside its cgroup" b.txt'

new slice
{ header slice; rule a '[]' '["a.txt"]' '"touch a.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" --slice workz-validation.slice -q --json > s.json
check "--slice places the run in the named slice and the summary has the engine's cost" 'jq -r "select(.event == \"launch_started\") | .cgroup" "$(last_launch)/events.jsonl" | grep -q "/workz-validation.slice/" && jq -e ".engine_cost.cpu_s > 0 and .engine_cost.max_rss_mib > 0" s.json > /dev/null'

new outer-scope
{ header outer-scope; rule a '[]' '["a.txt"]' '"touch a.txt"'; } > wf.toml
systemd-run --user --scope -q "$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> err.txt
check "a run started directly by systemd-run --scope gets a scope of its own" '[ "$(status_of s.json completed)" = 1 ] && [ ! -s err.txt ]'

new stage-marker
{ header stage-marker; rule a '[]' '["a.txt"]' '"cat /proc/self/cgroup > a.txt"'; } > wf.toml
WORKZ_STAGE=inner "$kanit" run wf.toml "${iso[@]}" -q --json > s1.json
scope1=$(jq -r 'select(.event == "launch_started") | .cgroup' "$(last_launch)/events.jsonl")
WORKZ_STAGE=inner:workz-1-1 "$kanit" run wf.toml "${iso[@]}" --rerun -q --json > s2.json
scope2=$(jq -r 'select(.event == "launch_started") | .cgroup' "$(last_launch)/events.jsonl")
check "an inherited isolation marker does not skip the run's scope, and the records directory is private" '[ "$(status_of s1.json completed)" = 1 ] && [[ "$scope1" == */workz-*.scope* ]] && [ "$(status_of s2.json completed)" = 1 ] && [[ "$scope2" == */workz-*.scope* ]] && [[ "$scope2" != */workz-1-1.scope* ]] && [ "$(stat -c %a .workz)" = 700 ]'

new launcher-args
mkdir bin
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > args.txt\n' > bin/systemd-run
chmod +x bin/systemd-run
{ header launcher-args; rule a '[]' '["a.txt"]' '"touch a.txt"'; } > wf.toml
cp wf.toml 'w$x.toml'
PATH="$PWD/bin:$PATH" "$kanit" run wf.toml > /dev/null 2>&1 && mv args.txt plain.txt
PATH="$PWD/bin:$PATH" "$kanit" run 'w$x.toml' > /dev/null 2>&1 && mv args.txt dollar.txt
check "the launcher asks systemd-run to keep \$ literal only for an argument that holds one" '[ -s plain.txt ] && ! grep -q -- --expand-environment plain.txt && grep -qx -- --expand-environment=no dollar.txt && grep -qx "w\$x.toml" dollar.txt'

new podman-failure
mkdir broken absent
printf '#!/bin/sh\necho "Error: database is locked" >&2\nexit 125\n' > broken/podman
printf '#!/bin/sh\n[ "$2" = exists ] && exit 1\necho "Error: no such image" >&2\nexit 125\n' > absent/podman
chmod +x broken/podman absent/podman
{ header podman-failure; rule a '[]' '["a.txt"]' '"touch a.txt"' 'container = "quay.io/x/tool:1"'; } > wf.toml
PATH="$PWD/broken:$PATH" "$kanit" run wf.toml --no-isolation -q > /dev/null 2> broken.txt
brc=$?
PATH="$PWD/absent:$PATH" "$kanit" run wf.toml --no-isolation -q > /dev/null 2> absent.txt
arc=$?
check "a failing Podman is named as failing, not as a missing image" '[ $brc = 2 ] && grep -q "podman image inspect quay.io/x/tool:1 failed" broken.txt && ! grep -q "not available locally" broken.txt && [ $arc = 2 ] && grep -q "not available locally" absent.txt'
fi

# --- Inputs ---

if want inputs; then
new input-errors
mkdir -p deep && p=deep && for i in $(seq 70); do p="$p/d"; done && mkdir -p "$p"
{ header input-errors; rule r '["deep"]' '["r.txt"]' '"touch r.txt"'; } > wf.toml
"$kanit" run wf.toml --no-isolation -q --json > s.json 2> r.err
rrc=$?
check "an input that cannot be read refuses the launch, which keeps its summary" '[ $rrc = 2 ] && grep -q "nests directories more than 64 levels deep" r.err && [ "$(jq -r .status s.json)" = refused ]'

new plan-missing
{ header plan-missing; rule count '["reads/s9.txt"]' '["c.txt"]' '"wc -l reads/s9.txt > c.txt"'; } > wf.toml
"$kanit" plan wf.toml > /dev/null 2> plan.err
prc=$?
"$kanit" plan wf.toml --budget > /dev/null 2> pb.err
pbrc=$?
check "plan, with or without --budget, fails as run would for a missing input" '[ $prc = 1 ] && grep -q "run would refuse this launch: 1 rule with a missing input" plan.err && [ $pbrc = 1 ] && grep -q "run would refuse this launch: 1 rule with a missing input" pb.err'

new manifest
echo data > ext.txt
{ header manifest; rule m '["ext.txt"]' '["m.txt"]' '"cp ext.txt m.txt"'; } > wf.toml
good=$(sha256sum ext.txt | cut -d" " -f1)
printf '{"%s": "sha256:%s"}\n' "$PWD/ext.txt" "$good" > good.json
printf '{"%s": "sha256:%s"}\n' "$PWD/ext.txt" "$(printf 0%.0s {1..64})" > bad.json
"$kanit" run wf.toml "${iso[@]}" -q --input-manifest bad.json --json > bad-run.json 2> err.txt
rc=$?
"$kanit" run wf.toml "${iso[@]}" -q --input-manifest good.json --json > s.json
check "a wrong manifest digest refuses the run, and a matching one runs" '[ $rc = 1 ] && grep -q "does not match its manifest digest" err.txt && [ "$(status_of s.json completed)" = 1 ]'
touch ext.txt
"$kanit" run wf.toml "${iso[@]}" -q --input-manifest good.json --json > touched.json
check "a touched manifest input with the same bytes is read once and its rule reused" '[ "$(status_of touched.json reused)" = 1 ] && jq -e "select(.event == \"inputs_checked\") | select(.files_read == 1)" "$(last_launch)/events.jsonl" > /dev/null'
"$kanit" status -d . --launch "$(jq -r .launch bad-run.json)" --json > refused-status.json
"$kanit" plan wf.toml --input-manifest bad.json > /dev/null 2> plan-bad.err
pbad=$?
check "a refused launch is recorded and shown by status, and plan refuses the manifest as run does" 'jq -e ".status == \"refused\" and (.error | test(\"manifest\"))" refused-status.json > /dev/null && [ $pbad = 1 ] && grep -q "inputs do not match the input manifest" plan-bad.err'

new during
echo x > in.txt
{ header during
  rule reader '["in.txt"]' '["r.txt"]' '"cat in.txt > r.txt"' 'priority = 10'
  rule writer '[]' '["w.txt"]' '"sleep 0.2; echo y >> in.txt; touch w.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> err.txt
check "an input changed during the run fails the launch" 'jq -e ".error | test(\"changed during the run\")" s.json > /dev/null'

new environment
{ header environment
  rule env '[]' '["out.txt"]' '"env > env.txt; test -z \"${OPENAI_API_KEY:-}${AWS_SECRET_ACCESS_KEY:-}${BASH_ENV:-}\" && test \"$WORKZ_THREADS\" = 1 && echo clean > out.txt"'
} > wf.toml
OPENAI_API_KEY=canary AWS_SECRET_ACCESS_KEY=canary BASH_ENV=/nonexistent "$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> err.txt
check "credentials and shell start-up variables do not reach rules" '[ "$(status_of s.json completed)" = 1 ] && [ "$(cat out.txt)" = clean ]'

if command -v python3 > /dev/null; then
new network
python3 -I -m http.server --bind 127.0.0.1 0 > server.log 2>&1 &
server=$!
wait_until 50 'port=$(grep -o "port [0-9]*" server.log | grep -o "[0-9]*"); [ -n "$port" ]'
{ header network
  rule net '[]' '["out.txt"]' "\"if (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; then echo reached > out.txt; else echo blocked > out.txt; fi\""
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json
kill $server; wait $server 2>/dev/null
{ header loopback; rule lo '[]' '["lo.txt"]' "\"id -u > lo.txt; python3 -I -c 'import socket; s = socket.socket(); s.bind((\\\"127.0.0.1\\\", 0)); s.listen(); socket.create_connection(s.getsockname()); print(\\\"ok\\\")' >> lo.txt\""; } > lo.toml
"$kanit" run lo.toml "${iso[@]}" -q --json > lo.json
check "a rule cannot reach a listener on the host's loopback, runs as the user and has its own loopback" '[ "$(cat out.txt)" = blocked ] && [ "$(head -1 lo.txt)" = "$(id -u)" ] && [ "$(tail -1 lo.txt)" = ok ]'
else skip "network and loopback (needs python3)"; fi
fi

# --- Commands ---

if want commands; then
new init
"$kanit" init > init.txt
"$kanit" validate --inputs > inputs.txt
irc=$?
mkdir data && seq 5 > data/S1.txt
"$kanit" init 2> again.txt
rc=$?
"$kanit" run workflow.toml "${iso[@]}" -q --json > s.json
check "init writes a starter workflow that runs, and never overwrites" '[ $rc = 2 ] && grep -q "does not overwrite" again.txt && [ "$(status_of s.json completed)" = 2 ] && [ "$(cat out/report.txt)" = "lines: 5" ]'
"$kanit" validate > default.txt
check "WORKFLOW defaults to workflow.toml, and validate --inputs exits 1 for a missing input" 'grep -q "^valid: " default.txt && [ $irc = 1 ] && grep -q "^missing input of rule " inputs.txt'
mkdir tpl && cd tpl && mkdir data && seq 3 > data/S1.txt && seq 4 > data/S2.txt
"$kanit" init --template > init.txt
"$kanit" prepare > prep.txt
"$kanit" run "${iso[@]}" -q --json > s.json
check "init --template writes a template and sample sheet that prepare and run" '[ "$(status_of s.json completed)" = 3 ] && [ "$(cat out/report.txt)" = "$(printf "3\n4")" ]'
cd ..
completions() { PATH="$(dirname "$kanit"):$PATH" bash -c "source <(kanit completion bash); COMP_WORDS=($1); COMP_CWORD=$2; _kanit; IFS='|'; echo \"\${COMPREPLY[*]}\""; }
"$kanit" init "my flow.toml" > /dev/null && touch "zz b.txt"
check "bash completion offers rule names and STEP/SAMPLE, options, control commands and launch IDs, and keeps names with a space whole" '[ "$(completions "kanit run workflow.toml -t \"\"" 4)" = "S1__count|count/S1|report" ] && [ "$(completions "kanit plan --su" 2)" = "--summary" ] && [ "$(completions "kanit control \"\"" 2)" = "stop|retry|cancel" ] && [ "$(completions "kanit report --launch \"\"" 3)" = "$(basename "$(last_launch)")" ] && [ "$(completions "kanit run \"my\\ flow.toml\" -t \"\"" 4)" = "S1__count|count/S1|report" ] && [ "$(completions "kanit run zz" 2)" = "zz b.txt" ] && [ "$(completions "kanit prepare --pa" 2)" = "--params" ]'
"$kanit" help run > help-run.txt
rc1=$?
"$kanit" run --help > run-help.txt
rc2=$?
"$kanit" schema > schema.json
check "help shows a command's options, also through --help, and schema prints JSON" '[ $rc1 = 0 ] && [ $rc2 = 0 ] && cmp -s help-run.txt run-help.txt && grep -q "^  --max-threads N" help-run.txt && jq -e ".properties.rules.items.additionalProperties == false" schema.json > /dev/null'
"$kanit" status --launch 20000101T000000.000-00000000 2> noid.txt
rc=$?
check "status --launch names a launch that does not exist" '[ $rc = 1 ] && grep -q "no launch 20000101T000000.000-00000000" noid.txt'
"$kanit" plan workflow.toml -t S1__cuont 2> typo-target.txt
rc=$?
check "an unknown target names the rule probably meant" '[ $rc = 2 ] && grep -q "unknown target .S1__cuont.; did you mean .S1__count.?" typo-target.txt'

new empty
"$kanit" report -d . 2> nolaunch.txt
rc1=$?
"$kanit" logs -d . x 2> noattempt.txt
rc2=$?
"$kanit" status --history x 2> hist-x.txt
rc3=$?
check "commands with nothing recorded exit 1, and --history x says it takes a number" '[ $rc1 = 1 ] && [ $rc2 = 1 ] && grep -q "no launch recorded" nolaunch.txt && [ $rc3 = 2 ] && grep -q "history takes a whole number of launches, and no workflow file x exists" hist-x.txt'
mkdir cl && cd cl && touch afile
{ header cl; rule a '[]' '["a.txt"]' '"touch a.txt"'; rule b '["a.txt"]' '["b.txt"]' '"touch b.txt"'; } > wf.toml
"$kanit" plan .. 2> dir-wf.txt; r1=$?
"$kanit" plan wf.toml -d afile 2> file-d.txt; r2=$?
"$kanit" verify wf.toml > verify.txt; r3=$?
check "a directory as WORKFLOW and -d naming a file are refused, and verify without records leaves no .workz behind" '[ $r1 = 2 ] && grep -q "is a directory; name the workflow file in it" dir-wf.txt && [ $r2 = 2 ] && grep -q "names a file, not a directory" file-d.txt && [ $r3 = 1 ] && grep -qE "^unrecorded +a$" verify.txt && [ ! -e .workz ]'
cd ..
printf '[workflow]\nname = "f"\nversion = "1"\n\n[[rules]]\nname = "x"\noutptu = ["x.txt"]\nshell = "true"\nmemory = "1M"\n' > typo.toml
{ echo "written before"; "$kanit" validate typo.toml; "$kanit" version; } > shared.txt 2>&1
check "a workflow error shows the offending line, and output to a file other commands also write appends to it" '[ "$(head -1 shared.txt)" = "written before" ] && grep -q "unknown key .outptu." shared.txt && grep -q "^  7 | outptu" shared.txt && tail -1 shared.txt | grep -q "^kanit "'
fi

# --- Monitoring ---

if want monitoring; then
new watch
{ header watch; rule w '[]' '["w.txt"]' '"echo working >&2; sleep 3; touch w.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json &
runner=$!
wait_until 50 'grep -qs working .workz/launches/*/attempts/w/001/stderr.log'
"$kanit" watch -d . --once > view.txt
"$kanit" status -d . --json > running.json
"$kanit" control -d . stop nosuch 2> ctl.txt
ctl_rc=$?
wait $runner
check "status --json describes a running launch, and control refuses a rule it does not run" 'jq -e ".status == \"running\" and .counts.running == 1 and (.counts | has(\"not_started\")) and .finished == null and .failures == [] and .changed_outputs == [] and .engine_key == 4 and (.engine | startswith(\"kanit \"))" running.json > /dev/null && [ $ctl_rc = 1 ] && grep -q "rule nosuch is not part of the running launch" ctl.txt'
check "watch shows the running rule with its memory and last output" 'grep -q "^w " view.txt && grep -q working view.txt && grep -q " [KMG]iB" view.txt'

new logs-command
{ header logs
  rule talk '[]' '["t.txt"]' '"echo to-out; echo to-err >&2; touch t.txt"'
  rule flaky '[]' '["f.txt"]' '"if [ -f tried ]; then echo second; touch f.txt; else touch tried; echo first; exit 1; fi"' 'retries = 1'
  rule S1__speak '[]' '["p.txt"]' '"echo spoken; touch p.txt"'
  rule broke '[]' '["b.txt"]' '"echo why-it-broke >&2; exit 3"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q -k > /dev/null 2>&1
"$kanit" logs -d . speak/S1 --stdout > pair.txt
"$kanit" logs -d . talk > both.txt
"$kanit" logs -d . -n 1 > failed.txt
"$kanit" logs wf.toml talk --stderr > err.txt
"$kanit" logs -d . flaky --attempt 1 --stdout > first.txt
"$kanit" logs -d . flaky --stdout > last.txt
check "logs shows a rule's streams under their headers, one stream, an earlier attempt, a rule named by STEP/SAMPLE, or the newest launch's failures" 'grep -qE "^stdout  talk  attempt 1  completed  7 B$" both.txt && grep -q "^to-out$" both.txt && grep -q "^to-err$" both.txt && [ "$(cat err.txt)" = to-err ] && [ "$(cat first.txt)" = first ] && [ "$(cat last.txt)" = second ] && [ "$(cat pair.txt)" = spoken ] && grep -qE "^stderr  broke  attempt 1  failed, exit 3  13 B$" failed.txt && grep -q "^why-it-broke$" failed.txt && ! grep -q talk failed.txt'
{ header logs; rule slow '[]' '["s.txt"]' '"for i in 1 2 3; do echo tick-$i; sleep 0.4; done; touch s.txt"'; } > slow.toml
"$kanit" run slow.toml "${iso[@]}" -q > /dev/null &
runner=$!
wait_until 50 '[ -n "$(ls -d .workz/launches/*/attempts/slow/001 2> /dev/null)" ]'
timeout 10 "$kanit" logs -d . slow --stdout --follow > follow.txt
rc=$?
wait $runner
check "logs --follow streams a running attempt and returns when it ends" '[ $rc = 0 ] && [ "$(grep -c tick- follow.txt)" = 3 ]'

new control
{ header control
  rule slow '[]' '["s.txt"]' '"sleep 30; touch s.txt"'
  rule after '["s.txt"]' '["a.txt"]' '"touch a.txt"'
  rule bad '[]' '["b.txt"]' '"[ -f fixed ] && touch b.txt"'
  rule b2 '["b.txt"]' '["b2.txt"]' '"touch b2.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -k --grace 1 -q --json > s.json 2> /dev/null &
runner=$!
wait_until 50 'jq -e "select(.event == \"task_failed\" or (.event == \"task_finished\" and .status == \"failed\"))" .workz/launches/*/events.jsonl > /dev/null 2>&1'
touch fixed
"$kanit" control -d . retry bad > /dev/null
wait_until 50 '[ -f b2.txt ]'
"$kanit" control -d . stop slow > /dev/null
wait $runner
"$kanit" control -d . cancel 2> ended.txt
rc=$?
check "control retries a failed rule with its blocked consumers, stops a rule on request, and refuses an ended launch" '[ -f b2.txt ] && [ "$(status_of s.json completed)" = 2 ] && [ "$(status_of s.json cancelled)" = 1 ] && [ "$(status_of s.json blocked)" = 1 ] && jq -e ".status == \"stopped\" and ([.failures[] | select(.status == \"cancelled\") | .reason] == [\"stopped on request\"])" s.json > /dev/null && [ "$(jq -r "select(.event == \"control\") | .result" "$(last_launch)/events.jsonl" | tr "\n" " ")" = "retrying stopping " ] && [ $rc != 0 ] && grep -q "has ended" ended.txt'

new clean
{ header clean
  rule a '[]' '["a.txt"]' '"date +%s%N > a.txt"'
  rule b '[]' '["b.txt"]' '"touch b.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q > /dev/null
for _ in 1 2 3; do "$kanit" run wf.toml "${iso[@]}" -t a --rerun -q > /dev/null; done
first=$(ls .workz/launches | head -1)
"$kanit" clean -d . --keep 1 --dry-run > dry.txt
kept_dry=$(ls .workz/launches | wc -l)
"$kanit" clean -d . --keep 1 > clean.txt
check "clean --dry-run removes nothing; clean --keep keeps the newest launches and one that holds a recorded attempt" '[ "$kept_dry" = 4 ] && grep -q "would remove 0 containers and 2 launches" dry.txt && [ "$(ls .workz/launches | wc -l)" = 2 ] && [ -d ".workz/launches/$first" ] && grep -q "kept 1 older launch" clean.txt'

new run-milestones
{ header run-milestones
  rule S1__trim '[]' '["t1"]' '"touch t1"'
  rule S2__trim '[]' '["t2"]' '"touch t2"'
  rule S1__align '["t1"]' '["a1"]' '"touch a1"'
  rule S2__align '["t2"]' '["a2"]' '"echo index missing >&2; exit 5"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -k --json > s.json 2> err.txt
check "the run log names rules by step and sample, and says when each step and sample has ended" 'grep -qE "plan +4 rules in 2 steps for 2 samples$" err.txt && grep -qE "^[0-9:]{8}  completed +trim +S1 " err.txt && grep -qE "step +trim +2 of 2 completed" err.txt && grep -qE "sample +S1 +all 2 steps completed" err.txt && grep -qE "failed +align +S2 +exit 5 after" err.txt && grep -qE "^ +[|│] index missing$" err.txt && grep -qE "kanit logs align/S2" err.txt && grep -qE "step +align +1 of 2 completed, 1 failed" err.txt && grep -qE "sample +S2 +1 of 2 steps completed, 1 failed" err.txt'

new run-lines
{ header run-lines
  rule ok '[]' '["ok.txt"]' '"touch ok.txt"'
  rule bad '[]' '["bad.txt"]' '"exit 4"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -k --json > s.json 2> err.txt
first_log="$(last_launch)/launch.log"
"$kanit" run wf.toml "${iso[@]}" -k --json > s2.json 2> err2.txt
check "run opens with its launch, plan, budget and records, and launch.log under .workz/latest keeps the same lines and the summary" '[ "$(sed -n 1p err.txt | cut -d" " -f1)" = kanit ] && grep -qE "^ +plan +2 rules$" err.txt && grep -qE "^ +budget +4 threads, 2.0 GiB, 4 jobs, (isolated|no isolation)$" err.txt && grep -qE "^ +records +\.workz/latest/ +log launch.log +page report.html$" err.txt && grep -qE "^[0-9]{2}:[0-9]{2}:[0-9]{2}  failed +bad +exit 4 after" err.txt && head -n "$(wc -l < err.txt)" "$first_log" | cmp -s - err.txt && grep -qE "^ +failed +1 of 2 rules done in .*: 1 completed, 1 failed$" "$first_log" && [ "$(readlink .workz/latest)" = "launches/$(basename "$(last_launch)")" ] && head -n "$(wc -l < err2.txt)" .workz/latest/launch.log | cmp -s - err2.txt && [ -s "$(last_launch)/report.html" ]'
"$kanit" run wf.toml "${iso[@]}" -k -q > text.txt 2> /dev/null
"$kanit" status -d . > status.txt
"$kanit" status -d . --json > status.json
"$kanit" plan wf.toml --json > plan.json
"$kanit" status -d . --history 2 --json > history.json
check "run and status print text wherever their output goes, and JSON only with --json" 'grep -qE "^ +failed +1 of 2 rules done in " text.txt && ! grep -q "{" text.txt && grep -qE "^ +failed +1 of 2 rules done in " status.txt && ! grep -q "{" status.txt && jq -e ".status == \"failed\"" status.json > /dev/null && jq -e ".rules | length == 2" plan.json > /dev/null && jq -e "length == 2 and .[0].failed == 1" history.json > /dev/null'
fi

# --- Terminal ---

if want terminal; then
if command -v tmux > /dev/null; then
tm() { tmux -L "workz-check-$$" -f /dev/null "$@"; }
start() { for _ in $(seq 30); do tm new-session -d "$@" 2> /dev/null && return 0; sleep 0.1; done; tm new-session -d "$@"; }
screen() { tm capture-pane -p -t "$sess"; }
wait_for() { local pattern=$1; wait_until 50 'screen | grep -q -- "$pattern"'; }

new watch-tty
{ header watch-tty
  rule slow '[]' '["s.txt"]' '"echo to-stdout; echo to-stderr >&2; sleep 4; touch s.txt"'
  rule quick '[]' '["q.txt"]' '"touch q.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json &
runner=$!
wait_until 50 '[ -d .workz/launches ]'
sess=w1; start -s "$sess" -x 100 -y 14 "NO_COLOR=1 \"$kanit\" watch -d . --interval 200; echo \$? > exit.txt; stty -a > stty.txt"
check "the interactive view lists the running rule first with its last output and the reservations" 'wait_for "running  *slow .*to-stderr" && screen | grep -q "1/4 reserved" && screen | grep -q "64M/2.0G reserved"'
tm send-keys -t "$sess" Enter
check "enter follows the selected attempt's standard error, and o switches to standard output" 'wait_for "slow .*attempt 1  running  stderr" && screen | grep -q "^to-stderr" && tm send-keys -t "$sess" o && wait_for "^to-stdout"'
tm send-keys -t "$sess" q t
check "t shows the timeline" 'wait_for "slow  *>>>"'
wait $runner
check "the view follows the launch to its end and stays open" 'wait_for "completed" && wait_for "slow  *===="'
tm send-keys -t "$sess" q q
wait_until 50 '[ -s exit.txt ]'
check "q leaves the view with status 0 and the terminal restored" '[ "$(cat exit.txt)" = 0 ] && grep -q " icanon" stty.txt && grep -q " echo " stty.txt'
rm -f exit.txt stty.txt
sess=w2; start -s "$sess" -x 100 -y 14 "NO_COLOR=1 \"$kanit\" watch -d . --interval 200; echo \$? > exit.txt; stty -a > stty.txt"
wait_for "kanit .*launch" && tm send-keys -t "$sess" C-c
wait_until 50 '[ -s exit.txt ]'
c_rc=$(cat exit.txt); grep -q " icanon" stty.txt && c_tty=1 || c_tty=0
rm -f exit.txt stty.txt
sess=w3; start -s "$sess" -x 100 -y 14 "NO_COLOR=1 \"$kanit\" watch -d . --interval 200; echo \$? > exit.txt; stty -a > stty.txt"
wait_for "kanit .*launch"
kill -TERM "$(pgrep -P "$(tm display-message -p -t "$sess" '#{pane_pid}')" -x kanit)"
wait_until 50 '[ -s exit.txt ]'
check "an interrupt key and SIGTERM leave the view with the terminal restored" '[ "$c_rc" = 0 ] && [ $c_tty = 1 ] && [ "$(cat exit.txt)" = 0 ] && grep -q " icanon" stty.txt'

new watch-control
{ header watch-control
  rule long '[]' '["l.txt"]' '"echo long-runs >&2; sleep 30; touch l.txt"'
  rule after '["l.txt"]' '["a.txt"]' '"touch a.txt"'
  rule other '[]' '["o.txt"]' '"touch o.txt"'
} > wf.toml
"$kanit" run wf.toml "${iso[@]}" --grace 1 -q --json > s.json 2> /dev/null &
runner=$!
wait_until 50 '[ -d .workz/launches ]'
sess=w4; start -s "$sess" -x 120 -y 16 "NO_COLOR=1 \"$kanit\" watch -d . --interval 200; echo \$? > exit.txt"
check "the view lists a rule that has yet to start as pending" 'wait_for "pending  *after"'
tm send-keys -t "$sess" / l o n g Enter
check "/ keeps the rules whose name matches" 'wait_for "running  *long" && ! screen | grep -q "pending  *after"'
tm send-keys -t "$sess" i
check "i shows the selected rule's request and live counters" 'wait_for "request  *1 threads, 64M" && screen | grep -q "^  memory  "'
tm send-keys -t "$sess" S
wait $runner
check "S stops the selected running rule through the control file" 'jq -e "select(.event == \"control\" and .command == \"stop\" and .rule == \"long\")" "$(last_launch)/events.jsonl" > /dev/null && [ "$(status_of s.json cancelled)" = 1 ]'
tm send-keys -t "$sess" q q

new watch-dead
{ header watch-dead; rule long '[]' '["l.txt"]' '"sleep 30; touch l.txt"'; } > wf.toml
"$kanit" run wf.toml "${iso[@]}" -q --json > s.json 2> /dev/null &
runner=$!
wait_until 50 'grep -qs task_started .workz/launches/*/events.jsonl'
kill -KILL $runner
wait $runner 2> /dev/null
sess=w5; start -s "$sess" -x 120 -y 12 "NO_COLOR=1 \"$kanit\" watch -d . --interval 200"
check "the interactive view of a killed launch says it did not finish and shows nothing running" 'wait_for "unfinished" && ! screen | grep -q "running"'
tm send-keys -t "$sess" S
check "the view sends no command to a launch without its engine" 'wait_for "the launch has ended" && [ ! -s "$(last_launch)/control" ]'
tm send-keys -t "$sess" q q

new run-tty
{ header run-tty
  rule ok '[]' '["ok.txt"]' '"touch ok.txt"'
  rule bad '[]' '["bad.txt"]' '"echo first-error-line >&2; echo last-error-line >&2; exit 3"'
  rule after '["bad.txt"]' '["after.txt"]' '"touch after.txt"'
} > wf.toml
sess=r1; start -s "$sess" -x 120 -y 20 "NO_COLOR=1 \"$kanit\" run wf.toml ${iso[*]} -k; echo \$? > exit.txt; sleep 30"
wait_until 100 '[ -s exit.txt ]'
check "on a terminal run prints a failure's last error lines, the blocked rules, no footer and a readable summary" '[ "$(cat exit.txt)" = 1 ] && screen | grep -qE "failed +bad +exit 3 after" && screen | grep -qE "^ +[|│] last-error-line" && screen | grep -qE "blocked +after +after bad failed" && ! screen | grep -qE " of 3 rules   " && screen | grep -qE "^ +failed +1 of 3 rules done in .*: 1 completed, 1 failed, 1 blocked$" && screen | grep -qE "^ +next +kanit logs bad " && ! screen | grep -q "{"'
rm -f exit.txt
sess=r3; start -s "$sess" -x 400 -y 20 "\"$kanit\" run wf.toml ${iso[*]} -k --json --no-color; echo \$? > exit.txt; sleep 30"
wait_until 100 '[ -s exit.txt ]'
esc=$(printf '\033')
check "run --json --no-color prints the JSON summary without colors on a terminal" '[ "$(cat exit.txt)" = 1 ] && screen | grep -q "\"status\":\"failed\"" && ! tm capture-pane -e -p -t "$sess" | grep -qF "$esc"'

tm kill-server 2> /dev/null
rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/workz-check-$$"
else skip "interactive watch (needs tmux)"; fi
fi

# --- Summary ---

echo
echo "$pass passed, $failed failed, $skipped skipped"
[ $failed = 0 ] || exit 1
[ $skipped = 0 ] || exit 3
