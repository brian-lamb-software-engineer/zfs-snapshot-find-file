#!/bin/bash
# common code lives on this file, code that all the other libs use, as well as main vars

# Common variables, constants, and utility functions
FILESTR=""
# Plan-only delete flag (creates a destroy plan but does not execute it).
# NOTE: This is a config-level setting. To generate plans set this to 1
# or pass --clean-snapshots; editing this file is the permanent switch.
SFF_DELETE_PLAN=1

# Master destroy execution flag (must be explicitly enabled in config).
# WARNING: This is the master switch for destructive execution. Do NOT
# enable it via runtime flags — edit this file to set `DESTROY_SNAPSHOTS=1`.
DESTROY_SNAPSHOTS=0
# Deletion / destroy flags (safe defaults)
# shellcheck disable=SC2034
SFF_DESTROY_FORCE=0
# CLI-request tracking var for destroy (declared at top so it's visible/configurable)
# Preserve any environment-provided request flag so callers can set it with
# `REQUEST_DESTROY_SNAPSHOTS=1 ./snapshots-find-file ...` or `export REQUEST_DESTROY_SNAPSHOTS=1`.
REQUEST_DESTROY_SNAPSHOTS=${REQUEST_DESTROY_SNAPSHOTS:-0}
# When a destroy execution was requested but the top-level master flag is disabled,
# set this so callers can emit a yellow notice near destroy-plan/apply output.
DESTROY_DISABLED_NOTICE=0
# Capture top-level allow flags so CLI args cannot override when intentionally disabled.
# Set these to 0 here to permanently disable plan/apply unless this file is edited.
SFF_DELETE_PLAN_ALLOWED=${SFF_DELETE_PLAN}
DESTROY_SNAPSHOTS_ALLOWED=${DESTROY_SNAPSHOTS}
# shellcheck disable=SC2034
ZFSSNAPDIR=".zfs/snapshot"
FILENAME="*"
FILENAME_ARR=()
FILEARR=()
#LOG_DIR=/tmp #default
LOG_DIR=/tmp

# Color codes for output
COL="\033["
RED="${COL}0;31m"
YELLOW="${COL}33m"
BLUE="${COL}0;34m"
# shellcheck disable=SC2034
CYAN="${COL}0;36m"
GREY="${COL}1;30m"
WHITE="${COL}1;37m"
# shellcheck disable=SC2034
PURPLE="${COL}0;35m"
# shellcheck disable=SC2034
GREEN="${COL}0;32m"
NC="${COL}0m" # No Color
# Prefix for temporary files created by this tool
SFF_TMP_PREFIX="sff_"
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
# shellcheck disable=SC2034
IGNORE_REGEX_PATTERNS=("${DEFAULT_IGNORE_REGEX_PATTERNS[@]}")
# shellcheck disable=SC2034
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
DATASETPATH=""
SNAPREGEX=""
RECURSIVE=0
COMPARE=0
VERBOSE=0
VVERBOSE=0
QUIET=0
# shellcheck disable=SC2034
OTHERFILE="" # Although not currently used in core logic, keep for completeness
DSP_CONSTITUENTS_ARR_CNT=0
TRAILING_WILDCARD_CNT=0
BASE_DSP_CNT=0
DATASETS=() # Will store the list of datasets to iterate

all_snapshot_files_found_tmp=$(mktemp "${LOG_DIR}/${SFF_TMP_PREFIX}all_snapshot_files_found.XXXXXX")

