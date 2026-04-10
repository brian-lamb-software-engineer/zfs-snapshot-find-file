#!/bin/bash
# common code lives on this file, code that all the other libs use, as well as main vars

#########################
# TOP VARS / CONSTANTS
# adjust these to change the configuration
##

# Plan-only delete flag (creates a destroy plan but does not execute it).
# NOTE: This is a config-level setting. Default is 0 (disabled).
# To generate plans at runtime pass --create-destroy-plan or --clean-snapshots
#  or set CREATE_DELETE_PLAN=1 in this file to make plan-generation the default.  
#  It will not destroy data, it will only print you a plan to do as such .
CREATE_DELETE_PLAN=1
# Master destroy execution flag (must be explicitly enabled in config).
# WARNING: This is the master switch for destructive execution. Do NOT
# enable it via runtime flags — edit this file to set `ALLOW_DESTROY_SNAPS=1`.
ALLOW_DESTROY_SNAPS=0
# Deletion / destroy flags (safe defaults), enables --force to the destroy command
ENABLE_ZFS_DESTROY_FORCE=0
# shellcheck disable=SC2034
# Intentionally not referenced in this file; used by callers/tests.
# shellcheck disable=SC2034
# (keeps shellcheck quiet about intentionally-unused config vars)

# Runtime request (tracking var) flag indicating the user requested destroy/apply for this run (e.g., via env/CLI). Actual destructive execution still requires the master ALLOW_DESTROY_SNAPS config to be enabled. 
# Preserve any environment-provided request flag so callers can set it with
# `REQUEST_ALLOW_DESTROY_SNAPS=1 ./snapshots-find-file ...` or `export REQUEST_ALLOW_DESTROY_SNAPS=1`.
# 
REQUEST_ALLOW_DESTROY_SNAPS=${REQUEST_ALLOW_DESTROY_SNAPS:-0}
# When a destroy execution was requested but the top-level master flag is disabled,
# set this so callers can emit a yellow notice near destroy-plan/apply output.
NOTIFY_DESTROY_IS_DISABLED=0
# Request runtime flag to opt-in zfs-diff fast path in the the compare/cleanup flow (when present, prefer zfs diff fast-path over find) 
# when set the tool will attempt zdiff and fall back to the legacy find path on per-dataset failure.
USE_ZDIFF=${USE_ZDIFF:-0}
SMART_DIFF=0
# shellcheck disable=SC2034
# `USE_ZDIFF` and `SMART_DIFF` are set/read across files; keep top-level declaration.
# Capture top-level allow flags so CLI args cannot override when intentionally disabled.
# Set these to 0 here to permanently disable plan/apply unless this file is edited.
ALLOW_CREATE_DELETE_PLAN=${CREATE_DELETE_PLAN}
ALLOW_DESTROY_SNAPS=${ALLOW_DESTROY_SNAPS}
# Default log/tmp directory root for sff artifacts (per-run subdir includes SHORT_TIMESTAMP)
# Allow environment override: if LOG_DIR_ROOT is already exported, keep it.
# We place run artifacts under ${LOG_DIR_ROOT}/${SHORT_TIMESTAMP}/ so filenames themselves need not include the timestamp.
LOG_DIR_ROOT="${LOG_DIR_ROOT:-/tmp/sff}"
# Prefix for temporary files created by this tool
SFF_TMP_PREFIX="sff_"
# ZFS snapshot dir constant
# shellcheck disable=SC2034
ZFSSNAPDIR=".zfs/snapshot"

# REGEX_IGNORE_PATTERNS_DEFAULT, By default, ignore these common filesystem noise patterns. Users may override
# Example 1: Ignore cache directories
# Example 2: Ignore temporary directories
# Example 3: Ignore macOS specific files
# Example 4: Ignore Windows specific thumbnail files
REGEX_IGNORE_PATTERNS_DEFAULT=("^.*\\.cache/.*$" "^.*/tmp/.*$" "^.*/\\.DS_Store$" "^.*/thumbs\\.db$")
# how many results you want back from -l option to list largest snapshots
LIST_AMOUNT=15

# Color codes for output
COL=$'\033['
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
PINK="${COL}1;35m"

# Export configuration flags so they are visible to sourced modules and to
# silence static analysis (shellcheck) about intentionally-declared globals.
export ENABLE_ZFS_DESTROY_FORCE BENCH SKIP_PLAN QUIET OTHERFILE USE_ZDIFF SMART_DIFF

#####
# Internal runtime globals
#  populated at runtime — not user-configurable"
#  leave them as non-exported globals.
##

# User-supplied dataset identifier (filesystem path or ZFS name) passed via -d; normalized 
#  later for filesystem vs ZFS-name use and used as the starting point for dataset
#  discovery and processing.
DATASETPATH=""
SNAP_SEARCH_REGEX=""
RECURSIVE=0
COMPARE=0
VERBOSE=0
VVERBOSE=0
MAX_DEPTH=0
MAX_SNAPS=0
SNAPSHOT_ONLY=0
# shellcheck disable=SC2034
# `QUIET` is read by other modules; keep declaration to document config.
QUIET=0
# shellcheck disable=SC2034
# otherfile is additional filenames passed via -o, legacy and retained for compatibility 
OTHERFILE="" # Although not currently used in core logic, keep for completeness
# DATASET_SEGMNTS Integer: the number of path components in the specified dataset (used when computing trailing-wildcard counts and base dataset depth).
DATASET_SEGMNTS=0
DATASET_SEGMNT_WLDCRDS=0
BASE_DSP_CNT=0
# Default file-search pattern and arrays
#FILEARR is tokenized find args build from -f input
FILEARR=()
# the legacy single-file search pattern (defaults to *); kept for backward-compatibility when -f is not supplied as multiple entries
FILENAME="*"
FILENAME_ARR=()
FILESTR=""
# shellcheck disable=SC2034
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
# Short timestamp without year for compact filenames (MMDD-HHMMSS)
SHORT_TIMESTAMP="${TIMESTAMP:4}"
DATASETS=() # Will store the list of datasets to iterate
# shellcheck disable=SC2034
REGEX_IGNORE_PATTERNS=("${REGEX_IGNORE_PATTERNS_DEFAULT[@]}")
LOG_DIR="${LOG_DIR_ROOT%/}${SHORT_TIMESTAMP:+/${SHORT_TIMESTAMP}}"
ERROR_OCCURRED=0

############################################################
# BEGIN CODE
## 

#########################
# setup per-run artifacts
# need to ensure this is done before anything else.  If this was put into a function,
#  e.g. init_run_artifacts() would need to ensure no helper runs before main calls it.  

# Ensure the per-run directory exists early so writers can use it.
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Source zfs-specific error handlers (modularized in lib/zfs_errors.sh)
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/zfs_errors.sh" ]]; then
  # shellcheck disable=SC1090
  source "$(dirname "${BASH_SOURCE[0]}")/zfs_errors.sh"
fi

# sets the path for the run-scoped list of snapshot files, truncates or creates that file
#  (the : is a no-op; the redirection creates/truncates). Errors silenced and non-fatal
all_snapshot_files_found_tmp="${LOG_DIR}/${SFF_TMP_PREFIX}all_snapshot_files_found.log"
: > "$all_snapshot_files_found_tmp" 2>/dev/null || true

# Initialize per-run commands log with a clear header so multiple runs
# appended to the same physical logfile are easy to distinguish. We include
# an ISO-like timestamp and a dashed separator.
cmdlog_file="${LOG_DIR}/${SFF_TMP_PREFIX}commands.log"
# Also append to the root LOG_DIR_ROOT commands log for backward compatibility
# (some older runs or external helpers may append to /tmp/sff/sff_commands.log).
root_cmdlog_file="${LOG_DIR_ROOT%/}/${SFF_TMP_PREFIX}commands.log"
{
  printf '%s\n' "------------------------------------------------------------"
  printf 'RUN START: %s\n' "$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date)"
  printf 'LOG_DIR: %s\n' "$LOG_DIR"
} >> "$cmdlog_file" 2>/dev/null || true
# Mirror header to root commands log as well (no-op if same file)
if [[ "$cmdlog_file" != "$root_cmdlog_file" ]]; then
  mkdir -p "$(dirname "$root_cmdlog_file")" 2>/dev/null || true
  {
    printf '%s\n' "------------------------------------------------------------"
    printf 'RUN START: %s\n' "$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date)"
    printf 'LOG_DIR: %s\n' "$LOG_DIR"
  } >> "$root_cmdlog_file" 2>/dev/null || true
fi

