#!/bin/bash
# ZFS comparison and delta analysis functions

# Phase 2 helpers: split large compare functions into smaller responsibilities
## MISSING_LEGEND_PRINTED was replaced by a pre-scan; keep for backward compat if referenced
MISSING_LEGEND_PRINTED=0

function _gather_live_files() {
  # Args: live_dataset_path tmp_base
  local live_dataset_path="$1"
  local tmp_base="$2"
  vlog "live_dataset_path=${live_dataset_path} tmp_base=${tmp_base}"
  local live_files_tmp
  # Ensure tmp_base exists and mktemp can create files there. Fall back to
  # a predictable file if mktemp fails to avoid returning an empty path.
  mkdir -p "$tmp_base" 2>/dev/null || true
  if ! live_files_tmp=$(mktemp "${tmp_base}/live_files.XXXXXX" 2>/dev/null); then
    live_files_tmp="${tmp_base}/live_files.fallback.${TIMESTAMP}"
    : > "$live_files_tmp" || return 1
  fi
  # Use -L to dereference symlinks to ensure we get actual file paths.
  # Using -print0 and xargs -0 for robust handling of special characters in filenames.
  #/bin/sudo /bin/find "$live_dataset_path" -type f -print0 2>/dev/null | xargs -0 -I {} bash -c 'echo "{}"' > "$live_files_tmp"
  # Use -print0 and xargs -0 to handle special chars robustly
  # Run the find pipeline and write results to the temp file. If the pipeline
  # fails, ensure the temp file still exists so callers don't error when reading.
  # shellcheck disable=SC2016
  /bin/sudo /bin/find "$live_dataset_path" -type f -print0 2>/dev/null | xargs -0 -I {} bash -c 'echo "$0"' "{}" > "$live_files_tmp" 2>/dev/null || true
  if [[ ! -f "$live_files_tmp" ]]; then
    : > "$live_files_tmp" || return 1
  fi
  echo "$live_files_tmp"
}

function _sort_snapshot_files() {
  # Args: raw_snapshot_file_list_tmp tmp_base
  local raw="$1"
  local tmp_base="$2"
  vlog "raw=${raw} tmp_base=${tmp_base}"
  local sorted
  sorted=$(mktemp "${tmp_base}/sorted_snapshot_files.XXXXXX")
  sort -t'|' -k1,1 -k3,3nr "$raw" > "$sorted"
  echo "$sorted"
}

function _csfld_process_sorted() {
  # Args: sorted_snapshot_files_tmp live_files_tmp log_file ignored_log_file seen_paths_tmp seen_ignored_paths_tmp
  local sorted_snapshot_files_tmp="$1"
  local live_files_tmp="$2"
  local log_file="$3"
  local ignored_log_file="$4"
  local seen_paths_tmp="$5"
  local seen_ignored_paths_tmp="$6"

  vlog "sorted=${sorted_snapshot_files_tmp} live=${live_files_tmp} log=${log_file} ignored=${ignored_log_file}"

  if [[ ${QUIET:-0} -eq 1 ]]; then
    echo -e "${YELLOW}Quiet mode enabled: per-file missing output suppressed; showing counts only.${NC}" >&2
  fi

  # If interactive verbose mode, pre-scan to determine whether any missing
  # entries exist so we can print a single legend line above the list.
  if [[ ${QUIET:-0} -ne 1 && ${VERBOSE:-0} -eq 1 ]]; then
    local _tmp_paths
    local _tmp_live
    _tmp_paths=$(mktemp)
    _tmp_live=$(mktemp)
    awk -F'|' '{print $1}' "$sorted_snapshot_files_tmp" | sort > "$_tmp_paths"
    sort "$live_files_tmp" > "$_tmp_live" 2>/dev/null || true
    local _missing_count
    _missing_count=$(comm -23 "$_tmp_paths" "$_tmp_live" | wc -l)
    if [[ ${_missing_count:-0} -gt 0 ]]; then
      echo -e "${GREEN}MISSING = (present in snapshot, absent in live)${NC}" >&2
    fi
    rm -f "$_tmp_paths" "$_tmp_live" || true
  fi

  local total_snapshot_entries=0
  local ignored_files_count=0
  local found_in_live_count=0
  local missing_files_count=0
  local skipped_reported_files_count=0

  # Iterate sorted records and delegate classification to helper to keep this
  # function concise and focused on counting/aggregation.
  # shellcheck disable=SC2034
  while IFS='|' read -r live_equivalent_path snap_name creation_time_epoch || [[ -n "$live_equivalent_path" ]]; do
    ((total_snapshot_entries++))
    [[ -z "$live_equivalent_path" ]] && continue
    if grep -Fxq "$live_equivalent_path" "$seen_paths_tmp" 2>/dev/null; then
      ((skipped_reported_files_count++))
      continue
    fi

    local result
    result=$(_csfld_check_path "$live_equivalent_path" "$snap_name" "$live_files_tmp" "$log_file" "$ignored_log_file" "$seen_paths_tmp" "$seen_ignored_paths_tmp")
    case "$result" in
      IGNORED) ((ignored_files_count++)) ;;
      FOUND) ((found_in_live_count++)) ;;
      MISSING) ((missing_files_count++)) ;;
      *) ;;
    esac
  done < "$sorted_snapshot_files_tmp"

  # Emit counters: total ignored found missing skipped
  echo "$total_snapshot_entries $ignored_files_count $found_in_live_count $missing_files_count $skipped_reported_files_count"
}

