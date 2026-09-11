# Evidence

Verbatim copies of the run logs and probe scripts that the step records in `docs/todo.md` and
`memory-bank/` cite. They used to live in `/tmp`, which meant the citations pointed at files that a
reboot would delete — and two of them had already been lost that way before S17. Moving them here
keeps every reference in `docs/` and `memory-bank/` resolvable, and lets a reader check the claims
rather than take them on trust.

Nothing here is executed by any workflow. These are artifacts.

## S17

| File | What it is |
|---|---|
| `s17-run.log` | The complete `bash scripts/checks/S17.sh` run that passed: `PASS: J1-J11 all PASS`, `PASS: ===== 17 PASS, 0 FAIL ===== in voting-a` |
| `s17-green-run.log` | Copy of the same run, kept separately because S17's earlier evidence was overwritten mid-run |
| `verify-jit-green.md` | `.workflow/verify-jit.md` from that run — `===== 11 PASS, 0 FAIL =====` |
| `s17-run-j11fail.log` | The first complete run, which failed at J11: MinIO answered **403 SignatureDoesNotMatch** because the S3 prefix was signed as `ns/` |
| `verify-jit-j11fail.md` | The suite report from that run, ending `10 PASS, 1 FAIL` |
| `s17-run-j11-nopass.log` | The second complete run, which failed the gate although J11 passed — J11 had no `pass` line, so a passing J11 printed nothing |
| `verify-jit-j11-nopass.md` | The suite report from that run: `10 PASS, 0 FAIL` and no J11 line |
| `race-test.sh` / `race-test.log` | Three clean-slate `voting-a` deploys, each requiring three distinct IPs and `count: 3` — the evidence that J1's duplicate-IP race is fixed rather than lucky. 3/3 OK |
| `block-race-test.sh` / `block-race.log` | Two iterations of `overlays/voting-a` and `overlays/voting-b` applied back to back, looking for the per-namespace lock failing to serialise the shared `jit-ipam` ConfigMap. Did **not** reproduce in two attempts |
| `leak-probe.sh` / `leak-probe.log` | v1 of the retry-path leak probe. It restarted the runner as soon as the phase went `Deleting`, so the in-flight destroy succeeded and the ledger looked clean — it tested nothing. Kept as the example of a probe that passes for the wrong reason |
| `leak-probe2.sh` / `leak-probe2.log` | v2, which holds the runner down through two failed retries. It proved the retry path leaks the block: claim and container gone, ledger still `{"hatch-leak": ... "count": 1}` |
| `clean-slate.sh` | The reset helper every probe above calls: claims, JIT containers, volumes, the demo namespaces and the IPAM ledger |
| `restore-env.sh` | Puts the demo back after the probes (voting-a deployed, ledger reset) |

## S16

Cited by `docs/todo.md`'s S16 record and `memory-bank/journal/2026-10-09.md`.

| File | What it is |
|---|---|
| `s16-run1-keep.log`, `s16-run2.log`, `s16-run3.log` | `bash scripts/checks/S16.sh` exit 0 on three consecutive runs |
| `s16-final.log` | The final S16 run before the review |
| `s16-postfix2.log` | The re-run after the review's concerns were fixed |
| `s16-negative.log`, `s16-negative2.log` | The negative test: the helpers pointed at non-existent containers, so the guarded checks FAIL with a readable reason instead of comparing two empty reads |
| `s16-premigration-tally.txt` | The empty pre-migration read, kept as the reason the helpers are guarded |

## Reproducing

The scripts are preserved exactly as they ran, so their internal paths still say `/tmp/...`. To run
one, put it and its siblings in `/tmp` first, or edit the paths at the top. They expect the JIT stack
up (`make jit-up`) and a `voting-a`/`voting-b` demo to work on; they create and destroy containers.
