#!/usr/bin/env bash
# Copied from the build-plan skill's review-guard-template in the S22 stage
# pre-flight, with the evidence path moved to docs/evidence/ (this repo's location).
# FROZEN.
#
#     scripts/review-guard.sh SNN        e.g. scripts/review-guard.sh 23
#
# Refuses a hand-over with an abbreviated prompt or no captured evidence behind it.
# It must print PASS before the prompt goes anywhere.
# SNN accepts an optional two-form evidence override:
#     scripts/review-guard.sh SNN <logfile>   for retro-steps like S22, whose
#                                             record is docs/evidence/s22-all-fail.log
set -euo pipefail

NN="${1:?usage: scripts/review-guard.sh <NN> [logfile]   e.g. 23}"

case "$NN" in
  ''|*[!0-9]*) ;;
  *) NN="$(printf '%02d' "$((10#$NN))")" ;;
esac

p="docs/reviews/S${NN}-review-prompt.md"
e="${2:-docs/evidence/S${NN}.log}"

fail() { echo "FAIL: $1"; exit 1; }

# --- 1. The prompt is the template, verbatim -------------------------------------------
[ -f "$p" ] || fail "$p does not exist - generate it from docs/reviews/REVIEW-PROMPT-TEMPLATE.md"

grep -qi "would it still pass if the core logic" "$p" \
  || fail "$p was abbreviated - regenerate it from the template, verbatim"

n="$(grep -cE '^[0-9]+\. ' "$p" || true)"
[ "$n" -ge 12 ] || fail "$p contains $n numbered question(s); the template has 12"

if grep -nE '\[(STEP|NN|TOPIC|GOAL|COMMIT_RANGE|FILES)\]' "$p"; then
  fail "$p still contains unsubstituted slots"
fi

# --- 2. There is evidence behind the hand-over ----------------------------------------
[ -f "$e" ] || fail "$e does not exist - run scripts/checkpoint.sh ${NN} before committing"
[ -s "$e" ] || fail "$e is empty"

grep -qEi '(^|[^[:alnum:]_])pass([^[:alnum:]_]|$)' "$e" \
  || fail "$e reports no PASS - the checkpoint did not pass"

grep -q '^# S' "$e" \
  || fail "$e was not written by scripts/checkpoint.sh - evidence is captured, never typed"

# --- 3. It is committed, and inside the range the review will actually look at ----------
git ls-files --error-unmatch "$e" >/dev/null 2>&1 \
  || fail "$e is untracked - a log outside the commit is not evidence"

range="$(grep -oE 'git diff [^ `]+' "$p" | head -1 | sed 's/^git diff //')"
[ -n "$range" ] || fail "no commit range found in $p - was the COMMIT_RANGE slot left blank?"

if ! git diff --name-only "$range" 2>/dev/null | sed 's/^[[:space:]]*//' | grep -qx "$e"; then
  fail "$e does not appear in 'git diff $range' - the reviewer never sees it. Use
       <previous step sha>..<this step sha>, and commit the log with the code."
fi

echo "PASS: $p intact ($n numbered questions); $e present, committed and inside $range"