# Print a compact run-vars header (only once at run start). This duplicates
# a summary to stderr for interactive users and appends a structured block
# to the per-run commands.log for auditing.
{
  # Compute compact verbose label inline (avoid calling functions not yet defined)
  if [[ ${VVERBOSE:-0} -ge 2 ]]; then
    _lbl="v3:"
  elif [[ ${VVERBOSE:-0} -ge 1 ]]; then
    _lbl="v2:"
  elif [[ ${VERBOSE:-0} -ge 1 ]]; then
    _lbl="v1:"
  else
    _lbl=""
  fi
  # Mirror a compact run-vars header to stderr only when very-verbose is enabled
  if [[ ${VVERBOSE:-0} -ge 1 ]]; then
    echo -e "${YELLOW}RUN-VARS-BEGIN${NC}" >&2
    echo -e "${_lbl} ${YELLOW}CREATE_DELETE_PLAN=${CREATE_DELETE_PLAN} ALLOW_CREATE_DELETE_PLAN=${ALLOW_CREATE_DELETE_PLAN} ALLOW_DESTROY_SNAPS=${ALLOW_DESTROY_SNAPS} ENABLE_ZFS_DESTROY_FORCE=${ENABLE_ZFS_DESTROY_FORCE} USE_ZDIFF=${USE_ZDIFF}${NC}" >&2
    echo -e "${_lbl} ${YELLOW}SKIP_ZFS_FAST=${SKIP_ZFS_FAST:-0} LOG_DIR_ROOT=${LOG_DIR_ROOT} LOG_DIR=${LOG_DIR} SFF_TMP_PREFIX=${SFF_TMP_PREFIX} ZFSSNAPDIR=${ZFSSNAPDIR}${NC}" >&2
    echo -e "${_lbl} ${YELLOW}VERBOSE=${VERBOSE} VVERBOSE=${VVERBOSE} QUIET=${QUIET}${NC}" >&2
  fi
  {
    printf 'RUN_VARS_BEGIN: %s\n' "$(date +"%Y-%m-%d %H:%M:%S")"
    printf '  CREATE_DELETE_PLAN=%s\n' "${CREATE_DELETE_PLAN}"
    printf '  ALLOW_CREATE_DELETE_PLAN=%s\n' "${ALLOW_CREATE_DELETE_PLAN}"
    printf '  ALLOW_DESTROY_SNAPS=%s\n' "${ALLOW_DESTROY_SNAPS}"
    printf '  ENABLE_ZFS_DESTROY_FORCE=%s\n' "${ENABLE_ZFS_DESTROY_FORCE}"
    printf '  USE_ZDIFF=%s\n' "${USE_ZDIFF}"
    printf '  SKIP_ZFS_FAST=%s\n' "${SKIP_ZFS_FAST:-0}"
    printf '  LOG_DIR_ROOT=%s\n' "${LOG_DIR_ROOT}"
    printf '  LOG_DIR=%s\n' "${LOG_DIR}"
    printf '  SFF_TMP_PREFIX=%s\n' "${SFF_TMP_PREFIX}"
    printf '  ZFSSNAPDIR=%s\n' "${ZFSSNAPDIR}"
    printf '  VERBOSE=%s VVERBOSE=%s QUIET=%s\n' "${VERBOSE}" "${VVERBOSE}" "${QUIET}"
  } >> "$cmdlog_file" 2>/dev/null || true
}


##################
# BEGIN FUNCTIONS

function help(){
  cat <<'HELP'
Usage: snapshots-find-file [ options ]
Options are:
[ -c (compare) ] [ -d <dataset> ] [ -f <file> ] [ -o <otherfile> ] [ -s <snap_regex> ] [ -r (recursive) ] [ -v | -vv | -vvv ] [ -q (quiet) ] [ -z (use zdiff instead of find) ] [ -D (--smart-diff) ] [ -S (show dataset avail space) ] [ -l list largest snapshots) ] [ --max-depth <n> ] [ --max-snaps <n> | -m <n> ]

A ZFS snapshot search tool.
  - Uses a constructed 'find'or zfs diff  command to search in specified snapshot for specified file, recursively by default or compare snapshots and live datasets.
  - Has the ability to search through multiple or all "snapshots" in a given dataset by using wildcard.
  - Has the ability to search for "files" (in snapshots) by wildcard, and maybe other regex calls
  - Has the ability to search for multiple files in the same run by specifying multiple (space separated) files (it's faster than running multiple times).
  - Has the ability to search in child datasets snapshots (all) when -r option is specified, or when wildcard dirs are specified for dataset, e.g. dataset/*, dataset/*/*, etc..
  - Has the ability to compare snapshots directly or snapshots to live dataset (-c option)
  - Has the ability to manage snapshots, prune/delete them, or give you a destroy command that you can run your self

USAGE:
  snapshots-find-file

  # required params
  -d (required) <dataset-path to search through>

  # optional params
  -c (optional) (compare snapshot files to live dataset files to find missing ones)
     (this shifts the mode of the program to find missing files compared from specified live dataset to a snapshot, as opposed to just finding a file in a snapshot)
      Use with or without `-c`, `--create-destroy-plan` (`-p`) or `--clean-snapshots` to prefer `zdiff` over `find`-based compare. The tool will fall back to the legacy `find` flow when `zfs` is unavailable or a per-dataset `zdiff` fails. Logs and fallback reasons are recorded in the per-run `commands.log` under `LOG_DIR`.

  -f (optional) <file-your-searching-for another-file-here> (multiple space separated allowed)

  -l (optional) list largest snapshot for specified dataset (use with -d) 
  -o (optional) <other-file-your-searching--for>

  -q (optional) quiet mode, supresses per-file lines while retaining summary and logs

  -s (optional) <snapshot-name-regex-term> (will search all if not specified)

  -r (optional) (recursively search into child datasets)

  -v (optional) (verbose output). Use `-vv` or `--very-verbose` for very-verbose tracing (prints function entries).

  -z (optional) use the ZFS `zdiff` (`zfs diff`) fast-path for comparisons when available.

  # uppercase params
  -C, --snap-only-compare (optional) run snapshot-only comparisons (pairwise snapshot diffs) instead of file-search; required by `--max-snaps`.

  -S (optional) List ZFS space and List largest snapshot in results (use with -d)

  # long params 
  --create-destroy-plan (optional) orchestrate cleanup and write a destroy-plan (dry-run). This flag only generates a plan and does not attempt to apply it.

  --clean-snapshots (optional) run cleanup and attempt to apply suggested snapshot deletions. This flag requests execution of the generated destroy plan; actual destructive execution still requires `ALLOW_DESTROY_SNAPS=1` in `lib/common.sh` (master guard).

  --force (optional) when used with destroy will add -f to zfs destroy commands in generated plan

  -D, --smart-diff (optional) enable smart diff mode for cleanup compare: perform extra content validation for M/R entries and ignore only proven same-content moves or metadata-only differences.

  --skip-plan (optional) skip cleanup/plan generation for this run even if CREATE_DELETE_PLAN=1

    Additional utility flags (non-destructive):

    - `--show-space`, `-S` : show ZFS dataset/pool available space using `zfs list -o name,avail` for the target dataset (requires `-d`).
    - `--list-largest`, `-l` : list largest snapshots for the target dataset using `zfs list -t snapshot -o name,used,creation` sorted by `used` (requires `-d`).
    - `--max-snaps <n>`, `-m <n>` : plan to keep only the newest <n> snapshots per-dataset; when used with `--create-destroy-plan` the tool will probe consecutive snapshots (oldest->newest) via `zfs diff` and mark older snapshots that are identical to their successor for deletion (plan-only). Use `--clean-snapshots` to request applying the generated plan (still gated by ALLOW_DESTROY_SNAPS).
   -h (this help)

Notes for deletion:
  - By default no destroys are executed. To generate a plan use `--create-destroy-plan` (plan-only). To request applying a generated plan in the same run, use `--clean-snapshots` (execution requested). Note: actual execution is gated by the `ALLOW_DESTROY_SNAPS` master switch in `lib/common.sh`.
  # To attempt to apply destroys enable `ALLOW_DESTROY_SNAPS=1` in `lib/common.sh` and then
    # re-run with `--clean-snapshots` to request execution of the generated plan (or use
    # `--create-destroy-plan` to only generate a plan). Applying a generated
    # plan requires enabling the master switch and confirming the interactive prompt.
  - You can also use --force to include '-f' on generated '/sbin/zfs destroy' commands in the plan.

  -r recursive search, searches recursively to specified dataset. Overrides dataset trailing wildcard paths, so does not obey the wildcard portion of the paths.  E.g. /pool/data/set/*/*/* will still recursively search in all /pool/data/set/. However, wildcards that aren't trailing still function as expected.  E.g. /pool/*/set/ will correctly still recurse through all datasets in /pool/data/set, where /pool/*/set/*/* will still recurse through the same, as the trailing wildcards are not obeyed when -r is used

HELP
  help_usage_examples
  exit 1;
}

function help_usage_examples() {
  cat <<'EXAMPLES'
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

  # Deletion examples — plan and force (apply requires enabling ALLOW_DESTROY_SNAPS in config)
  # generate a destroy plan (dry-run) for index.html in /nas/live/cloud
  snapshots-find-file -c -d "/nas/live/cloud" --create-destroy-plan -s "*" -f "index.html"
  # same using short flag -p for plan-only
  snapshots-find-file -c -d "/nas/live/cloud" -p -s "*" -f "index.html"

  # compare with smart-diff enabled to ignore only proven metadata-only M/R churn
  snapshots-find-file -c -D -v -d "/nas/live/cloud" -s "*" -f "index.html"

  # To apply a generated plan interactively, enable ALLOW_DESTROY_SNAPS=1 in lib/common.sh,
  # then re-run with --clean-snapshots to request execution of the generated plan (or use
  # --create-destroy-plan to only generate a plan). After confirmation the plan may be executed.
  # force destroy in generated plan (adds -f to zfs destroy when executed)
  snapshots-find-file -c -d "/nas/live/cloud" --create-destroy-plan --force -s "*" -f "index.html"

  # advanced: call cleanup function directly for a subset of datasets (debug)
  bash -lc 'source ./lib/common.sh; source ./lib/zfs-cleanup.sh; identify_and_suggest_snapshot_deletion_candidates "/nas/live/cloud" "/nas/live/cloud/tcc"'

  # Additional utility examples:

  # List largest snapshots for a dataset (shows top used snapshots):
  snapshots-find-file -d "/pool/data/set" --list-largest -l

  # Show ZFS available space for the target dataset:
  snapshots-find-file -d "/pool/data/set" --show-space -S

  # Snapshot-only compare mode (pairwise snapshot diffs) — useful with --max-snaps:
  snapshots-find-file -d "/pool/data/set" -C -z --max-snaps 10 --create-destroy-plan

Note: Dataset may be specified as either a ZFS name (e.g. pool/dataset) or a filesystem path (e.g. /pool/dataset). The tool normalizes both forms; prefer the filesystem path form (leading '/').
EXAMPLES
}

function help_error_response() {
  local opt="${1:-}";
  echo
  help_usage_examples
  echo
  echo -e "${YELLOW}Error: Unrecognized option: ${opt}${NC}"
  exit 1
}

