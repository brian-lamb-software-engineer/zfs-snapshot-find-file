# Snapshot Reducer — Product Requirements Document (PRD)

## Overview
Snapshot Reducer manages the safe discovery, comparison, and conservative deletion of ZFS snapshots to ensure that files existing only in snapshots are never accidentally destroyed. It provides snapshot file search, dataset comparison, and planned cleanup workflows.

---

## Purpose
- Storage optimization: reduce wasted space by identifying redundant or obsolete ZFS snapshots.
- Safety focus: prevent deleting snapshots that uniquely contain files missing from live datasets.
- Traceability: produce deterministic, logged, reviewable output artifacts for all operations.

---

## Principal Product Requirements
- Safety-first deletion: all destructive operations must be two-step (plan-first, apply-second) and peer-reviewed.
- Canonical evidence: each run writes machine-readable evidence files following the `SFF_TMP_PREFIX` convention:
  - `sff_acc_deleted-<timestamp>.csv` — records `snapshot|path` rows.
  - `sff_snap_holding-<timestamp>.txt` — lists protected snapshot IDs.
- Cleanup evidence use: the cleanup stage must cross-check evidence before proposing any deletions.
- Verbose tracing: support `-v` and `-vv` with `vlog()` auto-prefixes and route logs to `stderr`.
- Quiet mode: `-q` suppresses per-file lines while retaining summary and logs.
- Clean outputs: CSV and canonical artifacts contain no ANSI escapes or color traces.
- Master guard: `ALLOW_DESTROY_SNAPS` remains `0` by default and requires manual edit for activation.
- Maintainability: limit functions to ~60 lines; flag overlong functions during audits.
- Preserve documentation: retain all original comments and help text during refactors.

---

## Developer Workflow Notes
- Split functions bigger than 60 lines into helpers.
- Move all shared logic to `lib/common.sh`.
- Avoid relying on environment variables for feature control.
- Redirect command output to logs for later inspection (`> out.log 2>&1`).
- Keep comments immediately above the code or block they document.
- Before editing, review `copilot-context.md`.

---

## PHASE 1 — Cataloging and Code Audit (Status: ✅ Complete)
**Date:** 2025‑12‑10  

Scope
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
  - `lib/zfs-cleanup.sh`: `identify_and_suggest_snapshot_deletion_candidates()` — analyzes `zfs diff` output and prints snapshot deletion candidate destroy statements (non-destructive suggestions).

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
  - `identify_and_suggest_snapshot_deletion_candidates()` (zfs-cleanup.sh)
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
- Compare writes ignored matches to `compare-ignore-<timestamp>.out`. Be cautious with `REGEX_IGNORE_PATTERNS`: overly broad patterns can hide snapshot-only files and lead to missed dataloss reporting. Review the ignored-log when running compares. Consider adding --no-auto-recursive later.

Destroy safety recommendations (Phase 2 - before enabling automated destruction):
- Keep plan-only and apply separated: `--create-destroy-plan` (plan-only). To request applying a generated plan in the same run use `--clean-snapshots`. Apply is gated by the master config `ALLOW_DESTROY_SNAPS` in `lib/common.sh` and requires an interactive confirmation.
- Use a permanent top-level configuration guard for execution: require the master switch `ALLOW_DESTROY_SNAPS` in `lib/common.sh` to be explicitly enabled before any plan may be executed. This avoids environment-variable overrides and makes destructive capability a conscious config change.
---

Phase 2 — Modularization & Safe Delete Scaffolding (2026‑01‑19, Status: ✅ Complete)

Note: during Phase 2 initial work a conservative, opt-in scaffold was implemented to allow safe testing of deletion flows without enabling automatic destructive behavior. Key delivered items:

 - Added deletion orchestration: `--create-destroy-plan` (plan-only). The plan-only flow is controlled by `CREATE_DELETE_PLAN` and actual execution is gated by the master config `ALLOW_DESTROY_SNAPS` in `lib/common.sh`. A `--force` option is available to include `-f` on generated `zfs destroy` commands when applying a plan after enabling the master switch. Use `--clean-snapshots` to request execution of the generated plan in the same run (execution still blocked unless `ALLOW_DESTROY_SNAPS=1`).
