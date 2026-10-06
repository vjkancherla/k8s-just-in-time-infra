#!/usr/bin/env bash
# scripts/ci-checkpoint.sh - the CI build plan's checkpoint runner.
#
#     scripts/ci-checkpoint.sh CI<NN>              run step CI<NN>: every check narrated,
#                                                  output saved to docs/evidence/CI<NN>.log
#     scripts/ci-checkpoint.sh CI<NN> --explain    what step CI<NN> will check; runs nothing
#     scripts/ci-checkpoint.sh all                 run every CI checkpoint that exists, then a summary
#
# This is separate from the frozen Stage-H runner (scripts/checkpoint.sh) and the frozen
# Stage-H checkpoints (scripts/checks/S*.sh): their file names and evidence logs are never
# touched. This runner only ever looks at scripts/checks/CI*.sh and docs/evidence/CI*.log.
#
# The run is shown in the terminal and saved to docs/evidence/CI<NN>.log, so a reviewer in
# a later session can read what happened.
set -euo pipefail

usage="usage: scripts/ci-checkpoint.sh <CI<n> | all> [--explain]   e.g. scripts/ci-checkpoint.sh CI7"
NN="${1:?$usage}"

if [ "$NN" = "all" ]; then
  passed=0; failed=0; summary=""
  for c in scripts/checks/CI[0-9]*.sh; do
    [ -f "$c" ] || continue
    n="$(basename "$c" .sh)"          # CI07
    if "$0" "$n"; then
      passed=$((passed + 1)); summary="${summary}  ok    ${n}"$'\n'
    else
      failed=$((failed + 1)); summary="${summary}  FAIL  ${n}"$'\n'
    fi
    echo
  done
  echo "== all CI checkpoints"
  printf '%s' "$summary"
  echo
  if [ "$failed" -gt 0 ]; then
    echo "FAIL: ${failed} of $((passed + failed)) checkpoints failed"
    exit 1
  fi
  if [ "$passed" -eq 0 ]; then
    echo "FAIL: no checkpoints found in scripts/checks/CI*.sh"
    exit 1
  fi
  echo "PASS: ${passed} of ${passed} checkpoints passed"
  exit 0
fi

# Accept CI7, ci7, 7 as well as CI07.
n="${NN#CI}"; n="${n#ci}"
case "$n" in
  ''|*[!0-9]*) echo "FAIL: '$NN' is not a CI step id - use CI1..CIn or all" >&2; exit 1 ;;
  *) n="$(printf '%02d' "$((10#$n))")" ;;
esac
check="scripts/checks/CI${n}.sh"

if [ ! -f "$check" ]; then
  echo "FAIL: $check does not exist yet - it is written when step CI${n} starts"
  exit 1
fi

# --explain: the summary and the list of checks. Nothing executed, nothing saved.
if [ "${2:-}" = "--explain" ]; then
  CHECKPOINT_EXPLAIN=1 bash "$check"
  echo "   It will check, in order:"
  grep -E '^[[:space:]]*(check|check_eq|require|require_eq)[[:space:]]+"' "$check" \
    | sed -E 's/^[[:space:]]*(require[a-z_]*)[[:space:]]+"([^"]*)".*/     - \2   (stops the run if it fails)/; s/^[[:space:]]*check[a-z_]*[[:space:]]+"([^"]*)".*/     - \1/' \
    || echo "     (none found - this checkpoint asserts nothing)"
  echo
  echo "   Nothing was run. To run it: scripts/ci-checkpoint.sh CI${n}"
  exit 0
fi

log="docs/evidence/CI${n}.log"
mkdir -p "$(dirname "$log")"

{
  echo "# CI${n} checkpoint run"
  echo "# started  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# commit   $(git rev-parse --short HEAD 2>/dev/null || echo 'no commit yet')"
  echo "# check    $(git hash-object "$check" 2>/dev/null || echo unknown)"
  echo "# ---"
} >"$log"

# Shown and saved at once. The exit code is the checkpoint's, not tee's.
set +e
bash "$check" 2>&1 | tee -a "$log"
rc="${PIPESTATUS[0]}"
set -e
echo "# exit     $rc" >>"$log"

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

# Exit 0 is not enough: the verdict line is printed only by finish in lib.sh, after at
# least one check ran and none failed.
if ! grep -q "^PASS: CI${n} " "$log"; then
  echo "FAIL: CI${n} exited 0 but reached no PASS verdict - it asserts nothing"
  exit 1
fi
