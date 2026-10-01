# Project agent memory

k8s-just-in-time-infra: this file is the always-loaded memory for agents working in this repo.
It is kept short on purpose - every line here is paid on every session.

## Learnings

- Checkpoints: `scripts/checkpoint.sh SNN` once, exact step id (not `SS23`, not extra args). Inspect live-cluster namespace/resource assumptions before running; do not edit captured `docs/evidence/SNN.log`.
- Frozen checkpoints and binding designs: stop and ask unless the task explicitly authorizes writing an ADR.
- Reviews: exactly one final `Verdict:` line. Cited amendments and commit range must match the range actually reviewed.
- Failed reads: search the repo before retrying a guessed path. Before claiming exclusive file changes, account for every untracked worktree file.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