- Implemented generation of an executable destroy plan file (`/tmp/destroy-plan-<timestamp>.sh`) while continuing to display `WOULD delete` and commented `# /sbin/zfs destroy "<snap>"` lines in CLI output for review.
- Interactive confirmation is required before any plan is executed; there is no environment-variable bypass — enabling destructive runs requires editing `lib/common.sh` to set `ALLOW_DESTROY_SNAPS=1`.
- Split several long functions and moved shared helpers into `lib/common.sh` (e.g., `record_found_file`, `prompt_confirm`) to improve readability and reuse. Notable refactors:
  - `process_snapshots_for_dataset()` partially split into compare/non-compare handlers in `lib/zfs-search.sh` and now prints per-dataset totals in non-compare runs.
  - `identify_and_suggest_snapshot_deletion_candidates()` was split into helper collectors and evaluator/planner in `lib/zfs-cleanup.sh` (plan generation and gated execution).
- Reordered comparison output so the neutral-colored comparison summary is printed at the bottom of CLI output; `lib/zfs-compare.sh` now writes the summary to logs and `snapshots-find-file` prints the CSV-derived summary last.

These changes are intentionally conservative: destructive operations remain gated and require explicit flags and interactive confirmation. The next Phase 2 steps are to add test fixtures, further break down any remaining functions >60 lines, and add CI lint/tests before considering unattended execution.

Progress Update (2026-01-19)
- **Status**: In-progress, core refactors applied. A repo-wide function-length scan shows no functions exceeding 60 lines.
- **Completed in Phase 2:** Implemented `VVERBOSE` + `vlog()` tracing; added color constants and `SFF_TMP_PREFIX`; implemented conservative plan-first deletion scaffold gated by `ALLOW_DESTROY_SNAPS`; split several large functions (examples: `log_snapshot_deltas` -> `_lsd_process_dataset`; `parse_arguments` split into `_pa_*` helpers); restored many removed author comments; hardened temp-file handling.
- **Left to do:** Finish restoring any remaining removed author comments exactly above the code they document; add fixture-driven `--test-mode` and CI (`shellcheck`) in Phase 2 before enabling any unattended destruction.
- **Verification performed:** Ran function-length scan across `lib/*.sh` and `snapshots-find-file` — no functions >60 lines were found after recent splits. The `help()` function in `lib/common.sh` remains intentionally unchanged per project instruction.

----

# PHASE 3 — Comparison Enhancements & Deletion Workflow (2026‑01‑22, Status: ✅ Complete)

### Purpose
Finalize the comparison and cleanup pipeline so snapshot deletions are safe, reviewable, and backed by canonical evidence.

### Implementation Summary
- Comparison phase generates evidence:
  - `sff_acc_deleted-<ts>.csv`
  - `sff_snap_holding-<ts>.txt`
- Cleanup consults these evidence files before proposing deletions.  
- Destroy plans remain *plan-only* and include comment-prefixed `# BECAUSE:` and `# Command:` lines explaining each proposal.  

### Safety Checklist
- Master guard in `lib/common.sh` defaults to `0`, requiring manual enable and peer review.  
- Every deletion plan must include complete evidence files.  
- All CSV and artifact outputs must be ANSI-free.  
- Generated plans must contain reasoned annotations for review.

