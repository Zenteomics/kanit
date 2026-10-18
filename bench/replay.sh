#!/usr/bin/env bash
# Writes a replay of a prepared rnaFusion workflow: the same rules, inputs,
# outputs, priorities, groups and resource requests, with each command
# replaced by one that only creates its outputs. External relative inputs
# (scripts/, specs/) point back into the original run directory, read-only.
# Usage: bench/replay.sh RUN_DIR OUT_FILE
set -euo pipefail
run=$(realpath "$1")
awk -v run="$run" '
  /^output=/ { line = $0; sub(/^output=\[/, "", line); sub(/\]$/, "", line); gsub(/"/, "", line); gsub(/,/, " ", line); outs = line }
  /^input=/ { gsub(/"scripts\//, "\"" run "/scripts/"); gsub(/"specs\//, "\"" run "/specs/") }
  /^shell=/ { print "shell=\"touch " outs "\""; next }
  { print }
' "$run/main.oxoflow" > "$2"
