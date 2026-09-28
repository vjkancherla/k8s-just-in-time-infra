# Tenant Settings Change - Team Brainstorm
Date: 2026-09-25
Team: Kira, Nova, Sage, Ops (SRE swap-in for Milo), Ivy, Remy
Context read: jit-controller/main.py, deploy/crd/infraclaim.yaml, jit-modules/modules/{redis,postgres,pgadmin}/ (variables.tf + main.tf), docs/designs/{annotation-to-state,jit-infra-flows,runner-api}.md, memory-bank/{systemPatterns,projectbrief,activeContext,progress}.md
Full debate: [settings-change-transcript.md](./settings-change-transcript.md)
Reviewed: consilium 2026-09-25 — 1 blocker fixed (default-deny for undeclared keys), 1 risk in Open questions (checkpoint effort)
Amended: 2026-09-25 — user decided the day-2 surface: annotations are tenant-only and lifecycle-only; settings changes are console-owned. See the amendment section; it supersedes the Decision's entry point and diff baseline.

## Decision

**Concept 1 — Desired-state diff with classified params** (vote 5–1). The tenant
changes a setting by editing the same `jit.infra/<module>` annotation they used at
create time. The controller diffs annotation params against the claim's
`spec.params` — which from now on means *last successfully applied* — in both
`handle_deployment` and the 30s resync. Mutable-in-place changes are applied via
the runner's existing idempotent `tofu apply`; unsafe and identity-class changes
are rejected with a `ParamsUpdate=False` condition that names the
delete-and-redeclare path. No CRD change, no new runner endpoint.

Remy's premise challenge ("tenants should delete and redeclare, not update") was
answered on the merits — re-adding inside the soft-delete window resurrects the
*old* params silently, so the naive path does not work — and converted into the
v1 scope cut: only changes that apply safely in place are supported; everything
else is rejected with instructions rather than applied-and-lied-about.

Consilium 2026-09-25 added the default-deny row below: undeclared param keys are
rejected, because tofu only warns on unknown `-var`s and would record a typo as
successfully applied.

## Concepts

### 1. Desired-state diff with classified params  *(selected)*
Annotation params are diffed against `spec.params` (= last successfully applied)
in both `handle_deployment` and the resync. On change, each key is classified
against a controller-side map: mutable keys patch spec, call the runner's
existing idempotent apply, rewrite the Secret, and set `ParamsUpdate=True`;
unsafe keys and identity/controller-owned keys are rejected with
`ParamsUpdate=False` and a remediation message. `softDeleteTTL` updates with no
runner call (today it is silently ignored too — this fixes that for free).
Failed updates are terminal until the next Deployment event, matching the
existing Failed rule. Ships with an S-series checkpoint.

Two asymmetries, stated so nobody files them as bugs: create writes `spec.params`
at claim-creation time (existing behaviour; a failed create retries from the
annotation anyway), while update patches spec only *after* a successful apply.
And the update branch inside resync takes the same `claim_lock` the provision
path takes, so an update can never interleave with the TTL sweep's destroy.

v1 classification (from the docker-provider facts):

| Class | Keys | Behaviour |
|---|---|---|
| Mutable | redis `maxmemory`; pgadmin `http_port`, `pgadmin_email`, `pgadmin_password`; `softDeleteTTL` | Apply in place (container recreate, no data loss); TTL is metadata-only |
| Rejected: unsafe | postgres `postgres_db` | Volume persists, initdb runs once — the change would silently not take effect |
| Rejected: identity | `name`, `ip`, `network` | Controller-owned; an IP move breaks the EndpointSlice |
| Rejected: controller-owned | `postgres_password` | Generated once per namespace, reused from the Secret by design |
| Rejected: unknown | Any key the module does not declare | Default-deny: tofu only *warns* on undeclared `-var`s, so a typo would be applied-and-recorded as a no-op — the bug class this feature exists to kill |

- **Pros:** no CRD change (`spec.params` already exists); destroy safety falls
  out of spec-as-applied (`destroy_infra` already builds vars from `spec.params`,
  so a failed desired value can never poison a destroy); tenant stays on the
  annotation surface they already know; unsafe changes fail loudly with
  instructions instead of lying.