### Verification Steps
1. **Compare dry run:**
  ```bash
  snapshots-find-file -c -d <dataset> --create-destroy-plan -s <snap-regex> -f <file-pattern>
Inspect artifacts: verify both sff_acc_deleted-<ts>.csv and sff_snap_holding-<ts>.txt.

Generate cleanup plan:

```bash
snapshots-find-file --create-destroy-plan
```
Validate output: ensure each destroy candidate includes # BECAUSE: and # Command: details.

Operational Notes
REQUEST_ALLOW_DESTROY_SNAPS=1 enables confirmation prompts but cannot bypass master guard.

Logs (comparison-*.out) are automatically compressed after older runs.

Developer Workflow
Operators run all commands locally and share resulting logs.
Example:

bash
bash tests/run_smoke_tests.sh > /tmp/sff_smoke.log 2>&1
The agent will parse these logs; it never executes remote commands.

Acceptance Criteria
No snapshot listed in any sff_acc_deleted* file is proposed for deletion.

Machine-readable outputs validate correctly and omit ANSI codes.

All destroy plans begin with reviewed, comment-first sections.

Next Steps
Re-run function-length audit and refactor any remaining long blocks before next release cycle.



## PHASE 3.1 — ZFS-diff fast path & deterministic per-run logging (2026-01-24, Status: ✅ Complete)

Summary

- New opt-in fast-path: `-z` / `--zfs-diff` — compare and cleanup prefer `zfs diff` via the `sff_zfs_diff` wrapper. Absence of `-z` preserves legacy `find` behavior.
- Command wrappers: `sff_run` and `sff_zfs_diff` centralize command logging, normalize `zfs` invocation quirks, handle retries, and log outputs to `commands.log`.
- Deterministic per-run artifacts: persistent outputs are placed under `LOG_DIR_ROOT=/tmp/sff/<SHORT_TIMESTAMP>/` with stable filenames (comparison.out, comparison-delta.out, comparison-summary.csv, acc_deleted files, destroy-plan files).
- Evidence aggregation & vetting: the cleanup planner aggregates `sff_acc_deleted*` evidence and prevents proposing destroys that touch referenced snapshots; datasets with any sacred snapshots are protected.
- Enhanced destroy plans: plans are comment-first and include multi-line `# BECAUSE:`, `# DETAIL:`, and `# Command:` blocks with exact `zfs destroy` invocations for operator review.
- Tests & helpers: updated tests to look for per-run summary patterns and added function-length helpers.

Files changed (high-level)

- `lib/common.sh` — added `LOG_DIR` setup, `sff_run`, `sff_zfs_diff`, and `-z` parsing.
- `lib/zfs-compare.sh` — deterministic artifact names and pathway for zfs-fast-compare.
- `lib/zfs-cleanup.sh` — per-run deterministic names, `_prepare_cleanup_temp_files`, `_write_destroy_plan`, `_aggregate_evidence_into_sacred`, `_vet_plan_against_acc_files`, and dataset-level protection.
- `tests/*` — updated expectations for per-run artifacts and added logging helpers.
- `tools/count_funcs.*` — function-length helpers added.
- `agents/bash-expert.md` — guidance and notes added.

Next steps for Phase 3.1

- Wire `-z` into the compare flow and add per-dataset fallback to `find` when `zfs` is unavailable or returns errors.
- Add smoke parity tests verifying `-z` and legacy `-c` produce identical summary CSVs for fixtures.
- Sweep the codebase for any remaining `${SHORT_TIMESTAMP}_` filename occurrences and ensure all persistent artifacts land under `LOG_DIR`.

These updates (2026-01-24) harden safety, make artifacts deterministic, and add an opt-in zfs-diff fast path; the full zfs-fast-compare implementation and per-dataset fallback remain next tasks.

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

## Test-run workflow (runner provided)

- A lightweight smoke-test runner script is available at `tests/run_smoke_tests.sh` to execute canonical smoke checks and produce a single consolidated log at `tests/smoke.log`.
- The runner truncates `tests/smoke.log` before each run so the file reflects only the most recent test execution. This ensures reproducible manual testing and simplifies log review.
- `tests/smoke.log` is ignored by Git via `.gitignore` to avoid accidental commits.

Recommended usage:

1. Run the smoke tests locally:

```bash
bash tests/run_smoke_tests.sh
```
<!-- patch-test: append marker -->

2. After completion, examine `tests/smoke.log` or request the automation agent to read it back for triage.

3. Iterate on fixes and re-run until results are acceptable.

Note: This runner is intentionally lightweight and not a replacement for a fixture-driven `--test-mode` harness. It provides a fast way to collect runtime output and logs while we build a more complete automated test harness.
ADDED NEW FUNCTIONS TO ZFS-SEARCH
- added `process_snapshots_for_dataset()` improvements
- fixed xargs quoting for compare mode
- updated temporary file handling

----

