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

---

## Carried forward — do not lose these

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
