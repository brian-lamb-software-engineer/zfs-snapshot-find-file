#!/bin/bash
# zfs_errors.sh
# Error handler helpers for parsing ZFS stderr messages and emitting
# user-facing guidance. Each specific error has a tiny matcher function
# that returns a help string when matched. A central query function
# dispatches to handlers and a printer helper formats output.

# Print a formatted help message and the exact commands log path (copyable).
# Args: <help_text> <cmdlog_path>
function zfs_error_print_helper() {
  local help_text="${1:-}"; local cmdlog="${2:-}"
  if [[ -n "$help_text" ]]; then
    echo -e "${YELLOW}${help_text}${NC}" >&2
  fi
  if [[ -n "$cmdlog" ]]; then
    # Print the commands.log path in yellow so operators can copy it.
    echo -e "${YELLOW}Inspect commands log: ${cmdlog}${NC}" >&2
  fi
}

# Specific error matcher: 'Unable to determine which snapshots to compare: invalid name'
# Returns a help string on stdout when matched, non-zero otherwise.
function zfs_error_match_invalid_name() {
  local err="$1"
  if echo "$err" | grep -qi "Unable to determine which snapshots to compare: invalid name"; then
    cat <<'HELP'
Usually means zdiff couldn't parse or map the two snapshot names passed (bad name, missing snapshot, or wrong ordering).
Check that both snapshot names exist and are correctly ordered (older then newer), and re-run the exact `zfs diff` command shown in the commands log as the same user.
If the command succeeds as root but not as your user, it's likely a permission/delegation issue — re-run with sudo or adjust ZFS delegation.
HELP
    return 0
  fi
  return 1
}

# Registry-based query: pass the raw stderr (or snippet) and return a help string
# by invoking each matcher in turn. Prints the first matching help string.
function zfs_error_query() {
  local err="$1"; local res
  local handlers=(zfs_error_match_invalid_name)
  for h in "${handlers[@]}"; do
    res="$($h "$err" 2>/dev/null || true)"
    if [[ -n "$res" ]]; then
      printf '%s' "$res"
      return 0
    fi
  done
  return 1
}

# Helper to extract a short stderr snippet from a file and then query handlers.
# Args: <stderr_file> -> prints matched help and returns 0 if matched.
function zfs_error_handle_from_file() {
  local f="$1"; local cmdlog="$2"; local snippet
  if [[ -n "$f" && -f "$f" ]]; then
    snippet=$(head -n 8 "$f" 2>/dev/null || true)
  else
    return 1
  fi
  if [[ -n "$snippet" ]]; then
    local help
    help=$(zfs_error_query "$snippet" 2>/dev/null || true)
    if [[ -n "$help" ]]; then
      zfs_error_print_helper "$help" "$cmdlog"
      return 0
    fi
  fi
  return 1
}

# Require ZFS privileges helper: if not root, defer an actionable message
# to be printed later via `print_deferred_zfs_priv_msg`.
function require_zfs_priv_for() {
  local action="${1:-zfs diff/list}"; local dataset="${2:-<dataset>}"
  if [[ $(id -u 2>/dev/null || echo 1) -eq 0 ]]; then
    return 0
  fi
  ZFS_PRIV_MSG="Permission: current user may need to use sudo for this particular dataset condition; ${action} on ${dataset} may fail.\nIf you expect to perform ${action} operations, re-run as root (sudo) or enable appropriate ZFS delegation for this dataset."
  return 1
}

function print_deferred_zfs_priv_msg() {
  if [[ -n "${ZFS_PRIV_MSG:-}" ]]; then
    echo -e "${RED}${ZFS_PRIV_MSG}${NC}" >&2
    unset ZFS_PRIV_MSG
  fi
}

export -f zfs_error_print_helper zfs_error_match_invalid_name zfs_error_query zfs_error_handle_from_file
