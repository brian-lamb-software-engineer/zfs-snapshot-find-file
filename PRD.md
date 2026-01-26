````markdown
# Snapshot Reducer — Product Requirements Document (PRD)

Purpose
- Reduce wasted space from ZFS snapshots by identifying redundant snapshots and suggesting safe deletions.
- Detect potentially accidentally deleted files on live datasets by comparing live dataset contents to snapshot contents.

Agent: Developent workflow important notes:
- If you see functions that are >60 lines, break them out.  
- When breaking out functions, if you see pieces in that function that are being called from multiple places, break that piece out to its own function, and place it on common.sh, then call it, instead of its code from those multiple places. 
- avoid usage of ENV Variables, we dont need to code in functionality for that. 
- note, if you need output, you can give me the command and pipe that to a log, e.g. > out.log, where youo can then view that log yourself, as your inside the code base already

Scope (Phase 1)
- Catalog and inspect the current codebase split across `snapshots-find-file` ("sff") and `lib/*.sh`.
- This phase is strictly cataloging: do not change functionality or refactor code. The refactor into modular functions (<=60 lines each) is Phase 2.

AGENT: see copilot-context.md for instructions first
AGENT: do not remove my comments, keep them above the lines they belong to.  if that ends up being an arracy or code block that cant take comments, but it immediately above that block. 

Goals (Phase 1 — Cataloging)
- Keep all code DRY (Do Not Repeat Yourself): treat `lib/common.sh` as the shared utilities file (special case) used by other `lib/*.sh` files.  Where you see redundant lines, reduce them to a function that can be called in its place
- Do not modify behaviour or move code in this phase; only identify code that has not yet been moved off `snapshots-find-file` into `lib/`.
- Build an actionable mapping of which functions live in which files and list any residual code in `snapshots-find-file` that still needs extraction.
- Safe defaults: confirm no destructive operations will be executed as part of cataloging.

Constraints & Non-goals
- This phase is an inspection + cataloging step; no snapshot deletions will be executed and no behavior will be changed.
- Platform: primary runtime is Linux with `zfs`, `find`, `xargs`, `sudo` available.

Runtime output constraint
- When a function's output is consumed by a command-substitution (e.g. `read < <(...)`), that function MUST emit only the data payload on stdout. All informational, debug, or colored human-readable text must go to stderr or be written to a log file. This avoids contaminating machine-parsable outputs (CSV, counters) used by callers. Follow this rule when adding future debug prints or helpers.

Current repository state (inspection summary)
- Entry script: `snapshots-find-file` ("sff") — orchestration only; it sources these libraries and calls their functions:
  - `lib/common.sh`: CLI parsing, initialization, constants, global vars, and helpers (`help`, `parse_arguments`, `initialize_search_parameters`). This file is a special shared utilities file and should remain as the common dependency.
  - `lib/zfs-search.sh`: `process_snapshots_for_dataset()` — walks snapshot directories and finds files (COMPARE and non-COMPARE modes).
  - `lib/zfs-compare.sh`: `compare_snapshot_files_to_live_dataset()` and `log_snapshot_deltas()` — compares snapshot file lists to live dataset and produces delta logs.
  - `lib/zfs-cleanup.sh`: `identify_and_suggest_deletion_candidates()` — analyzes `zfs diff` output and prints candidate destroy statements (non-destructive suggestions).

Notes about `snapshots-find-file` (sff)
- `sff` currently contains only orchestration: sourcing libs, parsing arguments, initializing, iterating datasets, invoking `process_snapshots_for_dataset` for each dataset, and invoking compare/cleanup flows when `-c` is used. No leftover functional code was found in `sff` that executes core logic — all substantive logic appears in `lib/*.sh`.

Notes discovered during inspection
- All four library files referenced by the main script are present and implement core functionality.
- Several internal TODOs and comments exist (debug notes, small behavior questions). See code comments in `lib/*.sh`.
- No missing file artifact was found at `lib/` during this inspection; the missing work likely refers to incomplete extraction or further splitting of logic still residing inside the library functions themselves (to be addressed in Phase 2).

Identified gaps & recommendations (Phase 1 -> cataloging outcomes)
1. Confirmation: no substantive code remains in `sff` beyond orchestration. The "fourth" file you referenced is present; the remaining work is extraction/splitting inside `lib/*.sh` files (Phase 2).
2. Enforce function length rule in Phase 2: identify functions >60 lines and split into smaller helpers. Candidate functions to check:
   - `process_snapshots_for_dataset()` (zfs-search.sh)
   - `identify_and_suggest_deletion_candidates()` (zfs-cleanup.sh)
   - `compare_snapshot_files_to_live_dataset()` (zfs-compare.sh)
3. Add unit / integration test harness (small test datasets or mocked `zfs` outputs). Prefer a `--test-mode` flag that uses local directories rather than real `zfs` for fast dev.
4. Add static checks: `shellcheck` and a simple CI job (optional) to run lint/tests during refactor.
5. Improve robustness around IFS/globbing and `sudo find | xargs` usage (some TODOs already present in code).