PHASE 3.1 — ZFS‑diff Fast Path & Deterministic Logging (2026‑01‑24, Status: ✅ Complete)
Overview
Introduced an optional zfs diff fast‑path and deterministic per‑run directories for reproducible comparison and cleanup workflows.

Key Additions
Added -z / --zfs-diff flag for compare operations.

Implemented wrappers (sff_run, sff_zfs_diff) for consistent command logging and retry logic.

Deterministic logging under /tmp/sff/<SHORT_TIMESTAMP>/.

Cleanup planner aggregates evidence to prevent deleting sacred snapshots.

Destroy plans include multi‑line # BECAUSE:, # DETAIL:, and # Command: blocks.

Introduced lib/zfs-bench.sh for benchmark and test separation.

Next Steps
Complete zfs-fast-compare integration with fallback to find.

Add parity tests verifying identical summary CSV outputs.

Sweep legacy filenames for deterministic logging compliance.

## PHASE 3.2 — ZFS Search Optimization (2026-02-04, Status: 🧩 Planned)

Goal

- Extend `zfs diff` acceleration to snapshot-to-snapshot and non-compare search flows.

Success criteria

- `zfs_fast_search()` produces artifacts identical to legacy logic.
- Automatic per-dataset fallback to `find` when `zfs` fails.
- Smoke parity tests confirm equivalent missing-file counts.

Implementation plan

1. Audit `find` usage across `lib/zfs-search.sh` and related modules.
2. Implement `zfs_fast_search()` using `sff_zfs_diff` and `sff_run` wrappers.
3. Wire an optional `-z` / `--zfs-diff` toggle for non-compare runs.
4. Log all fallbacks to `commands.log` and record per-dataset fallback reasons.
5. Add smoke parity tests and a fixture harness to verify equivalence.
6. Update documentation and help text.

Constraints

- Maintain safety-first deletion model (`ALLOW_DESTROY_SNAPS`, `CREATE_DELETE_PLAN`).
- Do not alter artifact structure; persistent outputs must remain under per-run `LOG_DIR`.
- Provide per-dataset fallbacks to avoid inconsistent behavior.

----

 
## PHASE 4 — Rename CLI + Promote zfs-diff to Non-Compare Runs (2026-03-01, Status: 🧩 Planned)

- Objective

- Minor (docs-first): rename the canonical CLI for plan generation to `--create-destroy-plan` (`-p`) and repurpose `--clean-snapshots` to request execution of a generated plan (distinct semantics: plan-only vs execution-request).
- Major (behavior): enable `zfs diff` as the preferred fast-path for non-compare runs (non-`-c`), replacing `find`-based enumeration where safe and validated; provide per-dataset fallback to `find` when `zfs` is unavailable or unsuitable.

Rationale

- The rename reduces operator confusion: `--create-destroy-plan` clearly communicates plan-only semantics.
- Promoting `zfs diff` to non-compare runs significantly improves speed and accuracy for many workloads; doing it in a staged, tests-first manner reduces risk.

- Scope (what this phase will/do not do)

- Includes: docs rename and CLI semantic update (`--create-destroy-plan` = plan-only, `--clean-snapshots` = execution-request), opt-in `-z/--zfs-diff` wiring into non-compare flows, per-dataset zdiff logging, parity smoke tests, and a staged promotion to default after verification.
- Excludes: changing plan-first safety controls (`ALLOW_DESTROY_SNAPS` stays gated) and removing the ability to use `find` as a fallback or opt-out.

Implementation Plan (phased)


# Snapshot-Only Pruning — Q&A, Safety Checklist, and Implementation Plan

Q: What if I only want to compare snapshots to each other and prune identical snapshots?

A: You can compare snapshots pairwise (e.g., adjacent snapshots) using `zfs diff` (via `sff_zfs_diff`) and detect identical snapshots. However, file-level equality alone is not sufficient to guarantee safe deletion. The following checklist, commands, and policies show a safe, auditable approach to snapshot-only pruning.

## Why snapshot-only deletion is risky
- Identical file trees between snapshots do not prove the snapshot is safe to destroy: ZFS metadata (holds, clones, bookmarks) or external tooling (replication) may reference a snapshot.
- Destroying a snapshot referenced by a clone, hold, or replication workflow can fail or break recovery/replication chains.