function _csfld_check_path() {
  # Args: live_equivalent_path snap_name live_files_tmp log_file ignored_log_file seen_paths_tmp seen_ignored_paths_tmp
  local live_equivalent_path="$1"
  local snap_name="$2"
  local live_files_tmp="$3"
  local log_file="$4"
  local ignored_log_file="$5"
  local seen_paths_tmp="$6"
  local seen_ignored_paths_tmp="$7"

  # Check ignore patterns first, log unique ignored entries
  for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
    if [[ "$live_equivalent_path" =~ $pattern ]]; then
      if ! grep -Fxq "$live_equivalent_path" "$seen_ignored_paths_tmp" 2>/dev/null; then
        echo "$live_equivalent_path (ignored by pattern: '$pattern')" >> "$ignored_log_file"
        echo "$live_equivalent_path" >> "$seen_ignored_paths_tmp"
      fi
      # Send verbose ignore notices to stderr so stdout remains clean for
      # the numeric counters returned by the prepare-and-run helper.
      [[ $VERBOSE == 1 ]] && echo -e "${YELLOW}Ignoring (matches pattern): $live_equivalent_path (Pattern: '$pattern')${NC}" >&2
      printf '%s' "IGNORED"
      return 0
    fi
  done

  # Not ignored: check live dataset index
  if grep -Fxq "$live_equivalent_path" "$live_files_tmp" 2>/dev/null; then
    echo "$live_equivalent_path" >> "$seen_paths_tmp"
    printf '%s' "FOUND"
  else
    # Append the detailed missing-entry line to the comparison log only.
    echo -e "${GREEN}$live_equivalent_path (found in newest snapshot: [${WHITE}$snap_name${GREEN}] )${NC}" >> "$log_file"
    # If verbose and not in quiet mode, also emit a concise notice to stderr for interactive runs.
    if [[ ${QUIET:-0} -ne 1 && ${VERBOSE:-0} -eq 1 ]]; then
      echo -e "${GREEN}MISSING: $live_equivalent_path (snapshot: $snap_name)${NC}" >&2
    fi
    echo "$live_equivalent_path" >> "$seen_paths_tmp"
    printf '%s' "MISSING"
  fi
}

