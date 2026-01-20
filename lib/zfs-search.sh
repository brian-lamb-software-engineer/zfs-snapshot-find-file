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
  /bin/sudo /bin/find "$snappath" -type f \( "${FILEARR[@]}" \) -print0 2>/dev/null | \
    # shellcheck disable=SC2016
    xargs -0 -I {} bash -c 'echo "$1${5#$2}|$3|$4"' _ "${dataset}" "${snappath}" "${SNAPNAME}" "${creation_time_epoch}" "{}" >> "$all_snapshot_files_found_tmp"
}

function _handle_noncompare_snapdir() {
  local snappath="$1"
  local dataset="$2"
  local tmp_base="${LOG_DIR:-${TMPDIR:-/tmp}}"
  local found_tmp
  found_tmp=$(mktemp "${tmp_base}/found_files.XXXXXX")

  vlog "zfs-search.sh _handle_noncompare_snapdir called for dataset=${dataset} snappath=${snappath}"

  /bin/sudo /bin/find "$snappath" -type f \( "${FILEARR[@]}" \) -print0 2>/dev/null > "$found_tmp"
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
  if [[ ! -z "$TRAILING_WILDCARD_CNT" ]] && [[ "$TRAILING_WILDCARD_CNT" -gt 0 ]]; then
    local DS_CONST_ARR
    IFS=$'\n' read -r -d '' -a DS_CONST_ARR < <(echo "$dataset" | tr '/' '\n') || true
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
  if [[ "$SNAPREGEX" == "*" ]]; then
    regex_pattern=".*"
  else
    regex_pattern="$(printf '%s' "$SNAPREGEX" | sed -e 's/[][\.^$*+?(){}|]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g')"
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
    [[ $VERBOSE == 1 ]] && echo -e "(${YELLOW}No Snapshots found in this dataset${NC})"
    return 0
  fi

  vlog "zfs-search.sh _process_snappath dataset=${dataset} ds_path=${ds_path} snappath=${snappath}"

  local SNAPNAME=$(/bin/basename "$snappath")
  [ -L "${snappath%/}" ] && [[ $VERBOSE == 1 ]] && echo "Skipping symlink: ${snappath}" && return 0

  [[ $VERBOSE == 1 ]] && echo -e "Scanning snapshot:(${WHITE}$SNAPNAME${NC}) for files matching '${YELLOW}$FILESTR${NC}'"

  if ! _matches_snapshot_regex "$SNAPNAME"; then
    [[ $VERBOSE == 1 ]] && echo "Skipping, doesn't match -s regex"
    return 0
  fi

  [[ $VERBOSE == 1 ]] && echo -e "Search path:(${CYAN}$snappath${NC})"

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
    _handle_compare_snapdir "$snappath" "$dataset" "$dataset_name" "$SNAPNAME_local" "$creation_time_epoch"
  else
    _handle_noncompare_snapdir "$snappath" "$dataset"
  fi
}

function process_snapshots_for_dataset() {
  local dataset="$1"
  vlog "zfs-search.sh process_snapshots_for_dataset START dataset=${dataset}"
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
  [[ $VERBOSE == 1 ]] && echo -e "Processing dataset: ${WHITE}$PSFD_dataset_name${NC} (path: ${WHITE}$PSFD_ds_path${NC})"
  [[ $VERBOSE == 1 ]] && echo -e "${GREY}Using ZFSSNAPDIR: $ZFSSNAPDIR${NC}"
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
    _process_snappath "$snappath" "$dataset" "$ds_path" "$PSFD_dataset_name" && PSFD_snapshot_found=1 || true
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
