#!/bin/bash
# ZFS  snapshot search functions

function process_snapshots_for_dataset() {
  local dataset="$1"

  # Ensure globbing is on for the SNAPREGEX comparison, though set +f is already
  # at the start of the main procedural block, this is a safeguard.
  #set +f
  # no need for that here if its set globally at beginning of procedural

  ##
  # CUSTOM CODE CONTINUE BEGIN
    # manipulate dataset results since  when using trailing wildcards zfs list returns not just the ones that match the wildcards, the ones above them up to the specified one before the wildcard.  e.g. /pool/data/set/*/*/ will return /pool/data/set, /pool/data/set/1, but we would only expect to be searching only the childs, e.g. /pool/data/set/1/a, and maybe another /pool/data/set/1/b.
    #since trailing wildcards were defined, lets strip the datasets that come before the wildcard, from zfs list results to refine the datasets
    # This logic manipulates dataset results when using trailing wildcards
    if [[ ! -z "$TRAILING_WILDCARD_CNT" ]] && [[ "$TRAILING_WILDCARD_CNT" -gt 0 ]]; then
      # ADDED: Declared DS_CONST_ARR as local and used robust read -a
      local DS_CONST_ARR
      IFS=$'\n' read -r -d '' -a DS_CONST_ARR < <(echo "$dataset" | tr '/' '\n')
      # ADDED: Declared DS_CONST_ARR_CNT as local
      local DS_CONST_ARR_CNT=${#DS_CONST_ARR[@]}

      # echo trailing wildcard count = $TRAILING_WILDCARD_CNT
      # echo base dataset path count = $BASE_DSP_CNT
      # stripd dataset dirs off DSP_CONSTITUENTS_ARR that are less than the specified wildcard paths (because zfs list just returns them all when wildcard specified)

      # get count of this datasets specified path depth
      # echo "DS_CONST_ARR: ${DS_CONST_ARR[@]}"
      # echo "DS_CONST_ARR_CNT: $DS_CONST_ARR_CNT"

      # if this zfs list result dataset path depth count is less than or equal to depth count of the total elements in specified path then skip it
      # MODIFIED: Changed 'continue' to 'return' to exit function for this dataset
      if [[ "$DS_CONST_ARR_CNT" -le "$BASE_DSP_CNT" ]]; then
        [[ $VERBOSE == 1  ]] && echo -e "Skipping dataset (too high in hierarchy for trailing wildcards): ${dataset}"
        return # Exit the function for this dataset
      fi
      [[ $VERBOSE == 1  ]] && echo && echo -e "Searching Dataset:(${PURPLE}$dataset${NC})"
    fi
    # echo $dataset
    ##

    # ADDED: Declared snapdirs as local
    local snapdirs="/$dataset/$ZFSSNAPDIR/*"
    # echo "snapdirs $snapdirs"
    for snappath in $snapdirs; do
      #[[ $VERBOSE == 1 ]] && echo ..

      # dont process if snapshots dir is empty
      if [[ ! -d "$snappath" ]]; then
        [[ $VERBOSE == 1 ]] && echo -e "(${YELLOW}No Snapshots found in this dataset${NC}})"
        continue
      fi

      # ADDED: Declared SNAPNAME as local
      local SNAPNAME=$(/bin/basename "$snappath")

      #symlink check, skip if true
      # FIX: Corrected variable from $d to $snappath for the symlink check
      [ -L "${snappath%/}" ] && [[ $VERBOSE == 1 ]] && echo "skipping symlink: ${snappath}" && continue

      [[ $VERBOSE == 1 ]] && echo -e "Scanning snapshot:(${YELLOW}$SNAPNAME${NC}) for files matching '${YELLOW}$FILESTR${NC}' (Path: ${YELLOW}${current_snap_path}${NC})"
      [[ $VERBOSE == 1 ]] && echo "DEBUG: SNAPNAME='$SNAPNAME', SNAPREGEX='$SNAPREGEX'"

      local regex_pattern

      # If SNAPREGEX is literally '*', convert it to '.*' for regex to match anything (including empty string, though SNAPNAME shouldn't be empty)
      if [[ "$SNAPREGEX" == "*" ]]; then
        regex_pattern=".*"
      else
        # For other patterns, escape regex special characters and wrap in '.*' for a 'contains' match
        # The sed command will convert glob wildcards like '*' or '?' to their regex equivalents
        # and escape other characters that have special meaning in regex.
        regex_pattern="$(printf '%s' "$SNAPREGEX" | sed -e 's/[][\.^$*+?(){}|]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g')"
        regex_pattern=".*$regex_pattern.*" # Wrap in .* to ensure 'contains' logic similar to globbing
      fi

     # if [[ ! "$SNAPNAME" == *"$SNAPREGEX"* ]]; then
      # Use the =~ operator for regular expression matching
      # This matches if SNAPNAME contains the regex_pattern
      if [[ ! "$SNAPNAME" =~ $regex_pattern ]]; then
        [[ $VERBOSE == 1 ]] && echo "Skippping, doesnt match -s regex"
        continue;
      fi
      [[ $VERBOSE == 1 ]] && echo -e "Search path:(${BLUE}$snappath${NC})" && echo .

      ##
      # NEW FUNCTIONALITY MODIFICATION BEGIN: Conditional find command execution & bugfix
      # This block ensures 'local' declarations and 'zfs get' are performed only
      # when in COMPARE mode,
      # It also corrects the 'zfs get' commands target and the 'xargs' arg passing for accurate path construction
      ##
      if [[ $COMPARE == 1 ]]; then
        # ADDED: Declared full_snap_id as local
        # Correctly determine the full snapshot ID (dataset@snapshot) for zfs get
        local full_snap_id="${dataset}@${SNAPNAME}"

        # ADDED: Declared creation_time_epoch as local
        # Get creation timestamp for the current snapshot using the correct full snapshot ID
        local creation_time_epoch=$(zfs get -Hp creation "$full_snap_id" | awk 'NR==2{print $3}')

        # Output format: live_equivalent_path|snapshot_name|creation_time_epoch
        # `_` is a dummy variable for `bash -c` to ensure correct argument parsing.
        # $1: dataset (full path), $2: snappath, $3: SNAPNAME, $4: creation_time_epoch
        /bin/sudo /bin/find "$snappath" -type f \( -name "$FILESTR" \) -print0 2>/dev/null | \
        #xargs -0 -I {} bash -c 'echo "'"${1%/}"'${0#'"${2}"'}|'"${3}"'|'"${4}"'"' _ "${dataset}" "${snappath}" "${SNAPNAME}" "${creation_time_epoch}" >> "$all_snapshot_files_found_tmp"
        xargs -0 -I {} bash -c 'echo "$1${5#$2}|$3|$4"' _ "${dataset}" "${snappath}" "${SNAPNAME}" "${creation_time_epoch}" "{}" >> "$all_snapshot_files_found_tmp"

      else
        # ADDED: Declared RESULTS as local
        # Original functionality: find files and list them using ls.
        # The `grep` pipe was previously removed as it was causing 'ls terminated by signal 13' errors.
        local RESULTS=`/bin/time -f "time(sec):%e" /bin/sudo /bin/find "$snappath" -type f \( -name "$FILESTR" \) -exec ls -lh --color=always -g {} \;`
        [[ ! -z "$RESULTS" ]] && echo "$RESULTS"
      fi
      ##
      # NEW FUNCTIONALITY MODIFICATION END
      ##

      [[ $VERBOSE == 1 ]] && echo ... && echo
    done
}
