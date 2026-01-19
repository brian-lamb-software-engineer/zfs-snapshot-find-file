#!/bin/bash
# Common variables, constants, and utility functions

FILESTR=""
# Deletion / destroy flags (safe defaults)
SFF_DESTROY_FORCE=0
DELETE_SNAPSHOTS=0
DESTROY_SNAPSHOTS=0
# shellcheck disable=SC2034
ZFSSNAPDIR=".zfs/snapshot"
FILENAME="*"
FILENAME_ARR=()
FILEARR=()
#LOG_DIR=/tmp #default
LOG_DIR=/tmp
RED='\033[0;31m'
YELLOW='\033[33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
# Example 1: Ignore cache directories
# Example 2: Ignore temporary directories
# Example 3: Ignore macOS specific files
# Example 4: Ignore Windows specific thumbnail files
DEFAULT_IGNORE_REGEX_PATTERNS=(
  "^.*\.cache/.*$"
  "^.*/tmp/.*$"
  "^.*/\.DS_Store$"
  "^.*/thumbs\.db$"
)

# By default, ignore these common filesystem noise patterns. Users may override
# `IGNORE_REGEX_PATTERNS` (e.g. via editing this file or exporting before running).
IGNORE_REGEX_PATTERNS=("${DEFAULT_IGNORE_REGEX_PATTERNS[@]}")
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
DATASETPATH=""
SNAPREGEX=""
RECURSIVE=0
COMPARE=0
VERBOSE=0
OTHERFILE="" # Although not currently used in core logic, keep for completeness
DSP_CONSTITUENTS_ARR_CNT=0
TRAILING_WILDCARD_CNT=0
BASE_DSP_CNT=0
DATASETS=() # Will store the list of datasets to iterate

all_snapshot_files_found_tmp=$(mktemp "${LOG_DIR}/all_snapshot_files_found.XXXXXX")

