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
- `-z` / `--zdiff` : opt-in ZFS `zfs diff` fast-path for compare/search flows when available (non-breaking, falls back to legacy `find` when `zfs` is unavailable)

By default the tool is conservative: it will not perform destructive actions
unless explicitly enabled in the configuration file `lib/common.sh` (the
permanent guard variable `DESTROY_SNAPSHOTS` must be manually enabled).

## Safety and workflow

- The tool generates a destroy plan (`sff_destroy-plan-<timestamp>.sh`) and
  prints suggested removals as "WOULD delete" lines by default.
 - To execute a destroy plan you must:
  - enable the `DESTROY_SNAPSHOTS` switch in `lib/common.sh` and
  - run the generated plan script interactively after reviewing it.

Note: do NOT edit `lib/common.sh` except to intentionally change the master guard variable `DESTROY_SNAPSHOTS` from `0` to `1`. This is the permanent, explicit switch that enables real destructive execution; do not modify any other variables in `lib/common.sh` to try to bypass the safety model.

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

- Use the `z` fast-path (zdiff) to prefer `zfs diff` for faster snapshot comparisons:

```bash
./snapshots-find-file -c -z -v -d pool/dataset -s "*" -f "*"
```

- Search using `zdiff` to accelerate snapshot-to-snapshot differences (opt-in):

