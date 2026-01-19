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
- readme.md - contains product documentation, catalog of function maps, and more details on file contents
- AI_SUMMARY.md - a summary of what you have done, to catch you up on the next session, so read it right away on new session load.

AGENT: do not run git add/commit/push; present commit message only.
AGENT: keep original comments and placement when moving code.
AGENT: DO NOT touch my comments, e.g. # comment, keep them with the code them came with, if youo move the code, take the comments with it. 
AGENT: see AI_SUMMARY.md summary file to get caught up on where we left off.  this file will be updated at the end of a session before closing out for the night, which you will need to pick up on first thing, and keep it clean / maintained for things that are done.  so at the beginning of each session you read it, and when i deem sesion is done, you update it. 
AGENT: never edit smoke log.  it is just a log from the cli smoke test command, and you just read it only, and it erases each time I retest, then ill reinstruct you to read it. 