- **Cons:** trusts the docker provider's recreate decisions with no plan preview
  (Ivy's dissent — see Open questions); the classification map is
  controller-hardcoded knowledge that belongs to module authors; a Secret rewrite
  still needs a tenant-side pod restart before the app sees it.
- **Effort:** M (~3–5 days, assumed).
- **Touches:** `jit-controller/main.py` (diff in `handle_deployment` +
  `resync_referenced_by`, classification map, `provision_infra` update path,
  `ParamsUpdate` condition), `docs/designs/annotation-to-state.md`,
  `docs/designs/jit-infra-flows.md` (new update sequence diagram),
  `app/docs/MANUAL-TESTING-GUIDE.md`, new `scripts/checks/S19.sh` (assumed
  numbering).

### 2. Claim-spec as the tenant-editable object
Tenants `kubectl patch infraclaim` directly; an `on.update(infraclaims)` handler
drives apply; the annotation handler mirrors annotation→spec for GitOps users.
- **Pros:** kubectl-only operations; the claim becomes a real desired-state
  object; the most k8s-native shape.
- **Cons:** two writers of spec (tenant + annotation mirror) need a conflict
  policy; contradicts the settled "authoring on the Deployment" decision; bigger
  surface to document and test.
- **Effort:** M–L (~5–8 days, assumed).
- **Touches:** `jit-controller/main.py` (new handler + mirror),
  `deploy/crd/infraclaim.yaml` (likely), all three design docs.

### 3. Replace-only cattle
Any param change triggers a controller-orchestrated destroy+recreate, gated by a
`confirmDestroy: "true"` annotation for stateful modules.
- **Pros:** one code path for all params; no docker-recreate trust needed; data
  loss is explicit, never silent.
- **Cons:** postgres loses its volume on every tune (snapshot is out of scope);
  minutes of downtime for a maxmemory bump; recreates IPAM and timing races the
  design worked to eliminate.
- **Effort:** M (~3–4 days, assumed).
- **Touches:** `jit-controller/main.py`, checkpoint scripts, docs.

### 4. Runbook-only
No code; document delete-and-redeclare as the supported change path.
- **Pros:** cheapest; zero new failure modes.
- **Cons:** the runbook is a trap today — re-add inside the TTL window resurrects
  the *old* params silently; the honest version requires waiting out the TTL with
  data loss; every tenant rediscovers this.
- **Effort:** S (~0.5 day, assumed).
- **Touches:** `app/docs/MANUAL-TESTING-GUIDE.md` only.

## Debate highlights
- **Remy's premise challenge vs Kira/Sage/Ops:** "document delete-and-redeclare"
  lost because re-adding inside the soft-delete window resurrects the old params
  (`Orphaned → Ready` reprovisions nothing), and waiting out the TTL races the
  30s sweep. *Resolved:* challenge converted into the v1 class split — in-place
  for safe params, documented delete-and-redeclare for the rest.
- **Nova vs Sage on the diff baseline:** Sage wanted `status.lastAppliedParams`;
  Nova showed that making `spec.params` mean last-applied needs no CRD change
  (status fields are enumerated; spec.params already preserves unknown fields)
  and makes destroy safe by construction. *Resolved:* spec-as-applied, diff
  recomputed in resync as well as the handler.
- **Ops vs Kira on `postgres_db`:** apply-and-lie vs reject. *Resolved:* reject
  with a condition message naming the recreate path; the message preserves
  Remy's runbook exactly where it is right.
- **Kira vs Ops/Nova on stale env:** a Secret rewrite does not reach running
  pods. Kira's controller-driven rollout was rejected (a controller that patches
  tenant pod templates can mass-restart a namespace on a bug). *Resolved for
  v1:* `SecretUpdated` condition tells the tenant to `kubectl rollout restart`;
  automation is an open question.

## Roads not taken
- **Runner-side plan/drift detection** (unmade case, surfaced after the vote —
  the strongest argument against Concept 1): the controller forwards desired
  params every resync and the runner diffs via `tofu plan`, surfacing the plan
  before applying. This changes who owns update semantics — the runner stops
  being a dumb executor. It lost because the runner is deliberately stateless,
  an apply-per-claim-per-30s costs real seconds, and it collides with the
  Failed-terminal rule. It would win if the runner ever grows a cheap plan/diff
  endpoint — see Open questions.
- **The Deployment as the update owner** (coupling-unit alternative): each
  Deployment's annotation drives its own apply. Lost because claims are shared
  (vote+worker share redis) and first-writer-wins already settled the sharing
  semantics. Would win if modules ever became per-Deployment instead of
  per-namespace.

## Vote
| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | Same surface the tenant already knows; dissent: still wants automatic rollout on Secret change. |
| Nova | 1 | Wiring, not an engine — diff + existing idempotent apply + existing conditions. |
| Sage | 1 | Spec-as-applied gives destroy-safety by construction; concept 2 is the long-term shape, not v1. |
| Ops | 1 | Unsafe class rejected by default with instructions; blast radius is honest. |
| Ivy | 2 | Concept 1 trusts the docker provider's recreate decisions with no plan gate; an explicit claim edit is more falsifiable. Dissent recorded. |
| Remy | 1 | Premise challenge converted into the v1 class split; scope is contained. |

## Open questions
- [ ] Should the runner expose `tofu plan` so the controller can surface (or gate
  on) what an update will do before doing it? Ivy's dissent; the checkpoint suite
  is the v1 mitigation. (Ivy, Sage)
- [x] ~~Automatic rollout of referencing Deployments when an update rewrites
  Secret values?~~ Answered by the 2026-09-25 amendment: the console shows
  `SecretUpdated` with a **Restart pods** button (human-initiated rollout
  restart make target). The controller never patches tenant pod templates, so
  Ops's veto holds; Kira gets a one-click path instead of homework. (Kira, Nova)
- [ ] Should rejected param keys (identity/controller-owned) also be rejected at
  admission time via a validating webhook, rather than post-hoc by condition?
  Probably over-scope for a PoC. (Sage)
