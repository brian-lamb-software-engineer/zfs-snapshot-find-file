# snapshots-find-file — Snapshot search and cleanup

`snapshots-find-file` (a.k.a. `sff`) searches ZFS snapshots, lists matching files, and can compare snapshot inventories to a live dataset to detect missing files and suggest safe snapshot deletions.

Entry point: `snapshots-find-file` (root script)

Libraries used:
- `lib/common.sh` — CLI parsing, shared helpers, constants
- `lib/zfs-search.sh` — snapshot traversal and file discovery
- `lib/zfs-compare.sh` — compare snapshot file lists to live dataset and produce deltas
- `lib/zfs-cleanup.sh` — identify deletion candidates and generate destroy plans

Brief summary

Use `-c` (compare) to run dataloss detection: the tool builds a snapshot inventory and compares it to the live dataset to report files present in snapshots but missing on live. This is useful to triage accidental deletions or data drift before any cleanup.

Important notes

- Be careful with recursive scope: ensure you scan the same set of datasets you intend to compare (use `-r` or dataset wildcards appropriately).
- Default behavior is conservative — no destructive operations are executed unless you explicitly request them via `--destroy-snapshots`.


## Cleanup and destroy

The tool supports conservative, flag-driven snapshot cleanup workflows. By default nothing is destroyed — the tool generates a destroy plan and prints "WOULD delete" lines so you can review suggested removals.

Usage examples:

- Generate suggestions and a destroy-plan (dry-run):

```bash
./snapshots-find-file -c -d "/nas/live/cloud" --delete-snapshots -s "*" -f "index.html"
```

This writes an executable plan at `/tmp/destroy-plan-<timestamp>.sh` and prints suggested `WOULD delete` lines to the CLI for review.

- Interactive apply (prompted):

```bash
./snapshots-find-file -c -d "/nas/live/cloud" --destroy-snapshots -s "*" -f "index.html"
```

The script will prompt `Execute destroy plan now? [y/N]` before executing the generated plan. A log of executed destroys is written to `/tmp/destroy-exec-<timestamp>.log`.

- Force option (adds `-f` to generated `zfs destroy` commands):

```bash
./snapshots-find-file -c -d "/nas/live/cloud" --destroy-snapshots --force -s "*" -f "index.html"
```

Notes:

- The tool is intentionally conservative — test with `--delete-snapshots` (plan-only) before attempting to execute any destroys.
- There is no non-interactive `--yes` option; interactive confirmation is required before plan execution.






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

---

## Code Catalog — functions and TODOs

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

Additional runtime fixes applied during Phase 1 testing:
- `lib/common.sh` / `build_file_pattern()`: switched to a tokenized `FILEARR` so `find` receives `-name` and `-o` tokens as separate arguments; this fixes multi-`-f` and quoting/tokenization bugs.
- `discover_datasets()`: removed an extra `tail -n +2` from the recursive `zfs list` call which could cause the parent or first dataset to be omitted from discovery.