function help_conflict_response() {
  local opt_a="${1:-}"; local opt_b="${2:-}"
  echo
  help_usage_examples
  echo
  echo -e "${YELLOW}Error: Conflicting options: ${opt_a} and ${opt_b} cannot be combined.${NC}"
  exit 1
}

# Counter for recorded found files across the run
found_files_count=0

# Record a found file to the global snapshot list and increment the counter
function record_found_file() {
  local file="$1"
  # If MAX_DEPTH is set, record the parent directory truncated to that depth
  if [[ -n "${MAX_DEPTH:-0}" && ${MAX_DEPTH} -gt 0 ]]; then
    local dir
    dir=$(dirname "$file")
    # remove leading slash for processing
    local trim
    trim="${dir#/}"
    IFS='/' read -r -a parts <<< "$trim"
    local cnt=${#parts[@]}
    local rec
    if [[ $cnt -le ${MAX_DEPTH} ]]; then
      rec="/${trim}"
    else
      # join first N parts
      rec="/$(printf "%s/" "${parts[@]:0:${MAX_DEPTH}}" | sed 's:/$::')/*"
    fi
    # Deduplicate: only append if not already recorded
    if ! grep -Fxq "$rec" "$all_snapshot_files_found_tmp" 2>/dev/null; then
      echo "$rec" >> "$all_snapshot_files_found_tmp"
      ((found_files_count++))
    fi
  else
    echo "$file" >> "$all_snapshot_files_found_tmp"
    ((found_files_count++))
  fi
}

# Verbose tracing helper: prints when VVERBOSE is enabled
function vlog() {
  # Emit function/entry tracing when either -v or -vv is enabled so users
  # see which functions are running with a simple `-v`. Preserve the
  # more detailed internals output for -vvv (VVERBOSE>=2).
  if [[ ${VERBOSE:-0} -ge 1 || ${VVERBOSE:-0} -ge 1 ]]; then
    # Send verbose tracing to stderr so command-substitutions that capture
    # function output are not polluted by debug text.
    # Auto-prefix messages with calling script and function so callers do not
    # need to redundantly include filenames or function names everywhere.
    local caller_func="${FUNCNAME[1]:-MAIN}"
    local caller_file
    caller_file=$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")
    local msg="$*"
    # Label the entry line according to the highest active level.
    local _vlabel_entry
    _vlabel_entry=$(label_for_level 2)
    if [[ -z "$msg" ]]; then
      echo -e "${_vlabel_entry} ${BLUE}${caller_file}::${caller_func}${NC}" >&2
    else
      echo -e "${_vlabel_entry} ${BLUE}${caller_file}::${caller_func}: ${NC}${msg}" >&2
    fi

    # For -vvv, emit a compact timestamped internals line (no VVV label)
    # that includes caller, PID and selected top-level run-vars for quick
    # debugging. Then print caller file::function:line via show_call_context.
    if [[ ${VVERBOSE:-0} -ge 2 ]]; then
      local _ts
      _ts=$(date +"%Y-%m-%dT%H:%M:%S%z")
      # Use v3 label for internals so v3-only lines show 'v3:' distinct from v2.
      local _vlabel_internals
      _vlabel_internals=$(label_for_level 3)
      echo -e "${_vlabel_internals}${GREY}${_ts}${NC} ${WHITE}${caller_file}::${caller_func}${NC} pid=${$} LOG_DIR=${LOG_DIR} LOG_DIR_ROOT=${LOG_DIR_ROOT} SFF_TMP_PREFIX=${SFF_TMP_PREFIX} ZFSSNAPDIR=${ZFSSNAPDIR} USE_ZDIFF=${USE_ZDIFF:-0} SKIP_ZFS_FAST=${SKIP_ZFS_FAST:-0} CREATE_DELETE_PLAN=${CREATE_DELETE_PLAN:-0} QUIET=${QUIET:-0}" >&2
      show_call_context "${_vlabel_internals}" >&2
    fi
  fi
}


# Show a compact caller context (file::function:line). Call from functions
# when they want to emit which function is active. Example usage inside a
# function: [[ ${VVERBOSE:-0} -ge 2 ]] && show_call_context
function show_call_context() {
  # Optional first arg is a label prefix (e.g. 'v3:') to print before the context.
  local _label="${1:-}"
  local caller_func="${FUNCNAME[1]:-MAIN}"
  local caller_file
  caller_file=$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")
  local caller_line="${BASH_LINENO[0]:-0}"
  # Print the line as `line:<n>` to make the meaning explicit
  echo -e "${_label}${GREY}${caller_file}::${caller_func} line:${caller_line}${NC}"
}

# Return verbosity label: v1 for -v, v2 for -vv, v3 for -vvv; empty otherwise
function verbose_label() {
  # Return a single highest label (not cumulative). This is used for
  # compact run headers where a single indicator is preferable.
  if [[ ${VVERBOSE:-0} -ge 2 ]]; then
    printf 'v3:'
  elif [[ ${VVERBOSE:-0} -ge 1 ]]; then
    printf 'v2:'
  elif [[ ${VERBOSE:-0} -ge 1 ]]; then
    printf 'v1:'
  else
    printf ''
  fi
}

# Return a label only for the requested level if that level is active.
# Usage: label_for_level 1  -> prints 'v1:' if VERBOSE
#        label_for_level 2  -> prints 'v2:' if VVERBOSE>=1
#        label_for_level 3  -> prints 'v3:' if VVERBOSE>=2
function label_for_level() {
  local lvl=${1:-}
  case "$lvl" in
    1)
      [[ ${VERBOSE:-0} -ge 1 ]] && printf 'v1:' || printf '' ;;
    2)
      [[ ${VVERBOSE:-0} -ge 1 ]] && printf 'v2:' || printf '' ;;
    3)
      [[ ${VVERBOSE:-0} -ge 2 ]] && printf 'v3:' || printf '' ;;
    *) printf '' ;;
  esac
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
# top-level `ALLOW_DESTROY_SNAPS` is disabled. Callers (cleanup) should
# invoke this just above any destroy-plan messages so the notice appears in
# proximity to the destroy output.
function print_NOTIFY_DESTROY_IS_DISABLED() {
  if [[ "${NOTIFY_DESTROY_IS_DISABLED:-0}" -eq 1 ]]; then
    echo -e "${YELLOW}Note: Destroy execution requested but 'ALLOW_DESTROY_SNAPS' is disabled in configuration.${NC}"
  fi
}

