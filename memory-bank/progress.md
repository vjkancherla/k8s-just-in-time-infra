Updated: 2026-09-12

## Working
Nothing. S18 is complete on the code side, committed, and waiting on the independent review.

## Done (verified)
- `bash scripts/checks/S18.sh` -> twelve `ok:` lines, `PASS`, exit 0 (`docs/evidence/s18-final-gate.log`).
- The frozen checkpoint could not pass as written: `make -pRrq :` is non-zero under the script's
  `pipefail`, and a herestring overrode the heredoc meant to be its script. The human authorised the
  two-mechanic fix (`13c2502`); the before and after are in docs/evidence/s18-checkpoint-probe.log.
- `make demo-up` from cold: `rc=0`, `17 PASS, 0 FAIL`. `make state` = the design's JSON, agreeing with
  kubectl and docker, degrading to `up:false` with no cluster.
- `make verify` exits on the summary it wrote: 0 at 17 PASS, 2 at 11 FAIL. `make targets` = the 11-name
  allowlist. `ns-delete` refuses a namespace outside `voting-a voting-b` and refuses to run without NS.
- Every allowlisted target appends `docs/evidence/<target>.log` and keeps its exit code.

## Broken (confirmed by execution)
- None open.

## Suspected (read, not reproduced)
- Postgres's password can end up inconsistent across three places after a re-provisioning - the data
  directory, the container's `POSTGRES_PASSWORD`, and the `jit-postgres` Secret - leaving pods rejected.
  Seen once on a warm bring-up; the controller owns it, not S18.
- `app/scripts/verify.sh` still returns 0 however many R-checks fail, by design.
- `ipam.py` has no lock of its own; `_allocated_ip` cannot tell a failed read from "no address".

## In progress
Nothing.

## Blocked
- S18's two tracker boxes in `docs/todo.md` are the human's to tick.

## Learnings
- A frozen gate that cannot pass is a design question, not a checkpoint edit: prove it on a patched copy,
  leave the frozen file byte-identical until the human rules, and the copy's PASS is the question's evidence.
- `python3 - <<'PY' <<<"$data"`: the herestring wins on fd 0, so the script becomes the data - pass data
  as argv. And `make -pRrq :` always exits non-zero (no target `:` can exist); it needs `|| true` before
  it meets any `pipefail`.
- A claim is created by an event on the annotated Deployment, so a bring-up that merely restarts
  Deployments leaves their pods holding a Secret from before the re-provisioning. A cold apply does not.