#!/usr/bin/env bash
# CI04: the e2e job runs the cold path.
. "$(dirname "$0")/lib.sh"

describe "The e2e job runs the cold path" <<'EOF'
Proves: the e2e job writes the throwaway credentials, builds the controller,
        runs make test-up to 17 PASS on the runner, and uploads evidence when
        a run fails - all visible on the PR before main.
How:    checks the step order in ci.yml locally; then watches the branch's
        latest run, greps its logs for the 17 PASS literal, ties it to the PR
        head, and finds a failed run carrying the evidence artifact.
Needs:  the ci/CI04 branch pushed with ci.yml, a PR open, one green and one
        deliberately failed run on the branch, gh logged in. The live half
        takes up to ~45 minutes while a run is in flight.
EOF

WF=".github/workflows/ci.yml"
BRANCH="$(git branch --show-current)"
export BRANCH WF
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
export REPO

require "ci.yml parses as YAML" "$WF" \
  python3 -c "import yaml; yaml.safe_load(open('$WF'))"

check_eq "e2e writes .env, then builds, then runs test-up" "$WF, e2e steps in order" \
  "env build testup" "$(python3 - <<'PY'
import yaml
steps = yaml.safe_load(open('.github/workflows/ci.yml'))['jobs']['e2e']['steps']
runs = [(i, s.get('run', '')) for i, s in enumerate(steps)]
env = next(i for i, r in runs if 'MINIO_ROOT_USER' in r and 'MINIO_ROOT_PASSWORD' in r and '.env' in r)
build = next(i for i, r in runs if 'docker build' in r and 'jit-controller:latest' in r)
testup = next(i for i, r in runs if 'make test-up' in r)
print('env build testup' if env < build < testup else f'{env} {build} {testup}')
PY
)"

check "evidence uploads on failure, covering both evidence dirs" "$WF, upload-artifact step" \
  bash -c "python3 - <<'PY' | grep -q UPLOAD_OK
import yaml
steps = yaml.safe_load(open('.github/workflows/ci.yml'))['jobs']['e2e']['steps']
for s in steps:
    uses = s.get('uses', '')
    if 'upload-artifact' in uses and s.get('if', '') == 'failure()':
        paths = str(s.get('with', {}).get('path', ''))
        if 'docs/evidence/' in paths and 'app/.workflow/' in paths:
            print('UPLOAD_OK')
PY"

require "this branch has a CI run" "push the branch and open a PR - the pull_request trigger starts it" \
  bash -c 'test -n "$(gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 --json databaseId --jq ".[0].databaseId")"'

RUN="$(gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
export RUN
note "using latest run $RUN (watching if still in flight)"

check "the latest run finishes green" "run it after the final green run, not mid-sabotage - gh run view $RUN" \
  gh run watch "$RUN" --exit-status

check_eq "e2e job ran and succeeded on the runner" "gh run view $RUN --json jobs" \
  "success" "$(gh run view "$RUN" --json jobs --jq '.jobs[] | select(.name=="e2e") | .conclusion')"

check "make verify reached 17 PASS, 0 FAIL in the run logs" "gh run view $RUN --log" \
  bash -c 'gh run view "$RUN" --log 2>/dev/null | grep -qF "===== 17 PASS, 0 FAIL ====="'

check_eq "the green run sits on the PR head, before main" "gh pr view $BRANCH --json headRefOid" \
  "$(gh pr view "$BRANCH" --json headRefOid --jq .headRefOid)" "$(gh run view "$RUN" --json headSha --jq .headSha)"

check "a deliberately failed run uploaded the evidence artifact" "push a sabotage commit, watch it fail, then revert - V7" \
  bash -c '
    for id in $(gh run list --branch "$BRANCH" --workflow ci.yml --limit 10 --json databaseId,conclusion --jq ".[] | select(.conclusion==\"failure\") | .databaseId"); do
      names="$(gh api "repos/$REPO/actions/runs/$id/artifacts" --jq ".artifacts[].name")"
      if echo "$names" | grep -q "e2e-evidence"; then echo "run $id uploaded: $names"; exit 0; fi
    done
    echo "no failed run on $BRANCH carries the e2e-evidence artifact"; exit 1'

finish