function help(){
  cat <<'HELP'
A ZFS snapshot search tool.
  - Uses a constructed 'find' command to search in specified snapshot for specified file, recursively by default.
  - Has the ability to search through multiple or all "snapshots" in a given dataset by using wildcard.
  - Has the ability to search for "files" (in snapshots) by wildcard, and maybe other regex calls
  - Has the ability to search for multiple files in the same run by specifying multiple (space separated) files (it's faster than running multiple times).
  - Has the ability to search in child datasets snapshots (all) when -r option is specified, or when wildcard dirs are specified for dataset, e.g. dataset/*, dataset/*/*, etc..

USAGE:
  snapshots-find-file
  -d (required) <dataset-path to search through>
  -c (optional) (compare snapshot files to live dataset files to find missing ones)
     (this shifts the mode of the program to find missing files compared from specified live dataset to a snapshot, as opposed to just finding a file in a snapshot)
  -f (optional) <file-your-searching-for another-file-here> (multiple space separated allowed)
  -o (optional) <other-file-your-searching--for>
  -s (optional) <snapshot-name-regex-term> (will search all if not specified)
  -r (optional) (recursively search into child datasets)
  -v (optional) (verbose output). Use `-vv` or `--very-verbose` for very-verbose tracing (prints function entries).
  --clean-snapshots (optional) orchestrate cleanup and write a destroy-plan (dry-run)
  --force (optional) when used with destroy will add -f to zfs destroy commands in generated plan
  -h (this help)

Notes for deletion:
  - By default no destroys are executed. To generate a plan use --clean-snapshots.
  - To attempt to apply destroys enable `DESTROY_SNAPSHOTS=1` in `lib/common.sh` and then
    re-run with `--clean-snapshots` to generate/apply the plan. Applying a generated
    plan requires enabling the master switch and confirming the interactive prompt.
  - You can also use --force to include '-f' on generated '/sbin/zfs destroy' commands in the plan.

  -r recursive search, searches recursively to specified dataset. Overrides dataset trailing wildcard paths, so does not obey the wildcard portion of the paths.  E.g. /pool/data/set/*/*/* will still recursively search in all /pool/data/set/. However, wildcards that aren't trailing still function as expected.  E.g. /pool/*/set/ will correctly still recurse through all datasets in /pool/data/set, where /pool/*/set/*/* will still recurse through the same, as the trailing wildcards are not obeyed when -r is used

Examples:

  # search recursively, for all files in a given dataset, and its childs datasets recursively, and print verbose output
  snapshots-find-file -d "/pool/data/set" -rv

  # search for specified file in all of this dataset(only) snaps (won't iterate into child dataset snaps)
  snapshots-find-file -d "/pool/data/set" -s "*" -f "*1234*jpg"
  snapshots-find-file -d "/pool/data/set/" -s "*" -f "*1234*jpg"

  # same as before except search only snaps which reside inside all child datasets (only 1 level deep) of mentioned dataset only
  snapshots-find-file -d "/pool/data/set/*" -s "*" -f "*1234*"

  # same as before, except specifying specific regex for snap name
  snapshots-find-file -d "/pool/data/set/*" -s "*my-snap*" -f "*1234*"

  # same as before except adding a 2nd and 3rd file to search for
  snapshots-find-file -d "/pool/data/set/*" -s "*my-snap*" -f "*1234*.jpg *otherfile*.jpg yet-another-file.img"

  # search through specific snaps that reside in child datasets which reside 2 levels and beyond, in specified dataset
  snapshots-find-file -d "/pool/*/set/*/*" -s "*my-snap*" -f "*1234*.jpg"

  # search through all snaps that reside in child datasets which reside 2 levels and beyond, in specified dataset (will not pick up a 3rd level)
  snapshots-find-file -d "/pool/data/set/*/*" -s "*" -f "*1234*.jpg"

  # search recursively with verbose, through all datasets snaps, and for all files (short form) (e.g. list all snapshot files)
  snapshots-find-file -d "/pool" -rv

  # Deletion examples — plan and force (apply requires enabling DESTROY_SNAPSHOTS in config)
  # generate a destroy plan (dry-run) for index.html in /nas/live/cloud
  snapshots-find-file -c -d "/nas/live/cloud" --clean-snapshots -s "*" -f "index.html"

  # To apply a generated plan interactively, enable DESTROY_SNAPSHOTS=1 in lib/common.sh,
  # then re-run with --clean-snapshots to generate and (after confirmation) execute the plan.
  # force destroy in generated plan (adds -f to zfs destroy when executed)
  snapshots-find-file -c -d "/nas/live/cloud" --clean-snapshots --force -s "*" -f "index.html"

  # advanced: call cleanup function directly for a subset of datasets (debug)
  bash -lc 'source ./lib/common.sh; source ./lib/zfs-cleanup.sh; identify_and_suggest_deletion_candidates "/nas/live/cloud" "/nas/live/cloud/tcc"'

Note: Dataset may be specified as either a ZFS name (e.g. pool/dataset) or a filesystem path (e.g. /pool/dataset). The tool normalizes both forms; prefer the filesystem path form (leading '/').
HELP
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

# Verbose tracing helper: prints when VVERBOSE is enabled
function vlog() {
  if [[ ${VVERBOSE:-0} -eq 1 ]]; then
    # Send verbose tracing to stderr so command-substitutions that capture
    # function output are not polluted by debug text.
    # Auto-prefix messages with calling script and function so callers do not
    # need to redundantly include filenames or function names everywhere.
    local caller_func="${FUNCNAME[1]:-MAIN}"
    local caller_file
    caller_file=$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")
    local msg="$*"
    if [[ -z "$msg" ]]; then
      echo -e "${BLUE}${caller_file}::${caller_func}${NC}" >&2
    else
      echo -e "${BLUE}${caller_file}::${caller_func}: ${NC}${msg}" >&2
    fi
  fi
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

# Print a yellow warning if destroy execution was requested but the
# top-level `DESTROY_SNAPSHOTS_ALLOWED` is disabled. Callers (cleanup) should
# invoke this just above any destroy-plan messages so the notice appears in
# proximity to the destroy output.
function print_destroy_disabled_notice() {
  if [[ "${DESTROY_DISABLED_NOTICE:-0}" -eq 1 ]]; then
    echo -e "${YELLOW}Note: Destroy execution requested but 'DESTROY_SNAPSHOTS' is disabled in configuration.${NC}"
  fi
}

function parse_arguments() {
  # CRUCIAL FIX: Reset OPTIND to 1 before calling getopts.
  # This ensures getopts always starts parsing from the first argument,
  # preventing issues where it might skip arguments if OPTIND was previously modified.
  local OPTIND=1
  # If user passed combined short flags like '-cvv', count 'v' occurrences
  # across short-form args and enable very-verbose when two or more 'v's
  # are present (e.g. -vv or -cvv). Also honor long-form flags.
  local _v_count=0
  for _a in "$@"; do
    # honor explicit long-form
    if [[ "$_a" == "--very-verbose" || "$_a" == "--vv" ]]; then
      VVERBOSE=1; break
    fi
    # only consider short-form args that start with a single dash
    if [[ "$_a" == -* && "$_a" != --* ]]; then
      # count 'v' characters in the token
      local _v_only
      _v_only=${_a//[^v]/}
      _v_count=$(( _v_count + ${#_v_only} ))
      if [[ $_v_count -ge 2 ]]; then VVERBOSE=1; break; fi
    fi
  done
  # Support long-form options by pre-scanning and removing them from positional args
  local new_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -vv)
        VVERBOSE=1; shift ;;
      -q|--quiet)
        QUIET=1; shift ;;
      --clean-snapshots)
        REQUEST_SNAP_DELETE_PLAN=1; shift ;;
      --force)
        SFF_DESTROY_FORCE=1; shift ;;
      --very-verbose)
        VVERBOSE=1; shift ;;
      --*)
        echo -e "${YELLOW}Unknown option: $1${NC}"
        echo "Use --clean-snapshots, --force, --very-verbose or see help.";
        help
        exit 1
        ;;
      *) new_args+=("$1"); shift ;;
    esac
  done
  # restore positional args for getopts
  set -- "${new_args[@]}"
  # include 'q' and 'D' in the option string so getopts recognizes them
  while getopts ":d:f:o:s:rvhcVqD" ARG; do
    case "$ARG" in
      q)
        QUIET=1 ;;
      v) # echo "Running -$ARG flag for verbose output"
        VERBOSE=1 ;;
      V)
        VVERBOSE=1 ;;
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
        REQUEST_SNAP_DELETE_PLAN=1 ;;
      c)
         COMPARE=1 ;;
      h) help ;;
      :) echo "argument missing" ;;
      \?) echo "Something is wrong" ;;
    esac
  done

  # set back $1 index
  shift "$((OPTIND-1))"

  # Defensive validation: if the dataset path looks like an option (starts with '-')
  # it likely means argument parsing shifted incorrectly or the user mis-quoted.
  if [[ -n "$DATASETPATH" && "${DATASETPATH:0:1}" == "-" ]]; then
    echo -e "${RED}Error: dataset path appears to be an option: ${DATASETPATH}${NC}"
    echo "Check quoting and argument ordering. See help below:";
    help
    exit 1
  fi

  # Respect top-level allow flags: if the admin has permanently disabled
  # delete/destroy by setting the top-level variables to 0, ignore CLI
  # requests. This makes the top-level setting a hard switch that must be
  # edited in the file to enable destructive behavior.
  if [[ "${SFF_DELETE_PLAN_ALLOWED:-1}" -eq 0 ]]; then
    if [[ "${REQUEST_SNAP_DELETE_PLAN:-0}" -eq 1 ]]; then
      echo -e "${YELLOW}Note: --clean-snapshots ignored because destroy-plan generation is disabled in configuration.${NC}"
    fi
    SFF_DELETE_PLAN=0
  else
    if [[ "${REQUEST_SNAP_DELETE_PLAN:-0}" -eq 1 ]]; then
      SFF_DELETE_PLAN=1
    fi
  fi

  if [[ "${DESTROY_SNAPSHOTS_ALLOWED:-1}" -eq 0 ]]; then
    if [[ "${REQUEST_DESTROY_SNAPSHOTS:-0}" -eq 1 ]]; then
      # Defer printing the yellow notice until destroy-plan/apply output so it
      # appears near the destroy messages (callers should invoke
      # `print_destroy_disabled_notice` before printing destroy lines).
      DESTROY_DISABLED_NOTICE=1
    fi
    DESTROY_SNAPSHOTS=0
  else
    if [[ "${REQUEST_DESTROY_SNAPSHOTS:-0}" -eq 1 ]]; then
      DESTROY_SNAPSHOTS=1
    fi
  fi

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
  _isp_build
  _isp_debug_print
  _isp_finalize
}

