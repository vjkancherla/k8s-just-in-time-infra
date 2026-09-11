Updated: 2026-09-11

## Current focus
**S17 is complete.** Its review concerns are dispositioned, the cold start runs green end to end, and the
build plan's last Done item is ticked. The demo is healthy on the cluster that cold run rebuilt: three
claims Ready, ledger `{"voting-a": {"offset": 0, "count": 3}}`, three pods 1/1.

## Blocked
- Nothing. The 18 review boxes in `docs/todo.md` are the human's to tick; S17's is unticked like the rest.

## Done (verified)
- **The cold start, closed** (`docs/evidence/s17-cold-path-green.log`): destroy → deploy (creates the
  cluster, stops by design) → `jit-down` → `jit-up` → `make all` (`17 PASS, 0 FAIL`) → `make jit-verify`
  (`11 PASS, 0 FAIL`), start to finish on a cold host.
- **The last blocker settled, not patched: a container removal takes its volume.** `tofu destroy` always
  did (J6: `postgres data volume removed`; the module's comment forbids the `random_password`
  alternative); `jit-down`'s by-name sweep now removes `<container>-data` too — `scripts/jit-down.sh`
  step 2. Persisting the password could not have rescued the existing volume: its password lives in the
  data directory.
- Gate on the final code: `bash scripts/checks/S17.sh`, ends on its own last PASS line
  (`docs/evidence/s17-final-gate.log`).
- Earlier in S17: the ledger clear, the `OPTS` guard, the image import, the `voting-a` pin, the IP release.

## Checkpoints (final code)
- PASS: S17, `docs/evidence/s17-final-gate.log` — J1-J11 `11 PASS`, R1-R17 `17 PASS` in `voting-a`. Code
  since c95c051: `scripts/jit-down.sh` (the sweep's volume), `docs/evidence/s17-cold-path.sh`, docs.

## Commits
HEAD before this work: ab00fd8. This task: `jit-down` takes the swept container's volume, the cold-path
evidence, and the docs that recorded the question as open.

## Next step
Nothing queued for S17. Next, from `docs/todo.md`: the reviewer's open items (tenant visibility of an
`Orphaned` claim; `var.share_dir`'s `/tmp` default) or the S-1 frozen-gate question.

## Watch out
- Latent: `ipam.py` has no lock; `_allocated_ip` cannot tell a failed read from "no address"; a claim can sit
  `Ready` with no container (the stale-Ready detector needs the Secret to be gone).
- Untracked but referenced by README/todo/systemPatterns: `docs/jit-infra-poc.md`, `docs/jit-infra-flows.md`,
  `docs/01-jit-poc.md`, `docs/decisions/`. Also untracked: `terraform.tfstate%`, from a bad redirect.
