# Lessons

A rule per entry, with the evidence that produced it. Added when something had to be
reworked (build-plan.md "Done") or when a review surfaced a gap the reviewed step
could not fix itself. Rules, not narrative — the narrative belongs in the review file
that raised it.

---

## From S15 — the migration (`docs/reviews/S15-findings.md`)

**An overlay must not reach a directory that contains the overlay itself.**
`resources: ../..` from `kustomize/overlays/registry` resolved to the base's own tree,
and kustomize refused it: `cycle detected: candidate root '.../kustomize' contains
visited root '.../kustomize/overlays/registry'`. Manifests now live in `base/` and every
overlay references `../../base` — a sibling subtree, never an ancestor.

**Test an overlay by building it, not by describing it.**
R12 built the base and `sed`-ed the registry hostname in, so the broken overlay passed
`make verify` for the whole of Stage A-D. `kubectl kustomize <overlay>` is the only
honest test; `scripts/checks/S15.sh` now asserts it.

**Never route a secret back through a Terraform module output while the runner reads
`tofu output` in plain text.** A sensitive value renders as the literal `<sensitive>`,
so the value reaches the Secret unusable — `jid-postgres.url` is already in that state.
The controller writes the password it generated directly instead. Moving ownership into
the module (the right production shape) requires `tofu output -json` in the runner first.

**`Failed` is terminal until the Deployment changes, so a not-yet-ready dependency must
leave a claim pending, not failed.** Otherwise a race between two claims (pgadmin before
postgres) wedges the loser forever. `resolve_postgres_credentials` returns a pending
reason and `provision_infra` returns without touching the phase; the resync retries.

**A frozen checkpoint can be invalidated by a later step — record it, do not edit it.**
`scripts/checks/S00.sh` asserts 5 workloads and 17 PASS; S15 removed the first and S16
will restore the second. Its header now states the staleness. Note the trap: the failure
is latent while the old deployment is still running, so the gate passes misleadingly —
and it parses `verify.md` instead of running `verify.sh`, so a stale artifact satisfies it.

## From S16 — reworking the R-checks (`docs/reviews/S16-findings.md`)

**"Rework the six checks the migration invalidates" understates the change: grep for the
shared helper, not the requirement number.** The build plan named R2, R8, R9, R10, R11,
R16 and R17. R3, R4, R6 and R7 were also broken — not in their own bodies, but because
they read the stateful tiers through `psql_q` / `redis_q`, and R7 called
`kubectl exec "$PGPOD"` directly. Rewriting the two helpers to `docker exec` fixed four
checks without touching them; R7 needed one line. The step's own list was a good start and
an incomplete inventory.

**A stale gate that passes is more dangerous than one that fails.** `scripts/checks/S00.sh`
asserts "all 5 workloads Ready" and passed for as long as the pre-migration app happened to
still be running in `default`. Deploying the S15 manifests there produced
`FAIL: voting-app-redis not ready (ready='' desired='')`, exit 1 — the first honest result
it had given since S15. Its header predicted exactly this, which is why annotating a frozen
gate (rather than editing it) is the right repair: the record of the staleness is what makes
the failure readable.

---

## Carried forward — do not lose these

**A module output that does not exist cannot be defaulted away.**
`jit-controller/main.py` writes the Service port as `int(outputs.get("port", "6379"))`, so
`jit-pgadmin` advertises **6379** — redis's default — because the pgadmin module exposes no
`port` output and listens on 80. No R-check touches pgAdmin, so it is invisible today.
Owner: **S17**, where the pgadmin claim starts mattering.

**pgAdmin publishes a fixed host port (`http_port`, default 5050).** Two namespaces
cannot both run pgAdmin; the second claim goes `Failed`. Owner: **S17**, which deploys
`voting-a` and `voting-b`. Fix by parameterising `http_port` per claim via annotation
params, or by running pgAdmin in one namespace only.

**A committed secret literal sets a precedent.** `voting-app-secret-key` holds
`SECRET_KEY=dev-only-session-key-not-a-credential`. Acceptable only because it is a Flask
session key and R17 scopes `POSTGRES_PASSWORD` — no database credential is committed.
Before any real deployment, generate it externally (Secrets Manager, Sealed Secrets).

**The runner should move to `tofu output -json`.** Until it does, no module can own a
sensitive output, and secrets have to be written by the controller from values it
happens to know.

**Four things production needs that this PoC omits** (build-plan.md "Done"): snapshot
before destroy, `retain: true`, stopping rather than running during retention, async
provisioning, and real IAM.
