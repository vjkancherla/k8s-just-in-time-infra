#!/usr/bin/env bash
# CI06: the pipeline is report-only, hardened and written down.
. "$(dirname "$0")/lib.sh"

describe "The pipeline is report-only, hardened and written down" <<'EOF'
Proves: a newer push cancels its superseded run, main asks for no checks, the
        final run is green in both jobs with every suite literal present, and
        the README plus the design note describe the pipeline.
How:    checks the queue rule in ci.yml locally; asks the API about main's
        protection; watches the branch's latest run to green and an earlier
        run to cancelled; greps the logs and the docs.
Needs:  the ci/CI06 branch pushed with ci.yml, a PR open, two quick pushes so
        the first run is superseded, gh logged in. The live half takes up to
        ~45 minutes while the final run is in flight.
EOF

WF=".github/workflows/ci.yml"
BRANCH="$(git branch --show-current)"
export BRANCH WF
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
export REPO

require "ci.yml parses as YAML" "$WF" \
  python3 -c "import yaml; yaml.safe_load(open('$WF'))"

check_eq "one queue rule cancels superseded runs on the same ref" "$WF, top-level concurrency" \
  "ci-group true" "$(python3 -c "import yaml; c=yaml.safe_load(open('$WF')).get('concurrency', {}); print(('ci-group' if 'github.ref' in str(c.get('group', '')) else str(c.get('group', ''))), str(c.get('cancel-in-progress', '')).lower())")"

check "main asks for no checks, so red never blocks a merge" "gh api branches/main/protection" \
  bash -c '
    out="$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null)" \
      || { echo "branch main is unprotected: no required checks"; exit 0; }
    echo "$out" | python3 -c "
import json, sys
r = json.load(sys.stdin).get(\"required_status_checks\")
if not r or (not r.get(\"checks\") and not r.get(\"contexts\")):
    print(\"protection exists but requires no checks\")
else:
    print(\"required checks present: %s\" % r)
    sys.exit(1)"'

require "this branch has a CI run" "push the branch and open a PR - the pull_request trigger starts it" \
  bash -c 'test -n "$(gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 --json databaseId --jq ".[0].databaseId")"'

RUN="$(gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
export RUN
note "using latest run $RUN (watching if still in flight)"

check "the latest run finishes green in both jobs" "run it after the final green run - gh run view $RUN" \
  bash -c 'gh run watch "$RUN" --exit-status && test "$(gh run view "$RUN" --json jobs --jq "[.jobs[].conclusion] | all(. == \"success\")")" = "true"'

check "the final run reached every suite literal" "gh run view $RUN --log" \
  bash -c 'log="$(gh run view "$RUN" --log 2>/dev/null)"; echo "$log" | grep -qF "===== 17 PASS, 0 FAIL =====" && echo "$log" | grep -qF "===== 11 PASS, 0 FAIL =====" && echo "$log" | grep -q "skipping the browser suite" && echo "$log" | grep -q "32 passed"'

check_eq "the green run sits on the PR head, before main" "gh pr view $BRANCH --json headRefOid" \
  "$(gh pr view "$BRANCH" --json headRefOid --jq .headRefOid)" "$(gh run view "$RUN" --json headSha --jq .headSha)"

check "an earlier run on the branch was cancelled by supersede" "push twice in quick succession so the first run is stale - V9" \
  bash -c '
    for id in $(gh run list --branch "$BRANCH" --workflow ci.yml --limit 5 --json databaseId,conclusion --jq ".[] | select(.databaseId != $RUN) | .databaseId"); do
      c="$(gh run view "$id" --json conclusion --jq .conclusion)"
      if [ "$c" = "cancelled" ]; then echo "run $id cancelled by supersede"; exit 0; fi
    done
    echo "no cancelled run on $BRANCH besides $RUN"; exit 1'

check "the README points at the pipeline" "README.md Key documents" \
  bash -c 'grep -q "workflows/ci.yml" README.md'

check "the design note records the required-checks decision" "docs/designs/ci-pipeline.md" \
  bash -c 'grep -q -i "required checks" docs/designs/ci-pipeline.md && grep -q -i "defer" docs/designs/ci-pipeline.md'

finish
