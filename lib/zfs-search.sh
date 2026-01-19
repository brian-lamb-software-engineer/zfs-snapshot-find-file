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

  /bin/sudo /bin/find "$snappath" -type f \( "${FILEARR[@]}" \) -print0 2>/dev/null > "$found_tmp"
  if [[ -s "$found_tmp" ]]; then
    while IFS= read -r -d '' file; do
      echo -e "${GREEN}${file}${NC}"
      record_found_file "$file"
    done < "$found_tmp"
  fi
  rm -f "$found_tmp"
}

function process_snapshots_for_dataset() {
  local dataset="$1"

  # Ensure dataset path does not have trailing slashes
  dataset="${dataset%/}" # Remove trailing slash

  # Compute both filesystem path and ZFS dataset name forms.
  # `ds_path` is the filesystem-style path (leading slash). `dataset_name` is the ZFS name (no leading slash).
  local ds_path="$dataset"
  if [[ "$ds_path" != /* ]]; then
    ds_path="/$ds_path"
  fi
  local dataset_name="${dataset#/}"

  # Debugging output (show both forms)
  [[ $VERBOSE == 1 ]] && echo "Processing dataset: $dataset_name (path: $ds_path)"

  # Debugging output for ZFSSNAPDIR
  [[ $VERBOSE == 1 ]] && echo "Using ZFSSNAPDIR: $ZFSSNAPDIR"

  ##
  # CUSTOM CODE CONTINUE BEGIN
  # Manipulate dataset results since when using trailing wildcards zfs list returns not 
  #   just the ones that match the wildcards, the ones above them up to the specified one 
  #   before the wildcard.  e.g. /pool/data/set/*/*/ will return /pool/data/set, 
  #   /pool/data/set/1, but we would only expect to be searching only the childs, e.g. 
  #   /pool/data/set/1/a, and maybe another /pool/data/set/1/b.
  # Since trailing wildcards were defined, lets strip the datasets that come before the 
  #   wildcard, from zfs list results to refine the datasets.
  # This logic manipulates dataset results when using trailing wildcards.
  if [[ ! -z "$TRAILING_WILDCARD_CNT" ]] && [[ "$TRAILING_WILDCARD_CNT" -gt 0 ]]; then
    # ADDED: Declared DS_CONST_ARR as local and used robust read -a
    local DS_CONST_ARR
    IFS=$'\n' read -r -d '' -a DS_CONST_ARR < <(echo "$dataset" | tr '/' '\n')
    # ADDED: Declared DS_CONST_ARR_CNT as local
    local DS_CONST_ARR_CNT=${#DS_CONST_ARR[@]}

    # echo trailing wildcard count = $TRAILING_WILDCARD_CNT
    # echo base dataset path count = $BASE_DSP_CNT
    # Strip dataset dirs off DSP_CONSTITUENTS_ARR that are less than the specified 
    #   wildcard paths (because zfs list just returns them all when wildcard specified).

    # Get count of this dataset's specified path depth
    # echo "DS_CONST_ARR: ${DS_CONST_ARR[@]}"
    # echo "DS_CONST_ARR_CNT: $DS_CONST_ARR_CNT"

    # If this zfs list result dataset path depth count is less than or equal to depth 
    #   count of the total elements in specified path then skip it.
    # MODIFIED: Changed 'continue' to 'return' to exit function for this dataset.
    if [[ "$DS_CONST_ARR_CNT" -le "$BASE_DSP_CNT" ]]; then
      [[ $VERBOSE == 1  ]] && echo -e "Skipping dataset (too high in hierarchy for trailing wildcards): ${dataset}"
      return # Exit the function for this dataset
    fi
    [[ $VERBOSE == 1  ]] && echo && echo -e "Searching Dataset:(${PURPLE}$dataset${NC})"
  fi
  ##

  # Ensure globbing is enabled for processing snapshot directories
  # This is necessary for the SNAPREGEX comparison and glob expansion.
  set +f

  # ADDED: Declared snapdirs as local
  # Normalize dataset path to avoid double leading slashes in constructed paths
  local snapdirs="${ds_path%/}/$ZFSSNAPDIR/*"
  [[ $VERBOSE == 1 ]] && echo "Checking snapshot directory: $snapdirs"

  local snapshot_found=0
  # Track files found count at start for per-dataset reporting
  local dataset_start_count=${found_files_count:-0}
  for snappath in $snapdirs; do
    # Skip if the snapshot directory does not exist
    if [[ ! -d "$snappath" ]]; then
      [[ $VERBOSE == 1 ]] && echo -e "(${YELLOW}No Snapshots found in this dataset${NC})"
      continue
    fi

    snapshot_found=1
    # ADDED: Declared SNAPNAME as local
    local SNAPNAME=$(/bin/basename "$snappath")

    # Symlink check, skip if true
    [ -L "${snappath%/}" ] && [[ $VERBOSE == 1 ]] && echo "Skipping symlink: ${snappath}" && continue

    [[ $VERBOSE == 1 ]] && echo -e "Scanning snapshot:(${YELLOW}$SNAPNAME${NC}) for files matching '${YELLOW}$FILESTR${NC}'"

    local regex_pattern

    # If SNAPREGEX is literally '*', convert it to '.*' for regex to match anything
    if [[ "$SNAPREGEX" == "*" ]]; then
      regex_pattern=".*"
    else
      # Escape regex special characters and wrap in '.*' for a 'contains' match
      regex_pattern="$(printf '%s' "$SNAPREGEX" | sed -e 's/[][\.^$*+?(){}|]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g')"
      regex_pattern=".*$regex_pattern.*"
    fi

    # Use the =~ operator for regular expression matching
    if [[ ! "$SNAPNAME" =~ $regex_pattern ]]; then
      [[ $VERBOSE == 1 ]] && echo "Skipping, doesn't match -s regex"
      continue
    fi

    [[ $VERBOSE == 1 ]] && echo -e "Search path:(${BLUE}$snappath${NC})"

    ##
    # NEW FUNCTIONALITY MODIFICATION BEGIN: Conditional find command execution & bugfix
    # This block ensures 'local' declarations and 'zfs get' are performed only
    # when in COMPARE mode,
    # It also corrects the 'zfs get' commands target and the 'xargs' arg passing for accurate path construction.
    ##
    if [[ $COMPARE == 1 ]]; then
      local full_snap_id="${dataset_name}@${SNAPNAME}"
      local creation_time_epoch=$(zfs get -Hp creation "$full_snap_id" | awk 'NR==2{print $3}')
      _handle_compare_snapdir "$snappath" "$dataset" "$dataset_name" "$SNAPNAME" "$creation_time_epoch"
    else
      _handle_noncompare_snapdir "$snappath" "$dataset"
    fi
    ##
    # NEW FUNCTIONALITY MODIFICATION END
    ##
  done

  # Check if no snapshots were found
  if [[ $snapshot_found -eq 0 ]]; then
    echo -e "${RED}Error: No snapshots found for dataset: $dataset${NC}"
  fi

  # Disable globbing again after processing
  set -f

  ##
  # CUSTOM CODE END
  ##

  # Print per-dataset summary for non-compare runs
  if [[ $COMPARE != 1 ]]; then
    local dataset_end_count=${found_files_count:-0}
    local dataset_delta=$((dataset_end_count - dataset_start_count))
    echo "Total files found in dataset: $dataset_delta"
  fi
}
