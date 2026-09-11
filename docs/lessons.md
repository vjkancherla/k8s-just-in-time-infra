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

## S16 review — CONCERNS, decisions (`docs/reviews/S16-findings.md`)

No blockers. Both concerns were **fixed in this step**, not deferred to S17.

**1. The helpers' silent-empty pattern. Fix.** `psql_q` and `redis_q` return the empty
string on any failure, so two failed reads compare equal: R3 could pass on `"" == ""`, and
R8's drain assertion had the same shape. Keeping the helpers non-fatal is still right —
verify.sh has no `set -e`, and one unreadable dependency must not abort the other sixteen
checks — so the guard belongs in the comparisons: R2, R3, R6 and R8 now assert their reads
are non-empty and name the container when they are not. R4, R7 and R16 compare against
literals and fail on their own. Demonstrated by running `verify.sh` with
`REDIS_CONTAINER` / `POSTGRES_CONTAINER` pointed at non-existent containers
(`docs/evidence/s16-negative.log`): those checks now FAIL with a readable reason instead of
comparing empties. S17's `verify-jit.sh` runs under `set -euo pipefail` and should fail
fast instead of carrying the pattern over.

**A guard is not a fix if it skips the cleanup.** The first version of R8's guard returned
early on an unreadable read — and R8's scale-back-to-1 lived inside the branch it skipped,
so the worker was left at **0 replicas** with nothing consuming the queue. The negative
test caught it (`worker desired=0` after the run); the restore now sits outside the
branches and runs on the failure paths too, and the re-run ends `worker desired=1 ready=1`.
When a check pauses something to observe it, its early exits are part of the change.

**2. build-plan.md's "eleven unaffected" was stale. Fix.** The real split is eleven
invalidated (the seven rows in S16's table plus R3, R4, R6 and R7, which broke through the
shared helpers and R7's direct `kubectl exec "$PGPOD"`) and six unaffected (R1, R5,
R12-R15). S16's section was corrected in place with a dated note; the "Do not change R1,
R3-R7, R12-R15" sentence was wrong about R3-R7 for the same reason.

---

## From S17 — the demo, the J-suite and the fixes it exposed

**A bind mount is resolved by the Docker daemon, not by the process that wrote the file.**
`modules/pgadmin` wrote `servers.json` with `local_file` and bind-mounted the path into the
container. Tofu runs inside the `jit-runner` container, so on macOS the file existed only in
the runner's own `/tmp`; the daemon, asked to mount a path it could not see, **created an
empty directory** at `/pgadmin4/servers.json` and pgAdmin started with no server registered.
Nothing failed, for the whole of S5-S16, because nothing read the file. Fixed by writing to
a directory both sides can see: `deploy/runner.sh` mounts `$HOME/.jit-host-share` and the
runner exports `TF_VAR_share_dir`, which the module reads (tofu picks up `TF_VAR_*` from the
environment, and ignores the ones no module declares). `make jit-verify`'s J3 now reads the
file back out of the container.

**A claim's teardown needs every variable the module requires, and the Secret it reads them
from may already be gone.** `destroy_infra` read pgadmin's `postgres_url` from the
`jit-postgres` Secret only "if it had an address". When a namespace's postgres and pgadmin
claims expire in the same sweep, postgres is destroyed first and its Secret deleted, so
pgadmin's destroy failed with "No value for required variable" and the claim sat in
`Deleting` forever — the wedged-namespace failure the README warns about. It now falls back
to a placeholder the way `postgres_password` already did: destroying a container does not
need the real credentials, only a value for the variable.

**A module output that does not exist cannot be defaulted away.** (carried forward from S16)
`jit-pgadmin` advertised port **6379** because the controller defaults a missing `port`
output to redis's. The pgadmin module now exports `port = 80`, and `create_jit_service`
re-states the spec on 409 so a Service created before the fix does not keep the stale port.

**A test that can only pass on the first attempt is not testing what the design says it is.**
J4 asserts "other workloads unaffected" by draining a vote through the worker after the vote
Deployment is deleted. R9 (run inside J2) restarts Postgres, and `worker/app.py` BLPOPs
destructively, so **the first insert after a restart is lost** — measured on this cluster:
baseline landed, first-after-restart did not, second did. The check now makes up to three
attempts and asserts the worker recovered, instead of encoding a one-shot assumption the
worker never made.

