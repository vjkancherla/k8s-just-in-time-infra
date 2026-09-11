Updated: 2026-09-11

## Current focus
S17's checkpoint is green and committed (a82a6a9..328d07b), but **S17 is not done** - the author's own
verification found and proved a defect in the J1 fix. Stopped, awaiting one decision (see Next step).

## Blocked
- **The resync retry path leaks the IP block.** `main.py:896` is the only release on the TTL path, the
  retry branch (`main.py:841-849`) has none, and `main.py:942` makes the delete handler skip. Proven in
  `docs/evidence/leak-probe2.log`: claim and container gone, ledger still counting the namespace.
- Fixing it changes `jit-controller/main.py`, so the green run no longer describes the tree and
  `bash scripts/checks/S17.sh` (~25 min) must be re-run before S17 is done.
- The independent review has not run: it needs a different model in a fresh task to write
  `docs/reviews/S17-findings.md`, so `docs/todo.md`'s S17 review box stays unticked.

## Done (verified)
- `bash scripts/checks/S17.sh` exit 0: J1-J11 **11 PASS, 0 FAIL**, then R1-R17 **17 PASS, 0 FAIL** in
  voting-a (`docs/evidence/s17-run.log`, `docs/evidence/verify-jit-green.md`).
- J1's duplicate IP, at the level J1 tests: `docs/evidence/race-test.sh` 3/3, three distinct addresses and
  `count: 3` (`docs/evidence/race-test.log`); the double-release guard works in the normal teardown path.
- All twelve review questions answered from code, executing wherever possible, in
  `memory-bank/journal/2026-09-11.md` - which also records the README escape hatch failing for pgAdmin.

## Checkpoints (final code)
- PASS: S17, `scripts/checks/S17.sh` (exit 0) - true of a82a6a9..328d07b only; re-run if the fix lands.

## Commits
S17: 36a86b2, cfb99c0, d65f62d, 99a1397, 15991b5, 8a67327, e00a179; then bookkeeping 4b52099..328d07b (HEAD).

## Next step
Ask the human to choose: fix the retry-path leak and the README's missing `-var postgres_url`, re-run
`bash scripts/checks/S17.sh`, then run the independent review - or review the current code first.

## Watch out
- Latent, **not** reproduced: `ipam.py` has no lock, so `namespace_lock` cannot serialise two
  namespaces' `jit-ipam` read-modify-write (`docs/evidence/block-race.log`); `_allocated_ip` cannot tell a failed
  read from "no address"; `jit-down` never reconciles the ledger; and the gate never runs jit-up/jit-down.
- Temporary resources cleaned: `/tmp` holds no project files, the probes' orphan containers and
  ledger/MinIO entries are gone, cited logs now live in `docs/evidence/`. voting-a stays Ready, `count: 3`.
