#!/usr/bin/env bash
# Writes a generated workflow of RULES rules in layers of WIDTH, shaped like a
# prepared pipeline: rule sK__lN is step lN of sample sK. Each rule past the
# first layer reads one or two outputs of the layer before it, and its command
# only creates its output unless COMMAND is given; {output} in COMMAND names
# the rule's output.
# Usage: bench/graph.sh RULES WIDTH OUT_FILE [COMMAND]
set -euo pipefail
[ $# -ge 3 ] || { echo "usage: bench/graph.sh RULES WIDTH OUT_FILE [COMMAND]" >&2; exit 2; }
command=${4:-"touch {output}"}
awk -v n="$1" -v w="$2" -v cmd="$command" 'BEGIN {
  printf "[workflow]\nname = \"generated\"\nversion = \"1\"\n"
  for (i = 0; i < n; i++) {
    out = "o_" i ".txt"
    inputs = ""
    if (i >= w) {
      a = i - w
      b = a - a % w + (i * 7) % w
      inputs = "\"o_" a ".txt\""
      if (b != a) inputs = inputs ", \"o_" b ".txt\""
    }
    c = cmd
    gsub(/\{output\}/, out, c)
    printf "\n[[rules]]\nname = \"s%d__l%d\"\ninput = [%s]\noutput = [\"%s\"]\nshell = \"%s\"\nmemory = \"32M\"\n", i % w, int(i / w), inputs, out, c
  }
}' > "$3"
