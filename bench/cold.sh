#!/usr/bin/env bash
# One cold run in a fresh working directory below BASE, seeded with the files
# of TEMPLATE. Usage: bench/cold.sh BASE TEMPLATE COMMAND...
set -euo pipefail
base=$1 template=$2
shift 2
dir=$(mktemp -d "$base/run.XXXXXX")
cp -r "$template"/. "$dir"/
cd "$dir"
"$@" > stdout.log 2> stderr.log
