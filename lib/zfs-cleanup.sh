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
    acc_deleted_file="${LOG_DIR}/${SFF_TMP_PREFIX}acc_deleted.csv"
    : > "$acc_deleted_file" 2>/dev/null || true
    vlog "created_acc_deleted_file=${acc_deleted_file}"
  fi

  local accidentally_deleted_count=0

  echo "Snapshot,File_Path,Live_Dataset_Path" > "$acc_deleted_file"

  while IFS= read -r dataset; do
    vlog "processing_dataset=${dataset}"
    local -a snapshots=()
    mapfile -t snapshots < <(sff_run /sbin/zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n +2)
    [[ ${#snapshots[@]} -eq 0 ]] && continue

    local live_dataset_full_name="$dataset"
    for current_snap in "${snapshots[@]}"; do
      mapfile -t diff_output < <(sff_zfs_diff "$current_snap" "$live_dataset_full_name" 2>/dev/null)
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
            vlog "deleted_file=${path} snapshot=${current_snap}"
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

  vlog "START datasets_count=${#datasets_array[@]} prefix=${dataset_path_prefix}"

  # Print temp file paths we will use so it's easy to verify which files are
  # consulted during evaluation (helps debug mismatches between compare vs cleanup).
  local tmp_base_preview="${LOG_DIR:-${TMPDIR:-/tmp}}"
  echo -e "Using temp base for cleanup: ${tmp_base_preview}" >&2

  if [[ ${#datasets_array[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No datasets found for deletion candidate identification. Skipping.${NC}"
    return
  fi

  echo -e "\n${RED}--- Identifying Snapshot Deletion Candidates ---${NC}"
    echo -e "Snapshots are suggested for deletion if they do NOT contain:\n" \
      "  1. Important files that have been deleted from the live filesystem (unignored '-' diffs to live).\n" \
        "  AND\n" \
        "  2. Important new files or modifications (unignored '+' or 'M'/'R' diffs from their parent/preceding snapshot).\n" \
      "Review the comparison-delta.out log in the per-run log directory before deleting any snapshot.\n" \
        "------------------------------------------------------------${NC}"

  local tmp_base="${LOG_DIR:-${TMPDIR:-/tmp}}"

  # prepare temp files and datasets list (capture lines robustly)
  vlog "preparing_cleanup_temp_files tmp_base=$tmp_base TIMESTAMP=$TIMESTAMP datasets_count=${#datasets_array[@]}"
  mapfile -t __pc_out < <(_prepare_cleanup_temp_files "$tmp_base" "$TIMESTAMP" "${datasets_array[@]}")
  datasets_file="${__pc_out[0]:-}"
  acc_deleted_file="${__pc_out[1]:-}"
  snap_holding_file="${__pc_out[2]:-}"
  destroy_cmds_tmp="${__pc_out[3]:-}"
  plan_file="${__pc_out[4]:-}"

  if [[ -z "$datasets_file" || -z "$acc_deleted_file" || -z "$snap_holding_file" || -z "$destroy_cmds_tmp" || -z "$plan_file" ]]; then
    echo -e "${YELLOW}Warning: temp-file preparation returned incomplete values. Attempting fallback creation...${NC}"
    datasets_file="${tmp_base}/${SFF_TMP_PREFIX}datasets.log"
    : > "$datasets_file" 2>/dev/null || true
    for ds in "${datasets_array[@]}"; do printf '%s\n' "$ds" >> "$datasets_file"; done
    acc_deleted_file="${tmp_base}/${SFF_TMP_PREFIX}acc_deleted.csv"
    : > "$acc_deleted_file" 2>/dev/null || true
    snap_holding_file="${tmp_base}/${SFF_TMP_PREFIX}snap_holding.txt"
    : > "$snap_holding_file" 2>/dev/null || true
    destroy_cmds_tmp="${tmp_base}/${SFF_TMP_PREFIX}destroy_cmds.log"
    : > "$destroy_cmds_tmp" 2>/dev/null || true
    plan_file="$tmp_base/${SFF_TMP_PREFIX}destroy-plan.sh"
    : > "$plan_file" 2>/dev/null || true
  fi

  # Phase 1: gather unignored deleted files and mark sacred snapshots
  _collect_unignored_deleted_snapshots "$acc_deleted_file" "$snap_holding_file" "$datasets_file"

  echo -e "\n${RED}--- Snapshots Suggested for Deletion ---${NC}"
  echo ""
  # Phase 2: evaluate candidates and build plan
  _evaluate_deletion_candidates_and_plan "$datasets_file" "$snap_holding_file" "$acc_deleted_file" "$destroy_cmds_tmp" "$plan_file"

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
  datasets_file="${tmp_base}/${SFF_TMP_PREFIX}datasets.log"
  for ds in "${datasets_array[@]}"; do printf '%s\n' "$ds" >> "$datasets_file"; done

  local acc_deleted_file
  acc_deleted_file="${tmp_base}/${SFF_TMP_PREFIX}acc_deleted.csv"
  local snap_holding_file
  snap_holding_file="${tmp_base}/${SFF_TMP_PREFIX}snap_holding.txt"
  local destroy_cmds_tmp
  destroy_cmds_tmp="${tmp_base}/${SFF_TMP_PREFIX}destroy_cmds.log"
  local plan_file="$tmp_base/${SFF_TMP_PREFIX}destroy-plan.sh"

  printf '%s\n' "$datasets_file" "$acc_deleted_file" "$snap_holding_file" "$destroy_cmds_tmp" "$plan_file"
}

# helper: execute plan if requested and permitted
function _maybe_execute_plan() {
  local destroy_cmds_tmp="$1"
  local plan_file="$2"
  local tmp_base="$3"
  local ts="$4"

  # If plan exists and user opted into apply, enforce environment guard
  if [[ -s "$destroy_cmds_tmp" ]]; then
    if [[ "${REQUEST_DESTROY_SNAPSHOTS:-0}" -eq 1 ]]; then
      # Ask for confirmation before executing
      if prompt_confirm "Execute destroy plan now?" "n"; then
        # Enforce top-level allow flag: if config explicitly disables destroy
        # execution, never run destroys regardless of CLI flags.
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

# Write a human-reviewable destroy plan file from the temporary
# destroy_cmds file. The plan contains commented commands and a header
# describing how to apply the plan.
function _write_destroy_plan() {
  local destroy_cmds_tmp="$1"
  local plan_file="$2"
  local ts="$3"
  local tmp_base="$4"

  {
    echo "# ${SFF_TMP_PREFIX}destroy-plan generated: ${plan_file}"
    echo "# To apply: set DESTROY_SNAPSHOTS=1 in lib/common.sh and uncomment or run the commands after review"
    echo "# Generated: ${ts}"
    echo "#"
  } > "$plan_file"

  # Keep commands commented for safe review; transform '# Command: ...' into '# /sbin/zfs destroy ...'
  sed 's/^# Command: /# /' "$destroy_cmds_tmp" >> "$plan_file" || true
}

# Vet a generated plan against any acc_deleted evidence files and remove
# planned entries for snapshots referenced in those evidence files.
function _vet_plan_against_acc_files() {
  local plan_file="$1"
  local destroy_cmds_tmp="$2"
  local acc_deleted_file="$3"
  local tmp_base="$4"

  local -a _acc_files_all=()
  if [[ -f "$acc_deleted_file" ]]; then
    _acc_files_all+=("$acc_deleted_file")
  fi
  # Prefer SHORT_TS-prefixed acc_deleted files but fall back to legacy pattern
  mapfile -t _acc_glob_all < <(ls "${tmp_base}/${SFF_TMP_PREFIX}acc_deleted"* 2>/dev/null || true)
  for _f in "${_acc_glob_all[@]}"; do _acc_files_all+=("$_f"); done
  # Also include canonical locations (LOG_DIR and TMPDIR) in case compare and cleanup used different tmp bases
  mapfile -t _acc_glob_log < <(ls "${LOG_DIR:-/tmp}/${SFF_TMP_PREFIX}acc_deleted"* 2>/dev/null || true)
  for _f in "${_acc_glob_log[@]}"; do _acc_files_all+=("$_f"); done
  mapfile -t _acc_glob_tmp < <(ls "${LOG_DIR}/${SFF_TMP_PREFIX}acc_deleted"* 2>/dev/null || true)
  for _f in "${_acc_glob_tmp[@]}"; do _acc_files_all+=("$_f"); done

  # Extract commented destroy command lines from the plan
  local -a _plan_cmds
  mapfile -t _plan_cmds < <(grep -E '^# /sbin/zfs destroy' "$plan_file" || true)
  local _snap_name
  for _pc in "${_plan_cmds[@]}"; do
    _snap_name=$(awk '{for(i=1;i<=NF;i++) if($i=="destroy"){print $(i+1); break}}' <<< "$_pc")
    [[ -z "$_snap_name" ]] && continue
    for _af in "${_acc_files_all[@]}"; do
      if [[ -f "$_af" ]] && grep -Fq "$_snap_name" "$_af" 2>/dev/null; then
        # Anchor the match to the paragraph header to avoid accidental removals
        local _header_re
        _header_re="^# Snapshot: ${_snap_name}$"
        awk -v hdr="${_header_re}" 'BEGIN{RS=""; ORS="\n\n"} $0 !~ hdr{print $0}' "$plan_file" > "${plan_file}.new" && mv "${plan_file}.new" "$plan_file" || true
        awk -v hdr="${_header_re}" 'BEGIN{RS=""; ORS="\n\n"} $0 !~ hdr{print $0}' "$destroy_cmds_tmp" > "${destroy_cmds_tmp}.new" && mv "${destroy_cmds_tmp}.new" "$destroy_cmds_tmp" || true
        echo "Defensive vetting: removed $_snap_name from plan because it appears in evidence file: $_af" >&2
        break
      fi
    done
  done

  # If vetting removed all planned entries, annotate the plan and inform the operator
  if [[ ! -s "$destroy_cmds_tmp" ]]; then
    echo "# No destroy commands remain after defensive vetting against acc_deleted evidence." >> "$plan_file"
    echo "After defensive vetting no snapshots remain planned for deletion. No action required." >&2
  fi
}

# Aggregate evidence files and print snapshot names found in any
# acc_deleted artifacts. Prints one snapshot name per line to stdout.
# Caller may read this output and populate a `sacred` set.
function _aggregate_evidence_into_sacred() {
  local acc_deleted_file="$1"
  local tmp_base_from_plan="$2"
  local -a evidence_files=()

  if [[ -f "$acc_deleted_file" ]]; then
    evidence_files+=("$acc_deleted_file")
  fi
  # Prefer SHORT_TS-prefixed evidence files but fall back to legacy names
  mapfile -t _ef1 < <(ls "${tmp_base_from_plan}/${SFF_TMP_PREFIX}acc_deleted"* 2>/dev/null || true)
  for _f in "${_ef1[@]}"; do evidence_files+=("$_f"); done
  mapfile -t _ef2 < <(ls "${LOG_DIR:-/tmp}/${SFF_TMP_PREFIX}acc_deleted"* 2>/dev/null || true)
  for _f in "${_ef2[@]}"; do evidence_files+=("$_f"); done
  mapfile -t _ef3 < <(ls "${LOG_DIR}/${SFF_TMP_PREFIX}acc_deleted"* 2>/dev/null || true)
  for _f in "${_ef3[@]}"; do evidence_files+=("$_f"); done

  local ef line snap
  for ef in "${evidence_files[@]}"; do
    [[ -f "$ef" ]] || continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^Snapshot,File_Path ]] && continue
      snap=$(awk -F'|' '{gsub(/^"|"$/,"",$1); print $1}' <<< "$line")
      [[ -n "$snap" ]] && printf '%s\n' "$snap"
    done < "$ef"
  done
}

function _evaluate_deletion_candidates_and_plan() {
  # Args: datasets_file, snap_holding_file, acc_deleted_file, destroy_cmds_tmp, plan_file
  local datasets_file="$1"
  local snap_holding_file="$2"
  local acc_deleted_file="$3"
  local destroy_cmds_tmp="$4"
  local plan_file="$5"

  # Build an associative set of sacred snapshots
  declare -A sacred
  if [[ -f "$snap_holding_file" ]]; then
    while IFS= read -r s; do sacred["$s"]=1; done < "$snap_holding_file"
  fi

  # Determine tmp base from plan file so we can look for any acc_deleted files
  local _tmp_base_from_plan
  if [[ -n "$plan_file" ]]; then
    _tmp_base_from_plan=$(dirname "$plan_file")
  else
    _tmp_base_from_plan="${LOG_DIR}"
  fi

  # Gather any sacred snapshots found in acc_deleted evidence files and
  # add them to the `sacred` set so they are never suggested for deletion.
  mapfile -t _aggs < <(_aggregate_evidence_into_sacred "$acc_deleted_file" "${_tmp_base_from_plan}")
  for _s in "${_aggs[@]}"; do
    [[ -n "$_s" ]] && sacred["$_s"]=1 && vlog "sacred_from_evidence=${_s}"
  done

  # Build dataset-level sacred map: if any snapshot in a dataset is sacred,
  # mark the entire dataset as protected so no sibling snapshots are proposed.
  declare -A sacred_ds
  local snap ds
  for snap in "${!sacred[@]}"; do
    ds="${snap%@*}"
    [[ -n "$ds" ]] && sacred_ds["$ds"]=1
  done

  vlog "datasets_file=${datasets_file} START"
  while IFS= read -r dataset; do
    vlog "processing_dataset=${dataset}"
    local -a snapshots=()
    mapfile -t snapshots < <(sff_run /sbin/zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n +2)
    [[ ${#snapshots[@]} -eq 0 ]] && continue

    # Dataset-level protection: if any snapshot in this dataset is sacred,
    # skip proposing deletion for any snapshot in the dataset.
    if [[ -n "${sacred_ds[$dataset]:-}" ]]; then
      echo "Keeping all snapshots in dataset ${dataset}: dataset contains a sacred snapshot." >&2
      for current_snap in "${snapshots[@]}"; do
        [[ $VERBOSE == 1 ]] && echo "  Keeping ${current_snap}: dataset-level protection";
      done
      continue
    fi

    for i in "${!snapshots[@]}"; do
      local current_snap="${snapshots[$i]}"
      vlog "evaluating_snapshot=${current_snap}"
      # shellcheck disable=SC2034
      local is_deletion_candidate="true"

      if [[ -n "${sacred[$current_snap]}" ]]; then
        is_deletion_candidate="false"
        [[ $VERBOSE == 1 ]] && echo "  Keeping ${current_snap}: Contains unignored files deleted from live."
      else
        # Extra safety: check acc_deleted_file(s) for evidence of files present
        # in the snapshot but absent in live. We accept multiple candidate files
        # (the one prepared by cleanup or ones produced by compare runs).
        local _found_in_acc=0
        local -a _acc_files
        if [[ -f "$acc_deleted_file" ]]; then
          _acc_files+=("$acc_deleted_file")
        fi
        # also include any canonical sff_acc_deleted files in the tmp base
        mapfile -t _acc_glob < <(ls "${_tmp_base_from_plan}/${SFF_TMP_PREFIX}acc_deleted"* 2>/dev/null || true)
        for _f in "${_acc_glob[@]}"; do _acc_files+=("$_f"); done
        for _af in "${_acc_files[@]}"; do
          if [[ -f "$_af" ]] && grep -Fq "$current_snap" "$_af" 2>/dev/null; then
            _found_in_acc=1; break
          fi
        done
        if [[ "$_found_in_acc" -eq 1 ]]; then
          is_deletion_candidate="false"
          [[ $VERBOSE == 1 ]] && echo "  Keeping ${current_snap}: Contains files removed from live (refer to acc_deleted files)."
          continue
        fi
        local compare_from
        if (( i > 0 )); then compare_from="${snapshots[i-1]}"; else compare_from="$dataset"; fi
        local compare_to="$current_snap"
        if [[ -n "$compare_from" ]]; then
          mapfile -t diff_output_for_amr < <(sff_zfs_diff "$compare_from" "$compare_to" 2>/dev/null)
        else
          diff_output_for_amr=()
        fi

        # Minimal heuristic: if there are no diffs against the previous snapshot
        # and the snapshot is not marked sacred, suggest it for deletion (dry-run).
        if [[ ${#diff_output_for_amr[@]} -eq 0 ]]; then
          # Construct human-readable reason for deletion to help reviewers.
            local _reason_short="No diffs against previous snapshot and not marked sacred"
            # Build a more explicit detail block so operators can see final reasoning
            # (e.g. list compare points that had no differences).
            local _detail_msg
            _detail_msg="The following snapshots have NO DIFFERENCE\n- ${compare_from}\n- ${current_snap}"
            # Respect configured force flag when describing the command.
            local _cmd
            if [[ "${SFF_DESTROY_FORCE:-0}" -eq 1 ]]; then
              _cmd="/sbin/zfs destroy -f ${current_snap}"
            else
              _cmd="/sbin/zfs destroy ${current_snap}"
            fi
            {
              printf '\n# Snapshot: %s\n' "$current_snap"
              printf '# BECAUSE: %s\n' "${_reason_short}"
              # Emit a multi-line DETAIL block with '#' prefix so the plan
              # remains comment-first and easily human-reviewable.
              printf '%s\n' "# DETAIL: The following snapshots have NO DIFFERENCE"
              printf '# DETAIL: - %s\n' "${compare_from}"
              printf '# DETAIL: - %s\n' "${current_snap}"
              printf '# Command: %s\n' "${_cmd}"
            } >> "$destroy_cmds_tmp"
            # Print final reasoning to stdout so the operator sees why the
            # candidate was chosen before the dry-run notice.
            echo -e "${YELLOW}WOULD ${RED}DESTROY${YELLOW}: ${WHITE}${current_snap}${NC}  because:\nThe following snapshots have NO DIFFERENCE\n - ${compare_from}\n - ${current_snap}"
        else
          [[ $VERBOSE == 1 ]] && echo "Keeping ${current_snap}: diffs present"
        fi
      fi
    done
  done < "$datasets_file"

  # After evaluating, if commands were accumulated write the reviewable plan
  if [[ -s "$destroy_cmds_tmp" ]]; then
    _write_destroy_plan "$destroy_cmds_tmp" "$plan_file" "$TIMESTAMP" "${_tmp_base_from_plan:-${LOG_DIR}}"
    _vet_plan_against_acc_files "$plan_file" "$destroy_cmds_tmp" "$acc_deleted_file" "${_tmp_base_from_plan:-${LOG_DIR}}"
  fi
}