Phase 1 Deliverables (what I will produce next)
1. A catalog mapping: list of all functions, the file where each lives, and each function's start/end line numbers and line counts.
2. A compilation of TODO/FIXME comments found across `lib/*.sh`.
3. A short prioritized list of candidate functions (by line count) for Phase 2 extraction (no changes made yet).

Proposed next steps (Phase 2 — after catalog approval)
1. Automated analysis: run a scan to list function lengths; flag functions >60 lines.
2. For each flagged function, extract logical sub-functions into `lib/<area>-helpers.sh` (e.g., `lib/zfs-util.sh`) and update callers with minimal behaviour changes.
3. Add a `--dry-run` and `--test-mode` behavior that skips `sudo` and `zfs` and uses fixtures for tests.
4. Create a branch `feature/refactor-modularize` and open a PR with focused commits (one commit per function extraction).
5. Add lightweight tests and `shellcheck` fixes; run and verify on Linux.

additional items needed
1. for a path instead of file is specified for search, this needs to be implemented.  e.g. in a dataset there is a path of files -d "/nas/real-dataset" files serching for wanted to be /nas/real-dataset/users/brian/Documents .  if i user wants to just search inside a subpath (Documents) only in that dataset, it cant be specified in the -d line, beacuse output is that dataset doesnt exist, and if you specify this path in files, e.g. -f documents, or -f "users/brian/Documents" it wont work either.  


Recommendations (no changes in Phase 1)
- Add a `--test-mode` or fixture-driven mode and a `--dry-run` flag in Phase 2 before any operations that might modify snapshots.
- Add `shellcheck` linting and a minimal CI check for future refactors.

Acceptance criteria for Phase 1
- PRD exists (this file) and explicitly states this phase is catalog-only (no code changes).
- `snapshots-find-file` contains only orchestration; no leftover functional code to move in this phase.
- Deliverable mapping and prioritized extraction list will be produced next.

Appendix — quick actions I can take next
- Run function-length scan and list functions > 60 lines.
- Create branch and start extracting the first candidate function once you approve Phase 2 plan.
- Or, if you prefer, paste `git log --stat` output and I will review change history before refactor.

Recent runtime fixes applied (not part of Phase 2 refactor):
- Use a tokenized `FILEARR` when building `find` expressions so multiple `-f` patterns and `-o`/`-name` tokens are passed as separate arguments to `find`. This fixes multi-`-f` and quoting/tokenization issues discovered during testing.
- Fixed recursive dataset discovery by removing an extra `tail -n +2` that could drop the first dataset returned by `zfs list -rH`.

Compare mode behavior note:
- When `-c` (compare) is used, the tool now enables recursive dataset discovery implicitly (equivalent to `-r`) and prints a one-line warning. This ensures compare inspects child datasets so it reports snapshot-only files accurately for dataloss checks.
- Compare writes ignored matches to `compare-ignore-<timestamp>.out`. Be cautious with `IGNORE_REGEX_PATTERNS`: overly broad patterns can hide snapshot-only files and lead to missed dataloss reporting. Review the ignored-log when running compares. Consider adding --no-auto-recursive later.

Destroy safety recommendations (Phase 2 - before enabling automated destruction):
-- Keep plan-only and apply separated: `--clean-snapshots` (plan-only). Apply is gated by the master config `DESTROY_SNAPSHOTS` in `lib/common.sh` and requires an interactive confirmation.
- Use a permanent top-level configuration guard for execution: require the master switch `DESTROY_SNAPSHOTS` in `lib/common.sh` to be explicitly enabled before any plan may be executed. This avoids environment-variable overrides and makes destructive capability a conscious config change.
- Preserve an interactive confirmation step before executing any plan. Also generate and persist a human-readable pre-destroy report for review.

Phase 2 — Implemented scaffolding (partial)
-----------------------------------------

Note: during Phase 2 initial work a conservative, opt-in scaffold was implemented to allow safe testing of deletion flows without enabling automatic destructive behavior. Key delivered items:

 - Added deletion orchestration: `--clean-snapshots` (plan-only). The plan-only flow is controlled by `SFF_DELETE_PLAN` and actual execution is gated by the master config `DESTROY_SNAPSHOTS` in `lib/common.sh`. A `--force` option is available to include `-f` on generated `zfs destroy` commands when applying a plan after enabling the master switch.
- Implemented generation of an executable destroy plan file (`/tmp/destroy-plan-<timestamp>.sh`) while continuing to display `WOULD delete` and commented `# /sbin/zfs destroy "<snap>"` lines in CLI output for review.
- Interactive confirmation is required before any plan is executed; there is no environment-variable bypass — enabling destructive runs requires editing `lib/common.sh` to set `DESTROY_SNAPSHOTS=1`.
- Split several long functions and moved shared helpers into `lib/common.sh` (e.g., `record_found_file`, `prompt_confirm`) to improve readability and reuse. Notable refactors:
  - `process_snapshots_for_dataset()` partially split into compare/non-compare handlers in `lib/zfs-search.sh` and now prints per-dataset totals in non-compare runs.
  - `identify_and_suggest_deletion_candidates()` was split into helper collectors and evaluator/planner in `lib/zfs-cleanup.sh` (plan generation and gated execution).
