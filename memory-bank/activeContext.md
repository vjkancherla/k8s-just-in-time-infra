Updated: 2026-09-13

## Current focus
S18 is complete and ticked; the README has been through an external review pass. This session's open work is
`.gitignore`, widened to drop local tooling/state noise, with the S18 docs set still uncommitted.

## Blocked
- Nothing blocks. The tree's uncommitted work and the untracked `console/` are the human's call.

## Done (verified)
- `.gitignore` (uncommitted, this session): sections for secrets (`.env`, `.env.*`, any depth), Python,
  Terraform state, agent runtime (`.omo/`, `.workflow/` — which also covers `app/.workflow/`), OS/editor and
  backup noise. No global `*.log`, so the evidence logs stay committable. Executed: every rule bites, 0 tracked
  files newly ignored, untracked entries 45 → 24.
- README (uncommitted, this session): the reviewer's cuts applied — TOC and the Running-it table gone, `make
  check` out of the allowlist table, WARNING reworded to three irreversible targets, state-machine diagram
  cut, stale "voting app repo, read-only" prerequisite gone, `console/state.py` deleted (it was dead).
  Script-checked: every anchor, relative link, fence and table.
- Gate: `bash scripts/checks/S18.sh` → twelve `ok:` lines, `PASS` (`docs/evidence/s18-final-gate.log`), after
  the human approved the two-mechanic fix to the frozen checkpoint (`13c2502`).

## Checkpoints (final code)
- S18: PASS. S17's gate untouched (`make verify` = 17 PASS, `scripts/verify-jit.sh` unmodified).

## Next step
Human: commit the README with the rest of the uncommitted S18 set — the `destroy` target and allowlist, the
checkpoint's two name edits, `docs/evidence/s18-checkpoint-*.log`, this `.gitignore` — or discard them.
`console/` is untracked, so a commit that claims the console works has to add it.

## Watch out
- `console/` is untracked and its step is not in the plan: `docs/build-plan.md:608` calls the page over
  `make state` S19 and the proxy S20. It now holds `index.html` and `serve.py` (`state.py` deleted today).
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` is in neither the tree nor git history; restore it from `S17-review-prompt.md`.
- `docs/build-plan.md:616` and `docs/lessons.md:118` cite README sections by name ("From cold", the wedged
  namespace); both survive the rewrite.
- A warm bring-up can leave postgres's data directory, `POSTGRES_PASSWORD` and the `jit-postgres` Secret
  disagreeing and pods rejected; `demo-up` starts cold, so it never sees that shape.
- `.workflow/` is ignored wholesale, so `app/.workflow/*.md` (design, requirements, synthesis) stays uncommitted.
- `refs/cline/checkpoints/*` — 119 local refs — snapshot the whole tree, `.env` and `terraform.tfstate` with it.
  Never `git push --all`/`--mirror`; `git push origin main` is safe (GitHub holds only `main`, verified).
