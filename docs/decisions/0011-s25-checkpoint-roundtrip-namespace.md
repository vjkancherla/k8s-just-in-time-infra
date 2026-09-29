# 0011. S25 checkpoint amendment: the status round-trip must name the claim's namespace

Date: 2026-09-29
Status: accepted

## Context

S25's whole assertion is the round-trip in `scripts/checks/S25.sh`: patch a live
InfraClaim's `status` with `appliedParams`, `attemptedParamsHash` and `declaredBy`, then
`kubectl get` each one back, because a field the schema omits is pruned by the API server.

The checkpoint locates the claim with `kubectl get infraclaims -A -o name | head -1`
(`scripts/checks/S25.sh:28`) and then patches and reads back that string with **no**
namespace (`:30`, `:36`). `kubectl get -o name` does not carry the namespace — on the run
host (kubectl v1.36.3) it emits `infraclaim.jit.io/voting-a-pgadmin`, i.e.
`<resource>.<group>/<name>`, even under `-A`; namespaced objects are named
`<resource>/<name>` and never `<resource>/<namespace>/<name>`. The bare name therefore
resolves in the kubeconfig's current namespace (`default` here, and nothing in
`scripts/jit-up.sh`/`scripts/demo-up.sh` ever sets it), misses the claim, and the
checkpoint dies at `:33` before it can assert anything about pruning.

The first live capture shows exactly this — `docs/evidence/S25.log` ends
`Error from server (NotFound): infraclaims.jit.io "voting-a-pgadmin" not found` then
`FAIL: could not patch status - fields missing from the schema or the patch rejected`.
Earlier captures never reached it: they stopped at the CRD-absent precondition. The
assertion itself (three fields survive an API round-trip) is correct; only the claim's
location is wrong.

## Decision

Amend `scripts/checks/S25.sh` lines 28-38 to resolve the claim's namespace from the same
cluster list and name it on every call:

- read `claim_ns` from
  `kubectl get infraclaims -A -o jsonpath='{.items[0].metadata.namespace}'` (the same
  first item `-o name | head -1` selects), and `claim_name` as the basename of the
  `-o name` value;
- fail with a readable message if either cannot be resolved;
- patch `infraclaim "$claim_name" -n "$claim_ns"` and read each field back with the same
  `-n "$claim_ns"`.

Nothing else changes. The three field names, the `probe` values, the three read-backs and
every failure message are byte-identical; no assertion is added, removed or weakened.
The edit is committed with this ADR, before the checkpoint is run again.

## Consequences

**Easy.** The round-trip finds the claim wherever it lives, independent of the kubeconfig
context namespace — which the harness never sets and which the checkpoint must not quietly
depend on. The `-A` list is still the selector, so the checkpoint still proves the fields
against a real claim rather than a fabricated one.

**Hard / ruled out.** `scripts/checks/` takes one further edit, only under this ADR; a
later change needs another. The checkpoint's exit semantics and PASS line are unchanged.
The namespace and the name are read from the same list call and kubectl's default
ordering, so `.items[0]` and `-o name | head -1` select the same object.
