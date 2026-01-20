# snapshots-find-file — Snapshot search and cleanup

`snapshots-find-file` (a.k.a. `sff`) searches ZFS snapshots, lists matching files, and can compare snapshot inventories to a live dataset to detect missing files and suggest safe snapshot deletions.
# snapshots-find-file

snapshots-find-file ("sff") searches ZFS snapshots for matching files, can
compare snapshot inventories to a live dataset to detect missing files, and
helps generate conservative destroy plans for snapshot cleanup.

This README is user-focused: usage, safety, and quick examples. Developer
notes and change history live in PRD.md and AI_SUMMARY.md.

## Quick start

- Make the main script executable:

  chmod +x snapshots-find-file

- Scan snapshots for matching files (non-destructive):

  ./snapshots-find-file -v -d pool/dataset -s "snapshot-pattern" -f "*.log"

- Compare snapshot inventories to a live dataset (dataloss detection):

  ./snapshots-find-file -c -v -d pool/dataset -s "*" -f "*"

Flags of interest:

- `-c` : run compare mode (generate inventory and compare to live dataset)
- `-v` : verbose; `-vv` enables very-verbose function-entry tracing
- `--clean-snapshots` : generate a destroy plan (plan-only; does not apply)

By default the tool is conservative: it will not perform destructive actions
unless explicitly enabled in the configuration file `lib/common.sh` (the
permanent guard variable `DESTROY_SNAPSHOTS` must be manually enabled).

## Safety and workflow

- The tool generates a destroy plan (`sff_destroy-plan-<timestamp>.sh`) and
  prints suggested removals as "WOULD delete" lines by default.
- To execute a destroy plan you must:
  - enable the `DESTROY_SNAPSHOTS` switch in `lib/common.sh` and
  - run the generated plan script interactively after reviewing it.

This design prevents accidental destructive runs from command-line flags or
CI environment variables.

## Testing

There is a minimal integration test under `tests/validate_summary.sh` which
runs a dry-run compare, finds the generated summary CSV, and validates that
summary fields are numeric. Run the tests with:

  ./run_tests.sh

Note: the tests may require access to ZFS datasets on the host. For CI, it's
recommended to add a fixture or `--test-mode` to avoid depending on live
ZFS data.

## Files and libraries

- Entry point: `snapshots-find-file`
- Shared libraries: `lib/common.sh`, `lib/zfs-search.sh`,
  `lib/zfs-compare.sh`, `lib/zfs-cleanup.sh`

Developer notes, detailed PRD, and change history: see [PRD.md](PRD.md).