function _process_diff_pair() {
  # Args: parent_compare_point current_compare_point delta_log_file
  local parent_compare_point="$1"
  local current_compare_point="$2"
  local delta_log_file="$3"

  vlog "parent=${parent_compare_point} current=${current_compare_point} delta_log=${delta_log_file}"

  /sbin/zfs diff "$parent_compare_point" "$current_compare_point" 2>/dev/null | while IFS=$'\t' read -r type path; do
    local diff_type_char="${type:0:1}"
    local full_path="${path}"
    local is_ignored="false"
    local rendered_type=""

    case "$diff_type_char" in
      '+') rendered_type="ADD" ;;
      '-') rendered_type="DEL" ;;
      'M') rendered_type="MOD" ;;
      'R')
        rendered_type="REN"
        full_path="${path}"
        local new_path_for_check="${path##* -> }"
        for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
          if [[ "$new_path_for_check" =~ $pattern ]]; then
            is_ignored="true"
            break
          fi
        done
        ;;
      *) continue ;;
    esac

    if [[ "$diff_type_char" != "R" ]]; then
      for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
        if [[ "$full_path" =~ $pattern ]]; then
          is_ignored="true"
          break
        fi
      done
    fi

    printf "%s,\"%s\",%s,\"%s\",\"%s\",\"%s\"\n" \
           "${rendered_type}" \
           "${full_path//\"/\"\"}" \
           "${is_ignored}" \
           "${comparison_context//\"/\"\"}" \
           "${parent_compare_point//\"/\"\"}" \
           "${current_compare_point//\"/\"\"}" >> "$delta_log_file"
  done
}

function _get_all_compare_points() {
  # Args: dataset
  # Output: lines of compare points (oldest snapshot ... newest snapshot ... live dataset)
  local dataset="$1"
  vlog "dataset=${dataset}"
  # Get snapshots for this dataset, sorted by creation time ASCENDING (oldest to newest)
  # Skip header from zfs list
  zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n +2
  # Finally output the live dataset as the latest compare point
  printf '%s
' "$dataset"
}


function compare_snapshot_files_to_live_dataset() {
  local raw_snapshot_file_list_tmp="$1" # Expects file with live_equivalent_path|snap_name|timestamp
  local live_dataset_path="$2"
  vlog "raw=${raw_snapshot_file_list_tmp} live=${live_dataset_path}"

  local tmp_base="${LOG_DIR:-${TMPDIR:-/tmp}}"
  local log_file="$tmp_base/comparison-$TIMESTAMP.out"
  local ignored_log_file="$tmp_base/compare-ignore-$TIMESTAMP.out"

  # Informational output should go to stderr so stdout remains for data.
  echo -e "${CYAN}Starting comparison, results will be logged to:${NC} ${YELLOW}$log_file${NC}" >&2
  echo "Comparison initiated on $(date)" > "$log_file"
  echo "Live dataset path: $live_dataset_path" >> "$log_file"

  # Delegate work to a small prepare-and-run helper that returns counters
  read total_snapshot_entries ignored_files_count found_in_live_count missing_files_count skipped_reported_files_count < <(_csfld_prepare_and_run "$raw_snapshot_file_list_tmp" "$live_dataset_path" "$tmp_base" "$log_file" "$ignored_log_file")

  # Write final summary via helper
  _csfld_write_summary "$tmp_base" "$log_file" "$ignored_log_file" "$total_snapshot_entries" "$ignored_files_count" "$found_in_live_count" "$missing_files_count" "$skipped_reported_files_count"
}

function _csfld_prepare_and_run() {
  # Args: raw_snapshot_file_list_tmp live_dataset_path tmp_base log_file ignored_log_file
  local raw_snapshot_file_list_tmp="$1"
  local live_dataset_path="$2"
  local tmp_base="$3"
  local log_file="$4"
  local ignored_log_file="$5"

  # Always send gathering/info messages to stderr so callers capturing stdout
  # only receive the data payload (temp file paths and final counters).
  [[ $VERBOSE == 1 ]] && echo -e "${CYAN}Gathering live dataset files from: ${WHITE}$live_dataset_path${NC}" >&2
  local live_files_tmp
  live_files_tmp=$(_gather_live_files "$live_dataset_path" "$tmp_base")

  if [[ $VERBOSE == 1 ]]; then
    if [[ -f "$live_files_tmp" ]]; then
      local live_count
      live_count=$(wc -l < "$live_files_tmp" 2>/dev/null || echo 0)
    else
      live_count=0
    fi
    # Send this informational/debug message to stderr so the function's
    # stdout remains reserved for the final counters returned to callers.
    echo -e "${CYAN}Live dataset file count: ${live_count}${NC}" >&2
  fi

  local sorted_snapshot_files_tmp
  sorted_snapshot_files_tmp=$(_sort_snapshot_files "$raw_snapshot_file_list_tmp" "$tmp_base")

  local seen_paths_tmp
  seen_paths_tmp=$(mktemp "${tmp_base}/seen_paths.XXXXXX")
  local seen_ignored_paths_tmp
  seen_ignored_paths_tmp=$(mktemp "${tmp_base}/seen_ignored_paths.XXXXXX")

  read total_snapshot_entries ignored_files_count found_in_live_count missing_files_count skipped_reported_files_count < <(_csfld_process_sorted "$sorted_snapshot_files_tmp" "$live_files_tmp" "$log_file" "$ignored_log_file" "$seen_paths_tmp" "$seen_ignored_paths_tmp")

  rm -f "$seen_paths_tmp" "$seen_ignored_paths_tmp" "$sorted_snapshot_files_tmp" || true
  rm -f "$live_files_tmp" || true

  echo "$total_snapshot_entries $ignored_files_count $found_in_live_count $missing_files_count $skipped_reported_files_count"
}

