# Graphify freshness - working rules

The knowledge graph at `graphify-out/graph.json` only saves tokens while it matches
the code. A graph built from an older commit returns a confidently wrong architecture,
the model then reads the real files anyway, and the session pays twice. This repo's
graph once drifted 132 commits (`3d1d779` -> `898ac88`) before anyone noticed.

## Before any codebase question

1. Check freshness — cheap, no LLM:

   ```
   graphify check-update .
   ```

   or compare the two commits directly:

   ```
   git rev-parse HEAD
   graphify-out/graph.json  ->  built_at_commit
   ```

2. If stale, refresh before querying. Code is local and free (seconds):

   ```
   graphify update . --force
   ```

   `--force` is required when the rebuild has fewer nodes (deletions, or a file newly
   caught by `.graphifyignore`); without it the rebuild is refused and the old graph
   stays.

3. Then query the graph, not the files:

   ```
   graphify query "<question>" --budget 800
   ```

   Read a file only when the graph cannot answer.

## Keep it fresh as work lands

- After changing code, run `graphify update .` again — AST only, no API key.
- Docs, papers and images are semantic and need a model backend; `update` covers code
  only. Structural markdown (headings, links) is still refreshed locally.
- `graphify-out/` is generated and gitignored. Never commit it; commit
  `GRAPH_REPORT.md` if a shareable artifact is wanted.

## What is excluded

`.graphifyignore` drops one-off noise so traversal stays on architecture:
`docs/evidence/`, `scripts/checks/`, `memory-bank/journal/`. Widening that list is a
normal edit — but re-run `graphify update . --force` afterwards so stale nodes evict.
