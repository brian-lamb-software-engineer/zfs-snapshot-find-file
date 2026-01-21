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

Phase 3: Finalize Snapshot Deletion Workflow
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
