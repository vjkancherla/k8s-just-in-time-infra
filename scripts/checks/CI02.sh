#!/usr/bin/env bash
# CI02: a stock ubuntu-24.04 runner can host the cluster's fixed network.
. "$(dirname "$0")/lib.sh"

describe "A stock ubuntu-24.04 runner can host the cluster's fixed network" <<'EOF'
Proves: ci.yml declares the two-job skeleton with the three triggers, and a run
        on a hosted runner is green in both jobs on the PR head, before main.
How:    parses ci.yml locally; then finds the branch's run, watches it to
        completion, and ties its head SHA to the open PR.
Needs:  the ci/CI02 branch pushed with ci.yml, a PR open, gh logged in.
        The live half takes several minutes.
EOF

WF=".github/workflows/ci.yml"
BRANCH="$(git branch --show-current)"
export BRANCH WF

require "ci.yml parses as YAML" "$WF" \
  python3 -c "import yaml; yaml.safe_load(open('$WF'))"

check_eq "exactly the fast and e2e jobs" "$WF, jobs:" \
  "e2e fast" "$(python3 -c "import yaml; print(' '.join(sorted(yaml.safe_load(open('$WF'))['jobs'])))" )"

check_eq "the three triggers: push, pull_request, workflow_dispatch" "$WF, on:" \
  "pull_request push workflow_dispatch" "$(python3 -c "import yaml; print(' '.join(sorted(yaml.safe_load(open('$WF'))[True])))" )"

check_eq "push trigger is limited to main" "$WF, on.push.branches:" \
  "main" "$(python3 -c "import yaml; print(' '.join(yaml.safe_load(open('$WF'))[True]['push']['branches']))" )"

check_eq "both jobs are pinned to ubuntu-24.04" "$WF, runs-on:" \
  "ubuntu-24.04 ubuntu-24.04" "$(python3 -c "import yaml; d=yaml.safe_load(open('$WF')); print(' '.join(sorted(j['runs-on'] for j in d['jobs'].values())))" )"

require "this branch has a CI run" "push the branch and open a PR - the pull_request trigger starts it" \
  bash -c 'test -n "$(gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 --json databaseId --jq ".[0].databaseId")"'

RUN="$(gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
export RUN
note "watching run $RUN to completion (several minutes)"

check "the watched run finishes green" "gh run view $RUN" \
  gh run watch "$RUN" --exit-status

check_eq "run conclusion is success, not skipped" "gh run view $RUN --json conclusion" \
  "success" "$(gh run view "$RUN" --json conclusion --jq .conclusion)"

check_eq "fast job ran and succeeded on the runner" "gh run view $RUN --json jobs" \
  "success" "$(gh run view "$RUN" --json jobs --jq '.jobs[] | select(.name=="fast") | .conclusion')"

check_eq "e2e probe ran and succeeded on the runner" "gh run view $RUN --json jobs" \
  "success" "$(gh run view "$RUN" --json jobs --jq '.jobs[] | select(.name=="e2e") | .conclusion')"

check_eq "the green run sits on the PR head, before main" "gh pr view $BRANCH --json headRefOid" \
  "$(gh pr view "$BRANCH" --json headRefOid --jq .headRefOid)" "$(gh run view "$RUN" --json headSha --jq .headSha)"

finish
