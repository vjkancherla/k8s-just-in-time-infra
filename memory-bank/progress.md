Updated: 2026-09-11

## Working
The S17 checkpoint is green and committed, and the duplicate-IP fix works at the level J1 tests. What
is not working is one teardown path: a claim whose destroy succeeds on the resync *retry* leaks its IP
block. That, plus the README escape hatch's missing `-var postgres_url`, stands between S17 and "done".

## Done (verified)
- `bash scripts/checks/S17.sh` exit 0: J1-J11 11 PASS, 0 FAIL and R1-R17 17 PASS, 0 FAIL in voting-a.
- J1: three distinct IPs and IPAM `count: 3` over three clean-slate iterations, plus a two-namespace
  deploy (voting-a offset 0, voting-b offset 1) - `/tmp/race-test.log`, `/tmp/block-race.log`.
- The double-release guard fires correctly in the normal teardown path (controller log: the sweep
  releases, the handler skips).
- S0-S16 checkpoints pass and are committed. S00 fails by design (pre-migration assertions).

## Broken (confirmed by execution)
- **The resync retry path leaks the IP block.** The only release is `main.py:896` (TTL path); the retry
  branch `main.py:841-849` has none; `main.py:942` makes the delete handler skip. Claim gone,
  container gone, ledger keeps the entry (`/tmp/leak-probe2.log`).
- **The README escape hatch fails for pgAdmin.** `tofu destroy` with the documented variables errors
  `No value for required variable: postgres_url` - the module's variable has no default.

## Suspected (read, not reproduced)
- `ipam.py` has no lock; `namespace_lock` is per namespace, so two namespaces can interleave the
  ConfigMap read-modify-write. Not triggered in 2 attempts (`/tmp/block-race.log`).
- `_allocated_ip` returns `""` on ApiException, which means "allocate" - so a failed read can move a
  live claim's address and inflate the count.
- `jit-down` never reconciles `jit-ipam`.

## In progress
Nothing. Waiting on the fix-or-review decision; no files are being changed.

## Blocked
- S17's "done" claim, on the retry-path leak fix plus a fresh `bash scripts/checks/S17.sh`.
- The review box, on a different model writing `docs/reviews/S17-findings.md` with CLEAR.

## Learnings
- A guard that stops a second release creates the mirror bug: whoever owns the *first* release owns it
  on every path, and the retry branch inherited none.
- The ledger is written incrementally and never reconciled, so every missed decrement is permanent.
