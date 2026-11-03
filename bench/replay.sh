#!/usr/bin/env bash
# Writes a replay of a prepared workflow: the same rules, inputs, outputs,
# priorities, groups and resource requests, with each command replaced by one
# that only creates its outputs. External relative inputs (scripts/, specs/)
# point back into the prepared workflow's directory, read-only. Keys may be
# written `key=value` or `key = value`; a workflow in which no command was
# replaced is refused, since its replay would run the real tools.
# Usage: bench/replay.sh PREPARED_WORKFLOW OUT_FILE
set -euo pipefail
prepared=$(realpath "$1")
dir=$(dirname "$prepared")
awk -v run="$dir" '
  /^output *=/ { line = $0; sub(/^output *= *\[/, "", line); sub(/\] *$/, "", line); gsub(/"/, "", line); gsub(/,/, " ", line); outs = line }
  /^input *=/ { gsub(/"scripts\//, "\"" run "/scripts/"); gsub(/"specs\//, "\"" run "/specs/") }
  /^shell *=/ { print "shell = \"touch " outs "\""; replaced++; next }
  { print }
  END { if (replaced == 0) { print "replay: no shell line to replace in " FILENAME > "/dev/stderr"; exit 1 } }
' "$prepared" > "$2"
