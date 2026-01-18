## Project Context

Entrypoint:
- snapshots-find-file.sh (a.k.a. sff) (orchestrates all flows)

Libraries:
- lib/common.sh – DRY (do not repeat yoruself) functions that are relevant for calling from multiple files listed below, in a central place
- lib/zfs-cleanup.sh – functions for zfs cleanup , sort of a common libs file for 
- lib/zfs-search.sh – functions for the searching of files inside zfs snapshots and live datasets 
- lib/zfs-compare.sh - functions that compare live zfs dataset files against the snapshot files themselves

Docs:
- PRD.md - product requirements document, which contains project details
- CATALOG.md - function maps, and mroe details on file contents

AGENT: do not run git add/commit/push; present commit message only.
AGENT: keep original comments and placement when moving code.