```bash
./snapshots-find-file -z -v -d pool/dataset -s "*" -f "*.html"
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

## Benchmarking `zdiff` (bench mode)

What it's for:

- Validate performance and parity between the legacy `find`-based comparison and the opt-in `zfs diff` fast-path (`-z` / `--zdiff`).
- Produces timing and missing-count comparisons so you can decide whether to adopt `zdiff` for a workload.
- Bench mode is non-destructive and exits after reporting results.

How to run (example):

```bash
# Save per-run artifacts to a persistent folder and run the benchmark
LOG_DIR_ROOT=tests/tmp_parity_$(date +%s) ./snapshots-find-file -c --bench -v -d pool/dataset -s "*" -f "*"
```

Expected output (example):

```
Benchmark: running legacy (use_z=0) then zdiff (use_z=1) comparisons...
Legacy (find) time: 1234ms missing:1
ZDIFF time: 456ms missing:1
```

Notes:

- Bench mode runs the legacy compare first (find) and then the `zdiff` path (zfs diff) and prints `time(ms)` and `missing` counts for each run.
- Per-run artifacts are still written to the per-run `LOG_DIR` (set via `LOG_DIR_ROOT`): look for `comparison-summary-*.csv` (missing counts) and `sff_commands.log` which will include `ZDIFF_USED:` markers and per-diff durations when `zdiff` was used.
- If the missing counts differ between the two runs, investigate `comparison-delta-*.out` and `comparison-summary-*.csv` in the `LOG_DIR` to find mismatches and fallback reasons.
 - Bench implementation internals have been isolated to `lib/zfs-bench.sh` (developer-facing). The CLI and `--bench` flag remain unchanged for users.


## Search vs Compare vs Cleanup

- Search (non-compare): enumerates files inside snapshots that match `-f`/`-s` and prints or logs them. It should not perform live-vs-snapshot comparisons by default.
- Compare (`-c`): runs a live-dataset comparison and produces delta artifacts (`comparison-delta-*.out`, `sff_acc_deleted-*.csv`, `sff_snap_holding-*.txt`) used to detect files that exist only in snapshots (possible accidental deletions).
- Cleanup / Plan generation (`--clean-snapshots`): reads comparison evidence and suggests safe snapshot deletions (plan-only by default). Plan generation is controlled by the config-level `SFF_DELETE_PLAN` (in `lib/common.sh`) — if `SFF_DELETE_PLAN=1` the cleanup flow may run during normal searches; set `SFF_DELETE_PLAN=0` to prevent plan-generation by default.

Notes:
- If you only want a plain search, disable plan generation for that run by setting `SFF_DELETE_PLAN=0` in `lib/common.sh` or use the forthcoming runtime `--skip-plan` flag (will be documented when added).
- `-z` (zdiff) is an opt-in fast-path: the tool prefers `zfs diff` when available, but will fall back per-dataset to the legacy `find` behavior and log fallback reasons to `commands.log` in the per-run `LOG_DIR`.

## Environment forms & quiet mode

You can request interactive apply prompts via an environment variable. Two safe ways to do this:

- Inline for a single invocation (POSIX shell):

```bash
REQUEST_DESTROY_SNAPSHOTS=1 ./snapshots-find-file -cvv -d /path/to/dataset --clean-snapshots -f "*"
```

- Export for the session (POSIX shell):

```bash
export REQUEST_DESTROY_SNAPSHOTS=1
./snapshots-find-file -cvv -d /path/to/dataset --clean-snapshots -f "*"
```

- PowerShell (when invoking the script under WSL/`bash`):

```powershell
$env:REQUEST_DESTROY_SNAPSHOTS='1'
bash ./snapshots-find-file -cvv -d /path/to/dataset --clean-snapshots -f "*"
```

Quiet mode: use `-q` or `--quiet` to suppress per-file console output while still producing logs and the numeric summary. When quiet mode is active the tool prints a single yellow notice in the place where per-file lines would normally appear:

```bash
./snapshots-find-file -q -c -d /path/to/dataset -s "*" -f "*"
# -> prints a single yellow line: "[quiet] Per-file output suppressed; counts only"
```

Tips to avoid large logs filling disk:
- Use `-q` to avoid console spam.
- Set `LOG_DIR` to a filesystem with ample space before running (export `LOG_DIR=/mnt/big-disk`).
- Add large backup directories to `IGNORE_REGEX_PATTERNS` in `lib/common.sh` to exclude them from scans.
- Rotate or compress old `/tmp/sff_*` logs (e.g., `gzip /tmp/sff_*.out`).

## Safe deletion checklist (TEST-ONLY workflow)

Follow this workflow to VERIFY the interactive prompt and review a generated destroy plan without executing any `zfs destroy` commands. Do NOT edit `lib/common.sh` to enable execution until you have carefully reviewed the plan.

1. Ensure the master destroy flag is disabled in `lib/common.sh`:

```bash
# in lib/common.sh
DESTROY_SNAPSHOTS=0
```

2. Generate a destroy plan and trigger the execution prompt (prompt will appear, but execution will be blocked by the config):

```bash
REQUEST_DESTROY_SNAPSHOTS=1 ./snapshots-find-file -c -d /path/to/dataset --clean-snapshots
```

- Expected outcome: the script will prompt `Execute destroy plan now?`.
- After confirmation, because `DESTROY_SNAPSHOTS=0`, the tool will print a message that execution is blocked and will write the plan file (e.g. `/tmp/sff_destroy-plan-<timestamp>.sh`). No `zfs destroy` commands will run.

3. Inspect the generated plan file before enabling execution:

```bash
less /tmp/sff_destroy-plan-YYYYMMDD-HHMMSS.sh
grep "^# /sbin/zfs destroy" /tmp/sff_destroy-plan-YYYYMMDD-HHMMSS.sh
```

- Lines are intentionally commented (start with `# /sbin/zfs destroy ...`). Verify every snapshot listed is intended for deletion.

4. (Optional) If you want a rehearsal run, keep the destroy lines commented and run the plan through `bash -n` or examine its contents. Do not enable execution yet.

5. To apply the plan only after a careful review:

- Edit `lib/common.sh` and set `DESTROY_SNAPSHOTS=1` (explicit manual change required).
- Re-run the command with the same environment variable to trigger prompt and execution:

```bash
REQUEST_DESTROY_SNAPSHOTS=1 ./snapshots-find-file -c -d /path/to/dataset --clean-snapshots
```

- On confirmation the tool will create an executable `exec_plan` (it uncomments destroy lines) and run it. Logs will be written to `/tmp/sff_destroy-exec-<timestamp>.log`.

Safety reminders:
- Always test on a small, non-production dataset first.
- Keep `DESTROY_SNAPSHOTS=0` until you have manually verified the plan.
- Back up any critical data before enabling real deletes.

