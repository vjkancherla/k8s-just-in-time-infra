#!/usr/bin/env bash
# CI05: the e2e job runs the console and J suites.
. "$(dirname "$0")/lib.sh"

describe "The e2e job runs the console and J suites" <<'EOF'
Proves: after make test-up, the e2e job runs make console-test (server and
        contract pass, browser skips) and make jit-verify (11 PASS, 0 FAIL),
        finishing inside the 45-minute ceiling - all on the PR before main.
How:    checks the step order and the timeout in ci.yml locally; then watches
        the branch's latest run, asserts both steps succeeded, and greps the
        logs for the skip message and the 11 PASS literal.
Needs:  the ci/CI05 branch pushed with ci.yml, a PR open, gh logged in.
        The live half takes up to ~45 minutes while a run is in flight.
EOF

WF=".github/workflows/ci.yml"
BRANCH="$(git branch --show-current)"
export BRANCH WF

require "ci.yml parses as YAML" "$WF" \
  python3 -c "import yaml; yaml.safe_load(open('$WF'))"

check_eq "e2e runs test-up, then console-test, then jit-verify" "$WF, e2e steps in order" \
  "testup consoletest jitverify" "$(python3 - <<'PY'
import yaml
steps = yaml.safe_load(open('.github/workflows/ci.yml'))['jobs']['e2e']['steps']
runs = [(i, s.get('run', '')) for i, s in enumerate(steps)]
testup = next(i for i, r in runs if 'make test-up' in r)
consoletest = next(i for i, r in runs if 'make console-test' in r)
jitverify = next(i for i, r in runs if 'make jit-verify' in r)
print('testup consoletest jitverify' if testup < consoletest < jitverify else f'{testup} {consoletest} {jitverify}')
PY
)"

check_eq "the e2e job carries the 45-minute ceiling" "$WF, e2e timeout-minutes" \
  "45" "$(python3 -c "import yaml; print(yaml.safe_load(open('$WF'))['jobs']['e2e'].get('timeout-minutes', 'missing'))")"

require "this branch has a CI run" "push the branch and open a PR - the pull_request trigger starts it" \
  bash -c 'test -n "$(gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 --json databaseId --jq ".[0].databaseId")"'

RUN="$(gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
export RUN
note "using latest run $RUN (watching if still in flight)"

check "the latest run finishes green inside the ceiling" "run it after the final green run - gh run view $RUN" \
  gh run watch "$RUN" --exit-status

check_eq "e2e job ran and succeeded on the runner" "gh run view $RUN --json jobs" \
  "success" "$(gh run view "$RUN" --json jobs --jq '.jobs[] | select(.name=="e2e") | .conclusion')"

check_eq "the console-test step succeeded" "gh run view $RUN --json jobs, e2e steps" \
  "success" "$(gh run view "$RUN" --json jobs --jq '.jobs[] | select(.name=="e2e") | .steps[] | select(.name | contains("onsole")) | .conclusion')"

check_eq "the jit-verify step succeeded" "gh run view $RUN --json jobs, e2e steps" \
  "success" "$(gh run view "$RUN" --json jobs --jq '.jobs[] | select(.name=="e2e") | .steps[] | select(.name | contains("it-verify")) | .conclusion')"

check "the browser suite skipped on the runner" "gh run view $RUN --log" \
  bash -c 'gh run view "$RUN" --log 2>/dev/null | grep -q "skipping the browser suite"'

check "jit-verify reached 11 PASS, 0 FAIL in the run logs" "gh run view $RUN --log" \
  bash -c 'gh run view "$RUN" --log 2>/dev/null | grep -qF "===== 11 PASS, 0 FAIL ====="'

check_eq "the green run sits on the PR head, before main" "gh pr view $BRANCH --json headRefOid" \
  "$(gh pr view "$BRANCH" --json headRefOid --jq .headRefOid)" "$(gh run view "$RUN" --json headSha --jq .headSha)"

finish