# function too long, break up
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
    # honor explicit long-form for verbosity levels
    if [[ "$_a" == "--vvv" || "$_a" == "--very-very-verbose" ]]; then
      _v_count=$(( _v_count + 3 )); continue
    fi
    if [[ "$_a" == "--very-verbose" || "$_a" == "--vv" ]]; then
      _v_count=$(( _v_count + 2 )); continue
    fi
    # If a short-form token contains 'd' or 'f' combined with other letters (eg '-dqz' or '-qfX'),
    # warn the user — '-d' and '-f' must be provided as standalone tokens followed by their
    # respective arguments (e.g. `-d /pool/dataset` and `-f index.html`). Combined short flags
    # confuse getopts parsing and may consume the wrong token as the option value.
    if [[ "$_a" == -?* && "$_a" != --* && ${#_a} -gt 2 ]]; then
      if [[ "$_a" == *d* || "$_a" == *f* ]]; then
        echo -e "${YELLOW}Error: -d and -f must be separate tokens and placed immediately before their argument.\nExample: snapshots-find-file -d /pool/data/set -f index.html --create-destroy-plan${NC}" >&2
        exit 1
      fi
    fi
    # only consider short-form args that start with a single dash
    if [[ "$_a" == -* && "$_a" != --* ]]; then
      # count 'v' characters in the token
      local _v_only
      _v_only=${_a//[^v]/}
      _v_count=$(( _v_count + ${#_v_only} ))
    fi
  done
  # Support long-form options by pre-scanning and removing them from positional args
  local new_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -vv)
        VVERBOSE=1; shift ;;
      --show-space)
        SHOW_SPACE=1; shift ;;
      --list-largest)
        LIST_LARGEST=1; shift ;;
      -list-largest)
        LIST_LARGEST=1; shift ;;
      -show-space)
        SHOW_SPACE=1; shift ;;
      --max-depth)
        if [[ -n "$2" && "$2" != --* ]]; then
          MAX_DEPTH=$2; shift 2
        else
          echo -e "${RED}Error: --max-depth requires a numeric argument${NC}" >&2; exit 1
        fi ;;
      --max-snaps)
        if [[ -n "$2" && "$2" != --* ]]; then
          MAX_SNAPS=$2; shift 2
        else
          echo -e "${RED}Error: --max-snaps requires a numeric argument${NC}" >&2; exit 1
        fi ;;
      -max-snaps)
        if [[ -n "$2" && "$2" != --* ]]; then
          MAX_SNAPS=$2; shift 2
        else
          echo -e "${RED}Error: -max-snaps requires a numeric argument${NC}" >&2; exit 1
        fi ;;
      -q|--quiet)
        QUIET=1; shift ;;
      --create-destroy-plan)
        REQUEST_SNAP_DELETE_PLAN=1; shift ;;
      --snap-only-compare)
        SNAPSHOT_ONLY=1; shift ;;
      -snap-only-compare)
        SNAPSHOT_ONLY=1; shift ;;
      --create-destroy-plan)
        REQUEST_SNAP_DELETE_PLAN=1; shift ;;
      --clean-snapshots)
        # Request full cleanup: generate a plan and request execution for this run.
        REQUEST_SNAP_DELETE_PLAN=1; REQUEST_ALLOW_DESTROY_SNAPS=1; shift ;;
      -clean-snapshots)
        REQUEST_SNAP_DELETE_PLAN=1; REQUEST_ALLOW_DESTROY_SNAPS=1; shift ;;
      --force)
        # shellcheck disable=SC2034
        ENABLE_ZFS_DESTROY_FORCE=1; shift ;;
      -D|--smart-diff)
        SMART_DIFF=1; shift ;;
      --very-verbose)
        VVERBOSE=1; VERBOSE=1; shift ;;
      --zfs-diff)
        USE_ZDIFF=1; shift ;;
      --force-find)
        # Force legacy find usage (skip zfs fast-paths) for testing/debugging
        SKIP_ZFS_FAST=1; shift ;;
      --bench)
        # shellcheck disable=SC2034
        BENCH=1; shift ;;
      --skip-plan)
        # shellcheck disable=SC2034
        SKIP_PLAN=1; shift ;;
      --*)
        help_error_response "$1"
        ;;
      *) new_args+=("$1"); shift ;;
    esac
  done
  # restore positional args for getopts
  set -- "${new_args[@]}"
  # include 'q' and 'D' in the option string so getopts recognizes them
  while getopts ":d:f:o:s:rvhcpVqDzlSm:C" ARG; do
    case "$ARG" in
      q)
        # shellcheck disable=SC2034
        QUIET=1 ;;
      v) # echo "Running -$ARG flag for verbose output"
        VERBOSE=1 ;;
      l)
        LIST_LARGEST=1 ;;
      S)
        SHOW_SPACE=1 ;;
      m)
        MAX_SNAPS=$OPTARG ;;
      C)
        SNAPSHOT_ONLY=1 ;;
      V)
        VVERBOSE=1 ;;
      d) #echo "Running -d flag which is a placeholder to pass a dataset path arg ith it"
         #echo -"$ARG arg is $OPTARG"
         DATASETPATH=$OPTARG ;;
      s) # echo "Running -$ARG flag which is a placeholder to pass a snapshot arg with it"
         # echo "-$ARG arg is $OPTARG"
         SNAP_SEARCH_REGEX=$OPTARG ;;
      f) # echo "Running -$ARG flag which is a placeholder to pass a filename arg with it"
        # echo "-$ARG arg is $OPTARG"
        FILENAME_ARR+=("${OPTARG}") ;;
      o) # echo "Running -$ARG flag which is a placeholder to pass another file to also search for"
        # echo "-$ARG arg is $OPTARG"
        # shellcheck disable=SC2034
        OTHERFILE=$OPTARG ;;
      r)
         RECURSIVE=1 ;;
      D)
        REQUEST_SNAP_DELETE_PLAN=1 ;;
      z)
        USE_ZDIFF=1 ;;
      p)
        REQUEST_SNAP_DELETE_PLAN=1 ;;
      # Bench has no short option
      # SKIP_PLAN short form not bound to a single-letter short flag (use --skip-plan)
      c)
         COMPARE=1 ;;
      h) help ;;
      :) help_error_response "-$OPTARG" ;;
      \?) help_error_response "-$OPTARG" ;;
    esac
  done

  # set back $1 index
  shift "$((OPTIND-1))"

  # Apply verbosity token count collected earlier when parsing short-form args
  # This ensures `-v`, `-vv`, `-vvv` or combined short flags like `-cvv`
  # correctly enable `VERBOSE`/`VVERBOSE` levels.
  if [[ ${_v_count:-0} -ge 3 ]]; then
    VVERBOSE=2; VERBOSE=1
  elif [[ ${_v_count:-0} -ge 2 ]]; then
    VVERBOSE=1; VERBOSE=1
  elif [[ ${_v_count:-0} -ge 1 ]]; then
    VERBOSE=1
  fi

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
  if [[ "${ALLOW_CREATE_DELETE_PLAN:-1}" -eq 0 ]]; then
    if [[ "${REQUEST_SNAP_DELETE_PLAN:-0}" -eq 1 ]]; then
      # Defer printing of the plan-generation notice until the end of the run
      # so the message appears after dataset scanning and plan output.
      NOTIFY_PLAN_GENERATION_IGNORED=1
    fi
    CREATE_DELETE_PLAN=0
  else
    if [[ "${REQUEST_SNAP_DELETE_PLAN:-0}" -eq 1 ]]; then
      CREATE_DELETE_PLAN=1
    fi
  fi

  if [[ "${ALLOW_DESTROY_SNAPS:-1}" -eq 0 ]]; then
    if [[ "${REQUEST_ALLOW_DESTROY_SNAPS:-0}" -eq 1 ]]; then
      # Defer printing the yellow notice until destroy-plan/apply output so it
      # appears near the destroy messages (callers should invoke
      # `print_NOTIFY_DESTROY_IS_DISABLED` before printing destroy lines).
      NOTIFY_DESTROY_IS_DISABLED=1
    fi
    ALLOW_DESTROY_SNAPS=0
  else
    if [[ "${REQUEST_ALLOW_DESTROY_SNAPS:-0}" -eq 1 ]]; then
      ALLOW_DESTROY_SNAPS=1
    fi
  fi

  if [[ -z $DATASETPATH ]]; then
    echo "You must specify at least -d, exiting, bye!"
    help
    exit 1
  fi

  # Warn the user if neither -f nor -s is provided
  if [[ ${SNAPSHOT_ONLY:-0} -eq 0 ]]; then
    if [[ -z $FILENAME || $FILENAME == "*" ]] && [[ -z $SNAP_SEARCH_REGEX ]]; then
      echo -e "${YELLOW}No file pattern (-f) or snapshot regex (-s) specified. Defaulting to search for all files (*).${NC}"
    fi
  fi

  # Touch/mention CLI-toggled flags here so static analysis and downstream
  # sourced modules can see these variables were intentionally read/declared.
  # These no-op references do not change values but prevent SC2034 warnings
  # about intentionally-declared global flags.
  : "${ENABLE_ZFS_DESTROY_FORCE:-${ENABLE_ZFS_DESTROY_FORCE}}" "${BENCH:-${BENCH}}" "${SKIP_PLAN:-${SKIP_PLAN}}" "${QUIET:-${QUIET}}" "${OTHERFILE:-${OTHERFILE}}" "${USE_ZDIFF:-${USE_ZDIFF}}"

  # Defensive: don't allow mutually-conflicting runtime flags
  if [[ "${USE_ZDIFF:-0}" -eq 1 && "${SKIP_ZFS_FAST:-0}" -eq 1 ]]; then
    help_conflict_response "-z/--zfs-diff" "--force-find"
  fi

  # Convert collected -v counts into levels: 1 = -v, 2 = -vv, 3+ = -vvv
  if [[ ${_v_count:-0} -ge 3 ]]; then
    VVERBOSE=2; VERBOSE=1
  elif [[ ${_v_count:-0} -ge 2 ]]; then
    VVERBOSE=1; VERBOSE=1
  elif [[ ${_v_count:-0} -eq 1 ]]; then
    VERBOSE=1
  fi

  # Ensure any explicit VVERBOSE implies VERBOSE
  if [[ "${VVERBOSE:-0}" -ge 1 ]]; then
    VERBOSE=1
  fi

  # If the user requested one-off zfs-list utilities, run them now and exit.
  if [[ "${SHOW_SPACE:-0}" -eq 1 ]]; then
    _run_zfs_list_space
    exit 0
  fi
  if [[ "${LIST_LARGEST:-0}" -eq 1 ]]; then
    _run_zfs_list_largest
    exit 0
  fi

  # If user requested max-snaps plan generation as a one-off operation,
  # generate a plan and exit (plan-only). The plan generator probes
  # consecutive snapshots (oldest->newest) and marks older snapshots
  # that are identical to their successor for deletion until only
  # MAX_SNAPS remain or no further identical candidates exist.
  if [[ ${MAX_SNAPS:-0} -gt 0 ]]; then
    if [[ ${SNAPSHOT_ONLY:-0} -ne 1 ]]; then
      echo -e "${RED}Error: --max-snaps is only valid with snapshot-only compare mode (-C or --snap-only-compare).${NC}" >&2
      help
      exit 1
    fi
    if [[ -z "$DATASETPATH" ]]; then
      echo -e "${RED}Error: --max-snaps requires -d <dataset>${NC}" >&2; help; exit 1
    fi
    if [[ ${REQUEST_SNAP_DELETE_PLAN:-0} -eq 1 ]]; then
      # Show probe results first so operators see what was found before a plan
      # is generated. Then generate the plan non-interactively (because the
      # user explicitly requested plan generation via CLI flags).
      probe_max_snaps "$DATASETPATH" "$MAX_SNAPS"
      generate_max_snaps_plan "$DATASETPATH" "$MAX_SNAPS"
      exit 0
    fi
  fi

  # If user requested only to probe MAX_SNAPS (no plan requested), run probe and print recommendation
  if [[ ${MAX_SNAPS:-0} -gt 0 ]]; then
    if [[ ${SNAPSHOT_ONLY:-0} -ne 1 ]]; then
      echo -e "${RED}Error: --max-snaps is only valid with snapshot-only compare mode (-C or --snap-only-compare).${NC}" >&2
      help
      exit 1
    fi
    if [[ -z "$DATASETPATH" ]]; then
      echo -e "${RED}Error: --max-snaps requires -d <dataset>${NC}" >&2; help; exit 1
    fi
    if [[ ${REQUEST_SNAP_DELETE_PLAN:-0} -eq 0 ]]; then
      probe_max_snaps "$DATASETPATH" "$MAX_SNAPS"
      exit 0
    fi
  fi

  # Default behavior: when compare mode (-c) is requested, prefer the
  # zfs diff fast-path unless the caller explicitly requested skipping
  # fast-paths (e.g. --force-find). This makes `-c` implicitly opt-in to
  # zdiff for convenience.
  if [[ "${COMPARE:-0}" -eq 1 && "${USE_ZDIFF:-0}" -eq 0 && "${SKIP_ZFS_FAST:-0}" -eq 0 ]]; then
    USE_ZDIFF=1
    [[ ${VERBOSE:-0} -ge 1 ]] && echo -e "${CYAN}Auto-enabled zdiff for compare mode (-c)${NC}" >&2
  fi
}