## Safe snapshot-only pruning (recommended flow)
1. Identify snapshots sorted by creation:
   - `zfs list -t snapshot -o name -s creation -r pool/dataset`
2. Compare adjacent snapshots (cheap):
   - `sff_zfs_diff pool/dataset@old pool/dataset@new`
   - If zdiff output is empty and exit code is 0 → mark `old` as redundant candidate.
3. For each candidate, run pre-delete safety checks:
   - Ensure no holds: `zfs holds -H pool/dataset@<snap>` (expect empty)
   - Ensure no clones: `zfs get -H -o value clones pool/dataset@<snap>` (expect `-` or empty)
   - Check bookmarks and replication references (project-specific tooling/manual audit)
4. Policy rules (configurable):
   - Keep at least one snapshot in an identical run (e.g., keep the newest).
   - Require a minimum age (e.g., `--min-age DAYS`) before considering deletion.
   - Optionally require identical comparisons across multiple neighbors before pruning.
5. Always generate a destroy plan first:
   - Keep `CREATE_DELETE_PLAN=1` default; plans are written to `LOG_DIR` and include `# BECAUSE:` and `# CHECK:` annotations.
   - Actual `zfs destroy` must only run when `ALLOW_DESTROY_SNAPS=1` is set in `lib/common.sh` and operator confirms interactively.

## Operator audit & verification
- The operator running the command must be shown the verification artifacts and suggested commands: print the `sff_zfs_diff` command used, the zdiff output file path under `LOG_DIR`, and a suggested verification command such as:
  - `sff_zfs_diff pool/dataset@old pool/dataset@new | less`
- Persist all pre-delete checks and zdiff outputs under the run `LOG_DIR` so an operator can review before applying any plan.

## Command semantics and UX decisions (docs-first)
  - Canonical flag: `--create-destroy-plan` (`-p`) — generates a plan only and implies snapshot-compare behavior when appropriate.
  - Execution flag: `--clean-snapshots` — requests cleanup execution for the generated plan in the same run (still subject to `ALLOW_DESTROY_SNAPS` master guard and interactive confirmation).
- Behavior: when `-p` is specified the tool will implicitly enable snapshot-compare flows (equivalent to `-c` for pruning) so operators need not pass `-c` explicitly for snapshot pruning.
- Zdiff opt-in: `-z` / `--zfs-diff` controls whether `sff_zfs_diff` is preferred; `-z` with `-p` will prefer zdiff and fall back per-dataset to `find` when zdiff fails (fallbacks are logged).

## Verbosity and operator-facing output
- Default (`-p`): short summary of candidates and counts; no per-file listing unless `-v`.
- `-p -v`: include summarized pre-delete check results for each candidate (holds/clones status, zdiff-exit status, short log paths).
- `-p -vv`: include full per-candidate logs and zdiff outputs inlined or linked as file paths under `LOG_DIR`.
- Machine-readable outputs (CSV, plan files) remain ANSI/color-free; human-readable colorized text goes to `stderr`.

## Color preferences
- We'll collect operator color preferences (which elements should be red/yellow/pink/etc.) and document the agreed mapping in PRD. Pink is reserved for rare, high-importance markers only.
  - white is reserved for zfs data such as snapshot names and dataset names,ask if you have a good suggestion to use it on something else as well
  - green is for zfs filnames, ask if you have a good suggestion to use it on something else as well
  - pink hasnt been used yet, it can be reserved for very special cases, but do not want it for wide spread usage

## Suggested commands (examples)
- List snapshots sorted by creation:
  - `zfs list -t snapshot -o name -s creation -r pool/dataset`
- Compare two adjacent snapshots (operator verification):
  - `sff_zfs_diff pool/dataset@2026-01-01 pool/dataset@2026-01-02 | less`
- Check holds and clones for a candidate snapshot:
  - `zfs holds -H pool/dataset@2026-01-01`
  - `zfs get -H -o value clones pool/dataset@2026-01-01`