- Reordered comparison output so the neutral-colored comparison summary is printed at the bottom of CLI output; `lib/zfs-compare.sh` now writes the summary to logs and `snapshots-find-file` prints the CSV-derived summary last.

These changes are intentionally conservative: destructive operations remain gated and require explicit flags and interactive confirmation. The next Phase 2 steps are to add test fixtures, further break down any remaining functions >60 lines, and add CI lint/tests before considering unattended execution.

Phase 3.1 — ZFS-diff fast path & deterministic per-run logging (2026-01-24)
------------------------------------------------------------------
Summary of additions implemented to support a faster, safer compare/cleanup workflow:

- New opt-in fast-path: a `-z` / `--zfs-diff` flag that, when present, causes compare and cleanup flows to prefer `zfs diff` via the `sff_zfs_diff` wrapper instead of the legacy `find`-based enumeration. This is non-breaking: absence of `-z` preserves existing behaviour.
- `sff_run` and `sff_zfs_diff` command wrappers added to centralize command logging, normalize zfs invocation quirks (leading slash, ordering), retry on known zfs errors, and log outputs to the per-run `commands.log`.
- Deterministic per-run artifacts: moved persistent artifacts into a per-run directory `LOG_DIR_ROOT=/tmp/sff/<SHORT_TS>/` and replaced randomized `mktemp` filenames for persistent outputs (comparison.out, comparison-delta.out, comparison-summary.csv, acc_deleted files, destroy-plan files) so they are easy to find and reproduce per run.
- Evidence aggregation & defensive vetting: the cleanup planner now aggregates `acc_deleted` evidence from canonical locations and any `sff_acc_deleted*` files found in the plan/tmp base and removes any proposed destroys touching snapshots referenced by that evidence. Added dataset-level protection: if any snapshot in a dataset is sacred, protect the whole dataset from deletion proposals.
- Enhanced destroy-plan output: generated plans remain comment-first but now include multi-line `# BECAUSE:` and `# DETAIL:` blocks explaining why a snapshot was chosen, and `# Command:` lines showing the exact `zfs destroy` invocation for operator review.
- Tests & helpers updated: tests and validation scripts updated to search for the new per-run summary file patterns; helper scripts for function-length counting were added.

Files changed (high-level):
- `lib/common.sh` — added `LOG_DIR` per-run setup, `sff_run`, `sff_zfs_diff`, and CLI parsing for `-z`.
- `lib/zfs-compare.sh` — added deterministic comparison artifact names and a pathway to call the zfs-diff fast path (planned); summary CSV writing unified.
- `lib/zfs-cleanup.sh` — moved temp/persistent artifacts to per-run deterministic names; added `_prepare_cleanup_temp_files`, `_write_destroy_plan`, `_aggregate_evidence_into_sacred`, `_vet_plan_against_acc_files`, dataset-level protection, and multi-line plan detail blocks.
 - `lib/zfs-bench.sh` — new bench/test harness containing the `bench_zfs_fast_compare`, `bench_sff_run` (CLI bench entrypoint), and `bench_help` helpers; bench/test logic was moved here to keep production compare helpers slim.
 - `lib/zfs-compare.sh` — production compare helpers remain; fast-path caller updated to invoke `bench_zfs_fast_compare` (bench implementation lives in `lib/zfs-bench.sh`).
- `tests/*` — updated to search for per-run `comparison-summary.csv` and added logging helpers.
- `tools/count_funcs.*` — function-length helpers added (PowerShell and bash variants).
- `agents/bash-expert.md` — notes and guidance added.
 - `readme.md` — minor update noting that bench internals are isolated to `lib/zfs-bench.sh` while the CLI `--bench` flag remains unchanged.

Next steps for Phase 3.1:
- Finish wiring the `-z` flag into the compare flow to call the new zfs-fast-compare implementation and add per-dataset fallback to `find` when `zfs` is unavailable or returns errors.
- Add smoke tests that verify both `-z` (zfs-diff fast path) and legacy `-c` (find-based) produce identical summary CSV outputs for canonical fixtures.
- Sweep codebase for any remaining `${SHORT_TS}_`-prefixed filename occurrences and ensure all persistent artifacts land under the per-run `LOG_DIR`.

These updates reflect work applied on 2026-01-24 to harden safety, make artifacts deterministic per run, and add the safe, opt-in zfs-diff fast path toggle. Implementing the full zfs-fast-compare function and per-dataset fallback will be completed as the next implementation step.

Phase 3.2 — ZFS Search Optimization (planned)
--------------------------------------------
Goal
- Speed up non-compare (`search`) flows and snapshot-to-snapshot comparisons by selectively using `zfs diff` where it yields equivalent data faster than `find`-based snapshot enumeration.

Why
- The project already added a `zfs-diff` fast-path for compare flows (Phase 3.1). There are additional `find`-heavy code paths in the non-compare search and snapshot-to-snapshot logic that can benefit from the same approach and the existing `sff_zfs_diff` wrapper.

