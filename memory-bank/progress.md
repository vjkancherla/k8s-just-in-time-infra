Updated: 2026-09-13

## Working
Nothing open. Five README commands were wrong (there is no root `make all`); docs get their commands run once before shipping.

## Done (verified)
- `.gitignore` widened: secrets, Python, Terraform state, agent runtime (`.omo/`, `.workflow/`), OS/editor/backup
  noise; no global `*.log` (43 evidence logs), 0 tracked files newly ignored, pushed history audited clean.
- README through an external review pass: hand-kept TOC and duplicate guide prose removed, `make check` out
  of the console table, state-machine diagram dropped, the `tofu` escape hatch moved to the manual guide §10,
  `console/state.py` deleted. Script-checked: every anchor, relative link, fence and table.
- Independent review (`docs/reviews/S18-findings.md`, `16fa4ad`): no blockers; four concerns, listed there.
- `bash scripts/checks/S18.sh` → twelve `ok:` lines, `PASS` (`docs/evidence/s18-final-gate.log`); that run predates the rename.
- `make demo-up` from cold: `rc=0`, `17 PASS, 0 FAIL`; `make verify` exits on the summary it wrote (0 at 17
  PASS, 2 at 11 FAIL); every allowlisted target appends `docs/evidence/<target>.log` and keeps its exit code.
- 44 files committed in eight logical commits, pushed as `bd2a2fb`; remote tip == local HEAD, tree clean.
  `app/opencode.jsonc` was excluded: a live-looking DeepSeek key sits in a comment, though it never reached git.

## Broken (confirmed by execution)
- None open.

## Suspected (read, not reproduced)
- Postgres's password can disagree across its data directory, the container's `POSTGRES_PASSWORD` and the
  `jit-postgres` Secret after a re-provisioning, leaving pods rejected — seen once, on a warm bring-up.
- `app/scripts/verify.sh` still returns 0 however many R-checks fail, by design.
- `ipam.py` has no lock of its own; `_allocated_ip` cannot tell a failed read from "no address".

## In progress
Nothing.

## Blocked
- Nothing blocked. The tree is clean and level with `origin/main`; the console's missing plan step is the open item.

## Learnings
- Link and anchor checks belong in a script: a README's `](#anchor)` targets and relative paths all validate in
  one pass, and a checker that forgets to skip code fences reports phantom failures.
- A frozen gate that cannot pass is a design question, not a checkpoint edit: prove it on a patched copy, leave
  the frozen file byte-identical until the human rules, and the copy's PASS is the question's evidence.
- `python3 - <<'PY' <<<"$data"`: the herestring wins on fd 0, so the script becomes the data — pass data as
  argv. `make -pRrq :` always exits non-zero; it needs `|| true` before it meets any `pipefail`.