function _csfld_write_summary_csv() {
  # Args: tmp_base total ignored found missing skipped
  local tmp_base="$1"
  local total_snapshot_entries="$2"
  local ignored_files_count="$3"
  local found_in_live_count="$4"
  local missing_files_count="$5"
  local skipped_reported_files_count="$6"
  # Write a CSV summary file (defensive: strip ANSI sequences)
  local summary_csv="$tmp_base/comparison-summary-$TIMESTAMP.csv"
  local tmp_csv
  tmp_csv=$(mktemp "${tmp_base}/comparison-summary-tmp.XXXXXX")
  {
    echo "metric,value"
    echo "total_snapshot_entries,$total_snapshot_entries"
    echo "ignored_entries,$ignored_files_count"
    echo "found_in_live,$found_in_live_count"
    echo "missing,$missing_files_count"
    echo "skipped_duplicates,${skipped_reported_files_count:-0}"
  } > "$tmp_csv"

  local ESC
  ESC=$(printf '\033')
  if sed -r "s/${ESC}\[[0-9;]*[mK]//g" "$tmp_csv" > "$summary_csv" 2>/dev/null; then
    rm -f "$tmp_csv" || true
  else
    # If sed with escaped ESC sequence isn't supported, copy file as-is.
    cp "$tmp_csv" "$summary_csv" || true
    rm -f "$tmp_csv" || true
  fi

  # Background compress older logs from previous runs to conserve disk.
  # Runs in subshell so it does not block the main process. Excludes files
  # that contain the current $TIMESTAMP so we don't compress files we just created.
  (
    sleep 1
    cur_ts="$TIMESTAMP"
    base="$tmp_base"
    patterns=("$base/comparison-*.out" "$base/comparison-delta-*.out" "$base/comparison-summary-*.csv" "$base/sff_*")
    for pat in "${patterns[@]}"; do
      for f in $pat; do
        [[ -e "$f" ]] || continue
        case "$f" in
          *"$cur_ts"*) continue ;;
        esac
        # skip already compressed files
        [[ "$f" == *.gz ]] && continue
        # perform best-effort compression
        gzip -9 "$f" >/dev/null 2>&1 || true
      done
    done
  ) &

  printf '%s' "$summary_csv"
}

function _csfld_write_summary() {
  # Args: tmp_base log_file ignored_log_file total ignored found missing skipped
  local tmp_base="$1"
  local log_file="$2"
  local ignored_log_file="$3"
  local total_snapshot_entries="$4"
  local ignored_files_count="$5"
  local found_in_live_count="$6"
  local missing_files_count="$7"
  local skipped_reported_files_count="$8"

  echo "" >> "$ignored_log_file"
  echo "Ignored files cataloging finished." >> "$ignored_log_file"

  # Summary-writing notice is informational; route to stderr.
  echo -e "${CYAN}Writing comparison summary to logs...${NC}" >&2
  {
    echo "--- Comparison Summary ---"
    echo "Total snapshot entries processed: $total_snapshot_entries"
    echo "Total ignored entries: $ignored_files_count"
    echo "Total found in live dataset: $found_in_live_count"
    echo "Total missing (snapshot-only): $missing_files_count"
    echo "Total skipped (duplicates): ${skipped_reported_files_count:-0}"
    echo ""
  } >> "$log_file"

  echo "--- Ignored Summary ---" >> "$ignored_log_file"
  echo "Ignored entries count: $ignored_files_count" >> "$ignored_log_file"

  local summary_csv
  summary_csv=$(_csfld_write_summary_csv "$tmp_base" "$total_snapshot_entries" "$ignored_files_count" "$found_in_live_count" "$missing_files_count" "$skipped_reported_files_count")

  echo "Wrote summary to: $summary_csv" >> "$log_file"
}