Success criteria
- `zfs_fast_search()` provides the same canonical artifacts as the legacy search path (`sff_acc_deleted-<ts>.csv`, `sff_snap_holding-<ts>.txt`, `comparison-summary.csv`) and writes logs into the per-run `LOG_DIR`.
- Per-dataset fallback to legacy `find` occurs when `zfs` is unavailable or when `sff_zfs_diff` returns an error for a particular snapshot pair; fallbacks are logged to `commands.log`.
- Smoke parity tests demonstrate identical `missing` counts between legacy `find` and new `zfs`-based search on representative fixtures.

Planned work items (implementation plan)
1. Audit: identify all call sites where `find` is used for snapshot-to-snapshot enumeration in `lib/zfs-search.sh`, `lib/zfs-compare.sh`, and any other helper that powers the non-compare search.
2. Implement `zfs_fast_search()`:
  - For each snapshot pair in a dataset, call `sff_zfs_diff` to capture `+`/`-`/`M`/`R` lines.
  - Produce the same canonical artifacts and CSV summaries the cleanup and compare flows expect.
  - Keep `IGNORE_REGEX_PATTERNS` semantics identical to legacy behavior.
3. Wire: make the non-compare `search` flow optionally prefer `zfs` when `-z`/`--zfs-diff` is present; keep legacy `find` as default.
4. Fallbacks & logging: log per-dataset fallbacks to `${LOG_DIR}/${SFF_TMP_PREFIX}commands.log` and ensure the fallback calls the legacy code with `SKIP_ZFS_FAST=1` to avoid recursion.
5. Testing: add smoke parity tests (similar to `tests/smoke_parity_zfs_vs_find.sh`) and add a `--test-mode` fixture harness later to run deterministic comparisons without a live ZFS pool.
6. Docs: update `help` text, PRD, and examples to recommend `-z` when `zfs` is available and to document known zfs-diff quirks (leading slash, ordering) and when the fallback will be used.

Estimated effort: small-to-moderate; can be implemented in one PR with focused tests and docs.

Notes and constraints
- Preserve the safety-first deletion model: do not change plan/master-guard behavior (`SFF_DELETE_PLAN` / `DESTROY_SNAPSHOTS`).
- Maintain the canonical artifact formats so cleanup and vetting code remain unchanged or only require minimal adapters.
- Add per-dataset fallbacks rather than an all-or-nothing toggle to avoid surprising operators when `zfs` behaves inconsistently for certain snapshots.
---

Included content from `docs/PRD.md` (mirrored so `docs/PRD.md` can be removed):

````markdown
## Project Requirements Document (PRD)

Overview
- Purpose: Manage safe discovery, comparison, and conservative deletion of ZFS snapshots so that files which only exist in snapshots are never accidentally destroyed.  Additional snapshot file search and comparison capability. 

Principal Product Requirements
- Safety-first deletion workflow: deletion must be plan-first and reviewable. The default behavior must never execute destroys without an explicit configuration edit and peer review.
- Canonical evidence: comparison runs must emit machine-readable evidence files in the run tmp base using the `SFF_TMP_PREFIX` naming convention: `sff_acc_deleted-<ts>.csv` (rows: `snapshot|path`) and `sff_snap_holding-<ts>.txt` (snapshot ids).
- Cleanup consults evidence: the cleanup evaluator must consult any provided `acc_deleted` file and any `sff_acc_deleted*` files in the plan/tmp base before proposing snapshot deletions.
- Tracing and debugging: support `-v`, `-vv` for verbose and very-verbose tracing; `vlog()` must auto-prefix caller metadata and route tracing to stderr so machine outputs remain clean.
- Quiet mode: `-q` suppresses per-file lines while keeping summary and logs.
- Machine outputs sanitized: CSV and canonical artifacts must be free of ANSI/human traces; human/ANSI traces must be sent to stderr only.
- Config guards: `DESTROY_SNAPSHOTS` must remain `0` by default in `lib/common.sh`; enabling requires editing that file (master guard). `REQUEST_DESTROY_SNAPSHOTS` may be set for prompting but cannot override the master guard.
- Maintainability: prefer functions <= ~60 lines; schedule a function-length audit and refactors where needed.
- Preserve original author comments and help text in code and docs.

- Phase 3: Finalize Snapshot Deletion Workflow
- Agent changes: `bash-expert` audit and compatibility updates (Bash 4.2 compatibility, safety hardening, temp-file and read/mapfile fixes)
- Purpose: Prevent accidental destruction of snapshots that are the only remaining copy of files missing from the live dataset.

Key implementation summary
- The comparison step writes canonical evidence files into the run tmp base with the `SFF_TMP_PREFIX` naming convention: `sff_acc_deleted-<ts>.csv` (rows: `snapshot|path`) and `sff_snap_holding-<ts>.txt` (snapshot ids).
- The cleanup evaluator now consults a provided `acc_deleted` file and any `sff_acc_deleted*` files found in the plan/tmp base before proposing snapshot deletions.
- Destroy plans remain plan-first: generated plans include comment-prefixed `# BECAUSE:` reasons and `# Command:` lines that show the `zfs destroy` invocation. Actual execution requires editing `DESTROY_SNAPSHOTS=1` in `lib/common.sh` and confirming runtime prompts (if `REQUEST_DESTROY_SNAPSHOTS` is set).

