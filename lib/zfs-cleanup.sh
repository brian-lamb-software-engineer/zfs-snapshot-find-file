#!/bin/bash
# ZFS snapshot cleanup and deletion candidate functions
#
function _collect_unignored_deleted_snapshots() {
  # Args: temp_acc_deleted_file, temp_snap_holding_file, datasets_file
  local acc_deleted_file="$1"
  local snap_holding_file="$2"
  local datasets_file="$3"

  local accidentally_deleted_count=0

  echo "Snapshot,File_Path,Live_Dataset_Path" > "$acc_deleted_file"

  while IFS= read -r dataset; do
    local -a snapshots=()
    mapfile -t snapshots < <(/sbin/zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n +2)
    [[ ${#snapshots[@]} -eq 0 ]] && continue

    local live_dataset_full_name="$dataset"
    for current_snap in "${snapshots[@]}"; do
      mapfile -t diff_output < <(/sbin/zfs diff "$current_snap" "$live_dataset_full_name" 2>/dev/null)
      for line in "${diff_output[@]}"; do
        local type="${line:0:1}"
        local path="${line:2}"
        if [[ "$type" == "-" ]]; then
          local is_ignored="false"
          for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
            if [[ "$path" =~ $pattern ]]; then
              is_ignored="true"; break
            fi
          done
          if [[ "$is_ignored" == "false" ]]; then
            printf "%s,\"%s\",%s\n" "${current_snap}" "${path//\"/\"\"}" "${live_dataset_full_name}" >> "$acc_deleted_file"
            echo "$current_snap" >> "$snap_holding_file"
            ((accidentally_deleted_count++))
          fi
        fi
      done
    done
  done < "$datasets_file"

  if [[ "$accidentally_deleted_count" -eq 0 ]]; then
    echo "No potentially accidentally deleted files found that are not ignored."
  fi
}

function _evaluate_deletion_candidates_and_plan() {
  # Args: datasets_file, snap_holding_file, destroy_cmds_tmp, plan_file
  local datasets_file="$1"
  local snap_holding_file="$2"
  local destroy_cmds_tmp="$3"
  local plan_file="$4"

  # Build an associative set of sacred snapshots
  declare -A sacred
  if [[ -f "$snap_holding_file" ]]; then
    while IFS= read -r s; do sacred["$s"]=1; done < "$snap_holding_file"
  fi

  while IFS= read -r dataset; do
    local -a snapshots=()
    mapfile -t snapshots < <(/sbin/zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n +2)
    [[ ${#snapshots[@]} -eq 0 ]] && continue

    for i in "${!snapshots[@]}"; do
      local current_snap="${snapshots[$i]}"
      local is_deletion_candidate="true"

      if [[ -n "${sacred[$current_snap]}" ]]; then
        is_deletion_candidate="false"
        [[ $VERBOSE == 1 ]] && echo "  Keeping ${current_snap}: Contains unignored files deleted from live."
      else
        local compare_from
        if (( i > 0 )); then compare_from="${snapshots[i-1]}"; else compare_from="$dataset"; fi
        local compare_to="$current_snap"
        if [[ -n "$compare_from" ]]; then
          mapfile -t diff_output_for_amr < <(/sbin/zfs diff "$compare_from" "$compare_to" 2>/dev/null)
        else
          diff_output_for_amr=()
        fi
        for line in "${diff_output_for_amr[@]}"; do
          local type="${line:0:1}"
          local path="${line:2}"
          if [[ "$type" == "+" || "$type" == "M" || "$type" == "R" ]]; then
            local processed_path="$path"
            if [[ "$type" == "R" ]]; then processed_path="${path##* -> }"; fi
            local is_ignored="false"
            for pattern in "${IGNORE_REGEX_PATTERNS[@]}"; do
              if [[ "$processed_path" =~ $pattern ]]; then is_ignored="true"; break; fi
            done
            if [[ "$is_ignored" == "false" ]]; then
              is_deletion_candidate="false"
              [[ $VERBOSE == 1 ]] && echo "  Keeping ${current_snap}: Contains unignored ${type} change (relative to ${compare_from}): ${path}"
              break
            fi
          fi
        done
      fi

      if [[ "$is_deletion_candidate" == "true" ]]; then
        echo "WOULD delete this snapshot: ${current_snap}"
        echo "# /sbin/zfs destroy \"${current_snap}\""
        # Append the real destroy command to the plan file (uncommented)
        # Respect --force (SFF_DESTROY_FORCE) by adding -f when requested
        if [[ "${SFF_DESTROY_FORCE:-0}" -eq 1 ]]; then
          #echo "/sbin/zfs destroy -f \"${current_snap}\"" >> "$destroy_cmds_tmp"
          echo "WOULD DESTROY HERE1!"
        else
          ##echo "/sbin/zfs destroy \"${current_snap}\"" >> "$destroy_cmds_tmp"
          echo "WOULD DESTROY HERE2!"
        fi
      fi
    done
  done < "$datasets_file"

  # Create plan file if there are destroy commands
  if [[ -s "$destroy_cmds_tmp" ]]; then
    printf '%s\n' "#!/bin/bash" "# Destroy plan generated on $(date)" > "$plan_file"
    cat "$destroy_cmds_tmp" >> "$plan_file"
    chmod 700 "$plan_file" || true
    echo "Destroy plan written to: $plan_file"
  fi
}

function identify_and_suggest_deletion_candidates() {
  local dataset_path_prefix="$1"
  shift
  local -a datasets_array=("$@")

  if [[ ${#datasets_array[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No datasets found for deletion candidate identification. Skipping.${NC}"
    return
  fi

  echo -e "\n${RED}--- Identifying Snapshot Deletion Candidates ---${NC}"
  echo -e "Snapshots are suggested for deletion if they do NOT contain:\n" \
          "  1. Important files that have been deleted from the live filesystem (unignored '-' diffs to live).\n" \
          "  AND\n" \
          "  2. Important new files or modifications (unignored '+' or 'M'/'R' diffs from their parent/preceding snapshot).\n" \
          "Review the 'comparison-delta-${TIMESTAMP}.out' log before deleting any snapshot.\n" \
          "------------------------------------------------------------${NC}"

  # Prepare temp files and datasets list file
  local tmp_base="${LOG_DIR:-${TMPDIR:-/tmp}}"
  local datasets_file
  datasets_file=$(mktemp "${tmp_base}/datasets.XXXXXX")
  for ds in "${datasets_array[@]}"; do printf '%s\n' "$ds" >> "$datasets_file"; done

  local acc_deleted_file
  acc_deleted_file=$(mktemp "${tmp_base}/acc_deleted.XXXXXX")
  local snap_holding_file
  snap_holding_file=$(mktemp "${tmp_base}/snap_holding.XXXXXX")
  local destroy_cmds_tmp
  destroy_cmds_tmp=$(mktemp "${tmp_base}/destroy_cmds.XXXXXX")
  local plan_file="$tmp_base/destroy-plan-$TIMESTAMP.sh"

  # Phase 1: gather unignored deleted files and mark sacred snapshots
  _collect_unignored_deleted_snapshots "$acc_deleted_file" "$snap_holding_file" "$datasets_file"

  echo -e "\n${RED}--- Snapshots Suggested for Deletion ---${NC}"

  # Phase 2: evaluate candidates and build plan
  _evaluate_deletion_candidates_and_plan "$datasets_file" "$snap_holding_file" "$destroy_cmds_tmp" "$plan_file"

  # If plan exists and user requested apply, prompt first then respect master flag
  if [[ -s "$destroy_cmds_tmp" ]]; then
    if [[ "${REQUEST_DESTROY_SNAPSHOTS:-0}" -eq 1 ]]; then
      # Prompt the user before checking the permanent master switch so the
      # user can validate the plan and exercise the interactive flow.
      if prompt_confirm "Execute destroy plan now?" "n"; then
        # After confirmation, ensure the top-level master switch is enabled.
        if [[ "${DESTROY_SNAPSHOTS_ALLOWED:-1}" -eq 0 ]]; then
          echo -e "${YELLOW}Execution blocked: DESTROY_SNAPSHOTS is disabled in configuration. To permit execution, edit lib/common.sh and set DESTROY_SNAPSHOTS=1.${NC}"
          echo "Destroy plan written to: $plan_file"
        else
          local exec_log="$tmp_base/destroy-exec-$TIMESTAMP.log"
          local exec_plan="$tmp_base/destroy-plan-exec-$TIMESTAMP.sh"
          # Create an executable plan by uncommenting destroy lines that begin
          # with '# /sbin/zfs destroy'. Preserve other comments (e.g., header).
          sed 's/^# \/sbin\/zfs destroy/\/sbin\/zfs destroy/' "$plan_file" > "$exec_plan"
          chmod 700 "$exec_plan" || true
          echo "Executing destroy plan; logging to: $exec_log"
          bash "$exec_plan" > "$exec_log" 2>&1 || echo -e "${RED}One or more destroy commands failed; see $exec_log${NC}"
        fi
      else
        echo "User declined to execute destroy plan. Plan remains at: $plan_file"
      fi
    else
      echo -e "${YELLOW}Dry-run: no destroys executed. To apply, re-run with --destroy-snapshots.${NC}"
      echo "Destroy plan written to: $plan_file"
    fi
  fi

  # Cleanup temp files
  rm -f "$datasets_file" "$acc_deleted_file" "$snap_holding_file" "$destroy_cmds_tmp"
  echo -e "${BLUE}------------------------------------------------------------${NC}"
}
