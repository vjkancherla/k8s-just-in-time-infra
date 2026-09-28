#!/usr/bin/env bash
# Copied from the build-plan skill's checkpoint-runner-template in the S22 stage
# pre-flight. FROZEN, like scripts/checks/. Nobody edits this after S22.
#
# This is the only sanctioned way to run a Stage-H checkpoint:
#
#     scripts/checkpoint.sh SNN              e.g. scripts/checkpoint.sh 23
#     scripts/checkpoint.sh SNN <logfile>    reviewer, to avoid overwriting evidence
#
# Running scripts/checks/SNN.sh directly produces no artefact, so the pass cannot be
# reviewed and does not count. `make check` stays as the bare entrail-reader for the
# older steps; Stage H evidence always names `docs/evidence/SNN.log`.
set -euo pipefail

NN="${1:?usage: scripts/checkpoint.sh <NN> [logfile]   e.g. scripts/checkpoint.sh 23}"

case "$NN" in
  ''|*[!0-9]*) ;;
  *) NN="$(printf '%02d' "$((10#$NN))")" ;;
esac
check="scripts/checks/S${NN}.sh"
log="${2:-docs/evidence/S${NN}.log}"

if [ ! -f "$check" ]; then
  echo "FAIL: $check does not exist - checkpoints are all written in S22, before any implementation"
  exit 1
fi

# A checkpoint is frozen. An uncommitted edit to one is a stop trigger, not a nuance.
if [ -n "$(git status --porcelain -- "$check" 2>/dev/null)" ]; then
  echo "FAIL: $check has uncommitted changes - checkpoints are frozen. Revert it, then re-run."
  git --no-pager diff --stat -- "$check" || true
  exit 1
fi

mkdir -p "$(dirname "$log")"

{
  echo "# S${NN} checkpoint run - captured, never typed"
  echo "# started  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# commit   $(git rev-parse --short HEAD 2>/dev/null || echo 'not a git repo')"
  echo "# pending  $(git status --porcelain -- . ":(exclude)$log" 2>/dev/null | wc -l | tr -d ' ') uncommitted change(s)"
  echo "# host     $(hostname 2>/dev/null || echo unknown) as ${USER:-unknown}"
  echo "# command  bash $check"
  echo "# --- raw output follows - do not edit anything below this line ---"
} >"$log"

rc=0
bash "$check" >>"$log" 2>&1 || rc=$?
echo "# exit     $rc" >>"$log"

if [ "$rc" -ne 0 ]; then
  echo "FAIL: S${NN} exited ${rc}. Evidence: $log"
  exit "$rc"
fi

if ! grep -qEi '(^|[^[:alnum:]_])pass([^[:alnum:]_]|$)' "$log"; then
  echo "FAIL: S${NN} exited 0 but never reported a PASS. It asserts nothing. Evidence: $log"
  exit 1
fi

echo "PASS: S${NN} exited 0. Evidence: $log - commit it in this step's commit, not a later one."
