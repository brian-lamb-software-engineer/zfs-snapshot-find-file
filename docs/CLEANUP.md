Cleanup and destroy scenarios
---------------------------

1) Generate suggestions and a destroy-plan (dry-run):

Run compare and then request deletion orchestration. This will only write a plan and print "WOULD delete" lines; no destroys run.

```bash
./snapshots-find-file -c -d "/nas/live/cloud" --delete-snapshots -s "*" -f "index.html"
```

After running you'll find a plan at `/tmp/destroy-plan-<timestamp>.sh` and human-readable `WOULD delete` lines in the CLI output. Review the plan before applying.

2) Interactive apply (flag-driven):

Request destroy orchestration with the `--destroy-snapshots` flag. The script will prompt before executing the generated plan.

```bash
./snapshots-find-file -c -d "/nas/live/cloud" --destroy-snapshots -s "*" -f "index.html"
```

You will be asked: `Execute destroy plan now? [y/N]` — answer `y` to run the plan. A log of executed destroys is written to `/tmp/destroy-exec-<timestamp>.log`.

3) Force destroy option:

If you need to include `-f` when calling `/sbin/zfs destroy`, pass `--force` with `--destroy-snapshots`. The generated plan will include `-f` on each destroy line.

```bash
./snapshots-find-file -c -d "/nas/live/cloud" --destroy-snapshots --force -s "*" -f "index.html"
```

4) Advanced: direct function invocation (dry-run)

For debugging you can call the cleanup function directly to generate a plan for a subset of datasets. Note: applying the plan (execution) is best done via the main script using the `--destroy-snapshots` flag so that interactive prompting is handled consistently.

```bash
# dry-run plan generation only (direct invocation)
bash -lc 'source ./lib/common.sh; source ./lib/zfs-cleanup.sh; identify_and_suggest_deletion_candidates "/nas/live/cloud" "/nas/live/cloud/tcc"'
```

Notes:
- The tool is conservative by default — no destroys until you explicitly request them with `--destroy-snapshots`.
- Keep testing with `--delete-snapshots` (dry-run) to verify plans before executing any destroys.
- I did not add a `--yes` flag; interactive confirmation is required before any plan is executed.
