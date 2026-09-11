Updated: 2026-09-11

## Working
**S17 is complete.** The cold start runs green from a genuine `make destroy`, the teardown semantics are
settled and in the code, and the demo runs on the cluster that cold run rebuilt.

## Done (verified)
- Cold path green end to end (`docs/evidence/s17-cold-path-green.log`): `make all` `17 PASS, 0 FAIL`,
  `make jit-verify` `11 PASS, 0 FAIL`, three claims Ready, ledger `{"voting-a": {"offset": 0, "count": 3}}`.
- Gate on the final code (`docs/evidence/s17-final-gate.log`); `make verify` `17 PASS` in `voting-a`.
- `jit-down` now takes each swept container's Postgres volume with it (`scripts/jit-down.sh` step 2), so no
  volume outlives the password that opens it — the rule the destroy path always followed (J6 records it).
- Earlier S17: ledger cleared on `jit-down`; R-checks guard an empty `OPTS`; `jit-up` imports the controller
  image; `jit-down` survives no CRD; a bare `make all` deploys to `voting-a`.

## Broken (confirmed by execution)
- None open. The cold start was the last one — four defects, all fixed and re-run green.

## Suspected (read, not reproduced)
- `ipam.py` has no lock of its own; `namespace_lock` is process-local.
- `_allocated_ip` returns `""` on `ApiException`, which also means "allocate".
- A claim can be `Ready` with no container behind it; the stale-Ready check only looks for the Secret.

## In progress
Nothing.

## Blocked
- The 18 review boxes in `docs/todo.md` are the human's to tick; S17's is unticked like the rest.

## Learnings
- Settle a "design question" by reading the code first: three files already stated this answer, and the real
  defect was the one path that broke the rule the others followed.
- A password written inside the volume it opens cannot be rescued by persisting the password elsewhere.
- Run the failure path: the cold start found four defects, one of them in a fix made the same day.