**Idempotence is a property of the steps, not the target.** `make jit-up` looks idempotent
until `deploy/minio.sh` returns 409 `BucketAlreadyOwnedByYou` for the bucket it created on
the first run — the script recreated the container but not the bucket check. `up` is only as
re-runnable as the least re-runnable thing it calls.

**A destroy must never resolve to a module the caller did not name.** `jit-runner`'s
`DELETE /v1/runs/{workspace}` fell back to "the workspace's only cached run" whenever the
requested module had no in-memory entry. The TTL sweep destroys a claim and kopf's delete
handler then destroys the *same* claim again (removing the finalizer deletes the object, which
fires the handler) — and on that second call the cache no longer holds the module, so the
postgres retry resolved to **redis** and removed `voting-a-redis-redis`, a container that was
still referenced and `Ready`. Its claim stayed `Ready` with no container, which the stale-Ready
detector cannot see (the Secret still exists). The fallback now applies only when the request
names no module at all, which is what S06 and S07 do — the two frozen gates that rely on it.
Instrumentation was added to the runner at the same time: it had no logger, so the access log
recorded the workspace and nothing else, and this was invisible until a probe read the
container list.

**Two claims in one namespace can be handed the same IP, and reading the code did not say so.**
J1 deploys three claims and intermittently gave `pgadmin` and `redis` both `172.19.0.100`; the
loser failed to start with "Address already in use" and its claim went `Failed`, which is
terminal until the Deployment changes. Two independent causes, one symptom:

- `ensure_claim` allocated in four non-atomic steps — read this claim's address, read the other
  claims' addresses, pick the first free one, patch — and the only lock in play (`claim_lock`)
  was keyed **per claim** and taken *after* it, so it serialised provisioning and never
  allocation between different claims. kopf fires `on.create` **and** `on.update` for a single
  Deployment apply, each iterating every claim, so the interleaving is the normal case rather
  than a rare one. Fixed by taking `namespace_lock(ns)` around the whole read-pick-patch.
- `release_block` ran **twice** for a swept claim: the TTL sweep releases it, and then removing
  the finalizer deletes the object, which fires the delete handler and releases it again. The
  namespace's `count` reached zero while claims still held addresses, so the block was free to
  be issued to another namespace. `handle_claim_delete` now skips the release for a claim
  already in phase `Deleting`.

The symptom pointed at the wrong component — the duplicate surfaced as a *pgadmin* apply
failure, and the ledger's drifting `count` looked like a counting bug on its own. Evidence is
`docs/evidence/race-test.sh`: three clean-slate deploys, each asserting three distinct IPs. A single
green run cannot tell a fixed race from a lucky one.

**A check that was never executed is not a check that passes.** J11 had two defects no earlier
run could reveal, because no run had ever reached it:

- Its SigV4 list signed the prefix as `ns/`. A canonical query string uses S3's encoding, where
  `/` is `%2F`, so MinIO answered **403 SignatureDoesNotMatch**. `deploy/minio.sh` needs no such
  care — its PUT has no query string at all — which is what made copying its signing block look
  safe.
- Every J11 assertion is negative (a `fail` with no matching `pass`), so a *passing* J11 printed
  nothing: the suite exited 0 having reported ten checks, and the checkpoint's `^J11 PASS` gate
  could never be satisfied. The suite's first green run said `10 PASS, 0 FAIL` and the gate
  failed on a check that had in fact passed.

Both were caught only because the checkpoint asserts the PASS line and not just the exit code.
The exit code alone called it fine.

