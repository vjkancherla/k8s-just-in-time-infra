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
    echo "# command  scripts/s22-all-fail.sh --capture   (lint first, then runs scripts/checkpoint.sh for NN in 23..29 under a 240s watchdog each, derives this from the captured logs)"
    echo "# purpose: every Stage-H checkpoint asserts something real"
    echo "#          each fails readable before any implementation, 0 syntax errors"
  } > "$out"
else
  out=/dev/stdout
fi

# lint first: the two runaway shapes the stage has hit once each -
# recursion-in-wrapper (the kk helper) and unbounded wait loops - must ship no
# further. Anything found stops the pre-flight with no checkpoint ran.
if ! bash scripts/checks/lint-helpers.sh; then
  echo "FAIL S22 pre-flight: lint-helpers found a runaway-execution shape (written to stderr)" >> "$out"
  fail "lint-helpers found a runaway-execution shape - fix it before the pre-flight"
fi

for n in $DFS; do
  echo "--- S$n" >> "$out"
  if ! bash -n "scripts/checks/S$n.sh" 2>>"$out"; then ok=0; continue; fi

  # hard wall-clock bound, foreground: perl's alarm kills a wedged child at
  # 240s (four resync ticks + margin) and nothing is left running in the
  # background, so the batch can cost exactly one timeout and no more. No
  # background subshells: their inherited stdout holds a caller's pty open,
  # which wedged two earlier - real - capture runs of this stage.
  rc=0
  perl -e 'alarm 240; exec @ARGV' ./scripts/checkpoint.sh "$n" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 142 ] || [ "$rc" -ge 137 ]; then
    ok=0
    echo "S$n: did not return within the 240s alarm (rc=$rc) - see docs/evidence/S$n.log" >> "$out"
    continue
  fi
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
if [ "${1:-}" = "--capture" ]; then echo "captured: docs/evidence/s22-all-fail.log"; fi
