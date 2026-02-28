#!/bin/bash
# ZFS snapshot search functions
# 
# This script contains functions for searching ZFS snapshots for files matching
# specific patterns. It supports recursive searches, selective dataset matching
# using wildcards, and filtering snapshots based on regex patterns.
#
# Key Features:
# - Search for files in ZFS snapshots using patterns (e.g., -f "*file*").
# - Support for recursive searches (-r) to include child datasets.
# - Ability to target specific datasets using wildcards (e.g., /pool/data/*/*).
# - Filtering snapshots using regex patterns (-s).
# - Verbose output for debugging and detailed logging.

function _handle_compare_snapdir() {
  local snappath="$1"
  local dataset="$2"
  local dataset_name="$3"
  local SNAPNAME="$4"
  local creation_time_epoch="$5"

  local full_snap_id="${dataset_name}@${SNAPNAME}"
  # Ensure shared tmp path exists or has a sensible fallback so static analysis
  # can see the variable is intentionally available in this sourced context.
  all_snapshot_files_found_tmp="${all_snapshot_files_found_tmp:-${LOG_DIR}/${SFF_TMP_PREFIX}all_snapshot_files_found.log}"
  # Announce using legacy find (deduped) and record in commands log for traceability
  sff_print_find_banner_once "$dataset" "compare: collecting files from snapshot"
  /bin/sudo /bin/find "$snappath" -type f \( "${FILEARR[@]}" \) -print0 2>/dev/null | \
    # pass args into a sub-bash so we can reconstruct the output reliably; keep SC2154 disabled because
    # `all_snapshot_files_found_tmp` is defined in `lib/common.sh` and exported into the shell environment.
    # shellcheck disable=SC2154
    xargs -0 -I {} bash -c "echo \"\$1\${5#\$2}|\$3|\$4\"" _ "${dataset}" "${snappath}" "${SNAPNAME}" "${creation_time_epoch}" "{}" >> "$all_snapshot_files_found_tmp"
}

function _handle_noncompare_snapdir() {
  local snappath="$1"
  local dataset="$2"
  local tmp_base="${LOG_DIR:-${TMPDIR:-/tmp}}"
  local found_tmp
  found_tmp=$(mktemp "${tmp_base}/found_files.XXXXXX")

  vlog "dataset=${WHITE}${dataset}${NC} snappath=${WHITE}${snappath}${NC}"

  # shellcheck disable=SC2024
  # Announce using legacy find (deduped) and record in commands log for traceability
  sff_print_find_banner_once "$dataset" "non-compare snapshot scan"
  # Use sudo+tee to avoid shell redirection being performed as non-root
  /bin/sudo /bin/find "$snappath" -type f \( "${FILEARR[@]}" \) -print0 2>/dev/null | /bin/sudo tee "$found_tmp" >/dev/null
  if [[ -s "$found_tmp" ]]; then
    local _quiet_notice_printed=0
    while IFS= read -r -d '' file; do
      if [[ ${QUIET:-0} -ne 1 ]]; then
        echo -e "${GREEN}${file}${NC}"
      else
        if [[ $_quiet_notice_printed -eq 0 ]]; then
          echo -e "${YELLOW}[quiet] Per-file output suppressed; counts only${NC}"
          _quiet_notice_printed=1
        fi
      fi
      record_found_file "$file"
    done < "$found_tmp"
  fi
  rm -f "$found_tmp"
}