Safety checklist (must be satisfied before any destructive rollout)
- Master guard: `DESTROY_SNAPSHOTS` in `lib/common.sh` must remain `0` by default. Enabling requires explicit edit and peer review.
- Evidence files: any run that proposes deletions must include `sff_acc_deleted-<ts>.csv` and `sff_snap_holding-<ts>.txt` in the same tmp/log directory. Verify their contents before acting.
- Machine outputs: CSV artifacts (`comparison-summary-*.csv`, `sff_acc_deleted-*.csv`) must be free of ANSI/human traces; the code strips ANSI before writing these files.
- Reviewable plans: generated destroy plans must be comment-first, include BECAUSE/Command blocks, and be reviewed by an operator before enabling execution.

Verification steps
1. Run comparison in dry-run:

```bash
snapshots-find-file -c -d <dataset> --clean-snapshots -s <snap-regex> -f <file-pattern>
```

Confirm `Wrote summary to: /tmp/comparison-summary-<ts>.csv` and `sff_acc_deleted-<ts>.csv` in same tmp base.

2. Inspect `/tmp/sff_acc_deleted-<ts>.csv` and `/tmp/sff_snap_holding-<ts>.txt` to ensure they list `snapshot|path` entries for missing files.

3. Run cleanup plan generation (dry-run):

```bash
snapshots-find-file --clean-snapshots
```

or call `identify_and_suggest_deletion_candidates` and confirm the tool prints the tmp base it used and does NOT propose deletion for any snapshot referenced in any `sff_acc_deleted*` file.

4. Inspect generated plan (`sff_destroy-plan-<ts>.sh`) to ensure each candidate has a `# BECAUSE:` rationale and a commented `# Command:` line.

Operational notes
- To test interactive apply without permanently enabling the master guard, set `REQUEST_DESTROY_SNAPSHOTS=1` in the environment. The tool will prompt but will still not execute unless `DESTROY_SNAPSHOTS=1` is set in `lib/common.sh`.
- Logs: comparison writes `comparison-<ts>.out` and `comparison-delta-<ts>.out`; the tool performs best-effort background compression of older logs.

Developer workflow (cross-platform)
- When the operator runs commands on a Linux host (e.g., RHEL), the agent will provide exact shell commands that explicitly redirect both stdout and stderr into a single log file. The operator will run those commands locally and then paste the produced log file for inspection. The agent will not execute remote commands directly.
- Example: `bash tests/run_smoke_tests.sh > /tmp/sff_smoke.log 2>&1` — run this on your Linux machine and then paste the log contents for review.

Refactor/backlog note
- A function-length audit is required to schedule refactors for functions >60 lines. The workspace `logs/` file was empty earlier; see the `logs/function-lengths-<ts>.txt` created alongside this PRD update.

Acceptance criteria
- No snapshot referenced by any `sff_acc_deleted*` file may be proposed for deletion.
- Machine-readable outputs validate numeric summary fields and contain no ANSI sequences.
- Destroy plans remain comment-first and include BECAUSE/Command blocks for all candidates.

Next Steps
- Re-run or review the function-length audit (see `logs/function-lengths-*.txt`) and split functions over 60 lines into smaller helpers; then re-run verification steps above.

Notes about restoration
- This file was updated to restore the principal product requirements (safety, canonical evidence, tracing, QUIET mode, sanitized machine outputs, and master guard behavior) and to merge the Phase‑3 deletion workflow content you supplied. If you prefer the original exact wording preserved from an earlier revision, paste that text here and I will restore it verbatim.

````
# Snapshot Reducer — Product Requirements Document (PRD)

Purpose
- Reduce wasted space from ZFS snapshots by identifying redundant snapshots and suggesting safe deletions.
- Detect potentially accidentally deleted files on live datasets by comparing live dataset contents to snapshot contents.

Agent: Developent workflow important notes:
- If you see functions that are >60 lines, break them out.  
- When breaking out functions, if you see pieces in that function that are being called from multiple places, break that piece out to its own function, and place it on common.sh, then call it, instead of its code from those multiple places. 
- avoid usage of ENV Variables, we dont need to code in functionality for that. 
- note, if you need output, you can give me the command and pipe that to a log, e.g. > out.log, where youo can then view that log yourself, as your inside the code base already

Scope (Phase 1)
- Catalog and inspect the current codebase split across `snapshots-find-file` ("sff") and `lib/*.sh`.
- This phase is strictly cataloging: do not change functionality or refactor code. The refactor into modular functions (<=60 lines each) is Phase 2.

AGENT: see copilot-context.md for instructions first
AGENT: do not remove my comments, keep them above the lines they belong to.  if that ends up being an arracy or code block that cant take comments, but it immediately above that block. 

