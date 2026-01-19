#!/bin/bash
# ZFS snapshot cleanup and deletion candidate functions
#
function _collect_unignored_deleted_snapshots() {
  # Args: temp_acc_deleted_file, temp_snap_holding_file, datasets_file
  local acc_deleted_file="$1"
  local snap_holding_file="$2"
  local datasets_file="$3"

  # If caller failed to provide an acc_deleted_file path, create a safe temp file.
  if [[ -z "$acc_deleted_file" ]]; then
    acc_deleted_file=$(mktemp "${TMPDIR:-/tmp}/${SFF_TMP_PREFIX}acc_deleted.XXXXXX")
    vlog "zfs-cleanup.sh _collect_unignored_deleted_snapshots: created fallback acc_deleted_file=$acc_deleted_file"
  fi

  local accidentally_deleted_count=0

  echo "Snapshot,File_Path,Live_Dataset_Path" > "$acc_deleted_file"

  while IFS= read -r dataset; do
    vlog "zfs-cleanup.sh _collect_unignored_deleted_snapshots processing dataset: ${dataset}"
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
            vlog "zfs-cleanup.sh _collect_unignored_deleted_snapshots found deleted file: ${path} in snapshot ${current_snap}"
          fi
        fi
      done
    done
  done < "$datasets_file"

  if [[ "$accidentally_deleted_count" -eq 0 ]]; then
    echo "No potentially accidentally deleted files found that are not ignored."
  fi
}

# Public: Identify deletion candidates and present a safe destroy plan (dry-run by default)
function identify_and_suggest_deletion_candidates() {
  local dataset_path_prefix="$1"
  shift
  local -a datasets_array=("$@")

  vlog "zfs-cleanup.sh identify_and_suggest_deletion_candidates START; datasets_count=${#datasets_array[@]} prefix=${dataset_path_prefix}"

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

  local tmp_base="${LOG_DIR:-${TMPDIR:-/tmp}}"

  # prepare temp files and datasets list (capture lines robustly)
  [[ ${VVERBOSE:-0} -eq 1 ]] && echo "vlog: preparing cleanup temp files; tmp_base=$tmp_base TIMESTAMP=$TIMESTAMP datasets_count=${#datasets_array[@]}"
  mapfile -t __pc_out < <(_prepare_cleanup_temp_files "$tmp_base" "$TIMESTAMP" "${datasets_array[@]}")
  datasets_file="${__pc_out[0]:-}"
  acc_deleted_file="${__pc_out[1]:-}"
  snap_holding_file="${__pc_out[2]:-}"
  destroy_cmds_tmp="${__pc_out[3]:-}"
  plan_file="${__pc_out[4]:-}"

  if [[ -z "$datasets_file" || -z "$acc_deleted_file" || -z "$snap_holding_file" || -z "$destroy_cmds_tmp" || -z "$plan_file" ]]; then
    echo -e "${YELLOW}Warning: temp-file preparation returned incomplete values. Attempting fallback creation...${NC}"
    datasets_file=$(mktemp "${tmp_base}/${SFF_TMP_PREFIX}datasets.XXXXXX") || datasets_file=$(mktemp "${TMPDIR:-/tmp}/${SFF_TMP_PREFIX}datasets.XXXXXX")
    for ds in "${datasets_array[@]}"; do printf '%s\n' "$ds" >> "$datasets_file"; done
    acc_deleted_file=$(mktemp "${tmp_base}/${SFF_TMP_PREFIX}acc_deleted.XXXXXX") || acc_deleted_file=$(mktemp "${TMPDIR:-/tmp}/${SFF_TMP_PREFIX}acc_deleted.XXXXXX")
    snap_holding_file=$(mktemp "${tmp_base}/${SFF_TMP_PREFIX}snap_holding.XXXXXX") || snap_holding_file=$(mktemp "${TMPDIR:-/tmp}/${SFF_TMP_PREFIX}snap_holding.XXXXXX")
    destroy_cmds_tmp=$(mktemp "${tmp_base}/${SFF_TMP_PREFIX}destroy_cmds.XXXXXX") || destroy_cmds_tmp=$(mktemp "${TMPDIR:-/tmp}/${SFF_TMP_PREFIX}destroy_cmds.XXXXXX")
    plan_file="$tmp_base/${SFF_TMP_PREFIX}destroy-plan-${TIMESTAMP}.sh"
    if [[ -z "$plan_file" ]]; then
      echo -e "${RED}Error: cannot determine plan file path; aborting.${NC}"
      return 1
    fi
  fi

  # Phase 1: gather unignored deleted files and mark sacred snapshots
  _collect_unignored_deleted_snapshots "$acc_deleted_file" "$snap_holding_file" "$datasets_file"

  echo -e "\n${RED}--- Snapshots Suggested for Deletion ---${NC}"
  echo ""
  # Phase 2: evaluate candidates and build plan
  _evaluate_deletion_candidates_and_plan "$datasets_file" "$snap_holding_file" "$destroy_cmds_tmp" "$plan_file"

  # If plan exists, handle execution and cleanup in helpers
  _maybe_execute_plan "$destroy_cmds_tmp" "$plan_file" "$tmp_base" "$TIMESTAMP"
  _cleanup_cleanup_temp_files "$datasets_file" "$acc_deleted_file" "$snap_holding_file" "$destroy_cmds_tmp"
}

