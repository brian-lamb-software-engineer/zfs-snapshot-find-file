#!/bin/bash
# Common variables, constants, and utility functions

FILESTR=()

ZFSSNAPDIR=".zfs/snapshot"
FILENAME="*"
RED='\033[0;31m'
YELLOW='\033[33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

IGNORE_REGEX_PATTERNS=(
  "^.*\.cache/.*$" # Example 1: Ignore cache directories
  "^.*/tmp/.*$" # Example 2: Ignore temporary directories
  "^.*/\.DS_Store$" # Example 3: Ignore macOS specific files
  "^.*/thumbs\.db$" # Example 4: Ignore Windows specific thumbnail files
)

all_snapshot_files_found_tmp=$(mktemp)

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

function help(){
  echo
  echo "A ZFS snapshot search tool.
    - Uses a constructed 'find' command to search in specified(or all) snaps, for specified file, recursively.
    - Has the ability to search for multiple or all snaps in a given dataset by using wildcard.
    - Has the ability to search file names by wildcard and maybe other regex calls
    - Has the ability to search for multiple files in the same run by specifying multiple files (faster than running multiple times).
    - Has the ability to search in child datasets snaps(all) when -r option is specified, or when wildcard dirs are specified for dataset, e.g. dataset/*, dataset/*/*, etc..
    "
  echo "USAGE:
    snapshots-find-file
    -c (compare snapshot files to live dataset files to find missing ones)
    -d <dataset-path to search through>,
    -f <file-your-searching-for another-file> (multiple space separated allowed),
    -o <other-file-your-searching--for>
    -s <snapshot-name-regex-term>,
    -r (recursively search into child datasets)
    -v (verbose output),
    -h (this help)
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
  exit 1;
}

function parse_arguments() {
  # CRUCIAL FIX: Reset OPTIND to 1 before calling getopts.
  # This ensures getopts always starts parsing from the first argument,
  # preventing issues where it might skip arguments if OPTIND was previously modified.
  local OPTIND=1
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
         FILENAME="${OPTARG}" ;;
      o) # echo "Running -$ARG flag which is a placeholder to pass another file to also search for"
         # echo "-$ARG arg is $OPTARG"
         OTHERFILE=$OPTARG ;;
      r)
         RECURSIVE=1 ;;
      c)
         COMPARE=1 ;;
      h) help ;;
      :) echo "argument missing" ;;
      \?) echo "Something is wrong" ;;
    esac
  done

  # set back $1 index
  shift "$((OPTIND-1))"

  #if [[ -z $DATASETPATH ]] || [[ -z $FILENAME ]]; then
  if [[ -z $DATASETPATH ]]; then
    echo "You must specify atleast -d , exiting, bye!"
    help
    exit 1
  fi

}

function initialize_search_parameters() {

  local splitArr

  # split the FILENAME param, which may come in as a space separated argument value, that will be split into an array for passing to find command using -o -name for each addition, but not the first
  read -r -a splitArr <<<"$FILENAME"

  #iterate -f files to build the proper find command for them (appends -o -name for each addtnl)
  for i in "${!splitArr[@]}"; do
    if [[ "$i" -eq 0 ]]; then
      FILESTR="${splitArr[$i]}"
    else
      FILESTR+=" -o -name ${splitArr[$i]}"
    fi
  done

  # Discover datasets based on recursive flag, by iterating snapshot paths
  #for snappath in ${DATASETPATH%/}/$ZFSSNAPDIR/*; do
  #for snappath in ${DATASETPATH%/}/$ZFSSNAPDIR; do
  # Ensure globbing is enabled for 'zfs list' command that populates DATASETS
  # (it should be by default, but explicitly setting +f here if it was turned off globally)
  # Ensure globbing is on for zfs list and SNAPREGEX assignment
  set +f

  # Explicitly clear the DATASETS array before populating it
  DATASETS=()

  #Use a temporary array for robust population, then assign to global DATASETS
  local -a tmp_datasets

  if [[ $RECURSIVE == 1 ]];  then
    # assigns the output as a single string to DATASETS, but we prob want an array
    #DATASETS=$(zfs list -rH -o name ${DATASETPATH%/})
    # Use array assignment to ensure DATASETS is treated as an array
    # and handles potential newlines in zfs output robustly.
    #IFS=$'\n' read -r -d '' -a DATASETS < <(zfs list -rH -o name "${DATASETPATH%/}" | tail -n +2) # Added tail -n +2 to skip header
    IFS=$'\n' read -r -d '' -a tmp_datasets < <(zfs list -rH -o name "${DATASETPATH%/}" 2>/dev/null | tail -n +2)
    # Populate DATASETS array directly using command substitution and tail to skip header
    #DATASETS=($(zfs list -rH -o name "${DATASETPATH%/}" | tail -n +2))
  else
    #DATASETS=$(zfs list -H -o name ${DATASETPATH%/})
    # Use array assignment to ensure DATASETS is treated as an array
    # and handles potential newlines in zfs output robustly.
    #IFS=$'\n' read -r -d '' -a DATASETS < <(zfs list -H -o name "${DATASETPATH%/}" | tail -n +2) # Added tail -n +2 to skip header
    IFS=$'\n' read -r -d '' -a tmp_datasets < <(zfs list -H -o name "${DATASETPATH%/}" 2>/dev/null | tail -n +2)
    # Populate DATASETS array directly using command substitution and tail to skip header
    #DATASETS=($(zfs list -H -o name "${DATASETPATH%/}" | tail -n +2))
  fi
  # Assign the temporary array content to the global DATASETS array
  DATASETS=("${tmp_datasets[@]}")

  ##
  # CUSTOM CODE BEGIN
  # WARNING disabling flie globbing so it doesnt expand into the pathnames when you set them to a var. so if you add any code that needs it reenabled you will either need to process those before this line and set needed data to a var there, or reenable it after this code block
  set -f
  # get count of specified datasetpath path depth
  #DSP_CONSTITUENTS_ARR=($(echo "$DATASETPATH" | tr '/' '\n'))
  #DSP_CONSTITUENTS_ARR_CNT=${#DSP_CONSTITUENTS_ARR[@]}
  DSP_CONSTITUENTS_ARR=() # Explicitly initialize as empty array
  DSP_CONSTITUENTS_ARR=($(echo "$DATASETPATH" | tr '/' '\n'))
  DSP_CONSTITUENTS_ARR_CNT=${#DSP_CONSTITUENTS_ARR[@]}
  #echo "dsp constituents arr: ${DSP_CONSTITUENTS_ARR[*]}"
  # echo "dsp constituents arr cnt: ${#DSP_CONSTITUENTS_ARR[*]}"
  # count how many trailing asterisks
  # walk array backwards, using c style
  for (( idx=${#DSP_CONSTITUENTS_ARR[@]}-1; idx>=0; idx-- ));  do
    VAL=${DSP_CONSTITUENTS_ARR[$idx]}
    # echo "id($idx) val:($VAL)"
    # get id of the last dir before the trailing wildcards (-1 is because it stops on the dir after the last specified folder, subtract that also)
    TRAILING_WILDCARD_CNT=$(( $DSP_CONSTITUENTS_ARR_CNT - $idx -1 ))
    BASE_DSP_CNT=$(( $DSP_CONSTITUENTS_ARR_CNT - $TRAILING_WILDCARD_CNT ))
    # stop on last specified folder (first since were reverse sorted array)
    [[ $VAL != "*" ]] && break
  done
  set +f
  # CUSTOM CODE END (moved inside a function)
  ##
}