function help(){
  echo
  echo "A ZFS snapshot search tool.
    - Uses a constructed 'find' command to search in specified snapshot for specified file, recursively by default.
    - Has the ability to search through multiple or all "snapshots" in a given dataset by using wildcard.
    - Has the ability to search for "files" (in snapshots) by wildcard, and maybe other regex calls
    - Has the ability to search for multiple files in the same run by specifying multiple (space separated) files (it's faster than running multiple times).
    - Has the ability to search in child datasets snapshots (all) when -r option is specified, or when wildcard dirs are specified for dataset, e.g. dataset/*, dataset/*/*, etc..
    "
  echo "USAGE:
    snapshots-find-file
    -d (required) <dataset-path to search through> 
    -c (optional) (compare snapshot files to live dataset files to find missing ones) (this shifts the mode of the program to find missing files compared from specified live dataset to a snapshot, as opposed to just finding a file in a snapshot)
    -f (optional) <file-your-searching-for another-file-here> (multiple space separated allowed) 
    -o (optional) <other-file-your-searching--for>
    -s (optional) <snapshot-name-regex-term> (will search all if not specified)
    -r (optional) (recursively search into child datasets)
    -v (optional) (verbose output)
    --delete-snapshots (optional) orchestrate cleanup and write a destroy-plan (dry-run)
    --destroy-snapshots (optional) orchestrate cleanup and attempt to apply destroys (still requires SFF_ALLOW_DESTROY=1)
    --force (optional) when used with destroy will add -f to zfs destroy commands in generated plan
    -h (this help)
    "
  echo "
    Notes for deletion:
    - By default no destroys are executed. To generate a plan use --delete-snapshots.
    - To attempt to apply destroys pass --destroy-snapshots and set environment variable SFF_ALLOW_DESTROY=1.
    - You can also use --force to include '-f' on generated '/sbin/zfs destroy' commands in the plan.
  "
  echo "    -r recursive search, searches recursively to specified dataset. Overrides dataset trailing wildcard paths, so does not obey the wildcard portion of the paths.  E.g. /pool/data/set/*/*/* will still recursively search in all /pool/data/set/. However, wildcards that arent trailing still function as expected.  E.g. /pool/*/set/ will correctly still recurse through all datasets in /pool/data/set, where /pool/*/set/*/* will still recurse through the same, as the trailing wildcards are not obeyed when -r is used"
  echo '
    # search recursively, for all files in a given dataset, and its childs datasets recursively, and print verbose output
    snapshots-find-file -d "/pool/data/set" -rv'
  echo '
    #search for specified file in all of this dataset(only) snaps (wont iterate into child dataset snaps)
    snapshots-find-file -d "/pool/data/set"  -s "*" -f "*1234*jpg"
    snapshots-find-file -d "/pool/data/set/" -s "*" -f "*1234*jpg"'
  echo '
    # same as before except search only snaps which reside inside all child datasets(only 1 level deep) of mentioned dataset only
    snapshots-find-file -d "/pool/data/set/*" -s "*" -f "*1234*"'
  echo '
    #same as before, except specifying specifc regex for snap name
    snapshots-find-file -d "/pool/data/set/*" -s "*my-snap*" -f "*1234*"'
  echo '
    # same as before except adding a 2nd and 3rd file to search for
    snapshots-find-file -d "/pool/data/set/*" -s "*my-snap*" -f "*1234*.jpg *otherfile*.jpg yet-another-file.img"'
  echo '
    #search through specific snaps that reside in child datasets which reside 2 levels and beyond, in specified dataset
    snapshots-find-file -d "/pool/*/set/*/*" -s "*my-snap*" -f "*1234*.jpg"'
  echo '
    #search through all snaps that reside in child datasets which reside 2 levels and beyond, in specified dataset (will not pick up a 3rd level)
    snapshots-find-file -d "/pool/data/set/*/*" -s "*" -f "*1234*.jpg"'
  echo '
    #search recursively with verbose, through all datsets snaps, and for all files (short form) (e.g. list all snapshot files)
    snapshots-find-file -d "/pool" -rv'
  echo '
    # Deletion examples — plan, interactive apply, and force
    # generate a destroy plan (dry-run) for index.html in /nas/live/cloud
    snapshots-find-file -c -d "/nas/live/cloud" --delete-snapshots -s "*" -f "index.html"

    # interactive apply (will prompt before executing the generated plan)
    snapshots-find-file -c -d "/nas/live/cloud" --destroy-snapshots -s "*" -f "index.html"

    # force destroy in generated plan (adds -f to zfs destroy when executed)
    snapshots-find-file -c -d "/nas/live/cloud" --destroy-snapshots --force -s "*" -f "index.html"

    # advanced: call cleanup function directly for a subset of datasets (debug)
    bash -lc 'source ./lib/common.sh; source ./lib/zfs-cleanup.sh; identify_and_suggest_deletion_candidates "/nas/live/cloud" "/nas/live/cloud/tcc"'
'
  echo
  echo "Note: Dataset may be specified as either a ZFS name (e.g. pool/dataset) or a filesystem path (e.g. /pool/dataset). The tool normalizes both forms; prefer the filesystem path form (leading '/')."
  exit 1;
}

# Counter for recorded found files across the run
found_files_count=0

# Record a found file to the global snapshot list and increment the counter
function record_found_file() {
  local file="$1"
  echo "$file" >> "$all_snapshot_files_found_tmp"
  ((found_files_count++))
}

# Prompt for confirmation. Returns 0 if confirmed, non-zero otherwise.
function confirm_action() {
  local prompt="${1:-Are you sure? [y/N]}"
  read -r -p "$prompt " ans
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# Prompt with default option. Usage: prompt_confirm "Question?" "y"  (default is 'n')
function prompt_confirm() {
  local prompt="${1:-Are you sure?}"
  local default="${2:-n}"
  if [[ "$default" == "y" ]]; then
    prompt="$prompt [Y/n]"
  else
    prompt="$prompt [y/N]"
  fi
  local ans
  read -r -p "$prompt " ans
  if [[ -z "$ans" ]]; then
    ans="$default"
  fi
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

function parse_arguments() {
  # CRUCIAL FIX: Reset OPTIND to 1 before calling getopts.
  # This ensures getopts always starts parsing from the first argument,
  # preventing issues where it might skip arguments if OPTIND was previously modified.
  local OPTIND=1
  # Support long-form options by pre-scanning and removing them from positional args
  local new_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-snapshots)
        DELETE_SNAPSHOTS=1; shift ;;
      --destroy-snapshots)
        DESTROY_SNAPSHOTS=1; shift ;;
      --force)
        SFF_DESTROY_FORCE=1; shift ;;
      *) new_args+=("$1"); shift ;;
    esac
  done
  # restore positional args for getopts
  set -- "${new_args[@]}"
  while getopts ":d:f:o:s:rvhc" ARG; do
    case "$ARG" in
      v) # echo "Running -$ARG flag for verbose output"
         VERBOSE=1 ;;
      d) #echo "Running -d flag which is a placeholder to pass a dataset path arg ith it"
         #echo -"$ARG arg is $OPTARG"
         DATASETPATH=$OPTARG ;;
      s) # echo "Running -$ARG flag which is a placeholder to pass a snapshot arg with it"
         # echo "-$ARG arg is $OPTARG"
         SNAPREGEX=$OPTARG ;;
      f) # echo "Running -$ARG flag which is a placeholder to pass a filename arg with it"
        # echo "-$ARG arg is $OPTARG"
        FILENAME_ARR+=("${OPTARG}") ;;
      o) # echo "Running -$ARG flag which is a placeholder to pass another file to also search for"
         # echo "-$ARG arg is $OPTARG"
         OTHERFILE=$OPTARG ;;
      r)
         RECURSIVE=1 ;;
      D)
        DELETE_SNAPSHOTS=1 ;;
      X)
        DESTROY_SNAPSHOTS=1 ;;
      c)
         COMPARE=1 ;;
      h) help ;;
      :) echo "argument missing" ;;
      \?) echo "Something is wrong" ;;
    esac
  done

  # set back $1 index
  shift "$((OPTIND-1))"

  if [[ -z $DATASETPATH ]]; then
    echo "You must specify at least -d, exiting, bye!"
    help
    exit 1
  fi

  # Warn the user if neither -f nor -s is provided
  if [[ -z $FILENAME || $FILENAME == "*" ]] && [[ -z $SNAPREGEX ]]; then
    echo -e "${YELLOW}No file pattern (-f) or snapshot regex (-s) specified. Defaulting to search for all files (*).${NC}"
  fi
}

