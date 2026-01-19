# Compare mode

compare mode (-c) is a dataloss detector — it collects the snapshot file inventory and compares those paths against the current live dataset to report files that exist in snapshots but are missing from live. It's effectively "what would I lose if the live dataset were the source of truth?"

How it works (from your code)

process_snapshots_for_dataset() scans each snapshot and writes normalized snapshot file paths into all_snapshot_files_found_tmp (when not in compare it also prints ls -lh output).
When -c is set, top-level script calls compare_snapshot_files_to_live_dataset "$all_snapshot_files_found_tmp" "$DATASETPATH_FS" "${DATASETS[@]}".
compare_snapshot_files_to_live_dataset():
Builds a list of live files from the provided live_dataset_path.
Sorts snapshot entries (newest-first) to prefer newest snapshot for duplicates.
Reports snapshot paths that are not found in the live-file list (respecting IGNORE_REGEX_PATTERNS).
Writes logs: comparison-<timestamp>.out and comparison-delta-<timestamp>.out.
log_snapshot_deltas() and identify_and_suggest_deletion_candidates() consume those outputs to produce CSV deltas and suggested zfs destroy commands (non-destructive suggestions).

Why it was added (most likely reasons)

Detect accidental deletion or drift: identify files present in historical snapshots but missing from live (true dataloss).
Triage before cleanup: let you confirm whether a snapshot contains unique data before suggesting destroys.
Audit and reporting: produce machine-parsable CSV and human-readable logs to review deltas across snapshot pairs.
Important implications / pitfalls

Scope mismatch risk (your real bug): if -c runs non-recursive and the target files reside in child datasets, compare will report false negatives (it will say “not missing” when the missing file is simply in a child dataset you didn’t scan). So compare must scan the same set of datasets you expect to compare.
Performance / IO: compare mode potentially scans many snapshots and the whole live tree — it’s I/O heavy and slower than non-compare searches.
Accurate normalization matters: DATASETPATH_FS, dataset_name, and how snapshot paths are converted to “live-equivalent” paths must be correct or you’ll get mismatches.
Safety: compare should not destroy anything itself, only report — current code follows that (good). Cleanup step only prints suggestions.
False positives/ignored files: IGNORE_REGEX_PATTERNS can filter noise, but may hide some valid cases if misconfigured.

See cleanup and destroy examples: [docs/CLEANUP.md](docs/CLEANUP.md)
