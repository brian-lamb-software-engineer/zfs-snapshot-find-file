#!/bin/bash
# Smoke test: verify conflicting flags -z and --force-find produce an error
set -euo pipefail
SCRIPT="$(pwd)/snapshots-find-file"
if [[ ! -x "$SCRIPT" ]]; then
  echo "snapshots-find-file not found or not executable at $SCRIPT"
  exit 1
fi
TMPOUT=/tmp/smoke_conflict.out
if "$SCRIPT" --force-find -z -d /tmp 2>&1 | tee "$TMPOUT"; then
  echo "Expected failure when combining --force-find and -z, but command succeeded"
  exit 2
else
  if grep -qi "Conflicting options" "$TMPOUT"; then
    echo "OK: conflict detected and reported"
    exit 0
  else
    echo "FAIL: conflict not reported as expected"
    cat "$TMPOUT"
    exit 3
  fi
fi