Goals (Phase 1 — Cataloging)
- Keep all code DRY (Do Not Repeat Yourself): treat `lib/common.sh` as the shared utilities file (special case) used by other `lib/*.sh` files.  Where you see redundant lines, reduce them to a function that can be called in its place
- Do not modify behaviour or move code in this phase; only identify code that has not yet been moved off `snapshots-find-file` into `lib/`.
- Build an actionable mapping of which functions live in which files and list any residual code in `snapshots-find-file` that still needs extraction.
- Safe defaults: confirm no destructive operations will be executed as part of cataloging.

Constraints & Non-goals
- This phase is an inspection + cataloging step; no snapshot deletions will be executed and no behavior will be changed.
- Platform: primary runtime is Linux with `zfs`, `find`, `xargs`, `sudo` available.

Runtime output constraint
- When a function's output is consumed by a command-substitution (e.g. `read < <(...)`), that function MUST emit only the data payload on stdout. All informational, debug, or colored human-readable text must go to stderr or be written to a log file. This avoids contaminating machine-parsable outputs (CSV, counters) used by callers. Follow this rule when adding future debug prints or helpers.

Current repository state (inspection summary)
- Entry script: `snapshots-find-file` ("sff") — orchestration only; it sources these libraries and calls their functions:
  - `lib/common.sh`: CLI parsing, initialization, constants, global vars, and helpers (`help`, `parse_arguments`, `initialize_search_parameters`). This file is a special shared utilities file and should remain as the common dependency.
  - `lib/zfs-search.sh`: `process_snapshots_for_dataset()` — walks snapshot directories and finds files (COMPARE and non-COMPARE modes).
  - `lib/zfs-compare.sh`: `compare_snapshot_files_to_live_dataset()` and `log_snapshot_deltas()` — compares snapshot file lists to live dataset and produces delta logs.
  - `lib/zfs-cleanup.sh`: `identify_and_suggest_deletion_candidates()` — analyzes `zfs diff` output and prints candidate destroy statements (non-destructive suggestions).

Notes about `snapshots-find-file` (sff)
- `sff` currently contains only orchestration: sourcing libs, parsing arguments, initializing, iterating datasets, invoking `process_snapshots_for_dataset` for each dataset, and invoking compare/cleanup flows when `-c` is used. No leftover functional code was found in `sff` that executes core logic — all substantive logic appears in `lib/*.sh`.

Notes discovered during inspection
- All four library files referenced by the main script are present and implement core functionality.
- Several internal TODOs and comments exist (debug notes, small behavior questions). See code comments in `lib/*.sh`.
- No missing file artifact was found at `lib/` during this inspection; the missing work likely refers to incomplete extraction or further splitting of logic still residing inside the library functions themselves (to be addressed in Phase 2).

Identified gaps & recommendations (Phase 1 -> cataloging outcomes)
1. Confirmation: no substantive code remains in `sff` beyond orchestration. The "fourth" file you referenced is present; the remaining work is extraction/splitting inside `lib/*.sh` files (Phase 2).
2. Enforce function length rule in Phase 2: identify functions >60 lines and split into smaller helpers. Candidate functions to check:
   - `process_snapshots_for_dataset()` (zfs-search.sh)
   - `identify_and_suggest_deletion_candidates()` (zfs-cleanup.sh)
   - `compare_snapshot_files_to_live_dataset()` (zfs-compare.sh)
3. Add unit / integration test harness (small test datasets or mocked `zfs` outputs). Prefer a `--test-mode` flag that uses local directories rather than real `zfs` for fast dev.
4. Add static checks: `shellcheck` and a simple CI job (optional) to run lint/tests during refactor.
5. Improve robustness around IFS/globbing and `sudo find | xargs` usage (some TODOs already present in code).

Phase 1 Deliverables (what I will produce next)
1. A catalog mapping: list of all functions, the file where each lives, and each function's start/end line numbers and line counts.
2. A compilation of TODO/FIXME comments found across `lib/*.sh`.
3. A short prioritized list of candidate functions (by line count) for Phase 2 extraction (no changes made yet).

Proposed next steps (Phase 2 — after catalog approval)
1. Automated analysis: run a scan to list function lengths; flag functions >60 lines.
2. For each flagged function, extract logical sub-functions into `lib/<area>-helpers.sh` (e.g., `lib/zfs-util.sh`) and update callers with minimal behaviour changes.
3. Add a `--dry-run` and `--test-mode` behavior that skips `sudo` and `zfs` and uses fixtures for tests.
4. Create a branch `feature/refactor-modularize` and open a PR with focused commits (one commit per function extraction).
5. Add lightweight tests and `shellcheck` fixes; run and verify on Linux.

additional items needed
1. for a path instead of file is specified for search, this needs to be implemented.  e.g. in a dataset there is a path of files -d "/nas/real-dataset" files serching for wanted to be /nas/real-dataset/users/brian/Documents .  if i user wants to just search inside a subpath (Documents) only in that dataset, it cant be specified in the -d line, beacuse output is that dataset doesnt exist, and if you specify this path in files, e.g. -f documents, or -f "users/brian/Documents" it wont work either.  


Recommendations (no changes in Phase 1)
- Add a `--test-mode` or fixture-driven mode and a `--dry-run` flag in Phase 2 before any operations that might modify snapshots.
- Add `shellcheck` linting and a minimal CI check for future refactors.

