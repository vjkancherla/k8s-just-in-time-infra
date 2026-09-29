# 0026. S29 U13 asserts the postgres claim's own TTL maximum

Date: 2026-09-29
Status: accepted

## Context

`scripts/checks/S29.sh` U13 (two consumers with different TTLs, voting-b) ended its
`u13check` with:

```sh
ttl="$(kk get infraclaim voting-b-postgres -n voting-b -o jsonpath='{.spec.softDeleteTTL}')"
[ "$ttl" = "45m" ] || true
ttl="$(kk get infraclaim voting-b-redis -n voting-b -o jsonpath='{.spec.softDeleteTTL}')"
[ -n "$ttl" ] && [ "$ttl" = "45m" ]
```

The postgres half is vacuous: `|| true` makes it pass whatever the value, so only the redis
half asserts rule 7 (`spec.softDeleteTTL` is the maximum declared across a claim's
references). A gate half that cannot fail asserts nothing.

The expected postgres value is not 45m: `voting-b-postgres`'s references are `worker`
(declarer) and `result` (consumer), both pinned `softDeleteTTL: "10m"` in
`app/kustomize/base/`. The point of the postgres half is that U13's redis edit must not
leak a TTL across claims - rule 7 is per-claim.

## Decision

Amend the frozen `scripts/checks/S29.sh` U13 (`u13check` only), sanctioned by this ADR:
assert that `voting-b-postgres.spec.softDeleteTTL` is `10m` (its own references' maximum)
alongside the existing `voting-b-redis` = 45m assertion. The retry loop already waits for
the redis half; the postgres half is stable from `make test-up`, so the function succeeds
when both hold.

The `10m` is the base overlays' declared TTL for both postgres references; if the base
changes the assertion fails loudly, which is the intended direction. Computing the max from
the live annotations was rejected as a tautology that re-implements rule 7 in the test.

## Consequences

- Removing rule 7's per-claim scoping (letting one claim's TTL leak to another) now fails
  U13, so the gate asserts both halves of the rule rather than redis alone.
- The gate still depends on `make test-up` having provisioned voting-b; U13 already failed
  fast when the voting-b claims were missing, unchanged.
- No other assertion in U13 or S29 changes.
