#!/usr/bin/env bash
# lec_summary.sh — re-read build/fe/lec_*.log and print one line per module.
# Useful after a long lec_check.sh run, or while one is still going.
cd "$(dirname "$0")/.."
for f in build/fe/lec_*.log; do
  [[ -e $f ]] || continue
  m=$(basename "$f" .log); m=${m#lec_}
  if grep -q "Equivalence successfully proven" "$f" 2>/dev/null; then
    printf "  %-16s EQUIVALENT\n" "$m"
  elif grep -q "unproven .equiv cells in .equiv_status" "$f" 2>/dev/null; then
    n=$(grep -oE "Found [0-9]+ unproven" "$f" | tail -1 | grep -oE "[0-9]+")
    printf "  %-16s UNPROVEN (%s cells)\n" "$m" "$n"
  else
    printf "  %-16s incomplete / running\n" "$m"
  fi
done
