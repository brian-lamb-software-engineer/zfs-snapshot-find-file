#!/bin/bash
set -euo pipefail
LOG=new.log
: > "$LOG"
./snapshots-find-file -cvv -d "/nas/live/cloud/tcc" -s "*" --clean-snapshots -f "*" >> "$LOG" 2>&1 || true
summary=$(grep -oE "/tmp/.*/comparison-summary\\.csv" "$LOG" | tail -n1 || true)
echo -e "\n--- summary_csv: ${summary:-<none>} ---" >> "$LOG"
if [[ -n "$summary" && -f "$summary" ]]; then
  echo -e "\n--- CSV contents (first 200 lines) ---" >> "$LOG"
  sed -n '1,200p' "$summary" >> "$LOG" 2>&1 || true
  echo -e "\n--- Human-readable summary ---" >> "$LOG"
  awk -F, 'NR>1 { if($1=="total_snapshot_entries") print "Total snapshot entries processed: "$2; else if($1=="ignored_entries") print "Total ignored entries: "$2; else if($1=="found_in_live") print "Total found in live dataset: "$2; else if($1=="missing") print "Total missing (snapshot-only): "$2; else if($1=="skipped_duplicates") print "Total skipped (duplicates): "$2 }' "$summary" >> "$LOG" 2>&1 || true
else
  echo "No summary CSV found in run output." >> "$LOG"
fi
echo "WROTE: $LOG"
