#!/bin/bash
# Run a small set of smoke tests and capture output to tests/smoke.log
# Truncates the log on each run so the file only contains the latest results.

LOG_DIR="tests"
LOG_FILE="$LOG_DIR/smoke.log"

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"

echo "Smoke test run: $(date)" >> "$LOG_FILE"

CMDS=(
  "snapshots-find-file -c -d \"/nas/live/cloud/tcc\" --clean-snapshots -s \"*\" -f \"index.html\""
  "snapshots-find-file -c -d \"/nas/live/cloud/tcc\" --destroy-snapshots -s \"*\" -f \"index.html\""
  "snapshots-find-file -cv -d \"/nas/live/cloud/tcc\" --clean-snapshots -s \"*\" -f \"index.html\""
)

for cmd in "${CMDS[@]}"; do
  echo "=== Running: $cmd" | tee -a "$LOG_FILE"
  echo "---- OUTPUT BEGIN ----" >> "$LOG_FILE"
  # Run the command in a subshell; capture both stdout and stderr to the log.
  bash -lc "$cmd" >> "$LOG_FILE" 2>&1 || echo "COMMAND FAILED: $cmd" >> "$LOG_FILE"
  echo "---- OUTPUT END ----" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"
done

echo "Smoke tests completed: $(date)" >> "$LOG_FILE"

echo "Smoke tests finished — log written to: $LOG_FILE"
