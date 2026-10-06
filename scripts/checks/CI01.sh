#!/usr/bin/env bash
# CI01: the fast half is green locally, and the runner can be dispatched.
. "$(dirname "$0")/lib.sh"

describe "The fast half is green locally, and the runner can be dispatched" <<'EOF'
Proves: the four pytest suites and the lint pass from a clean install, and gh can dispatch a run.
How:    builds a throwaway venv from jit-controller/requirements.txt plus pytest, runs each
        suite in it, runs lint-helpers.sh, and asks gh for its token scopes.
Needs:  python3 with venv, network for pip, gh logged in.
EOF

VENV="${TMPDIR:-/tmp}/ci01-venv"
HASH="$VENV/.req-hash"
WANT="$(shasum jit-controller/requirements.txt | cut -d' ' -f1)"

if [ ! -x "$VENV/bin/python" ] || [ ! -f "$HASH" ] || [ "$(cat "$HASH")" != "$WANT" ]; then
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q -r jit-controller/requirements.txt pytest
  printf '%s' "$WANT" >"$HASH"
fi

require "throwaway venv has pytest and requests" "built from: jit-controller/requirements.txt plus pytest" \
  "$VENV/bin/python" -c "import pytest, requests"

check "test_ipam.py exits 0" "jit-controller/test_ipam.py" \
  "$VENV/bin/python" -m pytest jit-controller/test_ipam.py -q

check "test_declarers.py exits 0 with requests installed" "jit-controller/test_declarers.py; requests comes from jit-controller/requirements.txt" \
  "$VENV/bin/python" -m pytest jit-controller/test_declarers.py -q

check "test_serve.py and test_console.py exit 0" "console/test_serve.py and console/test_console.py" \
  "$VENV/bin/python" -m pytest console/test_serve.py console/test_console.py -q

check "scripts/checks/lint-helpers.sh prints PASS" "scripts/checks/lint-helpers.sh" \
  bash -c 'bash scripts/checks/lint-helpers.sh 2>&1 | grep -q PASS'

check "gh auth status names the workflow scope" "run: gh auth status" \
  bash -c 'gh auth status 2>&1 | grep -q workflow'

finish
