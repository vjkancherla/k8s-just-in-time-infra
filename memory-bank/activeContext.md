Updated: 2026-09-13

## Current focus
S18 is complete, ticked and published: the console, the guides and the `.gitignore` pass went up as eight
commits ending at `bd2a2fb`. The tree is clean and level with `origin/main`.

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

## Checkpoints (final code)
- S18: PASS. S17's gate untouched (`make verify` = 17 PASS, `scripts/verify-jit.sh` unmodified).

## Next step
Human: give the console a step in `docs/build-plan.md` — line 608 assigns the page, over `make state`, to S19
and the proxy to S20, but neither step exists and `console/` is already committed without them.

## Watch out
- `app/opencode.jsonc` is ignored but still on disk, holding a live-looking DeepSeek key (`sk-515c…`) in a
  comment. It was never published; rotate the key if you ever un-ignore, copy or mirror that file.
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` is in neither the tree nor git history; restore it from `S17-review-prompt.md`.
- `docs/build-plan.md:616` and `docs/lessons.md:118` cite README sections by name ("From cold", the wedged
  namespace); both survive the rewrite.
- A warm bring-up can leave postgres's data directory, `POSTGRES_PASSWORD` and the `jit-postgres` Secret
  disagreeing and pods rejected; `demo-up` starts cold, so it never sees that shape.
- `.workflow/` is ignored wholesale, so `app/.workflow/*.md` (design, requirements, synthesis) stays uncommitted.
- `refs/cline/checkpoints/*` — 119 local refs — snapshot the whole tree, `.env` and `terraform.tfstate` with it.
  Never `git push --all`/`--mirror`; `git push origin main` is safe (GitHub holds only `main`, verified).