Acceptance criteria for Phase 1
- PRD exists (this file) and explicitly states this phase is catalog-only (no code changes).
- `snapshots-find-file` contains only orchestration; no leftover functional code to move in this phase.
- Deliverable mapping and prioritized extraction list will be produced next.

Appendix — quick actions I can take next
- Run function-length scan and list functions > 60 lines.
- Create branch and start extracting the first candidate function once you approve Phase 2 plan.
- Or, if you prefer, paste `git log --stat` output and I will review change history before refactor.

Recent runtime fixes applied (not part of Phase 2 refactor):
- Use a tokenized `FILEARR` when building `find` expressions so multiple `-f` patterns and `-o`/`-name` tokens are passed as separate arguments to `find`. This fixes multi-`-f` and quoting/tokenization issues discovered during testing.
- Fixed recursive dataset discovery by removing an extra `tail -n +2` that could drop the first dataset returned by `zfs list -rH`.

Compare mode behavior note:
- When `-c` (compare) is used, the tool now enables recursive dataset discovery implicitly (equivalent to `-r`) and prints a one-line warning. This ensures compare inspects child datasets so it reports snapshot-only files accurately for dataloss checks.
- Compare writes ignored matches to `compare-ignore-<timestamp>.out`. Be cautious with `IGNORE_REGEX_PATTERNS`: overly broad patterns can hide snapshot-only files and lead to missed dataloss reporting. Review the ignored-log when running compares. Consider adding --no-auto-recursive later.

Destroy safety recommendations (Phase 2 - before enabling automated destruction):
-- Keep plan-only and apply separated: `--clean-snapshots` (plan-only). Apply is gated by the master config `DESTROY_SNAPSHOTS` in `lib/common.sh` and requires an interactive confirmation.
- Use a permanent top-level configuration guard for execution: require the master switch `DESTROY_SNAPSHOTS` in `lib/common.sh` to be explicitly enabled before any plan may be executed. This avoids environment-variable overrides and makes destructive capability a conscious config change.
- Preserve an interactive confirmation step before executing any plan. Also generate and persist a human-readable pre-destroy report for review.

Phase 2 — Implemented scaffolding (partial)
-----------------------------------------

Note: during Phase 2 initial work a conservative, opt-in scaffold was implemented to allow safe testing of deletion flows without enabling automatic destructive behavior. Key delivered items:

 - Added deletion orchestration: `--clean-snapshots` (plan-only). The plan-only flow is controlled by `SFF_DELETE_PLAN` and actual execution is gated by the master config `DESTROY_SNAPSHOTS` in `lib/common.sh`. A `--force` option is available to include `-f` on generated `zfs destroy` commands when applying a plan after enabling the master switch.
- Implemented generation of an executable destroy plan file (`/tmp/destroy-plan-<timestamp>.sh`) while continuing to display `WOULD delete` and commented `# /sbin/zfs destroy "<snap>"` lines in CLI output for review.
- Interactive confirmation is required before any plan is executed; there is no environment-variable bypass — enabling destructive runs requires editing `lib/common.sh` to set `DESTROY_SNAPSHOTS=1`.
- Split several long functions and moved shared helpers into `lib/common.sh` (e.g., `record_found_file`, `prompt_confirm`) to improve readability and reuse. Notable refactors:
  - `process_snapshots_for_dataset()` partially split into compare/non-compare handlers in `lib/zfs-search.sh` and now prints per-dataset totals in non-compare runs.
  - `identify_and_suggest_deletion_candidates()` was split into helper collectors and evaluator/planner in `lib/zfs-cleanup.sh` (plan generation and gated execution).
- Reordered comparison output so the neutral-colored comparison summary is printed at the bottom of CLI output; `lib/zfs-compare.sh` now writes the summary to logs and `snapshots-find-file` prints the CSV-derived summary last.

These changes are intentionally conservative: destructive operations remain gated and require explicit flags and interactive confirmation. The next Phase 2 steps are to add test fixtures, further break down any remaining functions >60 lines, and add CI lint/tests before considering unattended execution.

Phase 3.1 — ZFS-diff fast path & deterministic per-run logging (2026-01-24)
------------------------------------------------------------------
Summary of additions implemented to support a faster, safer compare/cleanup workflow:

- New opt-in fast-path: a `-z` / `--zfs-diff` flag that, when present, causes compare and cleanup flows to prefer `zfs diff` via the `sff_zfs_diff` wrapper instead of the legacy `find`-based enumeration. This is non-breaking: absence of `-z` preserves existing behaviour.
- `sff_run` and `sff_zfs_diff` command wrappers added to centralize command logging, normalize zfs invocation quirks (leading slash, ordering), retry on known zfs errors, and log outputs to the per-run `commands.log`.
- Deterministic per-run artifacts: moved persistent artifacts into a per-run directory `LOG_DIR_ROOT=/tmp/sff/<SHORT_TS>/` and replaced randomized `mktemp` filenames for persistent outputs (comparison.out, comparison-delta.out, comparison-summary.csv, acc_deleted files, destroy-plan files) so they are easy to find and reproduce per run.
- Evidence aggregation & defensive vetting: the cleanup planner now aggregates `acc_deleted` evidence from canonical locations and any `sff_acc_deleted*` files found in the plan/tmp base and removes any proposed destroys touching snapshots referenced by that evidence. Added dataset-level protection: if any snapshot in a dataset is sacred, protect the whole dataset from deletion proposals.
- Enhanced destroy-plan output: generated plans remain comment-first but now include multi-line `# BECAUSE:` and `# DETAIL:` blocks explaining why a snapshot was chosen, and `# Command:` lines showing the exact `zfs destroy` invocation for operator review.
- Tests & helpers updated: tests and validation scripts updated to search for the new per-run summary file patterns; helper scripts for function-length counting were added.

