Updated: 2026-09-13

## Current focus
S18 is complete, ticked and published at `5a7c7f2`. The tree is level with `origin/main` and holds two
uncommitted items: your in-progress `console/serve.py` and the recovered `console/state.py` reference.

## Blocked
- Nothing blocks. `app/opencode.jsonc` stays local — a live-looking DeepSeek key sits in one of its comments.

## Done (verified)
- `.gitignore` (committed `629bb3b`): secrets (`.env`, `.env.*`, any depth), Python, Terraform state, agent
  runtime (`.omo/`, `.workflow/` — also covers `app/.workflow/`) and `app/opencode.jsonc`, plus OS/editor noise.
  No global `*.log`, so evidence logs stay committable; 0 tracked files newly ignored, untracked 45 → 24.
- README (committed `b8879cf`): the reviewer's cuts applied — TOC and the Running-it table gone, `make check`
  out of the allowlist table, WARNING reworded to three irreversible targets, state-machine diagram cut, the
  stale "voting app repo, read-only" prerequisite gone. Script-checked: anchors, links, fences, tables.
- Gate: `bash scripts/checks/S18.sh` → twelve `ok:` lines, `PASS` (`docs/evidence/s18-final-gate.log`), after
  the human approved the two-mechanic fix to the frozen checkpoint (`13c2502`).
- Pushed `bd2a2fb` — eight commits covering `.gitignore`, the make targets, the plan, README, `console/`,
  reviews and both memory banks. Remote tip == local HEAD; `git grep` finds no key in the published tree.
- `console/state.py` was reported missing and recovered from a checkpoint snapshot (`16cd174`, blob `c1602802`).
  Measured against `make state` it is stale — 7 vs 3 containers, 0 vs 21 state objects, `expiresAt: ""` vs null.

## Checkpoints (final code)
- S18: PASS. S17's gate untouched (`make verify` = 17 PASS, `scripts/verify-jit.sh` unmodified).

## Next step
Human: decide the console's read model. `make state` emits no `ingresses`/`ingressPorts` and `index.html:670`
reads both, so the app panes have no URLs; the recovered `console/state.py` is stale, not the answer.

## Watch out
- `app/opencode.jsonc` is ignored but still on disk, holding a live-looking DeepSeek key (`sk-…`) in a
  comment. It was never published; rotate the key if you ever un-ignore, copy or mirror that file.
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` is in neither the tree nor git history; restore it from `S17-review-prompt.md`.
- `console/state.py` is untracked and **not** ignored (the checkpoint refs preserve it), so `git add -A` would
  commit it. It is a reference only: `/state` still runs `make state`, per `console/README.md`.
- `.workflow/` is ignored wholesale, so `app/.workflow/*.md` (design, requirements, synthesis) stays uncommitted.
- `refs/cline/checkpoints/*` — 119 local refs — snapshot the whole tree, `.env` and `terraform.tfstate` with it.
  Never `git push --all`/`--mirror`; `git push origin main` is safe (GitHub holds only `main`, verified).
- Untracked+unignored files leave no deletion record (`git log --diff-filter=D` is empty here); `console/generate.py` is still missing — recover from `7232782`.
