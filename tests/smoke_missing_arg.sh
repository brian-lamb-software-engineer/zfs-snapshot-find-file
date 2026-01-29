#!/bin/bash
# Smoke test: verify missing-argument handling for -s prints help error and exits non-zero
set -euo pipefail
SCRIPT="$(pwd)/snapshots-find-file"
if [[ ! -x "$SCRIPT" ]]; then
  echo "snapshots-find-file not found or not executable at $SCRIPT"
  exit 1
fi
# Run with missing -s argument; expect non-zero exit and help error mentioning -s
if "$SCRIPT" -d /tmp -s 2>&1 | tee /tmp/smoke_missing_arg.out; then
  echo "Expected failure when -s missing value, but command succeeded"
  exit 2
else
  if grep -q "Error: Unrecognized option: -s" /tmp/smoke_missing_arg.out; then
    echo "OK: missing-arg behavior produced expected help error"
    exit 0
  else
    echo "FAIL: output did not contain expected error string"
    cat /tmp/smoke_missing_arg.out
    exit 3
  fi
fi
