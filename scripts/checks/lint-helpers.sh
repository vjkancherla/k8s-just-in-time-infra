#!/usr/bin/env bash
# Lint for the two runaway-execution shapes this stage has already hit once
# each, so neither can ship again inside a checkpoint:
#
#   1. recursion-in-wrapper: a helper that wraps a command must call that
#      command by its original name. The first cut of the `kk` helper read
#      `kk() { kk --request-timeout=5s "$@"; }` - the rename hit the callee
#      inside its own definition, the helper recursed, and bash died SIGSEGV
#      (exit 139) instead of printing a readable FAIL.
#   2. unbounded wait loops: every retry loop must be seq-bounded. A `while
#      true ... sleep` wedges a checkpoint - and, through the batch that runs
#      them all, the whole pre-flight with it.
#
#   scripts/checks/lint-helpers.sh
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }

hits="$(python3 - <<'PY'
import glob, re
pat_rec = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{\s*([^"\s(]+)')
pat_unb = re.compile(r'^\s*while\s+(true|:)\b')
out = []
files = sorted(glob.glob("scripts/checks/*.sh")) + ["scripts/checkpoint.sh", "scripts/s22-all-fail.sh"]
for f in files:
    try: body = open(f).read().splitlines()
    except OSError: continue
    for i, line in enumerate(body):
        m = pat_rec.match(line)
        if m:
            first = m.group(2).rstrip("{() ")
            if first == m.group(1):
                out.append(f"{f}:{i+1}: helper '{m.group(1)}' calls itself: {line.strip()}")
        u = pat_unb.match(line)
        if u:
            out.append(f"{f}:{i+1}: unbounded while with no seq bound: {line.strip()}")
print("\n".join(out))
PY
)"
[ -n "$hits" ] && { echo "$hits"; fail "lint-helpers: runaway-execution shape found"; }
echo "PASS: no recursion-in-wrapper, no unbounded while across the checkpoints"
