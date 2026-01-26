#!/bin/bash
# Smoke test: compare parity between legacy find-based (-c) and zfs-diff fast-path (-c -z)
set -euo pipefail
LOGDIR_BASE="tests/tmp_parity_$(date +%s)"
mkdir -p "$LOGDIR_BASE"
export LOG_DIR_ROOT="$LOGDIR_BASE"

ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
: "${SFF_DATASET:=/nas/live/cloud/tcc}"

echo "Running legacy find-based compare (no -z)..."
(cd "$(dirname "$0")/.." && LOG_DIR_ROOT="$LOGDIR_BASE" ./snapshots-find-file -c -d "$SFF_DATASET" -s "*" -f "index.html") > /dev/null 2>&1 || true
# find the most recent run dir
DIR1=$(find "$LOGDIR_BASE" -mindepth 1 -maxdepth 2 -type f -name 'comparison-summary-*.csv' -printf '%h\n' 2>/dev/null | sort | tail -n1 || true)
if [[ -z "$DIR1" ]]; then
  echo "Legacy summary not found: no run directory under $LOGDIR_BASE" >&2
  exit 2
fi
SUMMARY1=$(ls "$DIR1"/comparison-summary-*.csv 2>/dev/null | sort | tail -n1 || true)

echo "Running zfs-diff fast-path (-z)..."
(cd "$(dirname "$0")/.." && LOG_DIR_ROOT="$LOGDIR_BASE" ./snapshots-find-file -c -z -d "$SFF_DATASET" -s "*" -f "index.html") > /dev/null 2>&1 || true
DIR2=$(find "$LOGDIR_BASE" -mindepth 1 -maxdepth 2 -type f -name 'comparison-summary-*.csv' -printf '%h
' 2>/dev/null | sort | tail -n1 || true)
if [[ -z "$DIR2" ]]; then
  echo "ZFS fast-path summary not found: no comparison-summary-*.csv under $LOGDIR_BASE" >&2
  exit 3
fi
SUMMARY2=$(ls "$DIR2"/comparison-summary-*.csv 2>/dev/null | sort | tail -n1 || true)

if [[ ! -f "$SUMMARY1" ]]; then
  echo "Legacy summary not found: $SUMMARY1" >&2
  exit 2
fi
if [[ ! -f "$SUMMARY2" ]]; then
  echo "ZFS fast-path summary not found: $SUMMARY2" >&2
  exit 3
fi

# Extract missing counts
M1=$(awk -F, '$1=="missing"{print $2}' "$SUMMARY1" | tr -d '\r' || echo "0")
M2=$(awk -F, '$1=="missing"{print $2}' "$SUMMARY2" | tr -d '\r' || echo "0")

echo "Legacy missing: $M1"
echo "ZFS missing:    $M2"

if [[ "$M1" != "$M2" ]]; then
  echo "Mismatch between legacy and zfs fast-path missing counts" >&2
  exit 4
fi

echo "Parity test passed: missing counts match ($M1)"

echo "Logs and summaries are in: $LOGDIR_BASE"
exit 0
