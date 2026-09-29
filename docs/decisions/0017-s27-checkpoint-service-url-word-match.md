# 0017. S27 checkpoint `service_url` match: one key per line for `grep -x`

Date: 2026-09-29
Status: accepted

## Context

[ADR 0015](0015-s27-checkpoint-mechanics-fixes.md) fixed the harness defects that stopped
`scripts/checks/S27.sh` reaching a correct module. With those in place the runner's
postgres apply returns (measured):

```
address port service_url service_url_analytics service_url_voting url volume_name
```

and step 2 then fails at

```
FAIL: the initial database lost its service_url key
```

The script builds that list as a single space-joined line —

```bash
urls="$(echo "$resp" | python3 -c '... print(" ".join(...keys()))')"
echo "$urls" | grep -qx "service_url" || fail "..."
```

— and `grep -x` matches a whole *line*. A space-joined multi-key line can never be the
exact string `service_url`, so the assertion is unsatisfiable for any module that returns
more than one output (this one returns seven). The adjacent
`grep -q service_url_analytics` (no `-x`) matches as a substring and is unaffected.

## Decision

Build `urls` one key per line (`print("\n".join(...))`) so the existing `grep -qx
"service_url"` compares against an exact line. The pattern, the `-x` exactness and the
failure message are unchanged; only the separator the script itself chose changes.

## Consequences

**Easy.** The `service_url` assertion tests what it says — that the initial database's
key is still present by exact name — while the sibling `service_url_analytics` substring
check continues to prove the flattened per-database key was added.

**Hard / ruled out.** The separator is now part of the contract: a space-joined list can
never satisfy `grep -x`. No assertion is removed or weakened; this makes an existing one
reachable.
