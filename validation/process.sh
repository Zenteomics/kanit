#!/usr/bin/env bash
# Process checks for the workz binary with real child processes, cgroups and
# signals. Usage: validation/process.sh WORKZ_BINARY OUTPUT_DIR
# OUTPUT_DIR must not exist; every check gets its own working directory there.
set -uo pipefail

workz=$(realpath "$1")
out=$2
[ -e "$out" ] && { echo "output directory exists: $out" >&2; exit 2; }
mkdir -p "$out"
out=$(realpath "$out")
pass=0
failed=0

ok() { pass=$((pass + 1)); printf 'pass  %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A fresh working directory per check.
new() { local d="$out/$1"; mkdir -p "$d"; cd "$d" || exit 2; }

# rule NAME INPUTS OUTPUTS SHELL [EXTRA]  (inputs and outputs are TOML arrays)
rule() {
  printf '[[rules]]\nname = "%s"\ninput = %s\noutput = %s\nshell = %s\n%s\n[rules.resources]\nthreads = 1\nmemory = "64M"\n\n' \
    "$1" "$2" "$3" "$4" "${5:-}"
}
header() { printf '[workflow]\nname = "%s"\nversion = "1"\n\n' "$1"; }
status_of() { jq -r ".counts.$2" "$1"; }
last_launch() { ls -d .workz/launches/* | tail -1; }
alive() { [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }

iso=(--max-threads 4 --max-memory 2G)

# Container and service checks need rootless Podman with these local images
# (workz never pulls); the terminal checks need tmux. Missing ones are skipped.
img=community.wave.seqera.io/library/coreutils_grep_gzip_lbzip2_pruned:838ba80435a629f8
img2=community.wave.seqera.io/library/fastp:1.1.0--08aa7c5662a30d57
star=community.wave.seqera.io/library/htslib_samtools_star_gawk:ae438e9a604351a4
skipped=0
skip() { skipped=$((skipped + 1)); printf 'skip  %s\n' "$1"; }
have_images() { command -v podman > /dev/null && podman image exists "$@" 2> /dev/null; }

# ---------------------------------------------------------------- reuse
export TZ=UTC LANG=C.UTF-8
new reuse
echo hello > in.txt
{ header reuse
  rule a '["in.txt"]' '["a.txt"]' '"cat in.txt > a.txt"'
  rule b '["a.txt"]' '["b.txt"]' '"cat a.txt a.txt > b.txt"'
  rule c '["in.txt"]' '["c.txt"]' '"wc -c < in.txt > c.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s1.json 2> err1.txt
check "first run completes all rules" '[ "$(status_of s1.json completed)" = 3 ]'
"$workz" run wf.toml "${iso[@]}" -q > s2.json
check "second run reuses every rule" '[ "$(status_of s2.json reused)" = 3 ]'
printf 'HELLO\n' > in.txt.new
cp -p in.txt in.txt.ref
cat in.txt.new > in.txt
touch -r in.txt.ref in.txt
"$workz" run wf.toml "${iso[@]}" -q > s3.json
check "same-size rewrite with restored mtime reruns its consumers" '[ "$(status_of s3.json completed)" = 3 ]'
sed -i 's/cat a.txt a.txt > b.txt/cat a.txt a.txt a.txt > b.txt/' wf.toml
"$workz" plan wf.toml > plan.txt
check "plan names the changed command" 'grep -q "run   b  (command changed)" plan.txt && grep -q "reuse a" plan.txt'
"$workz" run wf.toml "${iso[@]}" -q > s4.json
check "a command change reruns only that rule" '[ "$(status_of s4.json completed)" = 1 ] && [ "$(status_of s4.json reused)" = 2 ]'
echo tampered > a.txt
"$workz" run wf.toml "${iso[@]}" -q > s5.json 2> err5.txt
rc=$?
check "a changed recorded output is refused" '[ $rc = 1 ] && grep -q "changed since it was recorded" err5.txt'
"$workz" explain wf.toml b > explain.txt
check "explain reports the changed input" 'grep -q "input changed: .*a.txt" explain.txt'
"$workz" run wf.toml "${iso[@]}" -q --rerun -t a > s6.json
check "--rerun keeps the earlier bytes in previous/" 'grep -rq tampered "$(last_launch)/attempts/a/001/previous/"'
"$workz" verify wf.toml > verify.txt
check "verify accepts recorded outputs" 'grep -q "all match" verify.txt'
"$workz" verify wf.toml --content > verify2.txt
check "verify --content stores digests" 'grep -q "digests stored" verify2.txt && grep -q sha256 .workz/state.json'
"$workz" run wf.toml "${iso[@]}" -q > settle.json
"$workz" run wf.toml "${iso[@]}" -q > tz1.json
TZ=Asia/Tokyo "$workz" run wf.toml "${iso[@]}" -q > tz2.json
TZ=Asia/Tokyo "$workz" run wf.toml "${iso[@]}" -q > tz3.json
check "a time zone change reruns every rule and an unchanged one reuses them" '[ "$(status_of tz1.json reused)" = 3 ] && [ "$(status_of tz2.json completed)" = 3 ] && [ "$(status_of tz3.json reused)" = 3 ]'
TZ=Asia/Tokyo LANG=C "$workz" plan wf.toml > plan-lang.txt
check "plan names the variable when the locale changes" 'grep -q "run   a  (environment changed: LANG)" plan-lang.txt && grep -q "run   c  (environment changed: LANG)" plan-lang.txt'
TZ=Asia/Tokyo LANG=C "$workz" plan wf.toml --summary > plan-summary.txt
check "plan --summary counts the decisions by reason" 'grep -q "^ *2 run   environment changed: LANG$" plan-summary.txt && grep -q "^ *1 run   a producer runs$" plan-summary.txt && grep -q "^3 to run, 0 to reuse$" plan-summary.txt'
TZ=Asia/Tokyo LANG=C "$workz" explain wf.toml a > explain-lang.txt
check "explain gives the old and new value" "grep -q \"    LANG: was '\$LANG', now 'C'\" explain-lang.txt"
TZ=Asia/Tokyo PATH="/opt/workz-check/bin:$PATH" "$workz" explain wf.toml a > explain-path.txt
check "explain lists entries added to PATH" 'grep -q "    PATH: added /opt/workz-check/bin$" explain-path.txt'
TZ=Asia/Tokyo "$workz" plan wf.toml --pass-env NEWVAR > plan-pass.txt
check "a passed variable is part of the key" 'grep -q "run   a  (environment changed: NEWVAR)" plan-pass.txt'
TZ=Asia/Tokyo "$workz" run wf.toml "${iso[@]}" -q > /dev/null
TZ=Asia/Tokyo "$workz" verify wf.toml --content > /dev/null
cp a.txt a.copy && mv a.copy a.txt
TZ=Asia/Tokyo "$workz" run wf.toml "${iso[@]}" -q > restored.json
check "an output restored with the same bytes is accepted; its non-cutoff consumer reruns" '[ "$(status_of restored.json reused)" = 2 ] && [ "$(status_of restored.json completed)" = 1 ] && grep -q output_identity_refreshed "$(last_launch)/events.jsonl"'
cp a.txt a.copy && echo extra >> a.copy && mv a.copy a.txt
TZ=Asia/Tokyo "$workz" run wf.toml "${iso[@]}" -q > changed.json 2> /dev/null
rc=$?
check "an output with a stored digest and different bytes is still refused" '[ $rc = 1 ] && jq -e ".status == \"refused\"" changed.json > /dev/null'

new rerun-rule
echo x > in.txt
{ header rerun-rule
  rule a '["in.txt"]' '["a.txt"]' '"cat in.txt > a.txt"'
  rule b '["a.txt"]' '["b.txt"]' '"date +%s%N > b.txt"'
  rule c '["b.txt"]' '["c.txt"]' '"cat b.txt > c.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s1.json
"$workz" plan wf.toml --rerun-rule b > plan.txt
check "plan shows a requested rule and the consumers that follow it" 'grep -q "reuse a" plan.txt && grep -q "run   b  (rerun requested)" plan.txt && grep -q "run   c  (producer b runs)" plan.txt'
echo tampered > b.txt
"$workz" run wf.toml "${iso[@]}" --rerun-rule b -q > s2.json
check "--rerun-rule runs the rule and its consumers, keeping a changed output in previous/" '[ "$(status_of s2.json completed)" = 2 ] && [ "$(status_of s2.json reused)" = 1 ] && grep -rq tampered "$(last_launch)/attempts/b/001/previous/"'
"$workz" run wf.toml "${iso[@]}" --rerun-rule nosuch -q > /dev/null 2> err.txt
rc=$?
check "--rerun-rule refuses a name that is not a rule" '[ $rc = 2 ] && grep -q "no such rule" err.txt'

new workdir
mkdir data && echo hello > data/in.txt
{ header workdir
  rule a '["data/in.txt"]' '["work/a/out.txt"]' '"cat in.txt > out.txt; pwd > where.txt"' 'workdir = "work/a"
links = { "in.txt" = "data/in.txt" }'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s1.json
check "a rule runs in its workdir with links to its inputs" '[ "$(cat work/a/out.txt)" = hello ] && [ -L work/a/in.txt ] && [ "$(cat work/a/where.txt)" = "$PWD/work/a" ]'
"$workz" run wf.toml "${iso[@]}" -q > s2.json
sed 's|workdir = "work/a"|workdir = "work/b"|; s|work/a/out.txt|work/b/out.txt|' wf.toml > moved.toml
"$workz" plan moved.toml > plan.txt
check "a rerun keeps its workdir links, and moving the workdir reruns the rule" '[ "$(status_of s2.json reused)" = 1 ] && grep -q "run   a  (command changed)" plan.txt'
{ header workdir; rule x '[]' '["x.txt"]' '"true"' 'links = { "i" = "data/in.txt" }'; } > nowd.toml
{ header workdir; rule x '[]' '["work/x/x.txt"]' '"true"' 'workdir = "work/x"
links = { "i" = "data/in.txt" }'; } > notinput.toml
{ header workdir; rule x '[]' '["x.txt"]' '"true"' 'workdir = "../elsewhere"'; } > outside.toml
"$workz" validate nowd.toml 2> e1.txt; "$workz" validate notinput.toml 2> e2.txt; "$workz" validate outside.toml 2> e3.txt
check "links need a workdir and an input as target, and a workdir stays inside" 'grep -q "does not set" e1.txt && grep -q "not an input of the rule" e2.txt && grep -q "must be a directory below the working directory" e3.txt'
rm work/a/in.txt && echo real > work/a/in.txt
"$workz" run wf.toml "${iso[@]}" --rerun -q > s3.json 2> /dev/null
check "a link never replaces a file that is not a link" '[ "$(status_of s3.json failed)" = 1 ] && [ "$(cat work/a/in.txt)" = real ] && jq -r "select(.event == \"task_failed\") | .reason" "$(last_launch)/events.jsonl" | grep -q "would replace a file"'

# ---------------------------------------------------------------- early cutoff
new cutoff
echo data > in.txt
write_cutoff() {
  { header cutoff
    rule up '["in.txt"]' '["up.txt"]' "\"$1\"" 'cutoff = true'
    rule down '["up.txt"]' '["down.txt"]' '"cat up.txt up.txt > down.txt"'
    rule plain '["in.txt"]' '["plain.txt"]' '"tr a-z A-Z < in.txt > plain.txt"' "$2"
    rule after '["plain.txt"]' '["after.txt"]' '"cat plain.txt plain.txt > after.txt"'
  } > wf.toml
}
write_cutoff "tr a-z A-Z < in.txt > up.txt" ""
"$workz" run wf.toml "${iso[@]}" -q > c1.json
check "a cutoff rule records the digests of its outputs" '[ "$(status_of c1.json completed)" = 4 ] && jq -e ".outputs[0].sha256 | length == 64" "$(last_launch)/attempts/up/001/record.json" > /dev/null'
rm up.txt plain.txt
"$workz" run wf.toml "${iso[@]}" -q > c2.json
check "a regenerated cutoff output with the same bytes keeps its consumer reused" '[ "$(jq -r .counts.completed c2.json)" = 3 ] && [ "$(jq -r .counts.reused c2.json)" = 1 ] && jq -e "select(.event == \"task_reused\") | select(.rule == \"down\")" "$(last_launch)/events.jsonl" > /dev/null'
write_cutoff "cat in.txt | tr a-z A-Z > up.txt" ""
"$workz" run wf.toml "${iso[@]}" -q > c3.json
check "a changed command that writes the same bytes keeps its consumer reused" '[ "$(status_of c3.json completed)" = 1 ] && [ "$(status_of c3.json reused)" = 3 ]'
echo other > in.txt
"$workz" run wf.toml "${iso[@]}" -q > c4.json
check "different bytes rerun the consumers of a cutoff rule" '[ "$(status_of c4.json completed)" = 4 ]'
echo tampered > up.txt
"$workz" run wf.toml "${iso[@]}" -q > c5.json 2> err5.txt
rc=$?
check "a changed cutoff output is refused" '[ $rc = 1 ] && grep -q "changed since it was recorded" err5.txt'
"$workz" run wf.toml "${iso[@]}" -q --rerun -t up > /dev/null 2>&1
"$workz" run wf.toml "${iso[@]}" -q > /dev/null
write_cutoff "cat in.txt | tr a-z A-Z > up.txt" "cutoff = true"
"$workz" run wf.toml "${iso[@]}" -q > c6.json
c6_runs=$(jq -r 'select(.event == "task_started") | .rule' "$(last_launch)/events.jsonl" | tr '\n' ' ')
"$workz" run wf.toml "${iso[@]}" -q > c7.json
check "turning cutoff on reruns only the direct consumers, once" '[ "$c6_runs" = "after " ] && [ "$(status_of c7.json reused)" = 4 ]'
cp up.txt up.copy && mv up.copy up.txt
"$workz" run wf.toml "${iso[@]}" -q > c8.json
check "a cutoff output copied back with the same bytes keeps everything reused" '[ "$(status_of c8.json reused)" = 4 ]'

# ---------------------------------------------------------------- container rules
if have_images "$img" && have_images "$img2"; then
leftovers() { podman ps --all --quiet --filter "label=workz.workdir=$PWD" | wc -l; }
# Removes only the temporary name: `podman untag NAME` alone would remove
# every name of the image NAME points to.
drop_alias() {
  local id
  id=$(podman image inspect --format '{{.Id}}' localhost/workz-check:alias 2> /dev/null) || return 0
  podman untag "$id" localhost/workz-check:alias
}
trap drop_alias EXIT
crule() { rule "$1" "$2" "$3" "$4" "container = \"${5:-$img}\"
${6:-}"; }

new container
mkdir out && echo hello > in.txt
{ header container
  crule up '["in.txt"]' '["out/up.txt"]' '"tr a-z A-Z < in.txt > out/up.txt; echo to-stdout; head -c 60000000 /dev/zero | gzip -1 > /dev/null; if touch rogue.txt 2>/dev/null; then echo writable; else echo read-only; fi; if (exec 3<>/dev/tcp/1.1.1.1/53) 2>/dev/null; then echo net; else echo no-net; fi"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s1.json
a="$(last_launch)/attempts/up/001"
check "a container rule writes its output, owned by the user, and logs its stdout" '[ "$(cat out/up.txt)" = HELLO ] && [ "$(stat -c %u out/up.txt)" = "$(id -u)" ] && head -1 "$a/stdout.log" | grep -q to-stdout'
check "a container sees a read-only working directory and no network" 'grep -q read-only "$a/stdout.log" && grep -q no-net "$a/stdout.log" && [ ! -e rogue.txt ]'
check "the attempt counters cover the container, not only the podman client" 'jq -e ".cpu_source == \"cgroup\" and .cpu_s > .rusage.cpu_s and .cpu_s > 0.1" "$a/record.json" > /dev/null'
check "a finished container is removed" '[ "$(leftovers)" = 0 ]'
"$workz" run wf.toml "${iso[@]}" -q > s2.json
check "a container rule is reused like any rule" '[ "$(status_of s2.json reused)" = 1 ]'
podman tag "$img" localhost/workz-check:alias
{ header container; crule up '["in.txt"]' '["out/up.txt"]' '"tr a-z A-Z < in.txt > out/up.txt; echo to-stdout; head -c 60000000 /dev/zero | gzip -1 > /dev/null; if touch rogue.txt 2>/dev/null; then echo writable; else echo read-only; fi; if (exec 3<>/dev/tcp/1.1.1.1/53) 2>/dev/null; then echo net; else echo no-net; fi"' localhost/workz-check:alias; } > alias.toml
"$workz" run alias.toml "${iso[@]}" -q > s3.json
check "a retagged image with the same ID keeps its rule reused" '[ "$(status_of s3.json reused)" = 1 ]'
drop_alias
podman tag "$img2" localhost/workz-check:alias
"$workz" plan alias.toml > plan.txt
check "a tag that now names another image reruns its rule" 'grep -q "run   up  (command changed)" plan.txt'
drop_alias
"$workz" run alias.toml "${iso[@]}" -q > s4.json 2> err4.txt
rc=$?
check "a missing image refuses the launch without pulling" '[ $rc = 2 ] && jq -e ".status == \"refused\" and (.error | test(\"not available locally\"))" s4.json > /dev/null'

new container-workdir
echo inside > in.txt
{ header container-workdir; crule c '["in.txt"]' '["work/c/o.txt"]' '"tr a-z A-Z < in.txt > o.txt"' "" 'workdir = "work/c"
links = { "in.txt" = "in.txt" }'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
check "a container rule runs in its workdir with its links" '[ "$(cat work/c/o.txt)" = INSIDE ] && [ "$(leftovers)" = 0 ]'

new container-sizing
{ header container-sizing; crule big '[]' '["b.txt"]' '"x=$(head -c 200000000 /dev/zero | tr \"\\\\0\" a); touch b.txt"'; } > wf.toml
sed -i 's/memory = "64M"/memory = "1G"/' wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
"$workz" report -d . --bottlenecks > report.txt
# STEP N WALL REQ RSS PEAK SUGGEST: sized by the container's peak, not the client's RSS.
check "a container rule's suggested request covers its cgroup peak" 'awk '"'"'$1 == "big" { gsub(/M/, ""); exit !($6 > $5 && $7 >= $6) }'"'"' report.txt'
"$workz" report -d . --suggest > suggest.tsv
"$workz" report -d . --suggest --format json > suggest.json
check "report --suggest gives the same sizing as tsv and json" 'awk -F"\t" '"'"'$1 == "big" { exit !($8 >= $7 && $7 > 300) }'"'"' suggest.tsv && jq -e ".[0].step == \"big\" and .[0].suggest_mib >= .[0].peak_mib" suggest.json > /dev/null'

new container-mounts
echo "workz-check release" > os-release
{ header container-mounts; crule m '[]' '["m.txt"]' '"cat /etc/os-release > m.txt"' "" 'mounts = { "os-release" = "/etc/os-release" }'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s1.json
check "a mount places a host file over a path in the image" '[ "$(cat m.txt)" = "workz-check release" ]'
echo "changed" > os-release
"$workz" plan wf.toml > plan.txt
check "a changed mount source reruns its rule" 'grep -q "^run   m  (inputs changed)" plan.txt'
{ header container-mounts; rule h '[]' '["h.txt"]' '"touch h.txt"' 'mounts = { "os-release" = "/etc/os-release" }'; } > host.toml
"$workz" validate host.toml > /dev/null 2> err-host.txt
{ header container-mounts; crule m '[]' '["m.txt"]' '"true"' "" 'mounts = { "os-release" = "etc/os-release" }'; } > rel.toml
"$workz" validate rel.toml > /dev/null 2> err-rel.txt
check "mounts need a container rule and an absolute target" 'grep -q "has mounts but no container" err-host.txt && grep -q "must be an absolute path in the image" err-rel.txt'

new container-failures
{ header container-failures
  crule hog '[]' '["h.txt"]' '"x=$(head -c 400000000 /dev/zero | tr \"\\\\0\" a); touch h.txt"'
  crule slow '[]' '["s.txt"]' '"sleep 30; touch s.txt"' "" 'timeout = "1s"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -k --grace 2 -q > s.json 2> err.txt
check "a container above its memory request is killed as out of memory" 'grep -q "hog: out of memory" err.txt && jq -e ".cgroup.oom_kill >= 1" "$(last_launch)/attempts/hog/001/record.json" > /dev/null'
check "a timed-out container is stopped" 'grep -q "slow: timed out after 1 s" err.txt'
check "failed containers leave no container and no cgroup behind" '[ "$(leftovers)" = 0 ] && ! ls -d /sys/fs/cgroup$(jq -r "select(.event == \"launch_started\") | .cgroup" "$(last_launch)/events.jsonl" | sed "s|^/sys/fs/cgroup||")/task-* 2> /dev/null'

new container-interrupt
{ header container-interrupt; crule long '[]' '["l.txt"]' '"sleep 60; touch l.txt"'; } > wf.toml
setsid "$workz" run wf.toml "${iso[@]}" --grace 1 -q > s.json 2> err.txt &
launcher=$!
for _ in $(seq 100); do [ "$(leftovers)" = 1 ] && break; sleep 0.1; done
kill -INT -- -$launcher
wait $launcher
rc=$?
check "an interrupt stops a running container and removes it" '[ $rc = 130 ] && [ "$(status_of s.json cancelled)" = 1 ] && [ "$(leftovers)" = 0 ]'

new container-crash
{ header container-crash; crule long '[]' '["l.txt"]' '"sleep 60; touch l.txt"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s1.json 2>/dev/null &
engine=$!
for _ in $(seq 100); do [ "$(leftovers)" = 1 ] && break; sleep 0.1; done
kill -KILL $engine
wait $engine 2>/dev/null
{ header container-crash; crule long '[]' '["l.txt"]' '"touch l.txt"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s2.json
check "a container left by a killed engine is removed by the next launch" 'jq -e "select(.event == \"containers_checked\") | select(.leftovers_removed >= 1)" "$(last_launch)/events.jsonl" > /dev/null && [ "$(leftovers)" = 0 ] && [ "$(status_of s2.json completed)" = 1 ]'
{ header container-crash; crule long '[]' '["l.txt"]' '"sleep 60; touch l.txt"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" --rerun -q > s3.json 2>/dev/null &
engine=$!
for _ in $(seq 100); do [ "$(leftovers)" = 1 ] && break; sleep 0.1; done
kill -KILL $engine
wait $engine 2>/dev/null
"$workz" clean -d . > clean.txt
check "clean removes a container left by a killed engine" 'grep -q "removed 1 container(s)" clean.txt && [ "$(leftovers)" = 0 ]'

# ---------------------------------------------------------------- shared services
# srule NAME INPUTS OUTPUTS SHELL SERVICE: a container rule that joins SERVICE.
srule() { crule "$1" "$2" "$3" "$4"; printf 'shared = ["%s"]\n\n' "$5"; }
# service NAME COMMAND MEMORY
service() { printf '[shared.%s]\ncontainer = "%s"\ncommand = %s\nmemory = "%s"\n\n' "$1" "$img" "$2" "$3"; }
loads() { jq -c 'select(.event == "shared_loading")' "$(last_launch)/events.jsonl" | wc -l; }
no_cgroups() { ! ls -d /sys/fs/cgroup$(jq -r 'select(.event == "launch_started") | .cgroup' "$(last_launch)/events.jsonl" | sed 's|^/sys/fs/cgroup||')/{task,shared}-* 2> /dev/null; }

new service
{ header service
  service seg '"ipcmk -M 67108864; echo loaded"' 128M
  srule u1 '[]' '["u1.txt"]' '"ipcs -m > u1.txt"' seg
  srule u2 '[]' '["u2.txt"]' '"ipcs -m > u2.txt"' seg
  srule u3 '["u1.txt", "u2.txt"]' '["u3.txt"]' '"ipcs -m > u3.txt"' seg
} > wf.toml
"$workz" run wf.toml --max-threads 4 --max-memory 300M -q > s1.json
log=$(ls "$(last_launch)"/shared/seg-1.stderr.log)
check "rules joining a service see the System V segment it created" '[ "$(status_of s1.json completed)" = 3 ] && grep -q " 67108864 " u1.txt && grep -q " 67108864 " u2.txt && grep -q " 67108864 " u3.txt'
check "a service is loaded once for users that start at different times" '[ "$(loads)" = 1 ]'
check "a service counts its memory once, so two users fit beside it" '! grep -q "\"reason\":\"memory\"" "$(last_launch)/events.jsonl"'
check "the service command's output goes to its log, not the readiness line" 'grep -q "Shared memory id" "$log" && grep -q loaded "$log"'
check "a released service leaves no container and no cgroup behind" '[ "$(leftovers)" = 0 ] && no_cgroups'
"$workz" report -d . --bottlenecks > report.txt
check "the report sizes a service by what it held" 'awk '"'"'$1 == "seg" && $2 == "service" && $3 == 1 { found = 1 } END { exit !found }'"'"' report.txt'
"$workz" run wf.toml --max-threads 4 --max-memory 300M -q > s2.json
check "rules joining a service are reused without starting it" '[ "$(status_of s2.json reused)" = 3 ] && [ "$(loads)" = 0 ]'
sed -i 's/echo loaded/echo loaded again/' wf.toml
"$workz" plan wf.toml > plan.txt
check "a changed service command reruns the rules that join it" 'grep -q "run   u1  (command changed)" plan.txt && grep -q "run   u2  (command changed)" plan.txt'

if have_images "$star"; then
new service-star
awk 'BEGIN { srand(7); printf ">chr1\n"; for (i = 0; i < 2000000; i++) { g = g substr("ACGT", int(rand() * 4) + 1, 1); if (i % 80 == 79) { print g; s = s g; g = "" } }
  for (r = 0; r < 2; r++) { f = "r" r ".fq"; for (k = 0; k < 20000; k++) { p = int(rand() * (length(s) - 100)) + 1; printf "@r%d\n%s\n+\n%s\n", k, substr(s, p, 100), sprintf("%100s", "") > f } } }' > genome.fa
sed -i '/^+$/{n;s/ /I/g}' r0.fq r1.fq
star_rule() {  # NAME SAMPLE LOAD DIR [SHARED]
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
timeout 120 "$workz" run wf.toml "${iso[@]}" -q > s.json
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
timeout 60 "$workz" run wf.toml --max-threads 4 --max-memory 220M -q > s.json
check "an idle service gives its memory to a rule that needs it, and starts again later" '[ "$(status_of s.json completed)" = 3 ] && [ "$(loads)" = 2 ] && [ "$(leftovers)" = 0 ]'

new service-retry
{ header service-retry
  service seg '"ipcmk -M 1048576"' 64M
  srule flaky '[]' '["r.txt"]' '"if [ -f tried ]; then touch r.txt; else touch tried; exit 1; fi"' seg
} > wf.toml
sed -i 's/^name = "flaky"/&\nretries = 1/' wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
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
timeout 60 "$workz" run wf.toml "${iso[@]}" -k -q > s.json 2> err.txt
rc=$?
reason() { jq -r "select(.event == \"task_failed\") | select(.rule == \"$1\") | .reason" "$(last_launch)/events.jsonl"; }
check "a service that fails before it is ready fails its rule with the service's last line" '[ $rc = 1 ] && [ "$(reason b1)" = "shared input broken could not be loaded: exited with status 3 before it was ready: cannot load" ]'
check "a rule admitted after its service failed fails at once" '[ "$(reason b2)" = "$(reason b1)" ] && [ "$(status_of s.json completed)" = 1 ]'
check "a rule failed by its shared input says so on stderr" 'grep -q "failed b1: shared input broken could not be loaded" err.txt && grep -q "failed b2: shared input broken could not be loaded" err.txt'
check "a service above its memory is reported as out of memory" 'reason f1 | grep -q "^shared input fat could not be loaded: out of memory"'
check "failed services leave no container and no cgroup behind" '[ "$(leftovers)" = 0 ] && no_cgroups'

new service-timeout
{ header service-timeout
  service slow '"sleep 30"' 64M | sed 's/^memory = "64M"$/&\ntimeout = "1s"/'
  srule u '[]' '["u.txt"]' '"touch u.txt"' slow
} > wf.toml
t0=$(date +%s%N)
timeout 60 "$workz" run wf.toml "${iso[@]}" --grace 1 -q > s.json
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
check "a service that is not ready within its timeout fails its users ($ms ms)" '[ "$(jq -r "select(.event == \"task_failed\") | .reason" "$(last_launch)/events.jsonl")" = "shared input slow could not be loaded: did not become ready within 1 s" ] && [ $ms -lt 8000 ] && [ "$(leftovers)" = 0 ]'

new service-retry-start
echo mounted-ok > flag.txt
{ header service-retry-start
  service seg '"case $WORKZ_SERVICE_STOP in *-1.stop) echo first start fails >&2; exit 3 ;; esac; cat /etc/workz-flag >&2; ipcmk -M 1048576"' 64M | sed 's/^memory = "64M"$/&\nretries = 1\nmounts = { "flag.txt" = "\/etc\/workz-flag" }/'
  srule u '[]' '["u.txt"]' '"ipcs -m > u.txt"' seg
} > wf.toml
timeout 60 "$workz" run wf.toml "${iso[@]}" -q > s.json 2> /dev/null
check "a service that fails before it is ready starts again within its retries" '[ "$(status_of s.json completed)" = 1 ] && [ "$(loads)" = 2 ] && jq -e "select(.event == \"shared_retry\")" "$(last_launch)/events.jsonl" > /dev/null && grep -q " 1048576 " u.txt'
check "a service mount places a host file in its image" 'grep -q mounted-ok "$(last_launch)/shared/seg-2.stderr.log"'

new service-interrupt
{ header service-interrupt
  service slow '"sleep 60"' 64M
  srule u '[]' '["u.txt"]' '"touch u.txt"' slow
} > wf.toml
setsid "$workz" run wf.toml "${iso[@]}" --grace 1 -q > s.json 2> err.txt &
launcher=$!
for _ in $(seq 100); do [ "$(leftovers)" = 1 ] && break; sleep 0.1; done
t0=$(date +%s%N)
kill -INT -- -$launcher
wait $launcher
rc=$?
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
check "an interrupt stops a loading service and removes it within the grace period ($ms ms)" '[ $rc = 130 ] && [ "$(status_of s.json cancelled)" = 1 ] && [ "$(leftovers)" = 0 ] && [ $ms -lt 5000 ]'

new service-crash
{ header service-crash
  service seg '"true"' 64M
  srule u '[]' '["u.txt"]' '"sleep 60; touch u.txt"' seg
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s1.json 2> /dev/null &
engine=$!
for _ in $(seq 100); do [ "$(leftovers)" = 2 ] && break; sleep 0.1; done
kill -KILL $engine
wait $engine 2> /dev/null
# Podman keeps listing them as running: their conmon died with them.
run_cg=$(jq -r 'select(.event == "launch_started") | .cgroup' "$(last_launch)/events.jsonl")
for _ in $(seq 50); do [ -d "$run_cg" ] || break; sleep 0.1; done
check "a killed engine's service and container rules end with it" '[ ! -d "$run_cg" ]'
sed -i 's/sleep 60; //' wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s2.json
check "the next launch removes their containers and runs" '[ "$(status_of s2.json completed)" = 1 ] && [ "$(leftovers)" = 0 ]'

else skip "container rules and shared services (needs rootless Podman with $img and $img2)"; fi

# ---------------------------------------------------------------- failure policy
new failure
{ header failure
  rule bad '[]' '["bad.txt"]' '"echo boom >&2; exit 3"'
  rule child '["bad.txt"]' '["child.txt"]' '"cat bad.txt > child.txt"'
  rule slow '[]' '["slow.txt"]' '"sleep 1; echo ok > slow.txt"' 'priority = -1'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" --max-threads 1 -q > s1.json 2> err1.txt
rc=$?
check "a failure stops the run with status 1" '[ $rc = 1 ] && [ "$(status_of s1.json failed)" = 1 ] && [ "$(status_of s1.json blocked)" = 1 ]'
check "the failure message names the exit status and stderr file" 'grep -q "exited with status 3" err1.txt && grep -q boom "$(last_launch)/attempts/bad/001/stderr.log"'
"$workz" run wf.toml "${iso[@]}" -k -q > s2.json
check "--keep-going completes independent rules" '[ "$(status_of s2.json completed)" = 1 ] && [ -f slow.txt ]'

new missing-output
{ header missing; rule quiet '[]' '["never.txt"]' '"true"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json 2> err.txt
check "exit 0 without the declared output fails" 'grep -q "without output never.txt" err.txt'

new retry
{ header retry
  rule flaky '[]' '["f.txt"]' '"n=$(cat ../retry-count 2>/dev/null || echo 0); echo $((n+1)) > ../retry-count; [ $n -ge 1 ]; echo done > f.txt"' 'retries = 2'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json 2> err.txt
check "a retried rule completes and keeps both attempts" '[ "$(status_of s.json completed)" = 1 ] && [ -f "$(last_launch)/attempts/flaky/001/record.json" ] && [ -f "$(last_launch)/attempts/flaky/002/record.json" ]'

# ---------------------------------------------------------------- time limits and termination
new timeout
{ header timeout
  rule sleeper '[]' '["s.txt"]' '"sleep 30; touch s.txt"' 'timeout = "1s"'
  rule stubborn '[]' '["t.txt"]' '"trap \"\" TERM; while true; do sleep 0.2; done"' 'timeout = "1s"'
} > wf.toml
start=$(date +%s)
"$workz" run wf.toml "${iso[@]}" -k --grace 2 -q > s.json 2> err.txt
took=$(( $(date +%s) - start ))
check "timeouts end both tasks within the grace period" '[ "$(status_of s.json failed)" = 2 ] && [ $took -le 8 ] && grep -q "timed out after 1 s" err.txt'

new escaped
{ header escaped
  rule leaver '[]' '["l.txt"]' '"setsid sleep 300 < /dev/null > /dev/null 2>&1 & echo $! > ../escaped.pid; echo ok > l.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
sleep 0.5
pid=$(cat ../escaped.pid)
check "a process that leaves the task's session is ended with its cgroup" '! alive $pid'

new oom
{ header oom; rule hog '[]' '["h.txt"]' '"python3 -I -c \"b = bytearray(300 * 1024 * 1024)\"; touch h.txt"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json 2> err.txt
check "a task above its memory request is OOM-killed and reported" 'grep -q "out of memory: could not stay within its 64 MiB request" err.txt && jq -e ".cgroup.oom_kill >= 1" "$(last_launch)/attempts/hog/001/record.json" > /dev/null'
check "an OOM kill ends the whole task, its shell included" 'jq -e ".signal == 9 and .exit_code == null" "$(last_launch)/attempts/hog/001/record.json" > /dev/null'
# Tasks never swap: the run's scope allows no swap, which bounds every task below it.
{ header oom; rule swap '[]' '["s.txt"]' '"cg=$(sed -n \"s/^0:://p\" /proc/self/cgroup); cat /sys/fs/cgroup${cg%/*}/memory.swap.max > s.txt"'; } > swap.toml
"$workz" run swap.toml "${iso[@]}" -q > swap.json
check "the run's scope allows tasks no swap" '[ "$(cat s.txt)" = 0 ]'

new interrupt
{ header interrupt
  rule long1 '[]' '["l1.txt"]' '"sleep 60; touch l1.txt"'
  rule long2 '[]' '["l2.txt"]' '"trap \"\" TERM INT; while true; do sleep 0.2; done"'
} > wf.toml
setsid "$workz" run wf.toml "${iso[@]}" --grace 1 > s.json 2> err.txt &
launcher=$!
sleep 1.5
kill -INT -- -$launcher
wait $launcher
rc=$?
check "an interrupt cancels running tasks and exits 130" '[ $rc = 130 ] && [ "$(status_of s.json cancelled)" = 2 ]'
check "no task process survives the interrupt" '! pgrep -s $launcher > /dev/null'

new crash
{ header crash
  rule first '[]' '["1.txt"]' '"echo 1 > 1.txt"'
  rule second '["1.txt"]' '["2.txt"]' '"echo $$ > ../crash-task.pid; sleep 30; echo 2 > 2.txt"'
} > wf.toml
"$workz" run wf.toml --no-isolation -q > s1.json &
engine=$!
sleep 2
kill -KILL $engine
wait $engine 2>/dev/null
for _ in $(seq 20); do [ -d /proc/"$(cat ../crash-task.pid)" ] || break; sleep 0.1; done
check "without isolation, a task ends with a killed engine" '[ -s ../crash-task.pid ] && [ ! -d /proc/"$(cat ../crash-task.pid)" ]'
"$workz" plan wf.toml > plan.txt
check "after a killed engine, finished rules are reused and interrupted ones rerun" 'grep -q "reuse first" plan.txt && grep -q "run   second" plan.txt'

new crash-isolated
{ header crash-isolated; rule long '[]' '["l.txt"]' '"echo $$ > pid.txt; sleep 30; touch l.txt"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json 2> /dev/null &
engine=$!
for _ in $(seq 50); do [ -s pid.txt ] && break; sleep 0.1; done
kill -KILL $engine
wait $engine 2> /dev/null
for _ in $(seq 20); do [ -d /proc/"$(cat pid.txt)" ] || break; sleep 0.1; done
check "an isolated task ends with a killed engine" '[ -s pid.txt ] && [ ! -d /proc/"$(cat pid.txt)" ]'

# ---------------------------------------------------------------- admission
new groups
{ printf '[workflow]\nname = "groups"\nversion = "1"\n\n[resource_groups.disk]\nmax = 1\n\n'
  for i in 1 2 3; do
    printf '[[rules]]\nname = "g%s"\ninput = []\noutput = ["g%s.txt"]\nshell = "date +%%s.%%N > g%s.txt; sleep 0.3; date +%%s.%%N >> g%s.txt"\n[rules.resources]\nthreads = 1\nmemory = "64M"\ngroups = { disk = 1 }\n\n' $i $i $i $i
  done
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
overlap=$(cat g1.txt g2.txt g3.txt | paste - - | sort -n | awk 'NR > 1 && $1 < prev { o = 1 } { prev = $2 } END { print o + 0 }')
check "a group of size 1 never runs two members together" '[ "$overlap" = 0 ] && [ "$(status_of s.json completed)" = 3 ]'
waited=$(jq -r '[.queue.reasons[] | select(.reason == "group:disk") | .seconds] | add // 0' "$(last_launch)"/attempts/g*/001/record.json | awk '{ s += $1 } END { print (s > 0.5) }')
check "time spent waiting for the group is recorded with its reason" '[ "$waited" = 1 ] && grep -q "\"reason\":\"group:disk\"" "$(last_launch)/events.jsonl"'
"$workz" report -d . > report.tsv
"$workz" report -d . --format json > report.json
check "report lists every attempt with its use" '[ "$(wc -l < report.tsv)" = 4 ] && head -1 report.tsv | grep -q "^rule	attempt	status	wall_s" && jq -e "length == 3 and (.[0].waited_s | type == \"number\")" report.json > /dev/null'
"$workz" report -d . --bottlenecks > bottlenecks.txt
check "the bottleneck report names the critical path, the waiting group and request sizing" 'grep -q "critical path" bottlenecks.txt && grep -q "group:disk" bottlenecks.txt && grep -q "^  g3  *1 " bottlenecks.txt'


new group-advice
{ printf '[workflow]\nname = "advice"\nversion = "1"\n\n[resource_groups.disk]\nmax = 1\n\n'
  for i in 1 2 3; do
    printf '[[rules]]\nname = "g%s"\ninput = []\noutput = ["g%s.txt"]\nshell = "sleep 2.5; touch g%s.txt"\n[rules.resources]\nthreads = 1\nmemory = "64M"\ngroups = { disk = 1 }\n\n' $i $i $i
  done
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
"$workz" report -d . --bottlenecks > advice.txt
check "the report says when a group, not the budget, held rules back" 'grep -q "^  disk .* a higher max would have started it earlier" advice.txt'

new budget
{ header budget
  for i in 1 2 3; do printf '[[rules]]\nname = "m%s"\ninput = []\noutput = ["m%s.txt"]\nshell = "date +%%s.%%N > m%s.txt; sleep 0.3; date +%%s.%%N >> m%s.txt"\n[rules.resources]\nthreads = 1\nmemory = "600M"\n\n' $i $i $i $i; done
} > wf.toml
"$workz" run wf.toml --max-threads 4 --max-memory 1G -q > s.json
overlap=$(cat m1.txt m2.txt m3.txt | paste - - | sort -n | awk 'NR > 1 && $1 < prev { o = 1 } { prev = $2 } END { print o + 0 }')
check "memory admission never exceeds the budget" '[ "$overlap" = 0 ]'
"$workz" report -d . --bottlenecks > b.txt
held=$(awk '/^  at / { for (i = 1; i <= NF; i++) if ($i == "waited") w = $(i + 1) } END { print (w + 0 > 0.4) }' b.txt)
check "the critical path shows the wait of a rule held by the budget" '[ "$held" = 1 ]'
{ header toolarge; rule big '[]' '["b.txt"]' '"true"'; } | sed 's/memory = "64M"/memory = "8G"/' > big.toml
"$workz" run big.toml --max-memory 1G -q > /dev/null 2> err.txt
rc=$?
check "a rule larger than the budget is rejected before the run" '[ $rc = 2 ] && grep -q "needs 8192 MiB" err.txt'

new shared
mkdir ref && head -c $((64 * 1024 * 1024)) /dev/urandom > ref/index.bin
# Start cold: the first reader of a page is charged for it.
sync ref/index.bin && dd if=ref/index.bin iflag=nocache count=0 status=none
{ printf '[workflow]\nname = "shared"\nversion = "1"\n\n[shared.ref]\npath = "ref"\n\n'
  for i in 1 2; do
    printf '[[rules]]\nname = "use%s"\ninput = ["ref/index.bin"]\noutput = ["u%s.txt"]\nshell = "cksum ref/index.bin > u%s.txt; cg=$(sed -n \\"s/^0:://p\\" /proc/self/cgroup); cat /sys/fs/cgroup${cg%%/*}/memory.low > u%s.low; sleep 0.5"\n[rules.resources]\nthreads = 1\nmemory = "100M"\nshared = ["ref"]\n\n' $i $i $i $i
  done
} > wf.toml
"$workz" run wf.toml --max-threads 4 --max-memory 300M -q > s.json
ev="$(last_launch)/events.jsonl"
both=$(jq -r 'select(.event == "task_started") | .rule' "$ev" | wc -l)
check "shared input is loaded once and both users fit when it is counted once" '[ "$(status_of s.json completed)" = 2 ] && [ "$(grep -c shared_loaded "$ev")" = 1 ] && [ "$both" = 2 ]'
held=$(jq -r 'select(.event == "shared_loaded") | .holder_file_bytes' "$ev")
check "the holder group carries the shared page cache" '[ "$held" -ge $((60 * 1024 * 1024)) ]'
peak=$(jq -r '.cgroup.file' "$(last_launch)/attempts/use1/001/record.json")
check "a user task is not charged for the shared pages" '[ "$peak" -lt $((8 * 1024 * 1024)) ]'
# The run's scope protects the shared pages: memory.low of their size.
check "the run's scope protects the shared input's size from reclaim" 'jq -e "select(.event == \"memory_protected\") | select(.ok and .memory_low_mib == 64)" "$ev" > /dev/null && [ "$(cat u1.low)" = $((64 * 1024 * 1024)) ]'

new samples
{ header samples; rule busy '[]' '["b.txt"]' '"timeout 6 sh -c \"while :; do :; done\" || true; touch b.txt"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
check "run samples show the CPU in use and attempts keep their pressure totals" 'jq -e "select(.event == \"sample\") | select(.cpu_cores_used > 0.5)" "$(last_launch)/events.jsonl" > /dev/null && jq -e ".cgroup.cpu_some_us != null and .cgroup.io_some_us != null" "$(last_launch)/attempts/busy/001/record.json" > /dev/null'

new delegated
{ header delegated; rule hand '[]' '["h.txt"]' '"systemd-run --user --wait -q timeout 1.5 sh -c \"while :; do :; done\" || true; touch h.txt"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
"$workz" report -d . > r.tsv
"$workz" report -d . --bottlenecks > b.txt
check "work handed to another supervisor is reported as delegated, without sizing advice" '[ "$(status_of s.json completed)" = 1 ] && awk -F"\t" "NR == 2 { exit !(\$19 == \"true\") }" r.tsv && grep -q "work ran outside workz" b.txt'

new slice
{ header slice; rule a '[]' '["a.txt"]' '"touch a.txt"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" --slice workz-validation.slice -q > s.json
check "--slice places the run in the named slice and the summary has the engine's cost" 'jq -r "select(.event == \"launch_started\") | .cgroup" "$(last_launch)/events.jsonl" | grep -q "/workz-validation.slice/" && jq -e ".engine_cost.cpu_s > 0 and .engine_cost.max_rss_mib > 0" s.json > /dev/null'

new critical-path
{ header critical-path
  for i in 1 2 3 4 5 6; do rule "short$i" '[]' "[\"s$i.txt\"]" "\"sleep 0.3; touch s$i.txt\""; done
  rule c1 '[]' '["c1.txt"]' '"sleep 0.3; touch c1.txt"'
  rule c2 '["c1.txt"]' '["c2.txt"]' '"sleep 0.3; touch c2.txt"'
  rule c3 '["c2.txt"]' '["c3.txt"]' '"sleep 0.3; touch c3.txt"'
} > wf.toml
"$workz" run wf.toml --max-threads 2 --max-memory 1G -q > s.json
first=$(jq -r 'select(.event == "task_started") | .rule' "$(last_launch)/events.jsonl" | head -2 | tr '\n' ' ')
check "among equal priorities the head of the longest chain starts first ($first)" 'echo "$first" | grep -q "c1 "'
base=$(basename "$(last_launch)")
"$workz" run wf.toml --max-threads 2 --max-memory 1G --rerun -q > s2.json
"$workz" report -d . --compare "$base" > compare.txt
check "report --compare puts two launches side by side" 'grep -q "^baseline .*$base" compare.txt && grep -q "^  elapsed s " compare.txt && grep -q "^  c1 *1 " compare.txt'
"$workz" run wf.toml --max-threads 2 --max-memory 1G --rerun-rule c3 -q > s3.json
"$workz" report -d . --compare "$base" > compare-one.txt
check "report --compare marks a step with no completed attempt on one side" 'grep -q "^  short1 *0 .*no completed attempt in the launch" compare-one.txt && ! grep -q "%.*no completed attempt" compare-one.txt'

# ---------------------------------------------------------------- inputs and formats
new manifest
echo data > ext.txt
{ header manifest; rule m '["ext.txt"]' '["m.txt"]' '"cp ext.txt m.txt"'; } > wf.toml
good=$(sha256sum ext.txt | cut -d" " -f1)
printf '{"%s": "sha256:%s"}\n' "$PWD/ext.txt" "$good" > good.json
printf '{"%s": "sha256:%s"}\n' "$PWD/ext.txt" "$(printf 0%.0s {1..64})" > bad.json
"$workz" run wf.toml "${iso[@]}" -q --input-manifest bad.json > /dev/null 2> err.txt
rc=$?
check "a wrong manifest digest refuses the run" '[ $rc = 1 ] && grep -q "does not match its manifest digest" err.txt'
"$workz" run wf.toml "${iso[@]}" -q --input-manifest good.json > s.json
check "a matching manifest digest runs" '[ "$(status_of s.json completed)" = 1 ]'
touch ext.txt
"$workz" run wf.toml "${iso[@]}" -q --input-manifest good.json > touched.json
check "a touched manifest input with the same bytes is read once and its rule reused" '[ "$(status_of touched.json reused)" = 1 ] && jq -e "select(.event == \"inputs_checked\") | select(.files_read == 1)" "$(last_launch)/events.jsonl" > /dev/null'
stamp() { stat -c '{"dev": %d, "ino": %i, "size": %s, "mtime_ns": %.9Y, "ctime_ns": %.9Z}' "$1" | sed 's/\.//g'; }
echo stamped > st.txt
{ header stamped; rule s '["st.txt"]' '["s.txt"]' '"cp st.txt s.txt"'; } > stamped.toml
printf '{"%s": {"sha256": "sha256:%s", "stamp": %s}}\n' "$PWD/st.txt" "$(sha256sum st.txt | cut -d" " -f1)" "$(stamp st.txt)" > stamped.json
"$workz" run stamped.toml "${iso[@]}" -q --input-manifest stamped.json > s2.json
check "a stamped manifest whose stamp matches runs without reading the file" '[ "$(status_of s2.json completed)" = 1 ] && jq -e "select(.event == \"inputs_checked\") | select(.files == 1 and .files_read == 0)" "$(last_launch)/events.jsonl" > /dev/null'
mkdir stale && cd stale && echo old > st.txt
{ header stale; rule s '["st.txt"]' '["s.txt"]' '"cp st.txt s.txt"'; } > stale.toml
printf '{"%s": {"sha256": "sha256:%s", "stamp": %s}}\n' "$PWD/st.txt" "$(sha256sum st.txt | cut -d" " -f1)" "$(stamp st.txt)" > stale.json
echo new > st.txt
"$workz" run stale.toml "${iso[@]}" -q --input-manifest stale.json > /dev/null 2> err.txt
rc=$?
cd ..
check "a stale stamp makes workz read the file and refuse changed content" '[ $rc = 1 ] && grep -q "does not match its manifest digest" stale/err.txt && jq -e "select(.event == \"inputs_checked\") | select(.files_read == 1)" stale/.workz/launches/*/events.jsonl > /dev/null'
"$workz" status -d stale > stale-status.json
check "a refused launch is recorded and shown by status" 'jq -e ".status == \"refused\" and (.error | test(\"manifest\"))" stale-status.json > /dev/null'

new during
echo x > in.txt
{ header during
  rule reader '["in.txt"]' '["r.txt"]' '"cat in.txt > r.txt"' 'priority = 10'
  rule writer '[]' '["w.txt"]' '"sleep 0.2; echo y >> in.txt; touch w.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json 2> err.txt
check "an input changed during the run fails the launch" 'jq -e ".error | test(\"changed during the run\")" s.json > /dev/null'

new formats
printf '[workflow]\nname = "f"\nversion = "1"\n\n[[rules]]\nname = "x"\noutptu = ["x.txt"]\nshell = "true"\nmemory = "1M"\n' > typo.toml
"$workz" validate typo.toml 2> err.txt
check "an unknown key names its line and the closest key" 'grep -q "line 7: unknown key .outptu. in a rule; did you mean .output.?" err.txt'
{ echo "written before"; "$workz" validate typo.toml; "$workz" version; } > shared.txt 2>&1
check "output to a file other commands also write appends to it" '[ "$(head -1 shared.txt)" = "written before" ] && grep -q "unknown key .outptu." shared.txt && grep -q "^  7 | outptu" shared.txt && tail -1 shared.txt | grep -q "^workz "'
{ header cycle; rule p '["q.txt"]' '["p.txt"]' '"true"'; rule q '["p.txt"]' '["q.txt"]' '"true"'; } > cycle.toml
"$workz" validate cycle.toml 2> err.txt
check "a cycle is rejected" 'grep -q "cycle" err.txt'
{ header dup; rule p '[]' '["same.txt"]' '"true"'; rule q '[]' '["same.txt"]' '"true"'; } > dup.toml
"$workz" validate dup.toml 2> err.txt
check "two producers of one path are rejected" 'grep -q "both produce" err.txt'
{ header escape; rule p '[]' '["../outside.txt"]' '"true"'; } > escape.toml
"$workz" validate escape.toml 2> err.txt
check "an output outside the working directory is rejected" 'grep -q "inside the working directory" err.txt'
printf '[workflow]\nname = "v"\nversion = "1"\nformat_version = 2\n\n[[rules]]\nname = "x"\noutput = ["x.txt"]\nshell = "true"\nmemory = "1M"\n' > future.toml
"$workz" validate future.toml 2> err.txt
check "a newer format version is refused" 'grep -q "format_version 2 is not supported" err.txt'

new init
"$workz" init > init.txt
mkdir data && seq 5 > data/reads.txt
"$workz" init 2> again.txt
rc=$?
"$workz" run workflow.toml "${iso[@]}" -q > s.json
check "init writes a starter workflow that runs, and never overwrites" '[ $rc = 2 ] && grep -q "does not overwrite" again.txt && [ "$(status_of s.json completed)" = 2 ] && [ "$(cat out/report.txt)" = "reads: 5" ]'
words=$(PATH="$(dirname "$workz"):$PATH" bash -c 'source <(workz completion bash); COMP_WORDS=(workz run workflow.toml -t ""); COMP_CWORD=4; _workz; echo "${COMPREPLY[*]}"')
opts=$(PATH="$(dirname "$workz"):$PATH" bash -c 'source <(workz completion bash); COMP_WORDS=(workz plan --su); COMP_CWORD=2; _workz; echo "${COMPREPLY[*]}"')
check "bash completion offers rule names and command options" '[ "$words" = "count report" ] && [ "$opts" = "--summary" ]'
ctl=$(PATH="$(dirname "$workz"):$PATH" bash -c 'source <(workz completion bash); COMP_WORDS=(workz control ""); COMP_CWORD=2; _workz; echo "${COMPREPLY[*]}"')
sug=$(PATH="$(dirname "$workz"):$PATH" bash -c 'source <(workz completion bash); COMP_WORDS=(workz report --su); COMP_CWORD=2; _workz; echo "${COMPREPLY[*]}"')
check "bash completion offers control commands and every report option" '[ "$ctl" = "stop retry cancel" ] && [ "$sug" = "--suggest" ]'

new command-line
"$workz" help run > help-run.txt
rc1=$?
"$workz" run --help > run-help.txt
rc2=$?
check "help shows a command's options, also through --help" '[ $rc1 = 0 ] && [ $rc2 = 0 ] && cmp -s help-run.txt run-help.txt && grep -q "^  --max-threads N" help-run.txt'
"$workz" run wf.toml --max-thread 4 2> typo.txt
rc=$?
check "a mistyped option is named with the one probably meant" '[ $rc = 2 ] && grep -q "did you mean .--max-threads.?" typo.txt'
"$workz" run wf.toml --max-threads 2> missing.txt
rc1=$?
"$workz" run wf.toml --max-memory 4GB 2> invalid.txt
rc2=$?
check "an option without its value, or with a bad one, says what it needs" '[ $rc1 = 2 ] && grep -q "needs a value" missing.txt && [ $rc2 = 2 ] && grep -q "invalid value .4GB." invalid.txt'
"$workz" report -d . 2> nolaunch.txt
rc1=$?
"$workz" logs -d . x 2> noattempt.txt
rc2=$?
check "commands with nothing recorded to show exit 1" '[ $rc1 = 1 ] && [ $rc2 = 1 ] && grep -q "no launch recorded" nolaunch.txt'
"$workz" init --force 2> initopt.txt
rc=$?
check "init rejects options instead of using them as file names" '[ $rc = 2 ] && [ ! -e ./--force ] && grep -q "unknown option" initopt.txt'

new snippet
{ header snippet; rule a '[]' '["a.txt"]' '"true"' 'memroy = "1G"'; } > wf.toml
"$workz" validate wf.toml > /dev/null 2> err.txt
check "a workflow error shows the offending line" 'grep -q "did you mean .memory." err.txt && grep -q "| memroy = \"1G\"" err.txt'

# ---------------------------------------------------------------- monitoring
new watch
{ header watch; rule w '[]' '["w.txt"]' '"echo working >&2; sleep 3; touch w.txt"'; } > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json &
runner=$!
sleep 1.2
"$workz" watch -d . --once > view.txt
wait $runner
check "watch shows the running task with its memory and last output" 'grep -q "^w " view.txt && grep -q working view.txt && grep -q " Mi\| Ki" view.txt'
"$workz" status -d . > status.txt
check "status prints the finished summary" 'jq -e ".status == \"completed\"" status.txt > /dev/null'

new logs-command
{ header logs
  rule talk '[]' '["t.txt"]' '"echo to-out; echo to-err >&2; touch t.txt"'
  rule flaky '[]' '["f.txt"]' '"if [ -f tried ]; then echo second; touch f.txt; else touch tried; echo first; exit 1; fi"' 'retries = 1'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > /dev/null 2>&1
"$workz" logs -d . talk > both.txt
"$workz" logs wf.toml talk --stderr > err.txt
"$workz" logs -d . flaky --attempt 1 --stdout > first.txt
"$workz" logs -d . flaky --stdout > last.txt
check "logs shows a rule's streams, one stream, or an earlier attempt" 'grep -q "^to-out$" both.txt && grep -q "^to-err$" both.txt && [ "$(cat err.txt)" = to-err ] && [ "$(cat first.txt)" = first ] && [ "$(cat last.txt)" = second ]'
{ header logs; rule slow '[]' '["s.txt"]' '"for i in 1 2 3; do echo tick-$i; sleep 0.4; done; touch s.txt"'; } > slow.toml
"$workz" run slow.toml "${iso[@]}" -q > /dev/null &
runner=$!
for _ in $(seq 50); do [ -n "$(ls -d .workz/launches/*/attempts/slow/001 2> /dev/null)" ] && break; sleep 0.05; done
timeout 10 "$workz" logs -d . slow --stdout --follow > follow.txt
rc=$?
wait $runner
check "logs --follow streams a running attempt and returns when it ends" '[ $rc = 0 ] && [ "$(grep -c tick- follow.txt)" = 3 ]'
"$workz" status -d . --history > hist.txt
"$workz" status -d . --history 1 > hist1.txt
check "status --history lists recent launches, newest first" '[ "$(wc -l < hist.txt)" = 3 ] && [ "$(wc -l < hist1.txt)" = 2 ] && sed -n 2p hist.txt | grep -q "completed .* 1 "'

new control
{ header control
  rule slow '[]' '["s.txt"]' '"sleep 30; touch s.txt"'
  rule after '["s.txt"]' '["a.txt"]' '"touch a.txt"'
  rule bad '[]' '["b.txt"]' '"[ -f fixed ] && touch b.txt"'
  rule b2 '["b.txt"]' '["b2.txt"]' '"touch b2.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -k --grace 1 -q > s.json 2> /dev/null &
runner=$!
for _ in $(seq 50); do jq -e 'select(.event == "task_failed" or (.event == "task_finished" and .status == "failed"))' .workz/launches/*/events.jsonl > /dev/null 2>&1 && break; sleep 0.1; done
touch fixed
"$workz" control -d . retry bad > /dev/null
for _ in $(seq 50); do [ -f b2.txt ] && break; sleep 0.1; done
"$workz" control -d . stop slow > /dev/null
wait $runner
check "control retries a failed rule with its blocked consumers and stops a running one" '[ -f b2.txt ] && [ "$(status_of s.json completed)" = 2 ] && [ "$(status_of s.json cancelled)" = 1 ] && [ "$(status_of s.json blocked)" = 1 ] && [ "$(jq -r "select(.event == \"control\") | .result" "$(last_launch)/events.jsonl" | tr "\n" " ")" = "retrying stopping " ]'
"$workz" control -d . cancel 2> ended.txt
rc=$?
check "control refuses a launch that has ended" '[ $rc != 0 ] && grep -q "has ended" ended.txt'

new clean
{ header clean
  rule a '[]' '["a.txt"]' '"date +%s%N > a.txt"'
  rule b '[]' '["b.txt"]' '"touch b.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > /dev/null
for _ in 1 2 3; do "$workz" run wf.toml "${iso[@]}" -t a --rerun -q > /dev/null; done
first=$(ls .workz/launches | head -1)
"$workz" clean -d . --keep 1 --dry-run > dry.txt
check "clean --dry-run lists what it would remove and removes nothing" '[ "$(ls .workz/launches | wc -l)" = 4 ] && grep -q "would remove 0 container(s) and 2 launch(es)" dry.txt'
"$workz" clean -d . --keep 1 > clean.txt
check "clean --keep keeps the newest launches and one that holds a recorded attempt" '[ "$(ls .workz/launches | wc -l)" = 2 ] && [ -d ".workz/launches/$first" ] && grep -q "kept 1 older launch" clean.txt && "$workz" explain wf.toml b | grep -q "is reused"'
{ header clean; rule slow '[]' '["s.txt"]' '"sleep 2; touch s.txt"'; } > busy.toml
"$workz" run busy.toml "${iso[@]}" -q > /dev/null &
runner=$!
for _ in $(seq 50); do [ "$(ls .workz/launches | wc -l)" = 3 ] && break; sleep 0.1; done
"$workz" clean -d . --keep 1 > /dev/null 2> busy.txt
rc=$?
wait $runner
check "clean refuses while a run holds the working directory" '[ $rc != 0 ] && grep -q "a run holds" busy.txt'

new report-html
{ header report-html
  rule ok '[]' '["ok.txt"]' '"touch ok.txt"'
  rule bad '[]' '["bad.txt"]' '"echo \"<boom & stuff>\" >&2; exit 4"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -k -q > s.json
"$workz" report -d . --format html > r.html
check "the html report draws the timeline and shows each failure's error output escaped" 'grep -q "<svg" r.html && grep -q "Failures (1)" r.html && grep -q "&lt;boom &amp; stuff&gt;" r.html && ! grep -q "<boom" r.html && grep -q "What limited the launch" r.html && grep -q "<h2>Steps</h2>" r.html && grep -Eq "class=\"(st-[a-z]+|g[0-9]) crit\"" r.html && grep -Eq "text-anchor=\"end\"( class=\"crit\")?>bad</text>" r.html'
check "the html report has no scripts or remote assets, and has dark and print styles" '! grep -qi "<script" r.html && ! grep -Eq "(src|href)=\"https?:" r.html && grep -q "prefers-color-scheme:dark" r.html && grep -q "@media print" r.html'

new labels
{ header labels
  rule s1__ALIGN '[]' '["s1.txt"]' '"echo s1 > s1.txt"'
  rule s2__ALIGN '[]' '["s2.txt"]' '"echo s2 > s2.txt"'
  rule merge_all '["s1.txt", "s2.txt"]' '["all.txt"]' '"cat s1.txt s2.txt > all.txt"' 'step = "MERGE"
category = "report"
tool = "coreutils"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s1.json
first=$(basename "$(last_launch)")
check "an attempt records its labels, derived from its name or declared" 'jq -e ".labels.step == \"ALIGN\" and .labels.sample == \"s1\" and (.labels.declared.step | not)" .workz/launches/$first/attempts/s1__ALIGN/001/record.json > /dev/null && jq -e ".labels.step == \"MERGE\" and .labels.category == \"report\" and .labels.tool == \"coreutils\" and .labels.declared.step" .workz/launches/$first/attempts/merge_all/001/record.json > /dev/null'
sed -i 's/category = "report"/category = "summary"/' wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s2.json
check "changing a label reruns nothing" '[ "$(status_of s2.json reused)" = 3 ]'
"$workz" report -d . --launch "$first" --bottlenecks > bn.txt
check "the bottleneck report adds up time per category and per sample" 'grep -q "^time per category" bn.txt && grep -Eq "^  report +1 +1 " bn.txt && grep -q "^samples (completed attempts)" bn.txt && grep -Eq "^  s1 +1 +1 .*ALIGN" bn.txt'
"$workz" report -d . --launch "$first" --format html > r.html
check "the html report draws samples by step" 'grep -q "Samples by step" r.html && grep -q "<td class=\"row\">s1</td>" r.html && grep -q ">MERGE</th>" r.html'

if command -v tmux > /dev/null; then
# Interactive watch on a terminal: a private tmux server gives it a real
# terminal; the screen is read back with capture-pane.
tm() { tmux -L "workz-check-$$" -f /dev/null "$@"; }
# start ARGS...: a new detached session, tried again while a server whose last
# session just ended is still shutting down.
start() { for _ in $(seq 30); do tm new-session -d "$@" 2> /dev/null && return 0; sleep 0.1; done; tm new-session -d "$@"; }
# Each view gets its own session: a finished one can outlive its command briefly.
screen() { tm capture-pane -p -t "$sess"; }
# wait_for PATTERN: until the screen shows PATTERN, at most 5 s.
wait_for() { for _ in $(seq 50); do screen | grep -q -- "$1" && return 0; sleep 0.1; done; return 1; }
new watch-tty
{ header watch-tty
  rule slow '[]' '["s.txt"]' '"echo to-stdout; echo to-stderr >&2; sleep 4; touch s.txt"'
  rule quick '[]' '["q.txt"]' '"touch q.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json &
runner=$!
for _ in $(seq 50); do [ -d .workz/launches ] && break; sleep 0.1; done
sess=w1; start -s "$sess" -x 100 -y 14 "NO_COLOR=1 \"$workz\" watch -d . --interval 200; echo \$? > exit.txt; stty -a > stty.txt"
check "the interactive view lists the running rule first with its last output" 'wait_for "running  *slow .*to-stderr" && screen | grep -q "1/4 reserved" && screen | grep -q "64M/2.0G reserved"'
tm send-keys -t "$sess" Enter
check "enter follows the selected attempt's standard error" 'wait_for "slow .*attempt 1  running  stderr" && screen | grep -q "^to-stderr"'
tm send-keys -t "$sess" o
check "o switches the log to standard output" 'wait_for "^to-stdout"'
tm send-keys -t "$sess" q t
check "t shows the timeline" 'wait_for "slow  *>>>"'
wait $runner
check "the view follows the launch to its end and stays open" 'wait_for "completed" && wait_for "slow  *===="'
tm send-keys -t "$sess" q q
for _ in $(seq 50); do [ -s exit.txt ] && break; sleep 0.1; done
check "q leaves the view with status 0 and the terminal restored" '[ "$(cat exit.txt)" = 0 ] && grep -q " icanon" stty.txt && grep -q " echo " stty.txt'
rm -f exit.txt stty.txt
sess=w2; start -s "$sess" -x 100 -y 14 "NO_COLOR=1 \"$workz\" watch -d . --interval 200; echo \$? > exit.txt; stty -a > stty.txt"
wait_for "workz .*launch" && tm send-keys -t "$sess" C-c
for _ in $(seq 50); do [ -s exit.txt ] && break; sleep 0.1; done
check "an interrupt key leaves the view with the terminal restored" '[ "$(cat exit.txt)" = 0 ] && grep -q " icanon" stty.txt'
rm -f exit.txt stty.txt
sess=w3; start -s "$sess" -x 100 -y 14 "NO_COLOR=1 \"$workz\" watch -d . --interval 200; echo \$? > exit.txt; stty -a > stty.txt"
wait_for "workz .*launch"
kill -TERM "$(pgrep -P "$(tm display-message -p -t "$sess" '#{pane_pid}')" -x workz)"
for _ in $(seq 50); do [ -s exit.txt ] && break; sleep 0.1; done
check "SIGTERM leaves the view with the terminal restored" '[ "$(cat exit.txt)" = 0 ] && grep -q " icanon" stty.txt'
new watch-control
{ header watch-control
  rule long '[]' '["l.txt"]' '"echo long-runs >&2; sleep 30; touch l.txt"'
  rule after '["l.txt"]' '["a.txt"]' '"touch a.txt"'
  rule other '[]' '["o.txt"]' '"touch o.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" --grace 1 -q > s.json 2> /dev/null &
runner=$!
for _ in $(seq 50); do [ -d .workz/launches ] && break; sleep 0.1; done
sess=w4; start -s "$sess" -x 120 -y 16 "NO_COLOR=1 \"$workz\" watch -d . --interval 200; echo \$? > exit.txt"
check "the view lists a rule that has yet to start as pending" 'wait_for "pending  *after"'
tm send-keys -t "$sess" / l o n g Enter
check "/ keeps the rules whose name matches" 'wait_for "running  *long" && ! screen | grep -q "pending  *after"'
tm send-keys -t "$sess" i
check "i shows the selected rule's request and live counters" 'wait_for "request  *1 threads, 64M" && screen | grep -q "^  memory  "'
tm send-keys -t "$sess" S
wait $runner
check "S stops the selected running rule through the control file" 'jq -e "select(.event == \"control\" and .command == \"stop\" and .rule == \"long\")" "$(last_launch)/events.jsonl" > /dev/null && [ "$(status_of s.json cancelled)" = 1 ]'
tm send-keys -t "$sess" q q

# run and status on a terminal: event lines, a failure's error lines and a
# readable summary; --json and --no-color restore the output for scripts.
new run-tty
{ header run-tty
  rule ok '[]' '["ok.txt"]' '"touch ok.txt"'
  rule bad '[]' '["bad.txt"]' '"echo first-error-line >&2; echo last-error-line >&2; exit 3"'
  rule after '["bad.txt"]' '["after.txt"]' '"touch after.txt"'
} > wf.toml
sess=r1; start -s "$sess" -x 120 -y 20 "NO_COLOR=1 \"$workz\" run wf.toml ${iso[*]} -k; echo \$? > exit.txt; sleep 30"
for _ in $(seq 100); do [ -s exit.txt ] && break; sleep 0.1; done
check "on a terminal run prints a failure's last error lines, the blocked rules and a readable summary" '[ "$(cat exit.txt)" = 1 ] && screen | grep -q "failed  *bad: exited with status 3$" && screen | grep -q "^ *| last-error-line" && screen | grep -q "blocked  *after: it needs a rule that did not complete" && screen | grep -q "^ failed  *after .* 1 completed, 0 reused, 1 failed, 1 blocked" && screen | grep -q "^ next  *workz logs bad" && ! screen | grep -q "{"'
rm -f exit.txt
sess=r2; start -s "$sess" -x 120 -y 20 "\"$workz\" status -d .; sleep 30"
check "on a terminal status prints the readable summary" 'wait_for "^ failures  *bad  *exited with status 3" && screen | grep -q "^ *| last-error-line"'
rm -f exit.txt
# Wide enough that the JSON line does not wrap.
sess=r3; start -s "$sess" -x 400 -y 20 "\"$workz\" run wf.toml ${iso[*]} -k --json --no-color; echo \$? > exit.txt; sleep 30"
for _ in $(seq 100); do [ -s exit.txt ] && break; sleep 0.1; done
esc=$(printf '\033')
check "run --json --no-color prints the JSON summary without colors on a terminal" '[ "$(cat exit.txt)" = 1 ] && screen | grep -q "\"status\":\"failed\"" && ! tm capture-pane -e -p -t "$sess" | grep -qF "$esc"'

tm kill-server 2> /dev/null
rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/workz-check-$$"
else skip "interactive watch (needs tmux)"; fi

# ---------------------------------------------------------------- cases from the oxo-local acceptance programs
new retry-evidence
{ header retry-evidence
  rule fail_once '[]' '["out.txt"]' '"echo partial > out.txt; if test ! -f attempted; then touch attempted; echo intentional >&2; exit 23; fi; echo recovered > out.txt"'
  rule child '["out.txt"]' '["child.txt"]' '"cat out.txt > child.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" --retry 1 -q > s.json 2> err.txt
check "a retry keeps both attempts and the partial output of the first" '[ "$(status_of s.json completed)" = 2 ] && grep -rq partial "$(last_launch)/attempts/fail_once/002/previous/" && [ "$(cat child.txt)" = recovered ]'

new failed-branch
echo fail > flag
{ header failed-branch
  rule fail '["flag"]' '["out.txt"]' '"test \"$(cat flag)\" = pass; echo good > out.txt"'
  rule child '["out.txt"]' '["child.txt"]' '"cat out.txt > child.txt"'
  rule independent '[]' '["other.txt"]' '"echo good > other.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -k -q > s1.json 2> /dev/null
echo pass > flag
"$workz" run wf.toml "${iso[@]}" -q > s2.json
check "after a fixed failure, independent work is reused and the branch runs" '[ "$(status_of s1.json blocked)" = 1 ] && [ "$(status_of s2.json reused)" = 1 ] && [ "$(status_of s2.json completed)" = 2 ]'

new target
{ header target
  rule root '[]' '["root.txt"]' '"echo root > root.txt"'
  rule child '["root.txt"]' '["child.txt"]' '"cat root.txt > child.txt"'
  rule other '[]' '["other.txt"]' '"echo other > other.txt"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -t child -q > s.json
check "a target selects exactly its dependency closure" '[ "$(status_of s.json completed)" = 2 ] && [ ! -e other.txt ]'

new cpu
{ header cpu
  for i in 1 2 3; do printf '[[rules]]\nname = "c%s"\ninput = []\noutput = ["c%s.txt"]\nshell = "date +%%s.%%N > c%s.txt; sleep 0.25; date +%%s.%%N >> c%s.txt"\n[rules.resources]\nthreads = 3\nmemory = "64M"\n\n' $i $i $i $i; done
} > wf.toml
"$workz" run wf.toml --max-threads 4 --max-memory 2G -q > s.json
overlap=$(cat c1.txt c2.txt c3.txt | paste - - | sort -n | awk 'NR > 1 && $1 < prev { o = 1 } { prev = $2 } END { print o + 0 }')
check "CPU reservations never exceed the thread budget" '[ "$overlap" = 0 ] && [ "$(status_of s.json completed)" = 3 ]'

new logs
{ header logs
  rule verbose '[]' '["out.txt"]' "\"python3 -I -c 'print(\\\"START\\\" + \\\"x\\\" * 200000 + \\\"END\\\"); import sys; print(\\\"ERR\\\" + \\\"y\\\" * 200000, file=sys.stderr)'; echo good > out.txt\"" 'log = "logs/verbose.log"'
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
a="$(last_launch)/attempts/verbose/001"
check "complete separate logs and the combined log are retained" 'head -c 5 "$a/stdout.log" | grep -q START && [ $(stat -c %s "$a/stdout.log") -gt 200000 ] && [ $(stat -c %s "$a/stderr.log") -gt 200000 ] && [ $(stat -c %s logs/verbose.log) -gt 400000 ]'

new environment
{ header environment
  rule env '[]' '["out.txt"]' "\"python3 -I -c 'import os; assert not any(k in os.environ for k in [\\\"OPENAI_API_KEY\\\", \\\"AWS_SECRET_ACCESS_KEY\\\", \\\"BASH_ENV\\\"]); assert os.environ[\\\"WORKZ_THREADS\\\"] == \\\"1\\\"; open(\\\"out.txt\\\", \\\"w\\\").write(\\\"clean\\\")'\""
} > wf.toml
OPENAI_API_KEY=canary AWS_SECRET_ACCESS_KEY=canary BASH_ENV=/nonexistent "$workz" run wf.toml "${iso[@]}" -q > s.json 2> err.txt
check "credentials and shell start-up variables do not reach rules" '[ "$(status_of s.json completed)" = 1 ]'

new network
python3 -I -m http.server --bind 127.0.0.1 0 > server.log 2>&1 &
server=$!
for _ in $(seq 50); do port=$(grep -o 'port [0-9]*' server.log | grep -o '[0-9]*'); [ -n "$port" ] && break; sleep 0.1; done
{ header network
  rule net '[]' '["out.txt"]' "\"if (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; then echo reached > out.txt; else echo blocked > out.txt; fi\""
} > wf.toml
"$workz" run wf.toml "${iso[@]}" -q > s.json
kill $server; wait $server 2>/dev/null
check "a rule cannot reach a listener on the host's loopback" '[ "$(cat out.txt)" = blocked ]'
{ header loopback; rule lo '[]' '["lo.txt"]' "\"id -u > lo.txt; python3 -I -c 'import socket; s = socket.socket(); s.bind((\\\"127.0.0.1\\\", 0)); s.listen(); socket.create_connection(s.getsockname()); print(\\\"ok\\\")' >> lo.txt\""; } > lo.toml
"$workz" run lo.toml "${iso[@]}" -q > lo.json
check "a rule runs as the user and has its own loopback" '[ "$(head -1 lo.txt)" = "$(id -u)" ] && [ "$(tail -1 lo.txt)" = ok ]'

new terminate
{ header terminate; rule slow '[]' '["done.txt"]' '"sleep 8 & echo $! > child.pid; echo started > started.txt; wait; echo late > done.txt"'; } > wf.toml
"$workz" run wf.toml --max-threads 2 --max-memory 256M -q > s.json 2> err.txt &
launcher=$!
for _ in $(seq 100); do [ -f started.txt ] && break; sleep 0.05; done
kill -TERM $launcher
wait $launcher
rc=$?
sleep 0.5
child=$(cat child.pid)
check "SIGTERM to the launcher stops the run and its children" '[ $rc = 130 ] && [ ! -e done.txt ] && ! alive $child'
{ header terminate; rule slow '[]' '["done.txt"]' '"echo resumed > done.txt"'; } > wf.toml
"$workz" run wf.toml --max-threads 2 --max-memory 256M -q > s2.json
check "a later run completes the interrupted rule" '[ "$(cat done.txt)" = resumed ]'

new lock
{ header lock; rule slow '[]' '["done.txt"]' '"echo started > started.txt; sleep 1; echo done > done.txt"'; } > wf.toml
"$workz" run wf.toml --max-threads 1 --max-memory 128M -q > first.json &
first=$!
for _ in $(seq 100); do [ -f started.txt ] && break; sleep 0.05; done
"$workz" run wf.toml --max-threads 1 --max-memory 128M -q > second.json 2> err.txt
rc=$?
wait $first
check "a second run in the same directory is refused while the first holds the lock" '[ $rc = 1 ] && grep -q "another run holds" err.txt && [ "$(status_of first.json completed)" = 1 ]'

for name in ordinary shared_inputs log_is_input log_hardlink relative_alias log_output_hardlink input_output_hardlink log_symlink duplicate_side_write; do
  new "alias-$name"
  echo source > input
  inputs='["input"]'; log=task.log; benchmark=metrics.json
  case $name in
    shared_inputs) ln input second; inputs='["input", "second"]' ;;
    log_is_input) log=input ;;
    log_hardlink) ln input task.log ;;
    relative_alias) mkdir sub; inputs='["sub/../input"]'; log=input ;;
    log_output_hardlink) echo prior > out; ln out task.log ;;
    input_output_hardlink) ln input out ;;
    log_symlink) ln -s "$PWD/input" task.log ;;
    duplicate_side_write) benchmark=$log ;;
  esac
  printf '[workflow]\nname = "alias"\n\n[[rules]]\nname = "copy"\ninput = %s\noutput = ["out"]\nshell = "cat input > out"\nlog = "%s"\nbenchmark = "%s"\n[rules.resources]\nthreads = 1\nmemory = "64M"\n' "$inputs" "$log" "$benchmark" > wf.toml
  "$workz" validate wf.toml > /dev/null 2> err.txt
  rc=$?
  want=2; case $name in ordinary|shared_inputs) want=0 ;; esac
  check "alias case $name is $([ $want = 0 ] && echo accepted || echo rejected)" '[ $rc = $want ]'
done

echo
echo "$pass passed, $failed failed, $skipped skipped"
[ $failed = 0 ]