**A guard that prevents a second release hands the first one to a path you must then walk.**
`handle_claim_delete` skips its release for a claim already in phase `Deleting` — correct, and
what fixed the duplicate address above. But that also made the `Deleting` paths the owners of the
release, and the resync **retry** branch (the sweep's destroy fails, a later tick succeeds)
inherited none: it destroyed, cleaned up and deleted the claim while the handler dutifully
skipped, so the block stayed in the ledger with the claim and its container both gone. One of the
ten blocks, lost silently and permanently, on the path the retention window makes routine — the
runner being down at expiry, which is exactly what J10 rehearses. Both paths now release, and
both release only once `remove_finalizer_and_delete` reports the claim is gone: the release and
the claim's removal have to move together, because releasing before the removal releases a second
time on the next tick. When a guard moves an obligation to one path, enumerate every other path
that can reach that state. Evidence: `docs/evidence/leak-probe2.sh` (the leak) and
`docs/evidence/leak-probe3.sh` (the fix, and the controller log that shows which path released).

**A probe can pass by testing nothing.** v1 of the leak probe restarted the runner as soon as the
phase went `Deleting`, so the sweep's in-flight destroy succeeded after all — the sweep released
the block itself and the guard skipped the handler, which is precisely the behaviour the probe was
supposed to be distinguishing itself from. It printed a clean ledger and proved nothing. v2 holds
the runner down past the expiry **and** through two failed retries, so the success can only come
from the retry branch. Before believing a green probe, read its log against the component log and
ask which code path produced the result.

**A cold start is a different program from a warm one.** The build plan's last Done item — "`make all`
and `make jit-verify` both green from a cold `make destroy`" — had never been run. Running it found four
things no warm run can show:

- **A cluster's containerd is not Docker's image store.** `make destroy` deletes the k3d cluster and
  takes its images with it; `jit-controller:latest` was in `docker images` and nowhere else, so
  `make jit-up` waited its full 180s to fail on ImagePullBackOff. The earlier stages had imported it by
  hand (S8), and a cold host has nobody to do that. `jit-up.sh` now imports it when the cluster lacks it.
- **The module containers live on the daemon, not in the cluster** — so they survive both the app and
  the cluster, still holding addresses the new stack's empty IPAM ledger is about to hand out again.
  `cd app && make destroy` is not a cold start on its own; `make jit-down` has to be part of it.
- **Two scripts can each be right and still deadlock.** `app/scripts/deploy.sh` creates the cluster and
  then refuses to apply the app until the InfraClaim CRD exists; `scripts/jit-up.sh` refuses to run
  without the cluster. The first `deploy` of a cold start is therefore a deliberate failure whose only
  product is the cluster.
- **A base with no namespace deploys to `default`,** whose Ingress claims `vote.localhost` — the host
  `voting-a` owns. `make jit-verify` then refuses to run ("one namespace per demo host"), which is the
  suite's own guard working. Settled by the review: tenants never run in `default`; `app/Makefile` now
  defaults `NS`/`KUSTOMIZE_DIR` to the `voting-a` overlay.
- **A retained data volume and a regenerated password cannot both be right.** The same run stopped at
  `init-db` failing with `FATAL: password authentication failed for user "postgres"`. `jit-down` (and
  `clean-slate`) remove module containers with `docker rm -f`, which is not a `tofu destroy`, so the
  `docker_volume` stays — while the controller writes a *new* password into `jit-postgres` for the new
  stack. Postgres ignores `POSTGRES_PASSWORD` on a data directory that already exists, so the container
  is up, the Secret is right, and the app can never authenticate. Either the volume goes with the
  container or the password must be persisted; nothing in the PoC decides that.

The run also caught a bug in that same day's `jit-down` fix: `remaining="$(kubectl get infraclaims …
| wc -l)"` under `set -euo pipefail`. In a fresh cluster there is no CRD, so kubectl fails, `pipefail`
makes the whole pipeline fail, and `set -e` kills the script — after which the module containers it was
supposed to sweep stayed behind. The cold path is where unguarded reads go to die.

---

## Carried forward — do not lose these

**A module output that does not exist cannot be defaulted away.** RESOLVED in S17: the
pgadmin module exports `port = 80`, so `jit-pgadmin` advertises 80 rather than redis's 6379,
and `create_jit_service` re-states the spec on 409 so an older Service does not keep the
stale port. J3 asserts it.

**pgAdmin publishes a fixed host port (`http_port`, default 5050).** RESOLVED in S17: the
claim's annotation carries `params.http_port`, and `app/kustomize/overlays/voting-b` sets it
to 5051 — the two-namespace demo runs both, and J8 checks the second one.

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
