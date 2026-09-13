Updated: 2026-09-13

## Current focus
The console is mid-build — `serve.py` grew a GET /claim, so `claim` joined `CONSOLE_TARGETS` in the
Makefile. That reopens S18 by design: the frozen checkpoint expects 12 names, `make targets` prints 13.

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
- `make claim NS=... MODULE=...` added beside `state` (uncommitted): one InfraClaim as YAML, stderr left alone
  so `serve.py`'s /claim shows kubectl's error. Verified live: 35-line YAML; a NotFound exits non-zero.
- `console/state.py` was reported missing and recovered from a checkpoint snapshot (`16cd174`, blob `c1602802`).
  Measured against `make state` it is stale — 7 vs 3 containers, 0 vs 21 state objects, `expiresAt: ""` vs null.

## Checkpoints (final code)
- S18: PASS at `13c2502`, now red by design (12 vs 13 names). S17's gate untouched: `make verify` = 17 PASS.

## Next step
Human: approve the S18.sh fourth amendment — the header block plus `claim` in its `TARGETS` array, both
drafted in chat. `docs/evidence/claim-allowlist.log` is its evidence. Then I apply it and the gate is green.

## Watch out
- `app/opencode.jsonc` is ignored but still on disk, holding a live-looking DeepSeek key (`sk-…`) in a
  comment. It was never published; rotate the key if you ever un-ignore, copy or mirror that file.
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` is in neither the tree nor git history; restore it from `S17-review-prompt.md`.
- `scripts/checks/S18.sh` is byte-identical (blob `e4d858c3`) and must stay so until the amendment is approved:
  prove changes on a one-line copy, the way `docs/evidence/claim-allowlist.log` does.
- The console's `/state` poll runs `make state`, which tees into the tracked `docs/evidence/state.log` — a page left
  open appends a JSON line every 2s (197 by 02:16). It is also how a finished run's reads are audited after the fact.
- `refs/cline/checkpoints/*` — 119 local refs — snapshot the whole tree, `.env` and `terraform.tfstate` with it.
  Never `git push --all`/`--mirror`; `git push origin main` is safe (GitHub holds only `main`, verified).
