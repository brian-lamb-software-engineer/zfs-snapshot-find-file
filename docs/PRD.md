# Snapshot Reducer — Product Requirements Document (PRD)

Purpose
- Reduce wasted space from ZFS snapshots by identifying redundant snapshots and suggesting safe deletions.
- Detect potentially accidentally deleted files on live datasets by comparing live dataset contents to snapshot contents.

Scope (Phase 1)
- Catalog and inspect the current codebase split across `snapshots-find-file` ("sff") and `lib/*.sh`.
- This phase is strictly cataloging: do not change functionality or refactor code. The refactor into modular functions (<=60 lines each) is Phase 2.

Goals (Phase 1 — Cataloging)
- Keep code DRY: treat `lib/common.sh` as the shared utilities file (special case) used by other `lib/*.sh` files.
- Do not modify behaviour or move code in this phase; only identify code that has not yet been moved off `snapshots-find-file` into `lib/`.
- Build an actionable mapping of which functions live in which files and list any residual code in `snapshots-find-file` that still needs extraction.
- Safe defaults: confirm no destructive operations will be executed as part of cataloging.

Constraints & Non-goals
- This phase is an inspection + cataloging step; no snapshot deletions will be executed and no behavior will be changed.
- Platform: primary runtime is Linux with `zfs`, `find`, `xargs`, `sudo` available.

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
- Add `--dry-run` and `--force` flags and require an explicit `--confirm-destroy` flag (or environment variable) to actually execute any `zfs destroy` calls.
- Add a final interactive confirmation step and require an opt-in guard such as `SFF_ALLOW_DESTROY=1` for automated runs.
- Record and publish a pre-destroy report (what would be destroyed) and require human review before allowing the actual destroy operation to proceed.

---
Generated: $(date -u)

Commit message guidelines (project-wide)
Header: 4-8 words, ALL CAPS, concise (single line).
- Immediately on the next line, start bullet lines with a hyphen (no bullets) followed by a single space and concise text (no blank line allowed between header and bullets).
- Use 1-4 bullet lines total.
- Keep the message focused and high-level; implementation details belong in the PR body.

Example
ADDED NEW FUNCTIONS TO ZFS-SEARCH
- added `process_snapshots_for_dataset()` improvements
- fixed xargs quoting for compare mode
- updated temporary file handling