function initialize_search_parameters() {
  _isp_build
  _isp_debug_print
  _isp_finalize
}

# Non-destructive utilities: show zfs space and list-largest snapshots.
function _run_zfs_list_space() {
  local target="${DATASETPATH:-}"
  local zcmd
  # Use human-readable sizes for display and align columns
  if command -v /bin/sudo >/dev/null 2>&1; then
    zcmd=(/bin/sudo /sbin/zfs "list" "-o" "name,avail" "-rH")
  else
    zcmd=(/sbin/zfs "list" "-o" "name,avail" "-rH")
  fi
  echo -e "${CYAN}ZFS available space (target: ${target:-all}):${NC}" >&2
  local out
  if [[ -n "$target" ]]; then
    out=$("${zcmd[@]}" "$target" 2>/dev/null || true)
  else
    out=$("${zcmd[@]}" 2>/dev/null || true)
  fi
  if [[ -z "$out" ]]; then
    echo "(no datasets found)" >&2
    return 0
  fi
  # Print aligned columns: NAME (left), AVAIL (right) with NAME colored white
  printf "%-50s %12s\n" "NAME" "AVAIL"
  echo "$out" | while read -r name avail; do
    local colored_name
    colored_name="${WHITE}${name}${NC}"
    printf "%-50s %12s\n" "$colored_name" "$avail"
  done
}

function _run_zfs_list_largest() {
  local target="${DATASETPATH:-}"
  local zcmd
  if command -v /bin/sudo >/dev/null 2>&1; then
    zcmd=(/bin/sudo /sbin/zfs "list" "-t" "snapshot" "-o" "name,used,creation" "-rHp")
  else
    zcmd=(/sbin/zfs "list" "-t" "snapshot" "-o" "name,used,creation" "-rHp")
  fi
  echo -e "${CYAN}Largest snapshots for ${target}:${NC}" >&2
  # We need numeric sorting by 'used' (bytes). Use -p output and then
  # convert bytes to human-readable with numfmt for display.
  local tmp
  tmp=$({ "${zcmd[@]}" "${target}" 2>/dev/null || true; } )
  if [[ -z "$tmp" ]]; then
    echo "(no snapshots found)" >&2
    return 0
  fi
  # Show top entries (count controlled by LIST_AMOUNT)
  local limit=${LIST_AMOUNT:-22}
  echo "$tmp" | sort -k2 -nr | head -n "$limit" | while IFS=$'\t' read -r name used creation; do
    # Convert bytes to human-readable using numfmt if available
    local used_hr
    if command -v numfmt >/dev/null 2>&1; then
      used_hr=$(numfmt --to=iec --suffix=B --format="%.1f" "$used" 2>/dev/null || numfmt --to=iec "$used" 2>/dev/null || echo "$used")
    else
      used_hr=$used
    fi
    # Colorize: dataset and snapshot in WHITE, '@' separator in GREY
    local ds_part snap_part colored_name
    if [[ "$name" == *"@"* ]]; then
      ds_part="${name%@*}"
      snap_part="${name#*@}"
      colored_name="${WHITE}${ds_part}${GREY}@${WHITE}${snap_part}${NC}"
    else
      colored_name="${WHITE}${name}${NC}"
    fi
    printf "%-50s %12s %20s\n" "$colored_name" "$used_hr" "$creation"
  done
}