Files changed (high-level):
- `lib/common.sh` — added `LOG_DIR` per-run setup, `sff_run`, `sff_zfs_diff`, and CLI parsing for `-z`.
- `lib/zfs-compare.sh` — added deterministic comparison artifact names and a pathway to call the zfs-diff fast path (planned); summary CSV writing unified.
- `lib/zfs-cleanup.sh` — moved temp/persistent artifacts to per-run deterministic names; added `_prepare_cleanup_temp_files`, `_write_destroy_plan`, `_aggregate_evidence_into_sacred`, `_vet_plan_against_acc_files`, dataset-level protection, and multi-line plan detail blocks.
- `tests/*` — updated to search for per-run `comparison-summary.csv` and added logging helpers.
- `tools/count_funcs.*` — function-length helpers added (PowerShell and bash variants).
- `agents/bash-expert.md` — notes and guidance added.

Next steps for Phase 3.1:
- Finish wiring the `-z` flag into the compare flow to call the new zfs-fast-compare implementation and add per-dataset fallback to `find` when `zfs` is unavailable or returns errors.
- Add smoke tests that verify both `-z` (zfs-diff fast path) and legacy `-c` (find-based) produce identical summary CSV outputs for canonical fixtures.
- Sweep codebase for any remaining `${SHORT_TS}_`-prefixed filename occurrences and ensure all persistent artifacts land under the per-run `LOG_DIR`.

These updates reflect work applied on 2026-01-24 to harden safety, make artifacts deterministic per run, and add the safe, opt-in zfs-diff fast path toggle. Implementing the full zfs-fast-compare function and per-dataset fallback will be completed as the next implementation step.

---
Generated: $(date -u)

Commit message guidelines (project-wide)
Header: 4-8 words, ALL CAPS, concise (single line).
- Immediately on the next line, start bullet lines with a hyphen (no bullets) followed by a single space and concise text (no blank line allowed between header and bullets).
- Use 1-4 bullet lines total.
- Keep the message focused and high-level; implementation details belong in the PR body.
-Do a git diff --cached to get the info from files to build the sumamry for the commit messages
- Output in a text box so its easily copyable, and so there is no auto converting of hypens to bullets and no space after the header by vs code formatting.
- no quotes or backticks or $ or chars that will break the commit message and cause it to run a command

Example
```

## Test-run workflow (runner provided)

- A lightweight smoke-test runner script is available at `tests/run_smoke_tests.sh` to execute canonical smoke checks and produce a single consolidated log at `tests/smoke.log`.
- The runner truncates `tests/smoke.log` before each run so the file reflects only the most recent test execution. This ensures reproducible manual testing and simplifies log review.
- `tests/smoke.log` is ignored by Git via `.gitignore` to avoid accidental commits.

Recommended usage:

1. Run the smoke tests locally:

```bash
bash tests/run_smoke_tests.sh
```

2. After completion, examine `tests/smoke.log` or request the automation agent to read it back for triage.

3. Iterate on fixes and re-run until results are acceptable.

Note: This runner is intentionally lightweight and not a replacement for a fixture-driven `--test-mode` harness. It provides a fast way to collect runtime output and logs while we build a more complete automated test harness.
ADDED NEW FUNCTIONS TO ZFS-SEARCH
- added `process_snapshots_for_dataset()` improvements
- fixed xargs quoting for compare mode
- updated temporary file handling
```

Phase 2 Progress Update (2026-01-19)
- **Status**: In-progress, core refactors applied. A repo-wide function-length scan shows no functions exceeding 60 lines.
- **Completed in Phase 2:** Implemented `VVERBOSE` + `vlog()` tracing; added color constants and `SFF_TMP_PREFIX`; implemented conservative plan-first deletion scaffold gated by `DESTROY_SNAPSHOTS`; split several large functions (examples: `log_snapshot_deltas` -> `_lsd_process_dataset`; `parse_arguments` split into `_pa_*` helpers); restored many removed author comments; hardened temp-file handling.
- **Left to do:** Finish restoring any remaining removed author comments exactly above the code they document; add fixture-driven `--test-mode` and CI (`shellcheck`) in Phase 2 before enabling any unattended destruction.
- **Verification performed:** Ran function-length scan across `lib/*.sh` and `snapshots-find-file` — no functions >60 lines were found after recent splits. The `help()` function in `lib/common.sh` remains intentionally unchanged per project instruction.
