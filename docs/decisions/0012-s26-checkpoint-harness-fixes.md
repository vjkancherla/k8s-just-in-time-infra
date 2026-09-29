# 0012. S26 checkpoint harness and contract fixes

Date: 2026-09-29
Status: accepted

## Context

Stage H's checkpoints were frozen at `d0d4329` and amended once by
[ADR 0005](0005-stage-h-checkpoint-contract-fixes.md). S26's
(`scripts/checks/S26.sh`) amendments there were the conflict guard, group 5's
value, the `-g` → `-gt` typo and the `kill 0` cleanup trap. None of them was
exercised, because S26 never ran past its first precondition: `docs/evidence/S26.log`
and `docs/evidence/s22-all-fail.log` both record S26 failing with
`FAIL: CRD missing - run 'make jit-up' before this checkpoint`, with nothing
implemented.

With the cluster up (`make jit-up`) and the CRD present, the frozen script cannot
pass with a design-conforming controller. Six defects, each reproduced on this
tree:

1. **The scratch-Deployment helper passes its data to `kubectl`.** `make()` runs
   `kk apply -f - "$@" >/dev/null <<EOF`; `"$@"` is the Deployment name, module
   and JSON (`d1 redis {"module":...}`), which `kubectl apply` reads as
   unexpected positional arguments. Reproduced:
   `kubectl apply -f - foo bar` → `error: Unexpected args: [foo bar]`, exit 1.
   Every `make d…`, including the first, fails.

2. **Nine reads omit the namespace.** Group 1's `waitfield()` and the bare
   `kk get infraclaim "$NS-redis" …` calls in groups 2, 5, 6, 7, 8 and the group 9
   patch carry no `-n "$NS"`. The kubeconfig context namespace is empty
   (`kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}'`
   prints nothing), so kubectl reads `default`. Reproduced:
   `kubectl get infraclaim voting-a-redis` → `Error from server (NotFound)`;
   `kubectl get infraclaim voting-a-redis -n voting-a` → the claim. The claim
   `jit-stub-redis` is never found, so `waitfield` returns 1 and group 1 fails at
   the first assertion after the helper is fixed.

3. **`stub_get` greps the wrong workspace.** The helper is
   `grep -E "^POST module=$1 workspace=$2"` and every call passes
   `"$NS-redis"` (`jit-stub-redis`). The controller's runner workspace is the
   **namespace** (`docs/designs/runner-api.md`: "workspace — Namespace/workspace
   name"; `jit-controller/main.py`'s `call_runner(module, version, ns, …)`; live
   evidence: `jit-runner` logged `Destroy jit-s26probe … cached run
   (jit-s26probe/redis)` when the in-cluster controller cleaned up a probe
   Deployment). The stub records `workspace=jit-stub`, so every call count reads
   zero and groups 2, 4, 5 and 6 fail.

4. **Groups 5 and 6 contradict the design's conflict rule.** Group 3 sets the
   second declarer `dnn` back to the agreed `200mb`; groups 5 and 6 then change
   only `d1` (`222mb`, then `150mb`, then `111mb`) while `dnn` stays at `200mb`.
   The design resolves disagreeing declarers to nothing — "Disagreeing declarers
   change nothing … desired stays equal to applied"
   (`docs/designs/declarers-and-consumers.md:86`) — so a correct resolver never
   POSTs, and group 5's own comment ("allowed update: a value DIFFERENT from
   appliedParams") demands a POST. The conflict scenario is fully asserted by
   groups 2 and 3; the update groups need one agreeing declarer.

5. **Groups 8 and 9 wait on a claim that cannot exist.** They read
   `"$NS-redis-c2"`, but claim identity is `<namespace>-<module>`
   (`docs/designs/declarers-and-consumers.md` §Terms; the build plan's S22
   context: "claim `<namespace>-<module>`"). Reproduced: a Deployment named `c2`
   annotating `redis` in namespace `jit-s26probe` produced the claim
   `jit-s26probe-redis`, not `…-redis-c2`. Adding a consumer to an existing claim
   that has lost its declarers is group 7's `NoDeclarer` case; a genuinely
   consumer-only **new** claim needs a fresh namespace.