# Generate a plan that keeps only the newest N snapshots for a dataset.
# For safety the generator only marks an older snapshot for deletion when
# a consecutive `zfs diff <older> <newer>` produces no output (identical).
function generate_max_snaps_plan() {
  local dataset="$1"
  local keep="$2"
  # Optional 3rd arg: when set to '1' suppress the initial "Found N snapshots"
  # message (used when a probe already printed this information).
  local suppress_found_msg="${3:-0}"
  local zfs_bin
  if [[ -x /sbin/zfs ]]; then
    zfs_bin="/sbin/zfs"
  elif command -v zfs >/dev/null 2>&1; then
    zfs_bin="$(command -v zfs)"
  else
    echo "zfs not found" >&2; return 1
  fi

  # Warn early if the current user may lack privileges for zfs operations
  require_zfs_priv_for "zfs diff/list" "${dataset}" || true

  local out_plan_review out_plan_exec
  out_plan_review="${LOG_DIR}/${SFF_TMP_PREFIX}max_snaps_destroy_plan.sh.review"
  out_plan_exec="${LOG_DIR}/${SFF_TMP_PREFIX}max_snaps_destroy_plan.sh"
  : > "$out_plan_review"
  : > "$out_plan_exec"
  echo "#!/bin/bash" >> "$out_plan_exec"
  echo "# Plan: keep newest ${keep} snapshots for ${dataset}" >> "$out_plan_review"
  echo "# Plan: keep newest ${keep} snapshots for ${dataset}" >> "$out_plan_exec"

  # collect all snapshots oldest->newest using creation sort
  local -a snaps_all snaps
  mapfile -t snaps_all < <("$zfs_bin" list -t snapshot -o name,creation -H -s creation "${dataset}" 2>/dev/null | awk '{print $1}')
  local total_all=${#snaps_all[@]}
  echo
  if [[ "${suppress_found_msg}" != "1" ]]; then
    echo "Found ${total_all} snapshots for ${dataset}" >&2
  fi
  if (( total_all == 0 )); then
    echo "No snapshots found for ${dataset}" >&2
    return 0
  fi

  # select the oldest 'keep' snapshots (or fewer if not enough)
  local select_count=${keep}
  if (( select_count > total_all )); then select_count=${total_all}; fi
  snaps=("${snaps_all[@]:0:select_count}")

  local deletions=0
  local idx=0

  while (( idx < ${#snaps[@]} - 1 )); do
    local older newer outdiff
    older=${snaps[$idx]}
    newer=${snaps[$((idx+1))]}
    outdiff=$(sff_zfs_diff "$older" "$newer" 2>/dev/null || true)
    local _zdiff_rc=$?
    if [[ ${_zdiff_rc:-0} -eq 0 && -z "$outdiff" ]]; then
      # Annotate review file with commented reasoning and command
      echo "# BECAUSE: identical to ${newer}" >> "$out_plan_review"
      printf '# /sbin/zfs destroy "%s"\n' "$older" >> "$out_plan_review"
      # Append executable destroy command (with annotation) to exec plan
      echo "# BECAUSE: identical to ${newer}" >> "$out_plan_exec"
      printf '/sbin/zfs destroy "%s"\n' "$older" >> "$out_plan_exec"
      printf 'MAX_SNAPS_PLAN: %s marked for deletion (identical to %s)\n' "$older" "$newer" >> "${cmdlog_file}"
      deletions=$((deletions+1))
      # remove older from snaps array
      snaps=("${snaps[@]:0:$idx}" "${snaps[@]:$((idx+1))}")
      # do not advance idx so next pair checks new element at idx
      continue
    fi
    idx=$((idx+1))
  done

  if (( deletions == 0 )); then
    echo "No identical snapshot candidates found to reduce to ${keep}" >&2
    # clean up empty plans
    rm -f "$out_plan_review" "$out_plan_exec" 2>/dev/null || true
  else
    # Delegate plan file emission and printing to a shared helper so other
    # flows can reuse the same output formatting and ZDIFF_STDERR handling.
    emit_plan_files_and_print "$out_plan_review" "$out_plan_exec"
  fi
}

# Emit generated plan files and print review + ZDIFF_STDERR blocks.
# Args: <out_plan_review> <out_plan_exec>
function emit_plan_files_and_print() {
  local out_plan_review="$1"
  local out_plan_exec="$2"
  # make exec runnable
  chmod +x "$out_plan_exec" 2>/dev/null || true
  echo "Generated plans: review=${out_plan_review}  exec=${out_plan_exec}" >&2
  echo
  echo "--- Begin generated review plan: ${out_plan_review} ---" >&2
  sed -n '1,99999p' "$out_plan_review" >&2 2>/dev/null || cat "$out_plan_review" >&2
  echo "--- End generated review plan ---" >&2
  echo
  # Print all recorded ZDIFF_STDERR blocks from the per-run commands log in PINK
  local zdiff_blocks=""
  if [[ -f "${cmdlog_file}" ]]; then
    zdiff_blocks=$(awk 'BEGIN{pos=0} /ZDIFF_STDERR:/{pos=NR} {lines[NR]=$0} END{ if(pos){ for(i=pos;i<=NR;i++){ if(i==pos) print lines[i]; else if(lines[i] ~ /^  /) print lines[i]; else break } } }' "${cmdlog_file}" 2>/dev/null || true)
  fi
  if [[ -n "${zdiff_blocks}" ]]; then
    echo -e "${PINK}--- ZDIFF_STDERR blocks from ${cmdlog_file} ---${NC}" >&2
    while IFS= read -r l; do echo -e "${PINK}${l}${NC}" >&2; done <<< "$zdiff_blocks"
    echo -e "${PINK}--- end ZDIFF_STDERR blocks ---${NC}" >&2
    # Attempt to surface actionable help for recognized errors by querying
    # the modular zfs error handlers. Handlers expect a snippet; pass the
    # zdiff_blocks content and print any returned help text in yellow.
    if command -v zfs_error_query >/dev/null 2>&1; then
      local _help_text
      _help_text=$(zfs_error_query "$zdiff_blocks" 2>/dev/null || true)
      if [[ -n "$_help_text" ]]; then
        zfs_error_print_helper "$_help_text" "${cmdlog_file}" || true
      fi
    fi
  fi
  # If any zdiff errors occurred, print a clear fatal halt message and
  # return so callers do not proceed to prompt for or attempt execution.
  # If the commands log contains an ERROR_OCCURRED marker or any ZDIFF_STDERR
  # blocks were printed above, treat the run as errored so prompts are suppressed.
  if [[ -n "${zdiff_blocks}" ]] || { [ -f "${cmdlog_file}" ] && grep -q "^ERROR_OCCURRED:" "${cmdlog_file}" 2>/dev/null; }; then
    ERROR_OCCURRED=1
  fi
  if [[ ${ERROR_OCCURRED:-0} -eq 1 ]]; then
    echo -e "${RED}Halting: ZFS diff errors detected; aborting execution and prompts.${NC}" >&2
    echo -e "${YELLOW}Inspect commands log: ${cmdlog_file}${NC}" >&2
    return 0
  fi
  # After printing pink blocks (if any), print deferred red permission message (if any)
  print_deferred_zfs_priv_msg
}

# Ensure datasets do not exceed MAX_SNAPS by generating a destroy plan for
# the oldest snapshots beyond the requested keep count. This function only
# generates plans (comment-first review + exec script) and logs the plan
# to the per-run `commands.log`. It does not execute destroys; execution
# remains gated by `ALLOW_DESTROY_SNAPS` and interactive confirmation.
# Args: <dataset> <keep>
function ensure_max_snaps_per_dataset() {
  local dataset="$1" keep="$2"
  if [[ -z "$dataset" || -z "$keep" ]]; then
    return 1
  fi
  local zfs_bin
  if [[ -x /sbin/zfs ]]; then
    zfs_bin="/sbin/zfs"
  elif command -v zfs >/dev/null 2>&1; then
    zfs_bin="$(command -v zfs)"
  else
    echo -e "${YELLOW}zfs binary not found; cannot compute max-snaps for ${dataset}${NC}" >&2
    return 1
  fi

  local -a snaps_all snaps
  mapfile -t snaps_all < <("$zfs_bin" list -t snapshot -o name,creation -H -s creation "${dataset}" 2>/dev/null | awk '{print $1}')
  local total_all=${#snaps_all[@]}
  if (( total_all <= keep )); then
    return 0
  fi

  # snapshots to consider for deletion: the oldest (total_all - keep)
  local to_remove_count=$(( total_all - keep ))
  snaps=("${snaps_all[@]:0:to_remove_count}")

  local safe_name
  safe_name=$(echo "${dataset}" | sed 's:[/ ]:_:g')
  local out_plan_review="${LOG_DIR}/${SFF_TMP_PREFIX}maxsnaps_${safe_name}_${SHORT_TIMESTAMP}.review.sh"
  local out_plan_exec="${LOG_DIR}/${SFF_TMP_PREFIX}maxsnaps_${safe_name}_${SHORT_TIMESTAMP}.exec.sh"

  {
    echo "# ${SFF_TMP_PREFIX}max-snaps destroy-plan review: ${out_plan_review}"
    echo "# Dataset: ${dataset}  keep=${keep}  total=${total_all}  to_remove=${to_remove_count}"
    echo "# Generated: ${SHORT_TIMESTAMP}"
    echo
  } > "$out_plan_review"

  {
    echo "#!/bin/bash"
    echo "# Exec plan: remove oldest snapshots to enforce max-snaps=${keep} for ${dataset}"
    echo
  } > "$out_plan_exec"
  chmod +x "$out_plan_exec" 2>/dev/null || true

  local removed=0
  for s in "${snaps[@]}"; do
    echo "# Snapshot: ${s}" >> "$out_plan_review"
    echo "# BECAUSE: exceeds max-snaps=${keep} (oldest candidate)" >> "$out_plan_review"
    echo "# /sbin/zfs destroy ${s}" >> "$out_plan_review"
    printf '/sbin/zfs destroy "%s"\n' "$s" >> "$out_plan_exec"
    printf 'MAX_SNAPS_PLAN: %s marked for deletion (max-snaps keep=%s)\n' "$s" "$keep" >> "${cmdlog_file}" 2>/dev/null || true
    removed=$((removed+1))
  done

  if (( removed > 0 )); then
    echo "Generated max-snaps plan: review=${out_plan_review} exec=${out_plan_exec}" >&2
    emit_plan_files_and_print "$out_plan_review" "$out_plan_exec"
  else
    rm -f "$out_plan_review" "$out_plan_exec" 2>/dev/null || true
  fi
  return 0
}

# Ensure datasets do not exceed MAX_SNAPS by generating a destroy plan for
# the oldest snapshots beyond the requested keep count. This function only
# generates plans (comment-first review + exec script) and logs the plan
# to the per-run `commands.log`. It does not execute destroys; execution
# remains gated by `ALLOW_DESTROY_SNAPS` and interactive confirmation.
# Args: <dataset> <keep>
function ensure_max_snaps_per_dataset() {
  local dataset="$1" keep="$2"
  if [[ -z "$dataset" || -z "$keep" ]]; then
    return 1
  fi
  local zfs_bin
  if [[ -x /sbin/zfs ]]; then
    zfs_bin="/sbin/zfs"
  elif command -v zfs >/dev/null 2>&1; then
    zfs_bin="$(command -v zfs)"
  else
    echo -e "${YELLOW}zfs binary not found; cannot compute max-snaps for ${dataset}${NC}" >&2
    return 1
  fi

  local -a snaps_all snaps
  mapfile -t snaps_all < <("$zfs_bin" list -t snapshot -o name,creation -H -s creation "${dataset}" 2>/dev/null | awk '{print $1}')
  local total_all=${#snaps_all[@]}
  if (( total_all <= keep )); then
    return 0
  fi

  # snapshots to consider for deletion: the oldest (total_all - keep)
  local to_remove_count=$(( total_all - keep ))
  snaps=("${snaps_all[@]:0:to_remove_count}")

  local safe_name
  safe_name=$(echo "${dataset}" | sed 's:[/ ]:_:g')
  local out_plan_review="${LOG_DIR}/${SFF_TMP_PREFIX}maxsnaps_${safe_name}_${SHORT_TIMESTAMP}.review.sh"
  local out_plan_exec="${LOG_DIR}/${SFF_TMP_PREFIX}maxsnaps_${safe_name}_${SHORT_TIMESTAMP}.exec.sh"

  {
    echo "# ${SFF_TMP_PREFIX}max-snaps destroy-plan review: ${out_plan_review}"
    echo "# Dataset: ${dataset}  keep=${keep}  total=${total_all}  to_remove=${to_remove_count}"
    echo "# Generated: ${SHORT_TIMESTAMP}"
    echo
  } > "$out_plan_review"

  {
    echo "#!/bin/bash"
    echo "# Exec plan: remove oldest snapshots to enforce max-snaps=${keep} for ${dataset}"
    echo
  } > "$out_plan_exec"
  chmod +x "$out_plan_exec" 2>/dev/null || true

  local removed=0
  for s in "${snaps[@]}"; do
    echo "# Snapshot: ${s}" >> "$out_plan_review"
    echo "# BECAUSE: exceeds max-snaps=${keep} (oldest candidate)" >> "$out_plan_review"
    echo "# /sbin/zfs destroy ${s}" >> "$out_plan_review"
    printf '/sbin/zfs destroy "%s"\n' "$s" >> "$out_plan_exec"
    printf 'MAX_SNAPS_PLAN: %s marked for deletion (max-snaps keep=%s)\n' "$s" "$keep" >> "${cmdlog_file}" 2>/dev/null || true
    removed=$((removed+1))
  done

  if (( removed > 0 )); then
    echo "Generated max-snaps plan: review=${out_plan_review} exec=${out_plan_exec}" >&2
    emit_plan_files_and_print "$out_plan_review" "$out_plan_exec"
  else
    rm -f "$out_plan_review" "$out_plan_exec" 2>/dev/null || true
  fi
  return 0
}

# Probe the oldest N snapshots and print which are redundant (identical to next)
function probe_max_snaps() {
  local dataset="$1"
  local n="$2"
  local zfs_bin
  if [[ -x /sbin/zfs ]]; then
    zfs_bin="/sbin/zfs"
  elif command -v zfs >/dev/null 2>&1; then
    zfs_bin="$(command -v zfs)"
  else
    echo "zfs not found" >&2; return 1
  fi

  # Warn early if the current user may lack privileges for zfs operations
  require_zfs_priv_for "zfs diff/list" "${dataset}" || true

  local -a snaps_all snaps
  mapfile -t snaps_all < <("$zfs_bin" list -t snapshot -o name,creation -H -s creation "${dataset}" 2>/dev/null | awk '{print $1}')
  local total_all=${#snaps_all[@]}
  echo
  echo "Found ${total_all} snapshots for ${dataset}" >&2
  if (( total_all == 0 )); then
    echo "No snapshots found for ${dataset}" >&2
    return 0
  fi

  local select_count=${n}
  if (( select_count > total_all )); then select_count=${total_all}; fi
  snaps=("${snaps_all[@]:0:select_count}")

  local -a redundant
  local idx=0
  local -a redundant_pairs
  while (( idx < ${#snaps[@]} - 1 )); do
    local older=${snaps[$idx]}
    local newer=${snaps[$((idx+1))]}
    local outdiff
    outdiff=$(sff_zfs_diff "$older" "$newer" 2>/dev/null || true)
    local _zdiff_rc=$?
    if [[ ${_zdiff_rc:-0} -eq 0 && -z "$outdiff" ]]; then
      redundant+=("$older")
      redundant_pairs+=("${older}|${newer}")
    fi
    idx=$((idx+1))
  done

  if (( ${#redundant[@]} == 0 )); then
    echo "No redundant snapshots detected among the oldest ${select_count} snapshots." >&2
    echo "To generate a destroy plan for candidates run: snapshots-find-file -d ${dataset} --max-snaps ${n} --create-destroy-plan" >&2
    echo "To apply a generated plan interactively, re-run with --clean-snapshots (and ensure ALLOW_DESTROY_SNAPS=1 in lib/common.sh)." >&2
    return 0
  fi

  echo "Redundant snapshot candidates (older snapshots identical to their successor):" >&2
  for s in "${redundant[@]}"; do
    echo "  ${WHITE}${s}${NC}" >&2
  done
  # Print reproducible zfs diff commands so operators can re-run the exact
  # comparison in another terminal to validate the script's assessment.
  if (( ${#redundant_pairs[@]} > 0 )); then
    echo "" >&2
    echo "To reproduce this run the following command(s):" >&2
    for p in "${redundant_pairs[@]}"; do
      IFS='|' read -r _older _newer <<< "$p"
      # Use the same zfs binary the script selected to ensure parity
      echo "  ${zfs_bin} diff ${_older} ${_newer}" >&2
    done
  fi
  echo "" >&2
  echo "To preview destroy commands: snapshots-find-file -d ${dataset} --max-snaps ${n} --create-destroy-plan" >&2
  echo "To apply after preview: snapshots-find-file -d ${dataset} --max-snaps ${n} --clean-snapshots" >&2

  # If redundant candidates were found, offer to generate a plan now and optionally apply it.
  if (( ${#redundant[@]} > 0 )); then
    # If the user explicitly requested plan generation via CLI flags, skip
    # interactive prompting here and return control to the caller which will
    # generate the plan non-interactively. This ensures callers (including the
    # main CLI flow) can decide whether to auto-generate after showing probe
    # results.
    if [[ ${REQUEST_SNAP_DELETE_PLAN:-0} -eq 1 ]]; then
      return 0
    fi

    if prompt_confirm "Do you want to generate a destroy plan?" "n"; then
      generate_max_snaps_plan "${dataset}" "${n}" 1
      local out_plan_review out_plan_exec
      out_plan_review="${LOG_DIR}/${SFF_TMP_PREFIX}max_snaps_destroy_plan.sh.review"
      out_plan_exec="${LOG_DIR}/${SFF_TMP_PREFIX}max_snaps_destroy_plan.sh"
      if [[ -f "${out_plan_review}" ]]; then
        echo "Generated review plan: ${out_plan_review}" >&2
        echo "Executable plan: ${out_plan_exec}" >&2
        # If destroys are enabled in config, offer to apply now; otherwise just show and advise.
        if [[ ${ERROR_OCCURRED:-0} -eq 1 ]]; then
          echo -e "${RED}Errors detected during comparison; skipping execution prompt. Inspect ${cmdlog_file} for details.${NC}" >&2
        else
          if [[ "${ALLOW_DESTROY_SNAPS:-0}" -eq 1 ]]; then
            if prompt_confirm "Apply generated plan now?" "n"; then
              echo -e "${YELLOW}Applying destroy plan: ${out_plan_exec}${NC}" >&2
              bash "${out_plan_exec}" >> "${cmdlog_file}" 2>&1 || echo -e "${RED}Plan execution failed; check ${cmdlog_file}${NC}" >&2
            else
              echo "Plan generation complete. To apply later re-run with --clean-snapshots or run: bash ${out_plan_exec}" >&2
            fi
          else
            echo -e "${YELLOW}Note: ALLOW_DESTROY_SNAPS is disabled (simulate mode); plan will not be applied automatically.${NC}" >&2
            echo "Plan generation complete. Destroy plan written to: ${out_plan_exec} (simulate mode). To apply later enable ALLOW_DESTROY_SNAPS in lib/common.sh and re-run with --clean-snapshots, or run: bash ${out_plan_exec}" >&2
          fi
        fi
      else
        echo "Plan generation did not produce ${out_plan_review}" >&2
      fi
    fi
  fi
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
  [[ $VERBOSE == 1 ]] && echo -e "${GREY}Snapshot regex: $SNAP_SEARCH_REGEX${NC}"
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

# Dataset discovery and normalization helpers
# keeping operation-level helpers consolidated.

# Discover datasets based on recursive flag, by iterating zfs list results
#  and normalizing/deduping entries into the global `DATASETS` array.
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
    # NOTE: `zfs list -rH -o name` already emits one dataset per line without a
    # header; do NOT strip the first line with `tail -n +2` as that accidentally
    # drops the requested dataset when recursive discovery is used.
    mapfile -t tmp_datasets < <(zfs list -rH -o name "${datasetpath%/}" 2>/dev/null)
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
    echo -e "v1: Discovered datasets: ${WHITE}${ds_disp[*]}${NC}"
  fi

  # Restore disabled globbing
  set -f
}

## Normalize a dataset string to ZFS-name form (no leading/trailing slash)
function normalize_dataset_name() {
  local ds="$1"
  ds="${ds#/}"
  ds="${ds%/}"
  printf '%s' "$ds"
}

# Map a full snapshot file path to the live dataset equivalent path.
# Args:
#  $1 - ZFS dataset name (no leading slash), e.g. pool/dataset
#  $2 - snapshot root path (the directory that contains .zfs/snapshot/<snap>), e.g. /pool/dataset/.zfs/snapshot/<snap>
#  $3 - full file path inside the snapshot, e.g. /pool/dataset/.zfs/snapshot/<snap>/path/to/file
# Output: prints the live-equivalent path, e.g. /pool/dataset/path/to/file
function sff_decode_zfs_diff_path() {
  local raw_path="$1"

  if command -v perl >/dev/null 2>&1; then
    perl -e '$s = shift; $s =~ s/\\([0-7]{4})/chr(oct($1))/ge; print $s;' -- "$raw_path"
    return
  fi

  printf '%s' "$raw_path"
}

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
  DATASET_SEGMNTS=${#DSP_CONSTITUENTS_ARR[@]}
  # count how many trailing asterisks
  # walk array backwards, using c style
  for (( idx=${#DSP_CONSTITUENTS_ARR[@]}-1; idx>=0; idx-- ));  do
    VAL=${DSP_CONSTITUENTS_ARR[$idx]}
    # get id of the last dir before the trailing wildcards (-1 is because it stops
    #   on the dir after the last specified folder, subtract that also)
    DATASET_SEGMNT_WLDCRDS=$(( DATASET_SEGMNTS - idx - 1 ))
    # shellcheck disable=SC2034
    BASE_DSP_CNT=$(( DATASET_SEGMNTS - DATASET_SEGMNT_WLDCRDS ))
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

# Command-run wrapper: logs command and its output to a per-run commands log
# Usage: sff_run <cmd> [args...]
function sff_run() {
  vlog "sff_run: $*"
  local logfile="${LOG_DIR}/${SFF_TMP_PREFIX}commands.log"
  mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
  local start_ts
  start_ts=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date)
  echo "RUN: ${start_ts} $*" >> "$logfile"
  if "$@" > >(tee -a "$logfile") 2> >(tee -a "$logfile" >&2); then
    local end_ts
    end_ts=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date)
    echo "EXIT:0 END:${end_ts}" >> "$logfile"
    return 0
  else
    local st=$?
    local end_ts
    end_ts=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date)
    echo "EXIT:${st} END:${end_ts}" >> "$logfile"
    return $st
  fi
}

# Track whether we've already printed a single 'Using find' banner for this run.
# We only want one visible banner per run (printed on first fallback) rather
# than per-dataset repetition.
SFF_FIND_BANNER_PRINTED=0

# Print a single global 'Using find' banner the first time any codepath needs
# to fall back to legacy `find`. Also append a single `FALLBACK: USING_FIND: GLOBAL`
# entry to the per-run commands log with a brief reason and the dataset that
# triggered the first fallback.
function sff_print_find_banner_once() {
  local dataset="$1"
  local context="$2"
  if [[ "${SFF_FIND_BANNER_PRINTED:-0}" -eq 0 ]]; then
    echo -e "${YELLOW}Using legacy 'find' for one or more datasets in this run. (First fallback: ${dataset} ${context})${NC}" >&2
    printf 'FALLBACK: USING_FIND: GLOBAL %s FIRST:%s %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$dataset" "$context" >> "${LOG_DIR}/${SFF_TMP_PREFIX}commands.log" 2>/dev/null || true
    SFF_FIND_BANNER_PRINTED=1
  fi
}

# Emit a run-vars summary at EXIT for auditing (mirrors the BEGIN dump).
function show_run_vars_end() {
  local logfile="${LOG_DIR}/${SFF_TMP_PREFIX}commands.log"
  # Mirror the END vars to stderr for interactive visibility (in addition to the commands log).
  local _lbl
  _lbl=$(verbose_label)
  if [[ ${VVERBOSE:-0} -ge 1 ]]; then
    echo -e "${_lbl} ${YELLOW}PID=${$} CREATE_DELETE_PLAN=${CREATE_DELETE_PLAN} ALLOW_DESTROY_SNAPS=${ALLOW_DESTROY_SNAPS} USE_ZDIFF=${USE_ZDIFF}${NC}" >&2
    echo -e "${_lbl} ${YELLOW}SKIP_ZFS_FAST=${SKIP_ZFS_FAST:-0} LOG_DIR=${LOG_DIR} VVERBOSE=${VVERBOSE} VERBOSE=${VERBOSE} QUIET=${QUIET}${NC}" >&2
  fi
  # If we deferred a plan-generation notice earlier (admin disabled CREATE_DELETE_PLAN),
  # print it now at the end of the run so it appears after dataset scanning and plan output.
  if [[ ${NOTIFY_PLAN_GENERATION_IGNORED:-0} -eq 1 ]]; then
    echo -e "${YELLOW}Note: Plan-generation request ignored because CREATE_DELETE_PLAN is disabled in configuration. Use --create-destroy-plan to request a plan; use --clean-snapshots to request execution when allowed.${NC}" >&2
    echo
  fi
  {
    printf 'RUN_VARS_END: %s\n' "$(date +"%Y-%m-%d %H:%M:%S")"
    printf '  PID=%s\n' "$$"
    printf '  CREATE_DELETE_PLAN=%s\n' "${CREATE_DELETE_PLAN}"
    printf '  ALLOW_DESTROY_SNAPS=%s\n' "${ALLOW_DESTROY_SNAPS}"
    printf '  USE_ZDIFF=%s\n' "${USE_ZDIFF}"
    printf '  SKIP_ZFS_FAST=%s\n' "${SKIP_ZFS_FAST:-0}"
    printf '  LOG_DIR=%s\n' "${LOG_DIR}"
    printf '  VVERBOSE=%s VERBOSE=%s QUIET=%s\n' "${VVERBOSE}" "${VERBOSE}" "${QUIET}"
  } >> "$logfile" 2>/dev/null || true

  # When very-verbose mode is requested, mirror the per-run commands log
  # to stderr so users see the full telemetry at the bottom of the run output.
  if [[ ${VVERBOSE:-0} -ge 2 ]]; then
    echo -e "${GREY}--- RUN COMMANDS LOG (start) ---${NC}" >&2
    if [[ -f "$logfile" ]]; then
      sed -n '1,99999p' "$logfile" >&2 2>/dev/null || true
    fi
    echo -e "${GREY}--- RUN COMMANDS LOG (end) ---${NC}" >&2
  fi
}

# Register EXIT handler to print run summary variables
trap show_run_vars_end EXIT
 # ZFS stderr permission/error helpers live in lib/zfs_errors.sh
 # (sourced above). They implement detection, snippet extraction and
 # user-facing guidance. Report/printing helpers are available there.

  # ZFS diff wrapper: normalizes names, retries on ordering or leading-slash errors,
# logs the full output to the commands log, and prints the diff output to stdout
# so callers may pipe it as before.
function sff_zfs_diff() {
  local a="$1" b="$2"
  local logfile="${LOG_DIR}/${SFF_TMP_PREFIX}commands.log"
  mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
  local zfs_bin

  if [[ -x /sbin/zfs ]]; then
    zfs_bin="/sbin/zfs"
  elif command -v zfs >/dev/null 2>&1; then
    zfs_bin="$(command -v zfs)"
  else
    zfs_bin="zfs"
  fi

  # Log and inform which zfs binary was selected for transparency/debugging.
  # This helps explain why zdiff may succeed locally (e.g., /sbin/zfs vs PATH lookup).
  echo -e "${CYAN}Using zfs binary: ${zfs_bin}${NC}" >&2
  printf 'ZFS_BIN: %s %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$zfs_bin" >> "$logfile" 2>/dev/null || true

  # Strip leading slashes from dataset/snapshot names (normalize)
  a="${a#/}"
  b="${b#/}"

  local tmp
  tmp="${LOG_DIR}/${SFF_TMP_PREFIX}zfs-diff.log"

  # Telemetry: record start time (ns) when available
  local start_ns end_ns dur_ms
  start_ns=$(date +%s%N 2>/dev/null || echo 0)
  local run_ts
  run_ts=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date)
  echo "RUN: ${run_ts} $zfs_bin diff $a $b START_NS:$start_ns" >> "$logfile"
  # Capture stdout and stderr separately for diagnostics
  local tmp_out tmp_err
  tmp_out="${LOG_DIR}/${SFF_TMP_PREFIX}zfs-diff.out"
  tmp_err="${LOG_DIR}/${SFF_TMP_PREFIX}zfs-diff.err"
  "$zfs_bin" diff "$a" "$b" >"$tmp_out" 2>"$tmp_err" || true
  local st=$?
  end_ns=$(date +%s%N 2>/dev/null || echo 0)
  if [[ $start_ns -ne 0 && $end_ns -ne 0 ]]; then
    dur_ms=$(( (end_ns - start_ns) / 1000000 ))
  else
    dur_ms=0
  fi
  # Log stdout and stderr separately with clear markers
  if [[ -s "$tmp_out" ]]; then
    printf 'ZDIFF_STDOUT: %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" >> "$logfile" 2>/dev/null || true
    sed 's/^/  /' "$tmp_out" >> "$logfile" 2>/dev/null || true
  fi
  if [[ -s "$tmp_err" ]]; then
    printf 'ZDIFF_STDERR: %s (exit:%s)\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$st" >> "$logfile" 2>/dev/null || true
    sed 's/^/  /' "$tmp_err" >> "$logfile" 2>/dev/null || true
    # Inspect stderr for known ZFS errors and report guidance (modular handlers)
    zfs_error_handle_from_file "$tmp_err" "$logfile" || true
    # Any captured stderr from zfs diff is considered a run-level error
    # that should halt further destructive prompts until inspected.
    ERROR_OCCURRED=1
  fi
  # If zfs exited success but produced no stdout and wrote explanatory stderr
  # (e.g., delegated permission preventing just-in-time snapshots), treat
  # this as a functional failure so callers (probes) don't mark zdiff as usable.
  if [[ $st -eq 0 && ! -s "$tmp_out" && -s "$tmp_err" ]]; then
    # Read a short snippet of stderr to match common failure phrases.
    local _err_snip
    _err_snip=$(head -n 5 "$tmp_err" 2>/dev/null || true)
    if echo "$_err_snip" | grep -qiE "unable to generate diffs|delegated permission|permission"; then
      printf 'ZDIFF_STDERR_NOTE: %s (interpreting as failure)\n' "$(date +"%Y-%m-%d %H:%M:%S")" >> "$logfile" 2>/dev/null || true
      st=2
      # permission-like stderr detected: invoke modular handler
      zfs_error_handle_from_file "$tmp_err" "$logfile" || true
    fi
  fi
  local end_ts
  end_ts=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date)
  echo "EXIT:${st} END:${end_ts} DURATION_MS:${dur_ms}" >> "$logfile"

  # If the zfs diff exited non-zero or we forced st>0 due to stderr notes,
  # mark that an error occurred so callers can suppress destructive prompts.
  if [[ ${st:-0} -ne 0 ]]; then
    ERROR_OCCURRED=1
    printf 'ERROR_OCCURRED: %s EXIT:%s DURATION_MS:%s\n' "${end_ts}" "${st}" "${dur_ms}" >> "$logfile" 2>/dev/null || true
  fi

  if [[ $st -ne 0 ]]; then
    # Read combined outputs for heuristic checks
    local combined
    combined=""
    [[ -f "$tmp_out" ]] && combined+=$(cat "$tmp_out")
    [[ -f "$tmp_err" ]] && combined+=$(printf "\n"; cat "$tmp_err")
    if echo "$combined" | grep -qi "leading slash"; then
      # retry with stripped leading slashes
      "$zfs_bin" diff "${a#/}" "${b#/}" >"$tmp_out" 2>"$tmp_err" || true
      st=$?
      end_ns=$(date +%s%N 2>/dev/null || echo 0)
      dur_ms=$(( (end_ns - start_ns) / 1000000 ))
      printf 'RETRY(strip) RUN: %s DURATION_MS:%s\n' "$zfs_bin diff ${a#/} ${b#/}" "$dur_ms" >> "$logfile"
      if [[ -s "$tmp_out" ]]; then sed 's/^/  /' "$tmp_out" >> "$logfile"; fi
      if [[ -s "$tmp_err" ]]; then sed 's/^/  /' "$tmp_err" >> "$logfile"; fi
      printf 'RETRY(strip) EXIT:%s DURATION_MS:%s\n' "$st" "$dur_ms" >> "$logfile"
    fi
    if [[ $st -ne 0 ]]; then
      combined=""
      [[ -f "$tmp_out" ]] && combined+=$(cat "$tmp_out")
      [[ -f "$tmp_err" ]] && combined+=$(printf "\n"; cat "$tmp_err")
      if echo "$combined" | grep -qi "Not an earlier snapshot"; then
        "$zfs_bin" diff "$b" "$a" >"$tmp_out" 2>"$tmp_err" || true
        st=$?
        end_ns=$(date +%s%N 2>/dev/null || echo 0)
        dur_ms=$(( (end_ns - start_ns) / 1000000 ))
        printf 'RETRY(swap) RUN: %s DURATION_MS:%s\n' "$zfs_bin diff $b $a" "$dur_ms" >> "$logfile"
        if [[ -s "$tmp_out" ]]; then sed 's/^/  /' "$tmp_out" >> "$logfile"; fi
        if [[ -s "$tmp_err" ]]; then sed 's/^/  /' "$tmp_err" >> "$logfile"; fi
        printf 'RETRY(swap) EXIT:%s DURATION_MS:%s\n' "$st" "$dur_ms" >> "$logfile"
      fi
    fi
  fi

  # Emit the diff output to stdout for callers to consume
  # Emit the stdout output to stdout for callers to consume
  if [[ ${VVERBOSE:-0} -ge 1 ]]; then
    # Verbose: print zdiff stdout/stderr to the console for visibility
    if [[ -f "$tmp_out" && -s "$tmp_out" ]]; then
      cat "$tmp_out"
    fi
    if [[ -f "$tmp_err" && -s "$tmp_err" ]]; then
      # send stderr content to stderr so it is visually distinct
      cat "$tmp_err" >&2
    fi
  else
    if [[ -f "$tmp_out" ]]; then
      cat "$tmp_out"
    fi
  fi
  # If successful, record zdiff usage marker
  if [[ $st -eq 0 ]]; then
    echo "ZDIFF_USED: ${end_ts} $a $b DURATION_MS:${dur_ms}" >> "$logfile"
    # Informational on stderr for interactive runs
    echo -e "${CYAN}zdiff: $a -> $b took ${dur_ms}ms${NC}" >&2
      # If combined stderr/stdout shows permission-like issues, report them
      if echo "$combined" | grep -qiE "permission|permission denied|delegat|delegated|just[- ]?in[- ]?time|unable to generate diffs|not allowed"; then
        zfs_error_handle_from_file "$tmp_err" "$logfile" || true
      fi
  else
    echo "ZDIFF_FAILED: ${end_ts} $a $b EXIT:${st} DURATION_MS:${dur_ms}" >> "$logfile"
  fi
  rm -f "$tmp_out" "$tmp_err" || true
  return $st
}
