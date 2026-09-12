# S18 Review

Reviewer model: Claude (Sonnet 4.5)
Verdict: CLEAR

## Blockers
None.

## Concerns

1. **ALLOWED_NS is overridable in state.sh but ns-delete's fence is hardcoded in the Makefile.**
   `state.sh` exposes `ALLOWED_NS` as an environment variable (line 37: `ALLOWED_NS="${ALLOWED_NS:-voting-a voting-b}"`), while `ns-delete` uses the Makefile's `TENANTS` variable. If someone sets `ALLOWED_NS="default kube-system"`, state.sh would report on namespaces outside the console's intended fence, while ns-delete would still refuse them. The state read model and the delete fence would disagree. The comment on line 36 says "one fence in the project, not two," but the env-var override means there are effectively two. Low risk in the PoC; would matter if the env var leaks into CI or a container spec.

2. **demo-up.sh swallows deploy failures that are not the expected CRD-absent shape.**
   The `if ( cd app && make deploy ); then ... else ... fi` block (lines 58-62) catches any non-zero exit, not just the specific "CRD doesn't exist" case. If deploy fails for an unexpected reason (e.g., Docker is down, k3d can't start), the script prints the misleading message "deploy stopped before applying the app" and continues to step 4. The failure would surface later at `make jit-up` or `make verify`, but the error context would be wrong. Not a gate — the later steps catch it — but it would make debugging harder in practice.

3. **The verify target's exit behaviour changed for an existing target.**
   Before S18, `make verify` ran `cd app && ./scripts/verify.sh` and inherited verify.sh's exit 0 (it uses `set -uo pipefail` without `-e`). S18 changed it to delete `app/.workflow/verify.md`, re-run verify.sh, then grep the summary and exit 1 on any FAIL. This is the right behaviour — the design requires "exits non-zero on failure" — but the build-plan says "do not change their behaviour" for existing targets. The resolution is that the design's requirement overrides the build-plan's caution, and the R-check counting mechanism (parsing .workflow/) is preserved. Noted here so the next reviewer knows the pre/post behaviour.

4. **state.sh's MinIO signature is pure-Python AWS Signature V4.**
   The `list_bucket_objects` function (lines 131-207) implements HMAC-SHA256 signing by hand against urllib. This is correct for MinIO's current S3-compatible API, but if MinIO ever changes its default signing version, this code would break silently (returning empty stateObjects with a note). Inherent in the no-external-dependencies constraint; not actionable.

## Notes

- The diff is exactly the four files the step allowed: Makefile, scripts/state.sh (new), scripts/demo-up.sh (new), docs/evidence/*. No scripts/checks/ or .clinerules/ edits, no CI config, no docs/todo.md tick.
- All Python imports in state.sh are stdlib: datetime, hashlib, hmac, json, os, re, subprocess, sys, urllib.*, xml.etree.ElementTree. No new dependencies.
- The 11-target allowlist matches the design's action table exactly: demo-up, demo-soft, demo-restore, ns-delete, test-up, jit-up, verify, jit-verify, jit-down, state, targets.
- The cold path in demo-up.sh follows the order s17-cold-path-green.log established: destroy → jit-down → deploy → jit-up → create namespaces → deploy+verify per namespace. No second cold path introduced.
- The `expiresAt` normalisation (absent/"\""/null → null) is documented in state.sh lines 14-17 and matches the design's single spelling.
- Every allowlisted target appends to `docs/evidence/<target>.log` and preserves the inner script's exit code via `${PIPESTATUS[0]}`. `state` and `targets` log only stdout (their stdout IS the console's payload).
- The checkpoint has 9 substantive sections across 12 `ok:` lines. Removing either new script or the Makefile additions would cause multiple assertion failures — the checkpoint is not satisfiable with the logic deleted.

## Checkpoint assessment

`bash scripts/checks/S18.sh` passes on the current working tree: twelve `ok:` lines and `PASS` (exit 0). The checkpoint tests nine distinct properties: the allowlist is defined (11 targets, cross-checked with `make -pRrq`), `make targets` agrees with the hardcoded list, `make state` emits the documented JSON shape (validated by a Python schema check), claim count and per-claim phases agree with kubectl, running container count agrees with docker, state degrades to `up:false` with no cluster, ns-delete refuses a missing/default/kube-system namespace, a failing target exits non-zero, the soft path shows Orphaned claims with an expiry while keeping redis Ready and all containers running, the restore path returns all claims to Ready with cleared expiry, and evidence logs exist for both. The soft-path assertions (demo-soft → sleep 35 → check phases, demo-restore → sleep 35 → check recovery) test the controller's resync behaviour through the read model, not just the make targets themselves. The checkpoint would not pass with state.sh, demo-up.sh, or the Makefile additions removed.
