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

Local configuration

You can create a local `.env` file at the project root to override the
dataset and pattern used by the tests. Copy `.env.example` to `.env` and edit
the variables to match your environment. The `.env` file is ignored by git.

  cp .env.example .env
  # edit .env to set SFF_DATASET, SFF_SNAPSHOT_PATTERN, SFF_FILE_PATTERN


## Files and libraries

Short, one-line descriptions for each tracked file. This catalog intentionally avoids listing internal function names — use the tool's `--help` output for exact CLI flags and behavior.

- `snapshots-find-file` : Main CLI entrypoint and orchestrator.
- `lib/common.sh` : Shared utilities, logging helpers, and global configuration (including the master `DESTROY_SNAPSHOTS` guard).
- `lib/zfs-search.sh` : Snapshot and dataset discovery and file-list extraction logic.
- `lib/zfs-compare.sh` : Comparison logic and summary CSV generation.
- `lib/zfs-cleanup.sh` : Cleanup planning and destroy-plan generation (plan-only flows).
- `tests/validate_summary.sh` : Integration-style test that validates the summary CSV produced by a dry-run compare.
- `tests/run_smoke_tests.sh` : Smoke-test runner that writes consolidated output to `tests/smoke.log`.
- `run_tests.sh` : Convenience wrapper to run the test suite.
- `run_and_log.sh` : Local developer helper to capture command output (not required to be committed).
- `.env.example` : Template for a local `.env` used by tests (copy to `.env` and edit for local overrides). `.env` is ignored by Git.
- `.gitignore` : Files and patterns ignored by Git (includes `.env`, test logs).
- `PRD.md` : Product Requirements Document (requirements-only; not user-facing docs).
- `copilot-context.md` : Developer/agent guidance and operational notes for contributors.
- `LICENSE` : Project license.

If you need fixture-driven `--test-mode` or CI integration, open an issue or propose a branch — current tests run against live ZFS datasets by default.

## Quick CLI examples

These quick examples give common workflows; run `./snapshots-find-file --help` for full usage and flags.

- Show help:

```bash
./snapshots-find-file --help
```

- Search snapshots (non-destructive):

```bash
./snapshots-find-file -v -d pool/dataset -s "snapshot-pattern" -f "*.log"
```

- Compare snapshot inventories to a live dataset (dataloss detection):

```bash
./snapshots-find-file -c -v -d pool/dataset -s "*" -f "*"
```

- Generate a destroy plan (plan-only):

```bash
./snapshots-find-file --clean-snapshots
```

- Very-verbose function-entry tracing:

```bash
./snapshots-find-file -vv ...
```

For programmatic use, prefer the `--help` output as the authoritative reference for flags and semantics.