# Helpers split from initialize_search_parameters to keep function sizes small
function _isp_build() {
  # Build file pattern string from -f arguments and normalize dataset path
  build_file_pattern
  _normalize_dataset_fs "$DATASETPATH"
}

function _isp_debug_print() {
  [[ $VERBOSE == 1 ]] && echo -e "${GREY}Initializing search parameters...${NC}"
  [[ $VERBOSE == 1 ]] && echo -e "${GREY}Dataset path: $DATASETPATH_FS${NC}"
  [[ $VERBOSE == 1 ]] && echo -e "${GREY}File pattern: $FILENAME${NC}"
  [[ $VERBOSE == 1 ]] && echo -e "${GREY}Snapshot regex: $SNAPREGEX${NC}"
  [[ $VERBOSE == 1 ]] && echo -e "${GREY}Recursive flag: $RECURSIVE${NC}"
}

function _isp_finalize() {
  # Ensure compare mode implies recursive discovery for safety
  _ensure_compare_recursive

  # Discover datasets based on recursive flag
  discover_datasets "$DATASETPATH" "$RECURSIVE"

  # Compute trailing wildcard counts and base dataset depth
  _compute_trailing_wildcard_counts
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
      # Use mapfile for Bash 4.2 compatibility and to safely read lines into an array
      mapfile -t tmp_datasets < <(zfs list -rH -o name "${datasetpath%/}" 2>/dev/null | tail -n +2)
    else
      # Include only the specified dataset
      mapfile -t tmp_datasets < <(zfs list -H -o name "${datasetpath%/}" 2>/dev/null)
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
      echo -e "Discovered datasets: ${WHITE}${ds_disp[*]}${NC}"
    fi

    # Restore disabled globbing
    set -f
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

# Helpers to split initialize_search_parameters for Phase 2
# Normalize dataset filesystem path with leading slash for later filesystem operations
function _normalize_dataset_fs() {
  # Args: datasetpath
  DATASETPATH_FS="$1"
  DATASETPATH_FS="${DATASETPATH_FS#/}"
  DATASETPATH_FS="/${DATASETPATH_FS}"
}

function _ensure_compare_recursive() {
  # If compare mode requested, ensure recursive discovery
  if [[ $COMPARE -eq 1 && $RECURSIVE -ne 1 ]]; then
    echo -e "${YELLOW}Compare mode requires full dataset discovery; enabling recursive discovery (-r) for accurate results.${NC}"
    RECURSIVE=1
  fi
}

function _compute_trailing_wildcard_counts() {
  ##
  # CUSTOM CODE BEGIN
  # WARNING disabling file globbing so it doesn't expand into the pathnames when 
  #   you set them to a var. If you add any code that needs it reenabled, you
  #   will either need to process those before this line and set needed data to 
  #   a var there, or reenable it after this code block
  set -f
  DSP_CONSTITUENTS_ARR=() # Explicitly initialize as empty array
  DSP_CONSTITUENTS_ARR=($(echo "$DATASETPATH" | tr '/' '\n'))
  DSP_CONSTITUENTS_ARR_CNT=${#DSP_CONSTITUENTS_ARR[@]}
  # count how many trailing asterisks
  # walk array backwards, using c style
  for (( idx=${#DSP_CONSTITUENTS_ARR[@]}-1; idx>=0; idx-- ));  do
    VAL=${DSP_CONSTITUENTS_ARR[$idx]}
    # get id of the last dir before the trailing wildcards (-1 is because it stops
    #   on the dir after the last specified folder, subtract that also)
    TRAILING_WILDCARD_CNT=$(( DSP_CONSTITUENTS_ARR_CNT - idx - 1 ))
    # shellcheck disable=SC2034
    BASE_DSP_CNT=$(( DSP_CONSTITUENTS_ARR_CNT - TRAILING_WILDCARD_CNT ))
    # stop on last specified folder (first since we're reverse sorted array)
    [[ $VAL != "*" ]] && break
  done
  set +f
  # CUSTOM CODE END (moved inside a function)
  ##
}

## Print a validated, human-readable comparison summary from a CSV
# Args: summary_csv
function print_comparison_summary() {
  local summary_csv="$1"
  [[ -z "$summary_csv" || ! -f "$summary_csv" ]] && return 0
  local esc
  esc=$(printf '\033')
  # Use awk to strip ANSI sequences from the value column, validate numeric
  # values and print either the number or an INVALID marker to avoid silent
  # corruption when CSV values are contaminated.
  awk -F, -v esc="$esc" '
    NR>1 {
      key=$1; val=$2;
      gsub(esc "\\[[0-9;]*[mK]", "", val);
      if (key=="total_snapshot_entries") {
        if (val ~ /^[0-9]+$/) print "Total snapshot entries processed: " val;
        else print "Total snapshot entries processed: INVALID(" val ")";
      } else if (key=="ignored_entries") {
        if (val ~ /^[0-9]+$/) print "Total ignored entries: " val;
        else print "Total ignored entries: INVALID(" val ")";
      } else if (key=="found_in_live") {
        if (val ~ /^[0-9]+$/) print "Total found in live dataset: " val;
        else print "Total found in live dataset: INVALID(" val ")";
      } else if (key=="missing") {
        if (val ~ /^[0-9]+$/) print "Total live missing (exists in snapshot-only): " val;
        else print "Total live missing (exists in snapshot-only): INVALID(" val ")";
      } else if (key=="skipped_duplicates") {
        if (val ~ /^[0-9]+$/) print "Total skipped (duplicates): " val;
        else print "Total skipped (duplicates): INVALID(" val ")";
      }
    }' "$summary_csv"
}
