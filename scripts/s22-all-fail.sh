#!/usr/bin/env bash
# S22's own record builder (there is no scripts/checks/S22.sh by design).
# Re-runs every Stage-H checkpoint through scripts/checkpoint.sh - the only
# sanctioned way to run one - and derives the summary from the captured logs.
# Nothing here is typed: every line in docs/evidence/s22-all-fail.log is
# written from an executed run.
#
# Expected while nothing is implemented: every checkpoint FAILs on its stated
# precondition (or its named assertion), no syntax error, none passes.
#
#   scripts/s22-all-fail.sh              verify the all-fail state; emit summary
#   scripts/s22-all-fail.sh --capture    also write docs/evidence/s22-all-fail.log
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }
DFS="23 24 25 26 27 28 29"
ok=1

if [ "${1:-}" = "--capture" ]; then
  out=docs/evidence/s22-all-fail.log
  { echo "# S22 pre-flight checkpoint run - captured, never typed"
    echo "# started  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# commit   $(git rev-parse --short HEAD 2>/dev/null || echo none)"
    echo "# command  scripts/s22-all-fail.sh --capture   (runs scripts/checkpoint.sh for NN in 23..29 and derives this from the captured logs)"
    echo "# purpose: every Stage-H checkpoint asserts something real"
    echo "#          each fails readable before any implementation, 0 syntax errors"
  } > "$out"
else
  out=/dev/stdout
fi

for n in $DFS; do
  echo "--- S$n" >> "$out"
  if ! bash -n "scripts/checks/S$n.sh" 2>>"$out"; then ok=0; continue; fi
  ./scripts/checkpoint.sh "$n" >/dev/null 2>&1; rc=$?
  reason="$(grep -m1 '^FAIL' "docs/evidence/S$n.log" || true)"
  if [ "$rc" -eq 0 ]; then
    ok=0; echo "S$n PASSED unexpectedly" >> "$out"
  elif [ -n "$reason" ]; then
    echo "$reason" >> "$out"
  else
    ok=0; echo "S$n failed with no FAIL: line (rc=$rc)" >> "$out"
  fi
done

if [ "$ok" -eq 1 ]; then
  echo "PASS S22 pre-flight: 7 checkpoints, all failing readable, 0 syntax errors" >> "$out"
  echo "PASS" >> "$out"
else
  echo "FAIL S22 pre-flight: see the S-lines above" >> "$out"
fi
[ "$ok" -eq 1 ] || exit 1
[ "${1:-}" = "--capture" ] && echo "captured: docs/evidence/s22-all-fail.log"
