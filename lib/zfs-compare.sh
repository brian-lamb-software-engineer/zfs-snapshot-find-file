#!/bin/bash
# ZFS comparison and delta analysis functions

# Phase 2 helpers: split large compare functions into smaller responsibilities
function _gather_live_files() {
  # Args: live_dataset_path tmp_base
  local live_dataset_path="$1"
  local tmp_base="$2"
  vlog "zfs-compare.sh _gather_live_files live_dataset_path=${live_dataset_path} tmp_base=${tmp_base}"
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
  vlog "zfs-compare.sh _sort_snapshot_files raw=${raw} tmp_base=${tmp_base}"
  local sorted
  sorted=$(mktemp "${tmp_base}/sorted_snapshot_files.XXXXXX")
  cat "$raw" | sort -t'|' -k1,1 -k3,3nr > "$sorted"
  echo "$sorted"
}

function _process_diff_pair() {
  # Args: parent_compare_point current_compare_point delta_log_file
  local parent_compare_point="$1"
  local current_compare_point="$2"
  local delta_log_file="$3"

  vlog "zfs-compare.sh _process_diff_pair parent=${parent_compare_point} current=${current_compare_point} delta_log=${delta_log_file}"

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
  vlog "zfs-compare.sh _get_all_compare_points dataset=${dataset}"
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
  vlog "zfs-compare.sh compare_snapshot_files_to_live_dataset raw=${raw_snapshot_file_list_tmp} live=${live_dataset_path}"
  # Use LOG_DIR (configurable) or fall back to $TMPDIR or /tmp to avoid filling the current CWD
  local tmp_base="${LOG_DIR:-${TMPDIR:-/tmp}}"
  local log_file="$tmp_base/comparison-$TIMESTAMP.out"
  local ignored_log_file="$tmp_base/compare-ignore-$TIMESTAMP.out"

  echo -e "${CYAN}Starting comparison, results will be logged to:${NC} ${YELLOW}$log_file${NC}"
  echo "Comparison initiated on $(date)" > "$log_file"
  echo "Live dataset path: $live_dataset_path" >> "$log_file"
  echo "Ignored patterns:" >> "$log_file"
  for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
    echo "  - $pattern" >> "$log_file"
  done
  echo "" >> "$log_file"
  echo "Files missing from live dataset but present in snapshot(s):" >> "$log_file"
  echo "------------------------------------------------------------" >> "$log_file"
  echo -e "${CYAN}Logging ignored files to:${NC} ${YELLOW}$ignored_log_file${NC}"
  # Only warn about ignores if the user supplied/overrode ignore patterns
  local _default_join
  local _current_join
  _default_join="${DEFAULT_IGNORE_REGEX_PATTERNS[*]:-}"
  _current_join="${IGNORE_REGEX_PATTERNS[*]:-}"
  if [[ -n "$_current_join" && "$_current_join" != "$_default_join" ]]; then
    echo -e "${YELLOW}Warning: Ignore patterns may hide snapshot-only files; review ${ignored_log_file} for ignored entries.${NC}"
  fi
  echo "Unique Ignored Files (matching patterns in IGNORE_REGEX_PATTERNS):" > "$ignored_log_file"
  echo "------------------------------------------------------------" >> "$log_file"

  # 1. Get all files in the current live dataset
  [[ $VERBOSE == 1 ]] && echo -e "${CYAN}Gathering live dataset files from: ${WHITE}$live_dataset_path${NC}"
  local live_files_tmp
  live_files_tmp=$(_gather_live_files "$live_dataset_path" "$tmp_base")

  if [[ $VERBOSE == 1 ]]; then
    if [[ -f "$live_files_tmp" ]]; then
      local live_count
      live_count=$(wc -l < "$live_files_tmp" 2>/dev/null || echo 0)
    else
      live_count=0
    fi
    echo -e "${CYAN}Live dataset file count: ${live_count}${NC}"
  fi

  # Counters for summary
  local total_snapshot_entries=0
  local ignored_files_count=0
  local found_in_live_count=0
  local missing_files_count=0
  local skipped_reported_files_count=0

  # Temporary file to track paths already reported to avoid duplicates in main log
  local seen_paths_tmp
  seen_paths_tmp=$(mktemp "${tmp_base}/seen_paths.XXXXXX")
  #TODO figure out why the message below says "already reported" then clarify that reason or fix it
  # make it say 0 if its zero, right now i see an empty string ($skipped_reported)
  # Temporary file to track unique ignored paths for the ignored_log_file
  local seen_ignored_paths_tmp
  seen_ignored_paths_tmp=$(mktemp "${tmp_base}/seen_ignored_paths.XXXXXX")

  # Sort the raw snapshot file list by live_equivalent_path then by creation_timestamp (NEWEST first)
  # This ensures that when a path is encountered, it's the one from the newest snapshot.
  # Using | as delimiter for sort. -k1,1 ensures sorting on the first field (path),
  # -k3,3nr on the third field (timestamp) numerically in reverse (newest first).
  local sorted_snapshot_files_tmp
  sorted_snapshot_files_tmp=$(_sort_snapshot_files "$raw_snapshot_file_list_tmp" "$tmp_base")

  # Read sorted snapshot file paths (path|snap_name|timestamp)
  # Using 'while read -r' for robust line-by-line reading.
    while IFS='|' read -r live_equivalent_path snap_name creation_time_epoch || [[ -n "$live_equivalent_path" ]]; do
      # Count processed snapshot entries
      ((total_snapshot_entries++))

      # Check if this exact path has already been processed and reported
      if grep -Fxq "$live_equivalent_path" "$seen_paths_tmp"; then
        ((skipped_reported_files_count++)) # Increment skip counter
        continue
      fi

      # Check against the ignore list first
      local ignore_match=0
      for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
        if [[ "$live_equivalent_path" =~ $pattern ]]; then
          # Log unique ignored files to their separate file
          if ! grep -Fxq "$live_equivalent_path" "$seen_ignored_paths_tmp"; then
            echo "$live_equivalent_path (ignored by pattern: '$pattern')" >> "$ignored_log_file"
            echo "$live_equivalent_path" >> "$seen_ignored_paths_tmp"
            ((ignored_files_count++))
          fi
          [[ $VERBOSE == 1 ]] && echo -e "${YELLOW}Ignoring (matches pattern): $live_equivalent_path (Pattern: '$pattern')${NC}"
          ignore_match=1
          break
        fi
      done

      if [[ $ignore_match -eq 0 ]]; then
        # Check if the live_equivalent_path exists in our list of live files
        if grep -Fxq "$live_equivalent_path" "$live_files_tmp"; then
          ((found_in_live_count++))
          # Mark as seen to avoid duplicate reporting
          echo "$live_equivalent_path" >> "$seen_paths_tmp"
        else
          echo -e "${GREEN}$live_equivalent_path (found in newest snapshot: [${WHITE}$snap_name${GREEN}] )${NC}" | tee -a "$log_file"
          echo "$live_equivalent_path" >> "$seen_paths_tmp" # Mark as seen
          ((missing_files_count++))
        fi
      fi
    done < "$sorted_snapshot_files_tmp"

  echo "" >> "$ignored_log_file"
  echo "Ignored files cataloging finished." >> "$ignored_log_file"

  # Cleanup temporary files (counters retained for final summary)
  rm -f "$live_files_tmp" "$seen_paths_tmp" "$seen_ignored_paths_tmp" "$sorted_snapshot_files_tmp"

  # Aggregate summary (printed last for CLI readability)
  echo -e "${CYAN}Writing comparison summary to logs...${NC}"
  {
    echo "--- Comparison Summary ---"
    echo "Total snapshot entries processed: $total_snapshot_entries"
    echo "Total ignored entries: $ignored_files_count"
    echo "Total found in live dataset: $found_in_live_count"
    echo "Total missing (snapshot-only): $missing_files_count"
    echo "Total skipped (duplicates): ${skipped_reported_files_count:-0}"
    echo ""
  } >> "$log_file"

  # Append summary to ignored log as well
  echo "--- Ignored Summary ---" >> "$ignored_log_file"
  echo "Ignored entries count: $ignored_files_count" >> "$ignored_log_file"

  # Write a small CSV summary for tooling/automation
  local summary_csv="$tmp_base/comparison-summary-$TIMESTAMP.csv"
  {
    echo "metric,value"
    echo "total_snapshot_entries,$total_snapshot_entries"
    echo "ignored_entries,$ignored_files_count"
    echo "found_in_live,$found_in_live_count"
    echo "missing,$missing_files_count"
    echo "skipped_duplicates,${skipped_reported_files_count:-0}"
  } > "$summary_csv"

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

  vlog "zfs-compare.sh log_snapshot_deltas dataset_path=${dataset_path} datasets_count=${#datasets_array[@]}"

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
    [[ $VERBOSE == 1 ]] && echo -e "\n${PURPLE}Analyzing deltas for dataset: ${WHITE}$dataset${NC}"
    echo "--- Dataset: $dataset ---" >> "$delta_log_file"

    # Get snapshots for this dataset, sorted by creation time ASCENDING (oldest to newest)
    # We will iterate and build parent/child pairs
    # Delegate snapshot listing to helper to keep this function small
    local -a all_compare_points=()
    mapfile -t all_compare_points < <(_get_all_compare_points "$dataset")

    # If there's only one item (just the live dataset or no snapshots), skip diffing pairs
    if [[ ${#all_compare_points[@]} -lt 2 ]]; then
      echo "  No snapshots or only live dataset for $dataset. Skipping delta comparisons." >> "$delta_log_file"
      continue
    fi

    # Iterate through comparison pairs (oldest snapshot to next, newest snapshot to live)
    for (( i=0; i<${#all_compare_points[@]}-1; i++ )); do
      local parent_compare_point="${all_compare_points[i]}"
      local current_compare_point="${all_compare_points[i+1]}"
      local comparison_context="${parent_compare_point} to ${current_compare_point}"

      echo "\n--- Delta for: ${current_compare_point} (compared to ${parent_compare_point}) ---" >> "$delta_log_file"
      [[ $VERBOSE == 1 ]] && echo -e "  ${YELLOW}Comparing ${WHITE}${current_compare_point} ${YELLOW}to ${WHITE}${parent_compare_point}${NC}"

      # Use zfs diff to get changes
        # Delegate diff processing to helper to keep this function small
        _process_diff_pair "$parent_compare_point" "$current_compare_point" "$delta_log_file"
    done
  done
  echo "\nDelta analysis finished." >> "$delta_log_file"
}