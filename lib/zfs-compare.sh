#!/bin/bash
# ZFS comparison and delta analysis functions

function compare_snapshot_files_to_live_dataset() {
  local raw_snapshot_file_list_tmp="$1" # Expects file with live_equivalent_path|snap_name|timestamp
  local live_dataset_path="$2"
  local log_file="comparison-$TIMESTAMP.out"
  local ignored_log_file="compare-ignore-$TIMESTAMP.out"

  echo -e "${BLUE}Starting comparison, results will be logged to:${NC} ${YELLOW}$log_file${NC}"
  echo "Comparison initiated on $(date)" > "$log_file"
  echo "Live dataset path: $live_dataset_path" >> "$log_file"
  echo "Ignored patterns:" >> "$log_file"
  for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
    echo "  - $pattern" >> "$log_file"
  done
  echo "" >> "$log_file"
  echo "Files missing from live dataset but present in snapshot(s):" >> "$log_file"
  echo "------------------------------------------------------------" >> "$log_file"
  echo -e "${BLUE}Logging ignored files to:${NC} ${YELLOW}$ignored_log_file${NC}"
  echo "Unique Ignored Files (matching patterns in IGNORE_REGEX_PATTERNS):" > "$ignored_log_file"
  echo "------------------------------------------------------------" >> "$log_file"

  # Temporary file to store paths of files in the live dataset
  local live_files_tmp
  live_files_tmp=$(mktemp)

  # 1. Get all files in the current live dataset
  [[ $VERBOSE == 1 ]] && echo -e "${BLUE}Gathering live dataset files from: $live_dataset_path${NC}"
  # Use -L to dereference symlinks to ensure we get actual file paths.
  # Using -print0 and xargs -0 for robust handling of special characters in filenames.
  #/bin/sudo /bin/find "$live_dataset_path" -type f -print0 2>/dev/null | xargs -0 -I {} bash -c 'echo "{}"' > "$live_files_tmp"
  #/bin/sudo /bin/find "$live_dataset_path" -type f -print0 2>/dev/null | xargs -0 -I {} bash -c 'echo "$1"' _ "{}" > "$live_files_tmp"\
  # shellcheck disable=SC2016
  /bin/sudo /bin/find "$live_dataset_path" -type f -print0 2>/dev/null | xargs -0 -I {} bash -c 'echo "$0"' "{}" > "$live_files_tmp"

  [[ $VERBOSE == 1 ]] && echo -e "${BLUE}Live dataset file count: $(wc -l < "$live_files_tmp")${NC}"

  local missing_files_count=0
  # Temporary file to track paths already reported to avoid duplicates in main log
  local seen_paths_tmp
  seen_paths_tmp=$(mktemp)
  # Temporary file to track unique ignored paths for the ignored_log_file
  local seen_ignored_paths_tmp
  seen_ignored_paths_tmp=$(mktemp)

  # Sort the raw snapshot file list by live_equivalent_path then by creation_timestamp (NEWEST first)
  # This ensures that when a path is encountered, it's the one from the newest snapshot.
  # Using | as delimiter for sort. -k1,1 ensures sorting on the first field (path),
  # -k3,3nr on the third field (timestamp) numerically in reverse (newest first).
  local sorted_snapshot_files_tmp
  sorted_snapshot_files_tmp=$(mktemp)
  cat "$raw_snapshot_file_list_tmp" | sort -t'|' -k1,1 -k3,3nr > "$sorted_snapshot_files_tmp"

  # Read sorted snapshot file paths (path|snap_name|timestamp)
  # Using 'while read -r' for robust line-by-line reading.
  while IFS='|' read -r live_equivalent_path snap_name creation_time_epoch || [[ -n "$live_equivalent_path" ]]; do
      # Check if this exact path has already been processed and reported
      if grep -Fxq "$live_equivalent_path" "$seen_paths_tmp"; then
        # [[ $VERBOSE == 1 ]] && echo -e "${YELLOW}Skipping (already reported): $live_equivalent_path (from snapshot: $snap_name, timestamp: $creation_time_epoch)${NC}"
        ((skipped_reported_files_count++)) # Increment skip counter
        continue # Skip if already seen
      fi

      # Check against the ignore list first
      local ignore_match=0
      for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
          if [[ "$live_equivalent_path" =~ $pattern ]]; then
              # Log unique ignored files to their separate file
              if ! grep -Fxq "$live_equivalent_path" "$seen_ignored_paths_tmp"; then
                  echo "$live_equivalent_path (ignored by pattern: '$pattern')" >> "$ignored_log_file"
                  echo "$live_equivalent_path" >> "$seen_ignored_paths_tmp"
              fi
              [[ $VERBOSE == 1 ]] && echo -e "${YELLOW}Ignoring (matches pattern): $live_equivalent_path (Pattern: '$pattern')${NC}"
              ignore_match=1
              break
          fi
      done

      if [[ $ignore_match -eq 0 ]]; then
          # Check if the live_equivalent_path exists in our list of live files
          # Using grep -Fxq for exact string match and quiet output.
          if ! grep -Fxq "$live_equivalent_path" "$live_files_tmp"; then
              echo "$live_equivalent_path (found in newest snapshot: [$snap_name] )" | tee -a "$log_file"
              echo "$live_equivalent_path" >> "$seen_paths_tmp" # Mark as seen
              ((missing_files_count++))
          fi
      fi
  done < "$sorted_snapshot_files_tmp"

  echo "" >> "$ignored_log_file"
  echo "Ignored files cataloging finished." >> "$ignored_log_file"
  #TODO figure out why the message below says "already reported" then clarify that reasonor fix it
  # make it say 0 if its zero, right now i see an empty string ($skipped_reported)
  echo -e "${YELLOW}Total files skipped (already reported): [$skipped_reported_files_count] ${NC}" | tee -a "$log_file"
  echo "" | tee -a "$log_file"
  echo "------------------------------------------------------------" | tee -a "$log_file"
  echo "Comparison finished. Total missing files found: [$missing_files_count] " | tee -a "$log_file"

  # Cleanup temporary files
  rm -f "$live_files_tmp" "$seen_paths_tmp" "$seen_ignored_paths_tmp" "$sorted_snapshot_files_tmp"

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

  if [[ ${#datasets_array[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No datasets found for delta analysis. Skipping.${NC}" | tee -a "$delta_log_file"
    return # Exit function if no datasets to process
  fi

  local delta_log_file="comparison-delta-$TIMESTAMP.out"

  echo -e "${BLUE}Logging snapshot deltas to:${NC} ${YELLOW}$delta_log_file${NC}"
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
    [[ $VERBOSE == 1 ]] && echo -e "\n${PURPLE}Analyzing deltas for dataset: $dataset${NC}"
    echo "--- Dataset: $dataset ---" >> "$delta_log_file"

    # Get snapshots for this dataset, sorted by creation time ASCENDING (oldest to newest)
    # We will iterate and build parent/child pairs
    local snapshots_raw=$(zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n +2) # Skip header
    local -a snap_names=()
    while IFS= read -r line; do
      snap_names+=("$line")
    done < <(echo "$snapshots_raw")

    # Add the live filesystem itself as the "latest point" for comparison with the newest snapshot
    local -a all_compare_points=("${snap_names[@]}" "$dataset")

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
      [[ $VERBOSE == 1 ]] && echo -e "  ${YELLOW}Comparing ${current_compare_point} to ${parent_compare_point}${NC}"

      # Use zfs diff to get changes
      # Pipe directly to while read for robust parsing
      /sbin/zfs diff "$parent_compare_point" "$current_compare_point" 2>/dev/null | while IFS=$'\t' read -r type path; do
        local diff_type_char="${type:0:1}" # Extract the first char (+, -, M, R, D, etc.)
        local full_path="${path}" # Initialize full_path
        local is_ignored="false"
        local rendered_type="" # For CSV output (ADD, DEL, MOD, REN)

        case "$diff_type_char" in
          '+') rendered_type="ADD" ;;
          '-') rendered_type="DEL" ;;
          'M') rendered_type="MOD" ;;
          'R')
            rendered_type="REN"
            # For renames, the path is "old_path -> new_path". We want to check the new path for ignore patterns
            full_path="${path}" # Keep the full 'old -> new' string in the CSV path field
            local new_path_for_check="${path##* -> }" # Extract only the new path for pattern matching
            # Check new_path_for_check against ignore patterns
            for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
              if [[ "$new_path_for_check" =~ $pattern ]]; then
                is_ignored="true"
                break
              fi
            done
            ;;
          *) continue ;; # Skip other diff types like 'D' (directory), '?' etc.
        esac

        # For non-renames, check the full_path against ignore patterns
        if [[ "$diff_type_char" != "R" ]]; then
          for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
            if [[ "$full_path" =~ $pattern ]]; then
              is_ignored="true"
              break
            fi
          done
        fi

        # Output in CSV format
        # Use printf for robust CSV quoting, especially if paths have commas or quotes
        # Replace existing echo with printf
        printf "%s,\"%s\",%s,\"%s\",\"%s\",\"%s\"\n" \
               "${rendered_type}" \
               "${full_path//\"/\"\"}" \
               "${is_ignored}" \
               "${comparison_context//\"/\"\"}" \
               "${parent_compare_point//\"/\"\"}" \
               "${current_compare_point//\"/\"\"}" >> "$delta_log_file"
      done
    done
  done
  echo "\nDelta analysis finished." >> "$delta_log_file"
}