function initialize_search_parameters() {

  local splitArr

  # Build file pattern string from -f arguments (moved to patterns.sh)
  build_file_pattern
  # Normalize dataset filesystem path with leading slash for later filesystem operations
  DATASETPATH_FS="$DATASETPATH"
  DATASETPATH_FS="${DATASETPATH_FS#/}"
  DATASETPATH_FS="/${DATASETPATH_FS}"

  # Debugging output for key variables
  [[ $VERBOSE == 1 ]] && echo "Initializing search parameters..."
  [[ $VERBOSE == 1 ]] && echo "Dataset path: $DATASETPATH_FS"
  [[ $VERBOSE == 1 ]] && echo "File pattern: $FILENAME"
  [[ $VERBOSE == 1 ]] && echo "Snapshot regex: $SNAPREGEX"
  [[ $VERBOSE == 1 ]] && echo "Recursive flag: $RECURSIVE"

  # If compare mode requested, ensure we include child datasets for accurate dataloss detection.
  # This makes compare mode safe-by-default (it will search child datasets unless -r is explicitly omitted),
  # and prints a clear warning so the user understands the broader work being performed.
  if [[ $COMPARE -eq 1 && $RECURSIVE -ne 1 ]]; then
    echo -e "${YELLOW}Compare mode requires full dataset discovery; enabling recursive discovery (-r) for accurate results.${NC}"
    RECURSIVE=1
  fi

  # Discover datasets based on recursive flag, by delegating to helper
  # (moved to `lib/datasets.sh` as `discover_datasets()`)
  discover_datasets "$DATASETPATH" "$RECURSIVE"

  ##
  # CUSTOM CODE BEGIN
  # WARNING disabling file globbing so it doesn't expand into the pathnames when 
  #   you set them to a var. If you add any code that needs it reenabled, you
  #   will either need to process those before this line and set needed data to 
  #   a var there, or reenable it after this code block
  set -f
  # get count of specified datasetpath path depth
  #DSP_CONSTITUENTS_ARR=($(echo "$DATASETPATH" | tr '/' '\n'))
  #DSP_CONSTITUENTS_ARR_CNT=${#DSP_CONSTITUENTS_ARR[@]}
  DSP_CONSTITUENTS_ARR=() # Explicitly initialize as empty array
  DSP_CONSTITUENTS_ARR=($(echo "$DATASETPATH" | tr '/' '\n'))
  DSP_CONSTITUENTS_ARR_CNT=${#DSP_CONSTITUENTS_ARR[@]}
  # echo "dsp constituents arr: ${DSP_CONSTITUENTS_ARR[*]}"
  # echo "dsp constituents arr cnt: ${#DSP_CONSTITUENTS_ARR[*]}"
  # count how many trailing asterisks
  # walk array backwards, using c style
  for (( idx=${#DSP_CONSTITUENTS_ARR[@]}-1; idx>=0; idx-- ));  do
    VAL=${DSP_CONSTITUENTS_ARR[$idx]}
    # echo "id($idx) val:($VAL)"
    # get id of the last dir before the trailing wildcards (-1 is because it stops
    #   on the dir after the last specified folder, subtract that also)
    TRAILING_WILDCARD_CNT=$(( DSP_CONSTITUENTS_ARR_CNT - idx - 1 ))
    BASE_DSP_CNT=$(( DSP_CONSTITUENTS_ARR_CNT - TRAILING_WILDCARD_CNT ))
    # stop on last specified folder (first since we're reverse sorted array)
    [[ $VAL != "*" ]] && break
  done
  set +f
  # CUSTOM CODE END (moved inside a function)
  ##
}

  #!/bin/bash
  # Dataset discovery and normalization helpers (moved back from lib/datasets.sh)
  #
  # This logic was previously extracted for Phase 2; per project preference we
  # keep operation-level helpers consolidated. Preserving original comments.
  ## Discover datasets based on recursive flag, by iterating zfs list results
  ## and normalizing/deduping entries into the global `DATASETS` array.
  function discover_datasets() {
    local datasetpath="$1"
    local recursive_flag="$2"

    # Ensure globbing is enabled for 'zfs list' command that populates DATASETS
    # (it should be by default, but explicitly setting +f here if it was turned off globally)
    set +f

    # Explicitly clear the DATASETS array before populating it
    DATASETS=()

    # Use a temporary array for robust population, then assign to global DATASETS
    local -a tmp_datasets

    if [[ $recursive_flag == 1 ]]; then
      IFS=$'\n' read -r -d '' -a tmp_datasets < <(zfs list -rH -o name "${datasetpath%/}" 2>/dev/null | tail -n +2)
    else
      # Include only the specified dataset
      IFS=$'\n' read -r -d '' -a tmp_datasets < <(zfs list -H -o name "${datasetpath%/}" 2>/dev/null)
    fi

    # Assign the temporary array content to the global DATASETS array
    DATASETS=("${tmp_datasets[@]}")

    # Normalize and dedupe DATASETS entries to their ZFS-name form (no leading slash).
    local -a _norm
    for ds in "${DATASETS[@]}"; do
      local ds_norm="${ds#/}"
      ds_norm="${ds_norm%/}"
      if [[ ! " ${_norm[*]} " =~ ${ds_norm} ]]; then
        _norm+=("${ds_norm}")
      fi
    done

    # Ensure the specified dataset is included, even if it is a parent dataset
    # This ensures that the parent dataset is processed even without the -r flag
    local spec="${datasetpath%/}"
    spec="${spec#/}"
    if [[ ! " ${_norm[*]} " =~ ${spec} ]]; then
      _norm+=("${spec}")
    fi

    DATASETS=("${_norm[@]}")

    # Debugging output for discovered datasets (display with leading slashes)
    if [[ $VERBOSE == 1 ]]; then
      local -a ds_disp
      for ds in "${DATASETS[@]}"; do
        ds_disp+=("/${ds#/}")
      done
      echo "Discovered datasets: ${ds_disp[*]}"
    fi

    # Restore disabled globbing
    set -f
  }

  # Prompt the user for a yes/no confirmation. Returns 0 for yes, 1 for no.
  function prompt_confirm() {
    local prompt_msg="$1"
    local default_answer="$2" # 'y' or 'n'
    local reply
    if [[ -n "$default_answer" && "$default_answer" == "y" ]]; then
      read -r -p "$prompt_msg [Y/n]: " reply
      reply=${reply:-Y}
    else
      read -r -p "$prompt_msg [y/N]: " reply
      reply=${reply:-N}
    fi

    case "$reply" in
      Y|y) return 0 ;;
      *) return 1 ;;
    esac
  }

  ## Normalize a dataset string to ZFS-name form (no leading/trailing slash)
  function normalize_dataset_name() {
    local ds="$1"
    ds="${ds%/}"
    ds="${ds#/}"
    printf '%s' "$ds"
  }

  # Map a full snapshot file path to the live dataset equivalent path.
  # Args:
  #  $1 - ZFS dataset name (no leading slash), e.g. pool/dataset
  #  $2 - snapshot root path (the directory that contains .zfs/snapshot/<snap>), e.g. /pool/dataset/.zfs/snapshot/<snap>
  #  $3 - full file path inside the snapshot, e.g. /pool/dataset/.zfs/snapshot/<snap>/path/to/file
  # Output: prints the live-equivalent path, e.g. /pool/dataset/path/to/file
  function map_snapshot_to_live_path() {
    local dataset_name="$1"
    local snap_root="$2"
    local full_path="$3"

    # Ensure dataset_name is normalized (no leading slash)
    dataset_name="${dataset_name#/}"

    # Filesystem root for the dataset
    local fs_root="/${dataset_name%/}"

    # Ensure snap_root ends with a slash for prefix removal
    local snap_prefix="${snap_root%/}/"

    # Compute the path relative to the snapshot root
    local rel_path="${full_path#${snap_prefix}}"

    # Construct live-equivalent path
    printf '%s' "${fs_root%/}/${rel_path}"
  }

  # File pattern builder
  # Builds global `FILESTR` from `-f` args.
  # builds global `FILESTR` used by the `find` commands
  # across the codebase.
  function build_file_pattern() {
    local splitArr

    # Split the FILENAME param, which may come in as a space separated argument
    #  value, that will be split into an array for passing to find command using
    #  -o -name for each addition, but not the first
    # If the user supplied -f multiple times, use those entries as patterns.  
    if [[ ${#FILENAME_ARR[@]} -gt 0 ]]; then
      splitArr=("${FILENAME_ARR[@]}")
    else
      # Backwards compatibility: split the single FILENAME string if no -f array provided
      read -r -a splitArr <<<"$FILENAME"
    fi
    # iterate -f files to build the proper find command for them (appends -o -name for each addtnl)    FILESTR=""
    FILEARR=()
    for i in "${!splitArr[@]}"; do
      local pat="${splitArr[$i]}"
      # If the pattern includes a path separator, match by -path so users can
      # target files inside specific subdirectories (e.g. users/brian/Documents)
      if [[ "$pat" == *"/"* ]]; then
        # Trim any leading slash for consistent relative matching from snapshot root
        local pat_trim="${pat#/}"
        # If the user didn't include any wildcard, wrap with '*' so it matches
        # anywhere under the snapshot directory
        if [[ "$pat_trim" == *"*"* ]]; then
          local path_expr="*$pat_trim"
        else
          local path_expr="*$pat_trim*"
        fi
        if [[ "$i" -eq 0 ]]; then
          FILEARR+=(-path "$path_expr")
          FILESTR="-path $path_expr"
        else
          FILEARR+=(-o -path "$path_expr")
          FILESTR+=" -o -path $path_expr"
        fi
      else
        if [[ "$i" -eq 0 ]]; then
          FILEARR+=(-name "$pat")
          FILESTR="-name $pat"
        else
          FILEARR+=(-o -name "$pat")
          FILESTR+=" -o -name $pat"
        fi
      fi
    done
  }