# Helpers to break up process_snapshots_for_dataset for Phase 2
function _normalize_dataset() {
  # Normalize and compute both filesystem path and ZFS dataset name forms.
  # Args: dataset
  local dataset="$1"
  dataset="${dataset%/}"
  local ds_path="$dataset"
  if [[ "$ds_path" != /* ]]; then
    ds_path="/$ds_path"
  fi
  local dataset_name="${dataset#/}"
  printf '%s|%s' "$ds_path" "$dataset_name"
}

function _should_skip_for_trailing_wildcard() {
  # Trailing-wildcard handling: may decide to skip this dataset
  # Args: dataset
  # Returns 0 = keep processing, 1 = skip (return from caller)
  local dataset="$1"
  if [[ ! -z "$DATASET_SEGMNT_WLDCRDS" ]] && [[ "$DATASET_SEGMNT_WLDCRDS" -gt 0 ]]; then
    local DS_CONST_ARR
    # Split dataset components into array using IFS for Bash 4.2 compatibility
    IFS='/' read -r -a DS_CONST_ARR <<< "$dataset" || true
    local DS_CONST_ARR_CNT=${#DS_CONST_ARR[@]}
    if [[ "$DS_CONST_ARR_CNT" -le "$BASE_DSP_CNT" ]]; then
      [[ $VERBOSE == 1  ]] && echo -e "Skipping dataset (too high in hierarchy for trailing wildcards): ${dataset}"
      return 1
    fi
    [[ $VERBOSE == 1  ]] && echo && echo -e "Searching Dataset:(${PURPLE}$dataset${NC})"
  fi
  return 0
}

function _build_snapdirs() {
  # Args: ds_path
  local ds_path="$1"
  local snapdirs="${ds_path%/}/$ZFSSNAPDIR/*"
  printf '%s' "$snapdirs"
}

function _matches_snapshot_regex() {
  # Args: SNAPNAME
  local SNAPNAME="$1"
  local regex_pattern
  if [[ "$SNAP_SEARCH_REGEX" == "*" ]]; then
    regex_pattern=".*"
  else
    regex_pattern="$(printf '%s' "$SNAP_SEARCH_REGEX" | sed -e 's/[][\.^$*+?(){}|]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g')"
    regex_pattern=".*$regex_pattern.*"
  fi
  if [[ ! "$SNAPNAME" =~ $regex_pattern ]]; then
    return 1
  fi
  return 0
}

function _process_snappath() {
  # Args: snappath dataset ds_path dataset_name
  local snappath="$1"; shift
  local dataset="$1"; shift
  local ds_path="$1"; shift
  local dataset_name="$1"; shift

  if [[ ! -d "$snappath" ]]; then
    [[ $VERBOSE == 1 ]] && echo -e "v1: (${YELLOW}No Snapshots found in this dataset${NC})"
    return 0
  fi

  vlog "dataset=${WHITE}${dataset}${NC} ds_path=${WHITE}${ds_path}${NC} snappath=${WHITE}${snappath}${NC}"

  local SNAPNAME
  SNAPNAME=$(/bin/basename "$snappath")
  [ -L "${snappath%/}" ] && [[ $VERBOSE == 1 ]] && echo "v1: Skipping symlink: ${snappath}" && return 0

  [[ $VERBOSE == 1 ]] && echo -e "v1: Scanning snapshot:(${WHITE}$SNAPNAME${NC}) for files matching '${YELLOW}$FILESTR${NC}'"

  if ! _matches_snapshot_regex "$SNAPNAME"; then
    [[ $VERBOSE == 1 ]] && echo "v1: Skipping, doesn't match -s regex"
    return 0
  fi

  [[ $VERBOSE == 1 ]] && echo -e "v1: Search path:(${CYAN}$snappath${NC})"

  ##
  # NEW FUNCTIONALITY MODIFICATION BEGIN: Conditional find command execution & bugfix
  # This block ensures 'local' declarations and 'zfs get' are performed only
  # when in COMPARE mode,
  # It also corrects the 'zfs get' commands target and the 'xargs' arg passing for accurate path construction.
  ##

  if [[ $COMPARE == 1 ]]; then
    local SNAPNAME_local="$SNAPNAME"
    local full_snap_id="${dataset_name}@${SNAPNAME_local}"
    local creation_time_epoch
    creation_time_epoch=$(zfs get -Hp creation "$full_snap_id" | awk 'NR==2{print $3}')
    # Prefer zfs diff fast-path for compare runs when requested. If zdiff
    # produces no output or fails, fall back to the legacy find pipeline.
    if [[ "${USE_ZDIFF:-0}" -eq 1 && "${SKIP_ZFS_FAST:-0}" -ne 1 ]]; then
      local full_snap_id_2
      full_snap_id_2="$full_snap_id"
      # sff_zfs_diff emits tab-separated diff lines; capture them for parsing.
      mapfile -t diff_output < <(sff_zfs_diff "$full_snap_id_2" "$dataset_name" 2>/dev/null)
      if [[ ${#diff_output[@]} -gt 0 ]]; then
            for line in "${diff_output[@]}"; do
              local path="${line:2}"
          # normalize leading slash from paths to match find-style output
          path="${path#/}"
          # write a line compatible with compare pipeline: live_equivalent_path|snap_name|creation_time_epoch
          printf '%s|%s|%s\n' "${dataset}${path}" "${SNAPNAME_local}" "${creation_time_epoch}" >> "$all_snapshot_files_found_tmp"
        done
      else
        sff_print_find_banner_once "$dataset" "zdiff produced no output or failed for this snapshot; falling back to find"
        /bin/sudo /bin/find "$snappath" -type f \( "${FILEARR[@]}" \) -print0 2>/dev/null | \
          xargs -0 -I {} bash -c "echo \"\$1\${5#\$2}|\$3|\$4\"" _ "${dataset}" "${snappath}" "${SNAPNAME_local}" "${creation_time_epoch}" "{}" >> "$all_snapshot_files_found_tmp"
      fi
    else
      _handle_compare_snapdir "$snappath" "$dataset" "$dataset_name" "$SNAPNAME_local" "$creation_time_epoch"
    fi
  else
    # Prefer zfs diff fast-path for non-compare runs when requested.
    if [[ "${USE_ZDIFF:-0}" -eq 1 && "${SKIP_ZFS_FAST:-0}" -ne 1 ]]; then
      local full_snap_id
      full_snap_id="${dataset_name}@${SNAPNAME}"
      mapfile -t diff_output < <(sff_zfs_diff "$full_snap_id" "$dataset_name" 2>/dev/null)
      if [[ ${#diff_output[@]} -eq 0 ]]; then
        # Fallback to legacy find when zdiff produced no output or failed
        sff_print_find_banner_once "$dataset" "zdiff produced no output or failed for this snapshot; falling back to find"
        _handle_noncompare_snapdir "$snappath" "$dataset"
      else
        for line in "${diff_output[@]}"; do
          local path="${line:2}"
          # normalize leading slash from paths to match find-style output
          path="${path#/}"
          # Check against FILEARR patterns; if matches, record the file
          if _path_matches_filearr "$path"; then
            # For consistency with legacy path format, prefix with dataset filesystem root
            record_found_file "$path"
          fi
        done
      fi
    else
      _handle_noncompare_snapdir "$snappath" "$dataset"
    fi
  fi
}

# Helper: check if a given path matches any file patterns in FILEARR
function _path_matches_filearr() {
  local path="$1"
  # If FILEARR is empty, match all
  if [[ ${#FILEARR[@]} -eq 0 ]]; then
    return 0
  fi
  # Iterate FILEARR as key/value pairs (-name PAT or -path PAT)
  local i=0
  while [[ $i -lt ${#FILEARR[@]} ]]; do
    local key="${FILEARR[$i]}"
    local val="${FILEARR[$((i+1))]:-}"
      if [[ "$key" == "-name" ]]; then
      local base
      base="${path##*/}"
      if [[ "$base" == "$val" ]]; then
        return 0
      fi
    elif [[ "$key" == "-path" ]]; then
      # patterns in FILEARR for -path were built with leading/trailing '*' as needed
      if [[ "$path" == "$val" ]]; then
        return 0
      fi
    fi
    i=$((i+2))
  done
  return 1
}

function process_snapshots_for_dataset() {
  local dataset="$1"
  vlog "START dataset=${WHITE}${dataset}${NC}"
  _psfd_init "$dataset"
  if ! _psfd_should_process "$dataset"; then
    return
  fi
  _psfd_iterate_snapdirs "$dataset"
  _psfd_finalize "$dataset"
}

function _psfd_init() {
  local dataset="$1"
  IFS='|' read -r PSFD_ds_path PSFD_dataset_name < <(_normalize_dataset "$dataset")
  export PSFD_ds_path PSFD_dataset_name
  [[ $VERBOSE == 1 ]] && echo -e "v1: Processing dataset: ${WHITE}$PSFD_dataset_name${NC} (path: ${WHITE}$PSFD_ds_path${NC})"
  [[ $VERBOSE == 1 ]] && echo -e "v1: ${GREY}Using ZFSSNAPDIR: $ZFSSNAPDIR${NC}"
  PSFD_dataset_start_count=${found_files_count:-0}
  PSFD_snapshot_found=0
}

function _psfd_should_process() {
  local dataset="$1"
  if ! _should_skip_for_trailing_wildcard "$dataset"; then
    return 1
  fi
  return 0
}

function _psfd_iterate_snapdirs() {
  local dataset="$1"
  local ds_path="${PSFD_ds_path}"
  # Enable globbing for snapshot directory expansion
  set +f
  local snapdirs
  snapdirs=$(_build_snapdirs "$ds_path")
  [[ $VERBOSE == 1 ]] && echo "Checking snapshot directory: $snapdirs"

  for snappath in $snapdirs; do
    # Process each snapshot path via helper (keeps main function small)
    if _process_snappath "$snappath" "$dataset" "$ds_path" "$PSFD_dataset_name"; then
      PSFD_snapshot_found=1
    fi
  done
  # Disable globbing again
  set -f
}

function _psfd_finalize() {
  local dataset="$1"
  if [[ ${PSFD_snapshot_found:-0} -eq 0 ]]; then
    echo -e "${RED}Error: No snapshots found for dataset: $dataset${NC}"
  fi
  if [[ $COMPARE != 1 ]]; then
    local dataset_end_count=${found_files_count:-0}
    local dataset_delta=$((dataset_end_count - PSFD_dataset_start_count))
    echo "Total files found in dataset: $dataset_delta"
  fi
}