# helper: prepare temp files; outputs paths (datasets_file acc_deleted_file snap_holding_file destroy_cmds_tmp plan_file)
function _prepare_cleanup_temp_files() {
  local tmp_base="$1"; shift
  local ts="$1"; shift
  local -a datasets_array=("$@")

  local datasets_file
  datasets_file=$(mktemp "${tmp_base}/${SFF_TMP_PREFIX}datasets.XXXXXX")
  for ds in "${datasets_array[@]}"; do printf '%s\n' "$ds" >> "$datasets_file"; done

  local acc_deleted_file
  acc_deleted_file=$(mktemp "${tmp_base}/${SFF_TMP_PREFIX}acc_deleted.XXXXXX")
  local snap_holding_file
  snap_holding_file=$(mktemp "${tmp_base}/${SFF_TMP_PREFIX}snap_holding.XXXXXX")
  local destroy_cmds_tmp
  destroy_cmds_tmp=$(mktemp "${tmp_base}/${SFF_TMP_PREFIX}destroy_cmds.XXXXXX")
  local plan_file="$tmp_base/${SFF_TMP_PREFIX}destroy-plan-${ts}.sh"

  printf '%s\n' "$datasets_file" "$acc_deleted_file" "$snap_holding_file" "$destroy_cmds_tmp" "$plan_file"
}

# helper: execute plan if requested and permitted
function _maybe_execute_plan() {
  local destroy_cmds_tmp="$1"
  local plan_file="$2"
  local tmp_base="$3"
  local ts="$4"

  if [[ -s "$destroy_cmds_tmp" ]]; then
    if [[ "${REQUEST_DESTROY_SNAPSHOTS:-0}" -eq 1 ]]; then
      if prompt_confirm "Execute destroy plan now?" "n"; then
        if [[ "${DESTROY_SNAPSHOTS_ALLOWED:-1}" -eq 0 ]]; then
          echo -e "${YELLOW}Execution blocked: DESTROY_SNAPSHOTS is disabled in configuration. To permit execution, edit lib/common.sh and set DESTROY_SNAPSHOTS=1.${NC}"
          echo "Destroy plan written to: $plan_file"
        else
          local exec_log="$tmp_base/${SFF_TMP_PREFIX}destroy-exec-$ts.log"
          local exec_plan="$tmp_base/${SFF_TMP_PREFIX}destroy-plan-exec-$ts.sh"
          sed 's/^# \/sbin\/zfs destroy/\/sbin\/zfs destroy/' "$plan_file" > "$exec_plan"
          chmod 700 "$exec_plan" || true
          echo "Executing destroy plan; logging to: $exec_log"
          bash "$exec_plan" > "$exec_log" 2>&1 || echo -e "${RED}One or more destroy commands failed; see $exec_log${NC}"
        fi
      else
        echo "User declined to execute destroy plan. Plan remains at: $plan_file"
      fi
    else
      echo -e "${YELLOW}Dry-run: no destroys executed. To apply, enable DESTROY_SNAPSHOTS=1 in lib/common.sh and re-run with --clean-snapshots.${NC}"
      echo "Destroy plan written to: $plan_file"
    fi
  fi
}

# helper: cleanup temp files
function _cleanup_cleanup_temp_files() {
  rm -f "$1" "$2" "$3" "$4" || true
  echo -e "${BLUE}------------------------------------------------------------${NC}"
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

  vlog "zfs-cleanup.sh _evaluate_deletion_candidates_and_plan START; datasets_file=$datasets_file"
  while IFS= read -r dataset; do
    vlog "zfs-cleanup.sh _evaluate_deletion_candidates_and_plan processing dataset: ${dataset}"
    local -a snapshots=()
    mapfile -t snapshots < <(/sbin/zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n +2)
    [[ ${#snapshots[@]} -eq 0 ]] && continue

    for i in "${!snapshots[@]}"; do
      local current_snap="${snapshots[$i]}"
      vlog "zfs-cleanup.sh _evaluate_deletion_candidates_and_plan evaluating snapshot: ${current_snap}"
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

        # Minimal heuristic: if there are no diffs against the previous snapshot
        # and the snapshot is not marked sacred, suggest it for deletion (dry-run).
        if [[ ${#diff_output_for_amr[@]} -eq 0 ]]; then
          printf '# /sbin/zfs destroy %s\n' "$current_snap" >> "$destroy_cmds_tmp"
          echo "WOULD delete: $current_snap"
        else
          [[ $VERBOSE == 1 ]] && echo "Keeping ${current_snap}: diffs present"
        fi
      fi
    done
  done < "$datasets_file"
}
