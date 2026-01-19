# Code Catalog — functions and TODOs

Function map (file -> function -> start..end (count))

- lib/common.sh (203 lines)
  - `help()` : L36..L84 (49 lines)
  - `parse_arguments()` : L85..L130 (46 lines)
  - `initialize_search_parameters()` : L131..L203 (73 lines)

- lib/zfs-search.sh (122 lines)
  - `process_snapshots_for_dataset()` : L15..L122 (108 lines)

- lib/zfs-compare.sh (184 lines)
  - `compare_snapshot_files_to_live_dataset()` : L4..L100 (97 lines)
  - `log_snapshot_deltas()` : L101..L184 (84 lines)

- lib/zfs-cleanup.sh (136 lines)
  - `identify_and_suggest_deletion_candidates()` : L4..L136 (133 lines)

Notes and immediate observations
- `lib/common.sh` is the designated shared utilities file (`common.sh`) and should remain so; it contains CLI parsing and initialization helpers.
- Multiple functions exceed the 60-line target (candidates for Phase 2 splitting):
  - `initialize_search_parameters()` (73 lines)
  - `process_snapshots_for_dataset()` (108 lines)
  - `compare_snapshot_files_to_live_dataset()` (97 lines)
  - `log_snapshot_deltas()` (84 lines)
  - `identify_and_suggest_deletion_candidates()` (133 lines)

TODO / FIXME / NOTES extracted from code comments
- `lib/common.sh`
  - L86: "CRUCIAL FIX: Reset OPTIND to 1 before calling getopts."
  - L199: "CUSTOM CODE BEGIN"
  - L226: "CUSTOM CODE END (moved inside a function)"

- `lib/zfs-search.sh`
  - L28: "CUSTOM CODE CONTINUE BEGIN"
  - L38: "ADDED: Declared DS_CONST_ARR as local and used robust read -a"
  - L41: "ADDED: Declared DS_CONST_ARR_CNT as local"
  - L68: "ADDED: Declared snapdirs as local"
  - L69: "TODO look to if the first forward slash here is needed, because its coming up as double forward slash on $snapdirs value"
  - L82: "ADDED: Declared SNAPNAME as local"
  - L110..L132: "NEW FUNCTIONALITY MODIFICATION BEGIN/END" (COMPARE-specific changes; pay attention to xargs/bash quoting)
  - L145: "CUSTOM CODE END"

- `lib/zfs-compare.sh`
  - L88: "TODO figure out why the message below says \"already reported\" then clarify that reason or fix it"

- `lib/zfs-cleanup.sh`
  - No explicit TODO markers found, but function is large and contains PHASE comments and TODO-like notes in comments.

Immediate recommended next outputs (Phase 1 -> deliverable A)
1. Confirm this catalog (accept or request changes).
2. Produce a prioritized extraction list for Phase 2: sort candidate functions by length and propose helper names and split points.
3. Optional: create a `--test-mode` plan and small fixture harness before refactoring.

Generated: $(date -u)

Recent changes (applied during Phase 1)
- `lib/common.sh`: added `DATASETPATH_FS` (normalized filesystem path with leading "/"), normalized and deduped `DATASETS`, and improved verbose dataset display to show leading slashes.
- `lib/zfs-search.sh`: compute both `ds_path` (filesystem path) and `dataset_name` (ZFS name); use `ds_path` for snapshot directory scanning and `dataset_name` for ZFS commands; in non-COMPARE mode, append found file paths into the global temp file so the top-level script can detect matches.
- `snapshots-find-file`: pass `DATASETPATH_FS` into compare/delta/cleanup functions to ensure filesystem operations use absolute paths.

These changes fix duplicate/relative vs absolute dataset handling and ensure the main script correctly reports when snapshots contain matching files.
-
These changes fix duplicate/relative vs absolute dataset handling and ensure the main script correctly reports when snapshots contain matching files.

Additional runtime fixes applied during Phase 1 testing:
- `lib/common.sh` / `build_file_pattern()`: switched to a tokenized `FILEARR` so `find` receives `-name` and `-o` tokens as separate arguments; this fixes multi-`-f` and quoting/tokenization bugs.
- `discover_datasets()`: removed an extra `tail -n +2` from the recursive `zfs list` call which could cause the parent or first dataset to be omitted from discovery.
