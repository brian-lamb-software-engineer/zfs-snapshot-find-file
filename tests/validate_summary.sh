#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# tests/validate_summary.sh
# ---------------------------------------------------------------------------
# Purpose:
#   Run a non-destructive invocation of the snapshots-find-file tool, locate
#   the generated comparison summary CSV, and validate that key summary fields
#   are numeric. This script is intended as a lightweight integration check
#   to detect regressions where human-readable or ANSI-colored text leaks into
#   machine-consumable output files.
#
# Rationale:
#   The project uses command-substitution and downstream CSV consumers that
#   expect plain numeric values. During earlier testing we observed ANSI
#   escape sequences and diagnostic lines contaminating CSVs; this test
#   ensures that the final summary contains only expected numeric fields.
#
# Safety and assumptions:
#   - This script runs the project in a dry-run / plan-only mode. It does not
#     execute destructive snapshot deletion.
#   - The environment must have the project's `snapshots-find-file` script
#     available and executable from the repository root.
#   - Running this test may require access to ZFS datasets present on the
#     host. For CI use, consider adding a fixture-mode to the project so
#     tests do not depend on real ZFS datasets.
#
# Output and logs:
#   - Test log: tests/test.log
#   - Captured run output: tests/run_output.log
#
# Exit codes:
#   - 0: all validated fields are numeric
#   - 1: summary CSV missing or one or more invalid fields detected
# ---------------------------------------------------------------------------

LOG_DIR="tests"
mkdir -p "$LOG_DIR"
TEST_LOG="$LOG_DIR/test.log"
RUN_OUT="$LOG_DIR/run_output.log"
: > "$TEST_LOG"
: > "$RUN_OUT"

# Load local environment overrides if present
ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Defaults (used if .env not provided)
: "${SFF_DATASET:=/nas/live/cloud/tcc}"
: "${SFF_SNAPSHOT_PATTERN:=*}"
: "${SFF_FILE_PATTERN:=*}"

# Run the tool (dry-run) and capture all output.
./snapshots-find-file -cvv -d "$SFF_DATASET" -s "$SFF_SNAPSHOT_PATTERN" --clean-snapshots -f "$SFF_FILE_PATTERN" > "$RUN_OUT" 2>&1 || true

echo "Run output saved to: $RUN_OUT" >> "$TEST_LOG"

# Find produced summary CSV
summary=$(grep -oE "/tmp/.*/comparison-summary\\.csv" "$RUN_OUT" | tail -n1 || true)
if [[ -z "$summary" || ! -f "$summary" ]]; then
  echo "ERROR: No summary CSV found in run output." >> "$TEST_LOG"
  echo "--- run output (tail 200) ---" >> "$TEST_LOG"
  tail -n 200 "$RUN_OUT" >> "$TEST_LOG" 2>&1 || true
  echo "FAIL: summary CSV missing" | tee -a "$TEST_LOG"
  exit 1
fi

echo "Found summary CSV: $summary" >> "$TEST_LOG"

echo "--- CSV (first 200 lines) ---" >> "$TEST_LOG"
sed -n '1,200p' "$summary" >> "$TEST_LOG" 2>&1 || true

# Extract and sanitize values (strip ANSI escapes)
esc=$(printf '\033')
strip_ansi() { sed -r "s/${esc}\\[[0-9;]*[mK]//g"; }

total=$(awk -F, 'NR>1 && $1=="total_snapshot_entries"{print $2}' "$summary" | strip_ansi | tr -d '\r')
ignored=$(awk -F, 'NR>1 && $1=="ignored_entries"{print $2}' "$summary" | strip_ansi | tr -d '\r')
found=$(awk -F, 'NR>1 && $1=="found_in_live"{print $2}' "$summary" | strip_ansi | tr -d '\r')
missing=$(awk -F, 'NR>1 && $1=="missing"{print $2}' "$summary" | strip_ansi | tr -d '\r')
skipped=$(awk -F, 'NR>1 && $1=="skipped_duplicates"{print $2}' "$summary" | strip_ansi | tr -d '\r')

# Validation function
is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

errors=0
for kv in "total:$total" "ignored:$ignored" "found:$found" "missing:$missing" "skipped:$skipped"; do
  key=${kv%%:*}; val=${kv#*:}
  if ! is_num "$val"; then
    echo "ERROR: summary field '$key' invalid: '$val'" >> "$TEST_LOG"
    errors=$((errors+1))
  else
    echo "OK: $key = $val" >> "$TEST_LOG"
  fi
done

if [[ $errors -eq 0 ]]; then
  echo "OK: Comparison summary valid — total=$total ignored=$ignored found=$found missing=$missing skipped=$skipped" | tee -a "$TEST_LOG"
  exit 0
else
  echo "FAIL: $errors invalid field(s) found" | tee -a "$TEST_LOG"
  echo "--- CSV for inspection ---" >> "$TEST_LOG"
  sed -n '1,200p' "$summary" >> "$TEST_LOG" 2>&1 || true
  exit 1
fi
