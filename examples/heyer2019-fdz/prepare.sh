#!/usr/bin/env bash
# Prepares a workz workflow that runs fdz on four Heyer 2019 samples with
# known fusions: subset the reads, classify read pairs against a refz
# reference, search junctions, merge the calls and report the expected
# fusions. The refz files fdz maps are declared as shared inputs, loaded once
# and counted once in memory admission.
# Usage: prepare.sh FDZ_BINARY HEYER2019_DIR REFZ_DIR PAIRS OUT_DIR
set -euo pipefail
fdz=$(realpath "$1") heyer=$(realpath "$2") refz=$(realpath "$3") pairs=$4 out=$5
mkdir -p "$out"
lines=$((pairs * 4))
samples=(03JW 07KM 30RN 03NP)
{
  printf '[workflow]\nname = "heyer2019-fdz"\nversion = "1"\n\n'
  printf '[resource_groups.decompress]\nmax = 2\n\n'
  for f in annotation.refz transcripts.kmers genome.refz; do
    printf '[shared.%s]\npath = "%s/%s"\n\n' "${f%%.*}" "$refz" "$f"
  done
  junctions=()
  for s in "${samples[@]}"; do
    row=$(awk -F'\t' -v s="$s" '$1 == s' "$heyer/samples.tsv")
    r1="$heyer/$(cut -f5 <<< "$row")" r2="$heyer/$(cut -f6 <<< "$row")"
    printf '[[rules]]\nname = "subset_%s"\ninput = ["%s", "%s"]\noutput = ["reads/%s_1.fastq", "reads/%s_2.fastq"]\n' "$s" "$r1" "$r2" "$s" "$s"
    printf 'shell = "head -n %d <(zcat %s) > reads/%s_1.fastq; head -n %d <(zcat %s) > reads/%s_2.fastq"\n' $lines "$r1" "$s" $lines "$r2" "$s"
    printf 'log = "logs/subset_%s.log"\n[rules.resources]\nthreads = 2\nmemory = "256M"\ngroups = { decompress = 1 }\n\n' "$s"

    printf '[[rules]]\nname = "classify_%s"\ninput = ["reads/%s_1.fastq", "reads/%s_2.fastq", "%s/refz.manifest"]\n' "$s" "$s" "$s" "$refz"
    printf 'output = ["classify/%s.gene_pairs.tsv", "classify/%s.qc.tsv", "classify/%s.kept_1.fastq", "classify/%s.kept_2.fastq"]\n' "$s" "$s" "$s" "$s"
    printf 'shell = "%s classify --refz %s/refz.manifest --spill --out classify/%s reads/%s_1.fastq reads/%s_2.fastq"\n' "$fdz" "$refz" "$s" "$s" "$s"
    printf 'priority = 10\nlog = "logs/classify_%s.log"\nbenchmark = "metrics/classify_%s.json"\n[rules.resources]\nthreads = 1\nmemory = "512M"\nshared = ["annotation", "transcripts", "genome"]\n\n' "$s" "$s"

    printf '[[rules]]\nname = "junctions_%s"\ninput = ["classify/%s.gene_pairs.tsv", "classify/%s.kept_1.fastq", "classify/%s.kept_2.fastq"]\n' "$s" "$s" "$s" "$s"
    printf 'output = ["junctions/%s.junctions.tsv"]\n' "$s"
    printf 'shell = "%s junctions --refz %s/refz.manifest --pairs classify/%s.gene_pairs.tsv --out junctions/%s classify/%s.kept_1.fastq classify/%s.kept_2.fastq"\n' "$fdz" "$refz" "$s" "$s" "$s" "$s"
    printf 'priority = 20\nlog = "logs/junctions_%s.log"\nbenchmark = "metrics/junctions_%s.json"\n[rules.resources]\nthreads = 1\nmemory = "512M"\nshared = ["annotation", "transcripts", "genome"]\n\n' "$s" "$s"
    junctions+=("junctions/$s.junctions.tsv")
  done
  inputs=$(printf '"%s", ' "${junctions[@]}"); inputs="[${inputs%, }]"
  calls=$(printf 'fdz:%s ' "${junctions[@]}")
  printf '[[rules]]\nname = "merge"\ninput = %s\noutput = ["merged.events.tsv", "merged.calls.tsv"]\nshell = "%s merge --out merged %s"\n[rules.resources]\nthreads = 1\nmemory = "256M"\n\n' "$inputs" "$fdz" "$calls"
  printf '[[rules]]\nname = "report"\ninput = ["merged.events.tsv", "%s/samples.tsv"]\noutput = ["expected.tsv"]\n' "$heyer"
  printf 'shell = "for s in %s; do want=$(awk -F\\"\\\\t\\" -v s=$s %s $1 == s {print $3} %s %s/samples.tsv); a=${want%%%%::*}; b=${want##*::}; n=$(grep -c \\"$a.*$b\\\\|$b.*$a\\" merged.events.tsv || true); printf \\"%%s\\\\t%%s\\\\t%%s\\\\n\\" $s $want $n; done > expected.tsv"\n' "${samples[*]}" "'" "'" "$heyer"
  printf '[rules.resources]\nthreads = 1\nmemory = "64M"\n'
} > "$out/main.toml"
echo "$out/main.toml"
