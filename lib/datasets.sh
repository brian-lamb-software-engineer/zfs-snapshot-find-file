#!/bin/bash
# Dataset discovery and normalization helpers
#
# This file extracts the dataset discovery and normalization logic from
# `lib/common.sh` so it can be reused and tested independently.
#
# Keep original comments and placement when moving code.

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
    if [[ ! " ${_norm[*]} " =~ " ${ds_norm} " ]]; then
      _norm+=("${ds_norm}")
    fi
  done

  # Ensure the specified dataset is included, even if it is a parent dataset
  # This ensures that the parent dataset is processed even without the -r flag
  local spec="${datasetpath%/}"
  spec="${spec#/}"
  if [[ ! " ${_norm[*]} " =~ " ${spec} " ]]; then
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

## Normalize a dataset string to ZFS-name form (no leading/trailing slash)
function normalize_dataset_name() {
  local ds="$1"
  ds="${ds%/}"
  ds="${ds#/}"
  printf '%s' "$ds"
}
