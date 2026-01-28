#!/bin/bash
# Smoke test: simulate a missing-file evidence case to verify plan generation end-to-end
# This test stubs `sff_run` and `sff_zfs_diff` to avoid requiring real ZFS.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/zfs-cleanup.sh"

# Prepare a temporary LOG_DIR
TMP_ROOT=$(mktemp -d /tmp/sff_smoke.XXXXXX)
export LOG_DIR="$TMP_ROOT"
mkdir -p "$LOG_DIR"

# Create datasets file with one dataset
DATASET="nas/fake/ds"
DATASETS_FILE="$LOG_DIR/${SFF_TMP_PREFIX}datasets.log"
printf '%s\n' "$DATASET" > "$DATASETS_FILE"

# Prepare acc_deleted evidence file (simulate one missing file in a snapshot)
ACC_FILE="$LOG_DIR/${SFF_TMP_PREFIX}acc_deleted.csv"
printf 'Snapshot,File_Path,Live_Dataset_Path\n' > "$ACC_FILE"
# simulate that snapshot 'nas/fake/ds@oldsnap' holds a file missing from live
printf '%s|%s\n' "nas/fake/ds@oldsnap" "/path/to/missing.file" >> "$ACC_FILE"

# Prepare snap_holding file
SNAP_HOLD_FILE="$LOG_DIR/${SFF_TMP_PREFIX}snap_holding.txt"
echo 'nas/fake/ds@oldsnap' > "$SNAP_HOLD_FILE"

# Prepare destroy_cmds and plan paths
DESTROY_CMDS_TMP="$LOG_DIR/${SFF_TMP_PREFIX}destroy_cmds.log"
PLAN_FILE="$LOG_DIR/${SFF_TMP_PREFIX}destroy-plan.sh"
: > "$DESTROY_CMDS_TMP"
: > "$PLAN_FILE"

# Stub sff_run to output a zfs list header + two snapshots
sff_run() {
  if printf '%s ' "$@" | grep -q "zfs list"; then
    # print header line then two snapshots
    echo "NAME"
    echo "$DATASET@oldsnap"
    echo "$DATASET@newsnap"
  else
    command "$@"
  fi
}

# Stub sff_zfs_diff to return empty for oldsnap->newsnap (so newsnap becomes candidate)
sff_zfs_diff() {
  # Args: a b
  # For this test, always return empty (no diffs)
  return 0
}

# Run the evaluator directly
_evaluate_deletion_candidates_and_plan "$DATASETS_FILE" "$SNAP_HOLD_FILE" "$ACC_FILE" "$DESTROY_CMDS_TMP" "$PLAN_FILE"

# After evaluation, if destroy_cmds_tmp was populated, write the plan
if [[ -s "$DESTROY_CMDS_TMP" ]]; then
  _write_destroy_plan "$DESTROY_CMDS_TMP" "$PLAN_FILE" "$TIMESTAMP" "$LOG_DIR"
  echo "SMOKE: plan generated at: $PLAN_FILE"
  sed -n '1,200p' "$PLAN_FILE"
  exit 0
else
  echo "SMOKE: no destroy commands generated"
  exit 2
fi
