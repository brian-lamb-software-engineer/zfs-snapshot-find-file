#!/bin/bash
# ZFS snapshot cleanup and deletion candidate functions
#
function identify_and_suggest_deletion_candidates() {
  local dataset_path_prefix="$1" # This is the /nas/live/cloud/ path
  shift # Remove the first argument
  local -a datasets_array=("$@") # This contains dataset names like nas/live/cloud/tcc

  if [[ ${#datasets_array[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No datasets found for deletion candidate identification. Skipping.${NC}"
    return # Exit function if no datasets to process
  fi

  echo -e "\n${RED}--- Identifying Snapshot Deletion Candidates ---${NC}"
  echo -e "Snapshots are suggested for deletion if they do NOT contain:\n" \
          "  1. Important files that have been deleted from the live filesystem (unignored '-' diffs to live).\n" \
          "  AND\n" \
          "  2. Important new files or modifications (unignored '+' or 'M'/'R' diffs from their parent/preceding snapshot).\n" \
          "Review the 'comparison-delta-${TIMESTAMP}.out' log before deleting any snapshot.\n" \
          "------------------------------------------------------------${NC}"

  # New section for potentially accidentally deleted files (unignored '-' to live)
  # These are files you care about, so the snapshot holding them should NOT be deleted.
  echo -e "\n${RED}--- Potentially Accidentally Deleted Files Found ---${NC}"
  echo -e "The following files exist in a snapshot but have been deleted from the live filesystem."
  echo -e "Snapshots containing these files (if unignored) WILL NOT be suggested for deletion.\n"
  echo "Snapshot,File_Path,Live_Dataset_Path" # CSV header for this section

  local accidentally_deleted_count=0
  local -A snapshots_holding_unignored_deleted # Associative array to mark snapshots that hold unignored deleted files

  # --- PHASE 1: Identify Snapshots Holding Unignored Deleted Files (from Live) ---
  # This phase primarily populates the 'snapshots_holding_unignored_deleted' array.
  for dataset in "${datasets_array[@]}"; do
    local -a snapshots=()
    # Get all snapshots for the current dataset, sorted by creation time ASCENDING
    mapfile -t snapshots < <(/sbin/zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n +2)

    if [[ ${#snapshots[@]} -eq 0 ]]; then
      continue # No snapshots for this dataset
    fi

    local live_dataset_full_name="$dataset" # e.g., nas/live/cloud/tcc

    for current_snap in "${snapshots[@]}"; do
      # Capture zfs diff output from snapshot to live filesystem
      local -a diff_output=()
      mapfile -t diff_output < <(/sbin/zfs diff "$current_snap" "$live_dataset_full_name" 2>/dev/null)

      for line in "${diff_output[@]}"; do
        local type="${line:0:1}" # First character is diff type
        local path="${line:2}"   # Rest of the line is the path

        if [[ "$type" == "-" ]]; then # We are only interested in deleted files here
          local is_ignored="false"
          for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
            if [[ "$path" =~ $pattern ]]; then
              is_ignored="true"
              break
            fi
          done

          if [[ "$is_ignored" == "false" ]]; then
            # Found an unignored deleted file. Mark this snapshot and report it.
            # Use printf for robust CSV quoting
            printf "%s,\"%s\",%s\n" \
                   "${current_snap}" \
                   "${path//\"/\"\"}" \
                   "${live_dataset_full_name}"
            snapshots_holding_unignored_deleted["$current_snap"]="true" # Mark this snapshot as "sacred"
            ((accidentally_deleted_count++))
            # No need to break the inner loop; we want to report all such files for this snap
          fi
        fi
      done
    done
  done

  if [[ "$accidentally_deleted_count" -eq 0 ]]; then
    echo "No potentially accidentally deleted files found that are not ignored."
  fi
  echo -e "${BLUE}------------------------------------------------------------${NC}"

  echo -e "\n${RED}--- Snapshots Suggested for Deletion ---${NC}"

  # --- PHASE 2: Determine Actual Deletion Candidates ---
  for dataset in "${datasets_array[@]}"; do
    local -a snapshots=()
    mapfile -t snapshots < <(/sbin/zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n +2)

    # If no snapshots, nothing to delete for this dataset
    if [[ ${#snapshots[@]} -eq 0 ]]; then
      continue
    fi

    local prev_snap=""
    # Iterate from oldest to newest snapshot
    for i in "${!snapshots[@]}"; do
      local current_snap="${snapshots[$i]}"

      local is_deletion_candidate="true" # Assume it's a candidate until proven otherwise

      # Condition 1 Check: Does this snapshot hold unignored deleted files from live?
      if [[ "${snapshots_holding_unignored_deleted[$current_snap]}" == "true" ]]; then
        is_deletion_candidate="false"
        [[ $VERBOSE == 1 ]] && echo "  Keeping ${current_snap}: Contains unignored files deleted from live."
      else
        # Condition 2 Check: Does it contain unignored additions or modifications relative to its parent/next snapshot?
        local compare_from=""
        if (( i > 0 )); then # If not the very first snapshot, compare to its direct parent
          compare_from="${snapshots[i-1]}"
        else
          # If it's the very first snapshot, its "parent" for comparison is the live dataset itself.
          compare_from="$dataset"
        fi

        local compare_to="$current_snap"

        local -a diff_output_for_amr=()
        # Ensure we always have a valid 'compare_from' before attempting diff
        if [[ -n "$compare_from" ]]; then
            mapfile -t diff_output_for_amr < <(/sbin/zfs diff "$compare_from" "$compare_to" 2>/dev/null)
        fi

        for line in "${diff_output_for_amr[@]}"; do
          local type="${line:0:1}"
          local path="${line:2}"

          # Only interested in ADD, MOD, RENAME for this condition
          if [[ "$type" == "+" || "$type" == "M" || "$type" == "R" ]]; then
            local processed_path="${path}"
            if [[ "$type" == "R" ]]; then
                processed_path="${path##* -> }" # Extract the new path for rename check
            fi

            local is_ignored="false"
            for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
              if [[ "$processed_path" =~ $pattern ]]; then
                is_ignored="true"
                break
              fi
            done
            if [[ "$is_ignored" == "false" ]]; then
              is_deletion_candidate="false" # Found an unignored A/M/R change, so NOT a candidate
              [[ $VERBOSE == 1 ]] && echo "  Keeping ${current_snap}: Contains unignored ${type} change (relative to ${compare_from}): ${path}"
              break # No need to check more lines for this snapshot, it's already marked for keeping
            fi
          fi
        done
      fi # End of Condition 1/2 check

      # If, after all checks, it's still a deletion candidate
      if [[ "$is_deletion_candidate" == "true" ]]; then
        echo "WOULD delete this snapshot: ${current_snap}"
        echo "# /sbin/zfs destroy \"${current_snap}\""
      fi

      prev_snap="$current_snap" # Update prev_snap for the next iteration
    done # End for current_snap loop
  done # End for dataset loop
  echo -e "${BLUE}------------------------------------------------------------${NC}"
}