- [ ] RISK: the checkpoint is the estimate's critical path — S17/S18 history says
  S-series checks are where estimates die. Mitigation: the checkpoint is its own
  build-plan step, not a tail-end task; if effort forces a cut, drop the pgadmin
  mutable keys (ship redis `maxmemory` + TTL first), never the checkpoint. (Remy)

## Amendment 2026-09-25 — day-2 surface: console-owned settings

Decided by the user after the brainstorm and consilium: **annotations are touched
only by the tenant and are used only for lifecycle** — create, the keep-alive
lease, destroy, `softDeleteTTL`, and seeding params at claim-create time. Ongoing
settings changes are owned by the console. This supersedes the Decision's entry
point and diff baseline; the rest of the note stands.

| Concern | Owner | Surface |
|---|---|---|
| Lifecycle (create, lease, destroy, TTL, initial params) | Tenant only | Deployment annotations, in Git |
| Settings (day-2 param changes) | Tenant, via console | Console → InfraClaim |
| Apply, classify, reject, record | Controller | Unchanged pipeline |

What changes relative to the Decision:

1. **Entry point.** The annotation-diff update path is replaced by a claim
   watch: `@kopf.on.update(infraclaims)` fires when the console patches
   `spec.params`; the 30s resync diffs desired vs applied as the correctness
   net. The Deployment handler no longer diffs params after create — it ensures
   the claim (the lease) and mirrors `softDeleteTTL` (lifecycle data) only.
2. **Desired/applied split.** `spec.params` becomes *desired* (console-writable,
   seeded from the annotation at claim create). New CRD field
   `status.appliedParams` (`x-kubernetes-preserve-unknown-fields`) records last
   successfully applied; the update diff is spec vs appliedParams.
   `destroy_infra` switches to `status.appliedParams` with a `spec.params`
   fallback for pre-existing claims. This reopens the Nova–Sage synthesis in the
   debate: spec-as-applied depended on the annotation being the sole source of
   desired state. With two desired-state writers at different times (seed +
   console), Sage's original three-state model is the shape. Destroy-safety is
   preserved, relocated to status.
3. **Seed-at-create.** Annotation params are read once, at claim creation.
   Editing them afterwards sets a `ParamsManagedByConsole` condition ("params
   were seeded at create; change them via the console, or re-seed") — never a
   silent no-op, never a surprise application. A console **Re-seed from
   annotation** action (a make target copying annotation params into
   `spec.params`) is the escape hatch and flows through the same pipeline.
4. **Console path.** `make claim-set NS=… MODULE=… SET=key=value` →
   `kubectl patch infraclaim … --type merge` on `spec.params` (merge per key;
   `claim-unset` patches the key to null). The console keeps its own rule — no
   state, no kubectl of its own, no copied validation map. It submits and
   renders the controller's `ParamsUpdate` conditions. `make state` exposes
   per-claim desired params and conditions (the same claim query it already
   runs). Greying out rejected keys in the UI stays deferred: if wanted, the
   CRD addition above bundles a `status.paramClasses` field and the console
   renders from it.
5. **Emergent property.** Console tuning survives redeploy-inside-the-window:
   the claim survives resurrection, so its desired params survive too. Settings
   and data now have the same retention story.

Unchanged: the classification map with default-deny; `ParamsUpdate` conditions;
failed updates terminal until the next event (now: next claim or Deployment
event); the checkpoint suite (its annotation-driven cases become
`claim-set`-driven; the re-seed case covers resurrection-with-new-params); the
console's no-state rule.

Open questions resolved by this amendment: the stale-env question (console
shows `SecretUpdated` with a **Restart pods** button wired to a rollout-restart
make target — a human clicks; the controller never patches tenant pod
templates). The `paramsFrom` ConfigMap idea is parked: it answered annotation
ergonomics, and with annotations lifecycle-only plus console forms hiding the
JSON, its remaining value is GitOps-managed bulk seed params — revisit only if a
module grows a large seed-time param surface.

Effort delta (assumed): +~1 day over the note's M for the claim handler, CRD
addition, backfill and destroy retarget. Console work S–M (~2–4 days, assumed):
read-model params/conditions exposure, parametrized make targets with SAFE-style
validation, the claim-panel editor, restart button, and the three existing
console test suites.

## Next steps
- [ ] Feed this note into `/build-plan`, sequenced as: (1) classification map +
  `status.appliedParams` + claim `on.update` handler + `provision_infra` update
  path + destroy retarget in `jit-controller/main.py` (+ CRD), (2) the
  S19-shaped checkpoint (`claim-set` a `maxmemory` change → container command
  changed + condition cleared; `claim-set` a `postgres_db` change → claim stays
  Ready with rejection condition; TTL change via annotation → spec patched with
  no runner call; re-seed after annotation edit → applied; two writers at
  seed time → loser's `ParamsConflict`), (3) console: read-model exposure,
  `claim-set`/`claim-unset`/re-seed make targets, claim-panel editor, restart
  button, (4) `docs/designs/jit-infra-flows.md` update sequence diagram in the
  same step that changes the behaviour (per that doc's own rule).