## Implementation options (docs-first; code only on approval)
-- Implement `--create-destroy-plan` (`-p`) as the canonical plan generator and implement `--clean-snapshots` to request execution of the generated plan in the same run.
- Implement a `--snap-only-compare` or make `-p` imply the snapshot-compare behavior (preferred: `-p` implies compare for pruning).
- Wire `sff_zfs_diff` into the pruning flow when `-z` is present; record per-dataset zdiff outputs and fallback reasons to `commands.log`.
- Generate the destroy-plan with annotated `# BECAUSE:` and `# CHECK:` lines for every candidate.

## Operator approval
-  After you approve the PRD changes we will:
  1. Audit all occurrences and update docs/tests: replace plan-generation examples with `--create-destroy-plan` and use `--clean-snapshots` where an execution request is intended.
  2. Implement `-p` parse semantics so it implies snapshot-compare for pruning. (This begins the Major part)
  3. Wire `-z` into pruning flow with per-dataset fallback and detailed logging.
  4. Add deterministic fixture-driven parity tests and operator-review output.

1) Docs-only (non-destructive)
  - Update `PRD.md`, `readme.md`, and examples to show `--create-destroy-plan` (`-p`) as canonical.
  - Add unit/acceptance test updates that reference the new name (tests still exercise behavior unchanged).

2) Opt-in integration (non-destructive)
  - Wire `-z` / `--zfs-diff` into non-compare flows so the code calls `zfs_fast_search()` / `sff_zfs_diff` when present.
  - Record per-dataset zdiff outputs under the run `LOG_DIR` and add `commands.log` entries showing zdiff invocations and fallback reasons.
  - Implement per-dataset fallback: on zdiff failure, fall back to the existing `find` logic and record the event, and note it to output that its in fallback mode.

3) Parity verification (tests-first)
  - Add fixture-driven smoke parity tests comparing `-z` vs. legacy `find` outputs for representative datasets. these belong in tests/ folder, as a .sh shell script.
  - Ensure machine-readable artifacts (summary CSVs, `sff_acc_deleted-*.csv`) are identical in acceptance fixtures.

4) Promote to default (after approval)
  - If parity tests pass and operator review approves, change non-compare runs to prefer `zfs diff` by default (with `--no-zdiff` opt-out).
  - Maintain explicit config guard and interactive checks for any destructive apply operations.

- Acceptance Criteria

- Documentation and tests reference `--create-destroy-plan` as the plan-only flag; `--clean-snapshots` as the execution-request flag. Tests and docs show distinct semantics and examples for both.
- Parity smoke tests pass for representative fixtures: summary CSVs and candidate lists match between `zfs diff` and `find` flows.
- Per-dataset fallback behavior is implemented and logged; no silent failures.
- No change to plan-first safety model: disabling `ALLOW_DESTROY_SNAPS` remains effective.

Rollout steps & gating

- Stage A (Docs + CLI alias): merge docs-only update and test name changes; seek operator approval.
- Stage B (Opt-in): merge `-z` wiring for non-compare runs; run CI and parity tests; demo to operator.
- Stage C (Promote): after operator sign-off and proven parity in CI, flip default preference to `zfs diff` for non-compare runs and add a `--no-zdi` opt-out. Announce change and retain the alias deprecation window.

Risks & Mitigations

- zfs-specific edge cases (encryption, very large snapshots): mitigate by per-dataset fallback to `find` and conservative timeouts/retries in `sff_zfs_diff` if it turns out zdiff is slower or another good reason.
- Diverging outputs between `zfs diff` and `find`: mitigate by requiring parity fixtures and operator sign-off before promotion.
- Performance regressions for some datasets: measure with `lib/zfs-bench.sh` and provide revert/opt-out flags.  Skip this part for now, it can be a followup.  if we get past Phase 4, and you read this part, then ask if its time to implement/run this yet. 

Developer notes

- Keep plan-generation, audit content, and master-guard behavior unchanged.
- Log all zdiff invocations and fallback reasons into `commands.log` under the run `LOG_DIR` for post-run audits.
- Tests added in this phase must be deterministic and fixture-driven; avoid flakiness by mocking `zfs` outputs where practical.

If you approve this rewrite, I'll apply it to `PRD.md` now (docs-only). After approval we can branch and start the opt-in implementation and parity tests.
