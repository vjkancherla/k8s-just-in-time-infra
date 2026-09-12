Updated: 2026-09-12

## Current focus
**S18 is complete on the code side and closed on the frozen gate.** The console's surface exists -
`demo-up`, `demo-soft`, `demo-restore`, `ns-delete`, `test-up`, `state`, `targets` - its read model comes
from `make state`, and `bash scripts/checks/S18.sh` prints PASS. It waits now on an independent review.

## Blocked
- Nothing. S18's `check` box in `docs/todo.md` is unticked, and so are the review boxes: the human's to
  tick, as they have been for every step.

## Done (verified)
- Gate: `bash scripts/checks/S18.sh` -> twelve `ok:` lines, `PASS` (`docs/evidence/s18-final-gate.log`),
  after the human approved the two-mechanic fix to the frozen checkpoint (`13c2502`).
- `make demo-up` from cold: `rc=0`, `17 PASS, 0 FAIL` (`docs/evidence/demo-up.log`).
- `make state`: the design's object, block `172.19.0.100-109`, `expiresAt` normalised (`""` -> null), and
  `up:false` with empty lists when there is no cluster.
- `make verify NS=voting-a` -> 17 PASS exit 0; `NS=does-not-exist` -> exit 2. `make targets` prints the
  allowlist and nothing else; `ns-delete` refuses no-NS, `default` and `kube-system`.

## Checkpoints (final code)
- S18: PASS. S17's gate untouched (`make verify` = 17 PASS, `scripts/verify-jit.sh` unmodified).

## Commits
`13c2502` the checkpoint fix, `5a1b59c` the implementation, `47c0f19` the review prompt. HEAD before this
work: `2831f1c`.

## Next step
Stop. S18 is done when a different model writes CLEAR in `docs/reviews/S18-findings.md` from
`docs/reviews/S18-review-prompt.md`. Do not start S19.

## Watch out
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` is in neither the tree nor git history; the prompt mirrors
  `S17-review-prompt.md`, the last one generated from it. The template should be restored.
- A warm bring-up (app deployed, claims destroyed) leaves postgres's data directory, its
  `POSTGRES_PASSWORD` and the `jit-postgres` Secret disagreeing, and the pods are rejected. Out of this
  step's scope; `demo-up` avoids the shape by always starting cold.