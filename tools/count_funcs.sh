#!/usr/bin/env bash
# Count lines per function in lib/*.sh where functions are defined as "function name() {"
# Outputs: filename:function:lines
set -euo pipefail
for f in lib/*.sh; do
  awk '
  BEGIN{file=FILENAME}
  # Match function start: function name()
  /^[[:space:]]*function[[:space:]]+[a-zA-Z0-9_]+[[:space:]]*\(\)/ {
    # extract name
    match($0, /^[[:space:]]*function[[:space:]]+([a-zA-Z0-9_]+)[[:space:]]*\(\)/,arr)
    name=arr[1]
    cnt=0
    in=1
    next
  }
  in==1 {
    cnt++
    if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) {
      printf("%s:%s:%d\n", FILENAME, name, cnt)
      in=0
    }
  }
  ' "$f"
done | sort -t: -k3 -n -r
