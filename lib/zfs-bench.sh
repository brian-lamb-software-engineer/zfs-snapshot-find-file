#!/bin/bash
# Bench and zfs-fast compare helpers (moved from lib/zfs-compare.sh and snapshots-find-file)
# Provides:
# - function bench_zfs_fast_compare() : zfs-diff based compare (per-pair), writes delta and summary
# - function bench_sff_run() : single-entry bench runner used by CLI when BENCH is requested

# NOTE: relies on sff_zfs_diff() from lib/common.sh and compare_snapshot_files_to_live_dataset()/log_snapshot_deltas() from lib/zfs-compare.sh

# Top-level bench-only variables (kept here so production files remain slim)
# These are configurable by exporting before running the script in bench mode.
BENCH_TMP_BASE="${BENCH_TMP_BASE:-/tmp}"
function bench_help() {
  cat <<'BHELP'
Benchmark mode help (bench-only):
  - `--bench` runs a quick parity/telemetry check comparing legacy (find) vs zfs diff (zdiff) paths.
  - Requires `-c` (compare) to be meaningful; it is opt-in and exits after reporting timings and missing counts.
  - Per-run artifacts are written to `LOG_DIR_ROOT/<SHORT_TS>/` when `LOG_DIR_ROOT` is provided.
  - Example:
    LOG_DIR_ROOT=/tmp/sff_bench_$(date +%s) ./snapshots-find-file -c --bench -v -d pool/dataset -s "*" -f "*"
BHELP
}