function log_snapshot_deltas() {
  local dataset_path="$1"
  shift # Remove the first argument (dataset_path)
  #local -n datasets_array="$2" # Use nameref to access the global DATASETS array
  #local datasets_array_name="$2" # Variable to hold the name of the array
  # Use indirect expansion to access the array elements
  # This pattern means: ${!variable_holding_array_name[@]}
  #local -a datasets_array=("${!datasets_array_name[@]}") # Populate local array from global array by name
  local -a datasets_array=("$@")

  vlog "dataset_path=${dataset_path} datasets_count=${#datasets_array[@]}"

  # Ensure we write logs into configured LOG_DIR (or TMP fallback)
  local tmp_base="${LOG_DIR:-${TMPDIR:-/tmp}}"
  local delta_log_file="$tmp_base/comparison-delta-$TIMESTAMP.out"

  if [[ ${#datasets_array[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No datasets found for delta analysis. Skipping.${NC}"
    return # Exit function if no datasets to process
  fi

  echo -e "${CYAN}Logging snapshot deltas to:${NC} ${YELLOW}$delta_log_file${NC}"
  echo "Snapshot Delta Analysis initiated on $(date)" > "$delta_log_file"
  echo "Dataset path: $dataset_path" >> "$delta_log_file"
  echo "Ignored patterns:" >> "$delta_log_file"

  for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
    echo "  - $pattern" >> "$delta_log_file"
  done

  echo "" >> "$delta_log_file"

  # Add CSV header at the top of the delta log for easy parsing
  echo "Type,File_Path,Is_Ignored,Comparison_Context,Full_Parent_Snap,Full_Current_Snap" >> "$delta_log_file"
  # Iterate datasets (already filtered by recursive/wildcard logic in main script)
  for dataset in "${datasets_array[@]}"; do
    _lsd_process_dataset "$dataset" "$delta_log_file"
  done
  printf "\nDelta analysis finished.\n" >> "$delta_log_file"
}

function _lsd_process_dataset() {
  # Args: dataset delta_log_file
  local dataset="$1"
  local delta_log_file="$2"

  [[ $VERBOSE == 1 ]] && echo -e "\n${PURPLE}Analyzing deltas for dataset: ${WHITE}$dataset${NC}"
  echo "--- Dataset: $dataset ---" >> "$delta_log_file"

  local -a all_compare_points=()
  mapfile -t all_compare_points < <(_get_all_compare_points "$dataset")

  if [[ ${#all_compare_points[@]} -lt 2 ]]; then
    echo "  No snapshots or only live dataset for $dataset. Skipping delta comparisons." >> "$delta_log_file"
    return
  fi

  for (( i=0; i<${#all_compare_points[@]}-1; i++ )); do
    local parent_compare_point="${all_compare_points[i]}"
    local current_compare_point="${all_compare_points[i+1]}"
    local comparison_context="${parent_compare_point} to ${current_compare_point}"

    printf "\n--- Delta for: %s (compared to %s) ---\n" "${current_compare_point}" "${parent_compare_point}" >> "$delta_log_file"
    [[ $VERBOSE == 1 ]] && echo -e "  ${YELLOW}Comparing ${WHITE}${current_compare_point} ${YELLOW}to ${WHITE}${parent_compare_point}${NC}"

    _process_diff_pair "$parent_compare_point" "$current_compare_point" "$delta_log_file"
  done
}