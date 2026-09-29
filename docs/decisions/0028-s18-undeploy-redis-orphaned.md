# 0028. S18's post-undeploy redis assertion is wrong: undeploy removes every reference

Date: 2026-09-29
Status: accepted

## Context

`scripts/checks/S18.sh` line 147 asserts, after `make demo-undeploy`:

```sh
jq -e '[.namespaces[].claims[] | select(.module == "redis" and .phase == "Ready")] | length == 1'
```

the message "redis did not stay Ready - worker still references it". This encodes an
earlier design in which `demo-undeploy` left `worker` (a redis consumer) running, so the
redis claim kept its consumer lease and stayed `Ready` with no declarer.

The current `demo-undeploy` (`Makefile:99`) deletes all three Deployments
(`voting-app-vote`, `voting-app-worker`, `voting-app-result`). With every reference gone,
every claim - redis included - goes `Orphaned` with an `expiresAt`; none stays `Ready`. The
assertion cannot pass and no implementation could satisfy it, which is why S18 has been
recorded as broken in `docs/HANDOFF.md` P1.

## Decision

Amend the frozen `scripts/checks/S18.sh`, sanctioned by this ADR: assert that the redis claim
is `Orphaned` after `demo-undeploy` (alongside the existing "an Orphaned claim has an
`expiresAt`" and "no container destroyed" assertions), instead of asserting it stays
`Ready`. The message becomes "redis did not go Orphaned after undeploy removed every
reference".

No other assertion changes. The rest of S18 (target allowlist, `make state` shape, claim
counts, the fence, `demo-redeploy` returning every claim to `Ready`) is untouched.

## Consequences

- S18 becomes satisfiable again under the current `demo-undeploy`, and still fails loudly if
  undeploy stops orphaning redis (e.g. if it reverts to leaving a consumer behind, which
  would make redis `Ready` and this assertion fail in the other direction).
- The amendment was not re-run for evidence in the same session: S18 needs a live demo
  (`make demo-up`), the stack had no tenants after the S29 gate, and the human directed the
  session to stop paying the heavy bring-up cost. The next live S18 run is the confirmation.
- This ADR records a checkpoint edit whose evidence is deferred; a reader of `docs/todo.md`
  should treat S18's box as corrected-but-not-reconfirmed.