6. **The stub run is not confined to the scratch namespace.** The local
   controller is started clusterwide (no `WATCH_NAMESPACES`), so it reconciles
   every claim in the cluster against the port-8999 stub. The S25 checkpoint left
   `voting-a/voting-a-pgadmin` at `appliedParams={"probe":"s25"}` while its
   `spec.params` is `{}` (S25 review concern 2). A correct S26 resolver sees
   demanded ≠ applied, the pgadmin contract passes the empty desired, and the
   apply overwrites the live `jit-pgadmin` Secret through the stub — breaking the
   demo the later steps and the S29 gate run against.

Additionally, the local controller cannot authenticate as written: `custom_login`
unconditionally reads the in-cluster service-account token, which does not exist
on the Docker host (`FileNotFoundError`), and kopf retries instead of using the
kubeconfig. That is fixed in `jit-controller/main.py` (the handler is registered
only when the token exists, so kopf's kubeconfig fallback is used out of cluster);
it is not a checkpoint edit.

## Decision

Change, through this decision, exactly the six defects above, committed with this
ADR. Each fix is a harness or setup correction, not a softening: every assertion's
intent and message is preserved, and the script still fails readably when the S26
logic is absent.

### 1. `make()` — drop the stray `"$@"`

`kk apply -f - "$@" >/dev/null` becomes `kk apply -f - >/dev/null`. The heredoc
still interpolates `$1`/`$2`/`$3` for the Deployment's name, annotation key and
JSON, which is what those arguments are for.

### 2. The nine missing namespaces

`waitfield()` gains `-n "$NS"`; the bare `kk get infraclaim "$NS-redis" …` reads
in groups 2, 5, 6 and 7 gain `-n "$NS"`; the group 9 `kk patch infraclaim` gains
`-n "$NS"`. No assertion text changes.

### 3. `stub_get` — the workspace is the namespace

Every `stub_get redis "$NS-redis"` becomes `stub_get redis "$NS"`. The counts and
their assertions are unchanged; only the locator the grep needs is corrected.

### 4. Groups 5 and 6 — one agreeing declarer

After group 3's `ParamsConflict=False` assertion, add
`kk delete deploy dnn -n "$NS" --ignore-not-found`. The conflict is asserted by
groups 2 and 3 while `dnn` exists; the update flow is then exercised with the one
declarer the groups change. No group 5/6 assertion changes.

### 5. Groups 8 and 9 — a fresh namespace for the consumer-only claim

Before group 8, recreate the scratch namespace
(`kk delete ns "$NS" --wait=true --timeout=60s`, wait for it to go, `kk create ns
"$NS"`), then apply the consumer; the claim under test is `$NS-redis`, and group 9
patches that same claim. The assertions (`AwaitingDeclarer=True`, `Pending`, then
`Ready`) are unchanged; they now name a claim the design actually creates.

### 6. The stub run watches only the scratch namespace

The controller launch becomes
`RUNNER_URL=http://127.0.0.1:8999 WATCH_NAMESPACES="$NS" python3
jit-controller/main.py`. `main.py` already supports `WATCH_NAMESPACES`; this is
the mechanism for confining a local run.

## Consequences

**Easy.** The S26 harness now exercises what its comments claim: the six
resolution outcomes through the nine groups, with call counts that can only be
non-zero for a controller that really POSTs to the stub. Every assertion keeps
its message. The scratch run can no longer reconcile (and clobber) tenant claims,
which is the precondition for S29's live gate to find voting-a intact.

**Hard / ruled out.** `scripts/checks/S26.sh` is edited outside its ADR-0005
amendments; any later change needs another ADR. The S26 evidence must be
regenerated by `scripts/checkpoint.sh 26`, and the review prompt cites this ADR
for Q1/Q3/Q4 so the amendment is judged as a decision, not a violation. The
clusterwide local run the frozen script implied is gone; S29 remains the step
that exercises the real namespaces.

**Not in scope.** No controller assertion is removed: the six resolution
outcomes, the refusals, the retry gate, the success and failure branches, the
backfill and the stale-`Updating` recovery that the frozen groups assert stay
asserted. This ADR does not add coverage for the backfill or the
new-declarer-after-a-gap path, which the frozen checkpoint never tested; S29/U11
carries the backfill gate, and the implementation's unit tests cover both.