function bench_zfs_fast_compare() {
  local raw_snapshot_file_list_tmp="$1"
  local live_dataset_path="$2"
  vlog "bench_zfs_fast_compare raw=${raw_snapshot_file_list_tmp} live=${live_dataset_path}"

  local tmp_base="${LOG_DIR:-${TMPDIR:-${BENCH_TMP_BASE}}}"
  local delta_log_file="$tmp_base/comparison-delta.out"
  local acc_deleted_file="${tmp_base}/${SFF_TMP_PREFIX}acc_deleted.csv"
  local snap_holding_file="${tmp_base}/${SFF_TMP_PREFIX}snap_holding.txt"

  : > "$delta_log_file" 2>/dev/null || true
  : > "$acc_deleted_file" 2>/dev/null || true
  : > "$snap_holding_file" 2>/dev/null || true

  echo "Type,File_Path,Is_Ignored,Comparison_Context,Full_Parent_Snap,Full_Current_Snap" > "$delta_log_file"

  # Normalize dataset name for zfs commands (no leading slash)
  local dataset
  dataset="${live_dataset_path#/}"
  dataset="${dataset%/}"

  local -a all_compare_points=()
  mapfile -t all_compare_points < <(_get_all_compare_points "$dataset")

  if [[ ${#all_compare_points[@]} -lt 2 ]]; then
    echo "No snapshots or only live dataset for $dataset. Skipping zfs-fast-compare." >> "$delta_log_file"
    return 0
  fi

  for (( i=0; i<${#all_compare_points[@]}-1; i++ )); do
    local parent_compare_point="${all_compare_points[i]}"
    local current_compare_point="${all_compare_points[i+1]}"
    comparison_context="${parent_compare_point} to ${current_compare_point}"

    local diff_tmp
    diff_tmp=$(mktemp "${tmp_base}/zfs-diff-tmp.XXXXXX")
    sff_zfs_diff "$parent_compare_point" "$current_compare_point" > "$diff_tmp" 2>&1
    local st=$?
    if [[ $st -ne 0 ]]; then
      local cmdlog="${LOG_DIR}/${SFF_TMP_PREFIX}commands.log"
      mkdir -p "$(dirname "$cmdlog")" 2>/dev/null || true
      echo "FALLBACK: zfs diff failed for ${parent_compare_point} ${current_compare_point} (exit $st). Falling back to find-based compare for dataset ${dataset}." >> "$cmdlog"
      SKIP_ZFS_FAST=1 compare_snapshot_files_to_live_dataset "$raw_snapshot_file_list_tmp" "$live_dataset_path"
      rm -f "$diff_tmp" || true
      return 0
    fi

    while IFS=$'\t' read -r type path || [[ -n "$type" ]]; do
      local diff_type_char="${type:0:1}"
      local full_path="${path}"
      local is_ignored="false"

      case "$diff_type_char" in
        '+') local rendered_type="ADD" ;;
        '-') local rendered_type="DEL" ;;
        'M') local rendered_type="MOD" ;;
        'R') local rendered_type="REN" ;;
        *) continue ;;
      esac

      for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
        if [[ "$full_path" =~ $pattern ]]; then
          is_ignored="true"
          break
        fi
      done

      printf "%s,\"%s\",%s,\"%s\",\"%s\",\"%s\"\n" \
             "${rendered_type}" \
             "${full_path//\"/\"\"}" \
             "${is_ignored}" \
             "${comparison_context//\"/\"\"}" \
             "${parent_compare_point//\"/\"\"}" \
             "${current_compare_point//\"/\"\"}" >> "$delta_log_file"

      if [[ "$diff_type_char" == "-" ]]; then
        local snap_name
        snap_name="${parent_compare_point##*@}"
        if [[ "$snap_name" == "$parent_compare_point" ]]; then
          snap_name="${parent_compare_point}"
        fi
        if [[ ! -f "$acc_deleted_file" ]] || ! grep -Fq "${snap_name}|${full_path}" "$acc_deleted_file" 2>/dev/null; then
          printf '%s|%s\n' "$snap_name" "$full_path" >> "$acc_deleted_file" || true
        fi
        if [[ ! -f "$snap_holding_file" ]] || ! grep -Fxq "$snap_name" "$snap_holding_file" 2>/dev/null; then
          echo "$snap_name" >> "$snap_holding_file" || true
        fi
      fi

    done < "$diff_tmp"
    rm -f "$diff_tmp" || true
  done

  local missing_count
  if [[ -f "$acc_deleted_file" ]]; then
    missing_count=$(awk -F'|' 'END{print NR}' "$acc_deleted_file")
  else
    missing_count=0
  fi
  missing_count="${missing_count%% *}"
  if ! [[ "$missing_count" =~ ^[0-9]+$ ]]; then missing_count=0; fi
  local summary_csv="$tmp_base/comparison-summary-$TIMESTAMP.csv"
  local tmp_csv
  tmp_csv=$(mktemp "${tmp_base}/comparison-summary-tmp.XXXXXX")
  printf '%s\n' "metric,value" \
    "total_snapshot_entries,0" \
    "ignored_entries,0" \
    "found_in_live,0" \
    "missing,$missing_count" \
    "skipped_duplicates,0" > "$tmp_csv"
  mv -f "$tmp_csv" "$summary_csv" 2>/dev/null || cp -f "$tmp_csv" "$summary_csv" 2>/dev/null || true

  echo "Wrote zfs-fast comparison delta to: $delta_log_file" >> "$delta_log_file"
}

# Single-entry bench runner. Relies on globals: all_snapshot_files_found_tmp, DATASETPATH_FS, DATASETS, LOG_DIR_ROOT
function bench_sff_run() {
  # inner helper
  function __run_once() {
    local use_z="$1"
    local _ts
    _ts=$(date +"%Y%m%d-%H%M%S")
    TIMESTAMP="${_ts}"
    SHORT_TS="${TIMESTAMP:4}"
    LOG_DIR="${LOG_DIR_ROOT}/${SHORT_TS}"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    # Ensure the snapshot list tmp file is defined (falls back to LOG_DIR-based name).
    all_snapshot_files_found_tmp="${all_snapshot_files_found_tmp:-${LOG_DIR}/${SFF_TMP_PREFIX}all_snapshot_files_found.log}"
    if [[ "$use_z" -eq 1 ]]; then REQUEST_ZFS_COMPARE=1; else REQUEST_ZFS_COMPARE=0; fi # shellcheck disable=SC2034 (bench toggles shared flag)
    SKIP_ZFS_FAST=${SKIP_ZFS_FAST:-0}
    if [[ "$use_z" -eq 0 ]]; then SKIP_ZFS_FAST=1; fi
    local start_ns end_ns dur_ms
    start_ns=$(date +%s%N 2>/dev/null || echo 0)
    compare_snapshot_files_to_live_dataset "$all_snapshot_files_found_tmp" "$DATASETPATH_FS"
    log_snapshot_deltas "$DATASETPATH_FS" "${DATASETS[@]}"
    end_ns=$(date +%s%N 2>/dev/null || echo 0)
    if [[ $start_ns -ne 0 && $end_ns -ne 0 ]]; then dur_ms=$(( (end_ns - start_ns) / 1000000 )); else dur_ms=0; fi
    local summary_csv="$LOG_DIR/comparison-summary-${TIMESTAMP}.csv"
    local missing
    local tries=0
    while [[ ! -s "$summary_csv" && $tries -lt 6 ]]; do
      sleep 0.2
      tries=$((tries+1))
    done
    if [[ -s "$summary_csv" ]]; then
      missing=$(awk -F, 'BEGIN{ORS=""} $1=="missing"{gsub(/\r/,"",$2); print $2}' "$summary_csv" 2>/dev/null || echo "0")
    else
      missing="0"
    fi
    printf '%s,%s,%s\n' "$use_z" "$dur_ms" "$missing"
  }

  oldIFS=$IFS
  IFS=',' read -r _legacy_usez legacy_ms legacy_missing < <(__run_once 0 | tail -n1) # shellcheck disable=SC2034 (legacy use flag unused in bench summary)
  IFS=',' read -r _zdiff_usez zdiff_ms zdiff_missing < <(__run_once 1 | tail -n1) # shellcheck disable=SC2034 (zdiff use flag unused in bench summary)
  IFS=$oldIFS

  if [[ -z "${legacy_missing// /}" ]]; then
    fallback_summary=""
    if [[ -n "${LOG_DIR_ROOT:-}" ]]; then
      fallback_summary=$(find "${LOG_DIR_ROOT}" -type f -name 'comparison-summary-*.csv' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | awk '{print $2}') || true
    fi
    if [[ -z "${fallback_summary}" ]]; then
      fallback_summary=$(find tests/tmp_parity_* -type f -name 'comparison-summary-*.csv' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | awk '{print $2}') || true
    fi
    if [[ -n "${fallback_summary}" && -f "${fallback_summary}" ]]; then
      legacy_missing=$(awk -F, '$1=="missing"{gsub(/\r/,"",$2); print $2}' "${fallback_summary}" 2>/dev/null || echo "")
      echo "(bench) legacy missing fallback read from: ${fallback_summary}" >&2
    fi
  fi

  echo "Legacy (find) time: ${legacy_ms}ms missing:${legacy_missing}"
  echo "ZDIFF time: ${zdiff_ms}ms missing:${zdiff_missing}"
}

export -f bench_zfs_fast_compare bench_sff_run bench_help
