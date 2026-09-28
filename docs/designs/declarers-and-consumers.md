# Declarers and consumers - shared infra params (S22)
Date: 2026-09-28
Extends: [jit-infra-poc.md](./jit-infra-poc.md) (v4) - answers its open question on annotation edits
Amends: [annotation-to-state.md](./annotation-to-state.md) (params become declarer-only),
        [jit-infra-flows.md](./jit-infra-flows.md) (update sequence, state-machine note)
Lineage: [README.md](./README.md) - where this document sits in the design record
Unchanged: claim naming, ownership, soft/hard cleanup, ADR 0001

## Decision

Each shared claim gets at most one set of params, written by the Deployments that **declare** it; every other Deployment only **consumes** it. An annotation with a `params` key declares; an annotation without one consumes. A settings change is one edit to the declaring annotation, and the controller converges it through a per-module mutability contract that refuses anything not declared safe.

**Load-bearing choice:** the lease (who keeps the infra alive) and the definition (what the infra is) are separate roles. Every referencing Deployment holds the lease; only declarers shape the infra.

**Rejected alternative: every referencing Deployment is an equal writer**, reconciled by unanimity or first-writer-wins. With six Deployments on one Postgres, a change is a six-file edit, a rollout passes through a conflict window, and whichever Deployment happened to be applied first decides for everyone. It would win only if consumers genuinely need different settings from one shared instance, which one container cannot give them anyway.

Scope: build step S22. v1 mutable surface is redis `maxmemory`, postgres `databases` (additive) and an allowlist of postgres server settings. Everything else is refused with a named condition.

## From the original design

This note extends jit-infra-poc.md (v4); it keeps the claim, its ownership and both cleanup speeds, and changes only who may write params and what happens when they change.

&#91;embedded content: original design vs declarers and consumers\]

Solid arrows define the infra; dashed arrows only keep it alive.

|  | Original (v4) | Declarers and consumers (S22) |
| --- | --- | --- |
| Who writes params | Every Deployment that names the module | Only declarers (annotation has `params`) |
| Other Deployments | Also writers, each with a copy | Consumers: hold the lease, no params |
| Edit on a live Deployment | Silently ignored | Applied if allowed, refused with a reason if not |
| Differing params | First writer wins, warning condition | `ParamsConflict` among declarers only; consumers never conflict |
| Rollouts with no param change | Free | Still free |
| Claim name, Namespace ownership, soft and hard cleanup, readiness gate | Defined in v4 | Unchanged |
| Open question "re-apply or refuse?" | Open | Answered: re-apply what the module allows, refuse the rest |

## Problem

Today a settings change on live infra does nothing, and the design as written cannot make it do something without breaking the shared-claim model.

- **One claim, many writers.** The claim is `{namespace}-{module}`, so every Deployment annotating `jit.infra/postgres` in `voting-a` shares `voting-a-postgres`. Each one carries its own copy of the params. Changing a setting means editing every copy, and first-writer-wins (`check_param_conflict`) means the first Deployment applied silently decides for the rest.
- **The no-op is deliberate.** `jit-infra-poc.md` calls the create-409 no-op plus the idempotent `tofu apply` "two guards, which is right for something that creates databases". Removing them without a replacement guard turns every rollout into a potential container replace.
- **The runner hides changes too.** `POST /v1/runs` returns its cached success for a workspace regardless of the params sent, so even a re-POST with new params changes nothing.
- **Postgres settings are mostly init-time.** `POSTGRES_DB` and `POSTGRES_PASSWORD` are container env, read only when the data directory is empty. Changing them replaces the container, the volume keeps the old data directory, and the new value is ignored while the Secret reports it.
- **Redis is a queue.** `maxmemory` sits in the container `command`, so changing it replaces the container and drops unprocessed votes. The PoC's own open question says this: "Re-apply will recreate Redis and drop the queue."

The tenant-visible result is the worst kind: the annotation says one thing, the infra runs another, and nothing reports the difference.

## Terms and annotation schema

The annotation key and claim naming do not change; the only new rule is that the presence of a `params` key decides the role.

| Term | Meaning |
| --- | --- |
| Reference | Any live Deployment in the namespace whose annotations include `jit.infra/<module>`. Recomputed every resync, as today. |
| Lease | What every reference holds: the claim stays `Ready` while at least one reference exists. |
| Declarer | A reference whose annotation has a `params` key, including `params: {}` ("module defaults"). |
| Consumer | A reference whose annotation has no `params` key. It holds the lease and has no opinion on settings. |
| Desired params | Resolved from the declarers (next section) and projected onto `spec.params`. |
| Applied params | What the runner last applied successfully, recorded in `status.appliedParams`. |

```yaml
# worker: owns the database definition
jit.infra/postgres: '{"module":"postgres","moduleVersion":"v1","softDeleteTTL":"10m",
  "params":{"databases":["voting"],"settings":{"max_connections":"200"}}}'

# result, and every other Deployment that uses the database
jit.infra/postgres: '{"module":"postgres","softDeleteTTL":"10m"}'
```

- `params: {}` and a missing `params` are different on purpose. Empty means "I declare the defaults"; missing means "no opinion".
- Existing annotations all carry `params`, so today every reference is a declarer. They keep working unchanged as agreeing declarers.
- No explicit `role` field. The `params` key is the role, which keeps the annotation to one extra rule rather than a new vocabulary.
- `softDeleteTTL` may appear on any reference, declarer or consumer, because it is lifecycle data, not a setting.

## Resolution rules

Desired params come only from declarers, and they change only when every declarer agrees; consumers never cause or block a change.

&#91;embedded content: desired-params resolution · 3 outcomes\]

The controller evaluates this on every Deployment event and every 30s resync, from live Deployments only, so the answer survives a controller restart.

1. **Normalize first.** Declarer params go through the same `_normalize_params` the conflict check already uses, so resync and conflict check never disagree about "equal".
2. **Agreeing declarers set desired params.** Their normalized params are projected onto `spec.params`. A losing Deployment's event never writes spec.
3. **Disagreeing declarers change nothing.** `ParamsConflict=True` lists each declarer with its params. On an existing claim, desired stays equal to applied. On a new claim, first-writer-wins stays as today, so create behaviour is unchanged.
4. **No declarers change nothing.** A claim created by a consumer waits in `Pending` with `AwaitingDeclarer`; its pods stay blocked on the missing Secret, which is the existing readiness gate. An existing claim whose declarer is deleted keeps its applied params and sets `NoDeclarer`, an informational condition. No consumer is ever promoted to declarer.
5. **A consumer that adds `params` becomes a declarer.** If it agrees, nothing happens; if it disagrees, rule 3 applies.
6. **A new declarer after a gap is an update, not a conflict.** If the old declarer is gone and a new one appears with different params, those params are desired and go through the contract.
7. **`softDeleteTTL` is the maximum** declared across all references, declarers and consumers alike. TTL only matters once no references remain, and a longer window errs in the safe direction. It is a spec patch with no runner call.

A Deployment scaled to zero still exists, so it still counts as a reference and, if it declares, still has to agree.

## Mutability contract

The guard that replaces "do nothing on re-apply" is a per-module table of which params may change and how. Anything not in the table is refused.

A param is mutable only if both hold:

1. **The change is tolerable:** it adds or tunes, never removes data, and never relies on an init-time setting.
2. **Existing outputs stay the same:** every Secret key that exists today keeps its value, so running pods, the Service and the EndpointSlice are untouched. New keys may be added.

| Module | Param | Kind | On change | Downtime |
| --- | --- | --- | --- | --- |
| redis | `maxmemory` | Server setting | Container replaced on the same IP; queue contents lost | Seconds (spike measures it) |
| postgres | `databases` (list) | Logical object | Additions create databases in place; removals refused | None |
| postgres | `settings.max_connections`, `settings.shared_buffers`, `settings.work_mem` | Server setting | Container replaced; managed volume survives (`remove_volumes=false`) | Seconds |
| postgres | `postgres_db` (legacy) | Identity | Refused; add to `databases` instead | n/a |
| postgres | `postgres_password` | Controller-owned | Refused | n/a |
| pgadmin | any | Not assessed | Refused in v1 | n/a |
| any | `name`, `ip`, `network` | Identity | Refused; an IP move breaks the EndpointSlice | n/a |
| any | a key the module does not declare | Unknown | Refused; tofu only warns on unknown `-var`s, so a typo would be recorded as applied | n/a |

Values are validated before any runner call: `maxmemory` must match `^[0-9]+(kb|mb|gb)$`, settings must parse as their Postgres types, database names must be valid identifiers. An invalid value applies green and then crash-loops, so the controller refuses it rather than discovering it later.

The table lives in the controller in v1, next to `_normalize_params`. When a fourth module appears it should move into each module directory, owned by the module author.

## Update flow

The update is level-triggered: every evaluation compares desired with applied, so a missed event, a second edit mid-apply and a controller restart all resolve the same way. No new phase is added; progress and failure are conditions on a `Ready` claim.

1. **Resolve.** On a Deployment event or resync tick, compute desired params (resolution rules) and compare with `status.appliedParams`. Equal: stop, which is what keeps rollouts free.
2. **Check the contract.** Any refused key sets `UpdateRefused` naming the key and reason, and nothing is applied, including the allowed keys in the same edit. A partial apply would leave the annotation half-true.
3. **Skip known failures.** If the desired params hash equals `status.attemptedParamsHash` and `UpdateFailed=True`, stop. A failed update is retried only when the desired params change.
4. **Lock and re-read.** Take `claim_lock`, re-read the claim, and re-resolve. The spec can move between steps 1 and 4, because `ensure_claim` runs outside the lock today.
5. **Apply.** Set `Updating=True` and `attemptedParamsHash`, then `POST /v1/runs` with the tenant params plus the controller overlay (`name`, `ip`, `network`, resolved credentials).
6. **On success,** write `appliedParams` (tenant params only), add any new Secret keys, clear `Updating` and `UpdateFailed`. If an existing output changed, set `OutputsChanged`: that is a contract bug, not a tenant error.
7. **On failure,** keep phase `Ready` and the old Secret, set `UpdateFailed` with the runner message, clear `Updating`. Never `Deleting`, never touch the finalizer.

One apply per handler. An edit that lands during an apply is picked up by the next evaluation.

### State fields

The CRD status is a closed list, so each field needs a schema entry or the API server prunes it.

| Field | Holds | Written when |
| --- | --- | --- |
| `spec.params` | Desired params, projected from declarers | Resolution changes |
| `status.appliedParams` | Tenant params last applied; never credentials, because claim status is readable by anyone who can `get infraclaims` | Every successful apply, including the first create |
| `status.attemptedParamsHash` | Hash of the params last sent to the runner | Before each POST |
| `status.declaredBy` | Names of the declaring Deployments, recomputed each resync like `referencedBy` | Every resync |

**Backfill on upgrade:** a `Ready` claim with no `appliedParams` adopts its normalized `spec.params` without calling the runner. Without this, the first resync after the controller upgrade would replace every Redis.

### Conditions

| Condition | Set when | Cleared when |
| --- | --- | --- |
| `ParamsConflict` | Declarers disagree | Declarers agree, or only one remains |
| `AwaitingDeclarer` | A new claim has only consumers | A declarer appears |
| `NoDeclarer` | An existing claim's declarers are all gone | A declarer appears |
| `UpdateRefused` | Desired params include a refused key or invalid value | Desired params pass the contract |
| `Updating` | Just before the runner call | Apply returns, or found stale (below) |
| `UpdateFailed` | Runner error | Next successful apply |
| `OutputsChanged` | An existing Secret key would change value | Next apply with unchanged outputs |

### Crash recovery and the runner

- **Stale `Updating`.** The controller runs one replica. If `Updating=True` and this process does not hold that claim's lock, the flag is left over from a crash: clear it and re-evaluate.
- **Runner cache.** Key the success cache on a hash of module, workspace and params. Ship this first; without it every update is a silent no-op recorded as applied.
- **Handler blocking.** `call_runner` can block for up to 600s. If it is a synchronous call inside an `async` kopf handler, it blocks the event loop and the 30s resync stops with it. Run it with `asyncio.to_thread` (the step 0 spike confirms which case applies).

## Postgres module changes

Databases become tofu resources managed against the running server, so adding one is a real in-place change instead of an ignored environment variable.

- **Provider.** Add `cyrilgdn/postgresql` beside `kreuzwerker/docker`. The runner sits at `.10` on the same Docker network as Postgres at `.101`, and the controller already sends `postgres_password`, so the provider can connect.
- **Provider config from inputs.** Configure host and password from `var.ip` and `var.postgres_password`, never from container attributes, so the provider has known values on the first apply.
- **Wait for the server.** Give the container a health check (`pg_isready`) and `wait = true`, so tofu creates databases only after Postgres accepts connections.
- **Databases.** `postgresql_database` with `for_each` over `var.databases`. The initial database from `POSTGRES_DB` already exists after init, so a plain create would fail; an import block brings it into state instead (for\_each on imports needs OpenTofu 1.7+, to confirm in the runner image).
- **Settings.** Pass allowlisted settings as `-c key=value` in the container `command`. A change replaces the container; the managed `docker_volume.postgres_data` stays because a replace does not destroy it.
- **Secret keys.** Each database adds `service_url_<db>` to `jit-postgres`. Existing keys, including `service_url` for the initial database, never change, so running pods are untouched. A Deployment that needs a new database adds an env reference, which rolls that Deployment anyway.

### Destroy-path caveats

The new resources must not break the soft-delete and namespace-delete paths, which today end in one `tofu destroy`.

- **No `prevent_destroy`.** It would block the legitimate destroy on TTL expiry or namespace deletion, holding the finalizer and leaving the namespace in `Terminating`. Additive-only is enforced by the contract instead.
- **Drop the logical resources from state before destroy.** `DROP DATABASE` fails while connections are open, and a refresh fails outright if the container is already gone. The runner runs `tofu state rm` on `postgresql_*` resources before `tofu destroy`; the volume deletion removes the data anyway.
- **pgadmin is unaffected in v1.** It reads `postgres_url` from the Secret, which does not change. Registering new databases in pgadmin is an open question.

## Tenant experience and migration

A tenant changes a shared database by editing one annotation and reading one condition set.

```bash
# 1. Edit the declarer (here: worker) and apply
kubectl annotate deploy voting-app-worker -n voting-a --overwrite \
  jit.infra/postgres='{"module":"postgres","params":{"databases":["voting","analytics"]}}'

# 2. Watch it converge
kubectl get infraclaim voting-a-postgres -n voting-a \
  -o jsonpath='{.status.appliedParams}{"\n"}{.status.conditions}'

# 3. Who declares this claim?
kubectl get infraclaim voting-a-postgres -n voting-a -o jsonpath='{.status.declaredBy}'
```

The consumers need no edit. A consumer that wants the new database adds `service_url_analytics` from `jit-postgres` to its env, which rolls it as any env change does.

**What tenants must know**, in the module docs and the console:

- Which Deployment declares each module, and that the others should carry no `params`.
- That a Redis `maxmemory` change replaces the container and drops queued items; a Postgres setting change restarts the server with data intact.
- That removing a database, renaming `postgres_db` or changing the password is refused, and why.

### Migrating the voting app

| Module | Declarer | Consumers (drop `params`) |
| --- | --- | --- |
| redis | `voting-app-vote` | `voting-app-worker` |
| postgres | `voting-app-worker` (writes the votes table) | `voting-app-result` |
| pgadmin | `voting-app-vote` | none |

Migration needs no ordering. Before it, all annotations are agreeing declarers; after it, one declarer and consumers. Both resolve to the same desired params, so no apply runs. Check the actual manifests first: `annotation-to-state.md` disagrees with itself on whether `worker` annotates redis.

## Verification (S22)

Each check is an assertion in `scripts/checks/S22.sh`. "One tick" means one 30s resync plus one runner call.

| # | Setup | Assert |
| --- | --- | --- |
| U1 | Edit the redis declarer to `maxmemory: 128mb` | Within one tick: container command has `--maxmemory 128mb`, `appliedParams` matches, IP and existing Secret bytes unchanged |
| U2 | Add `analytics` to the postgres declarer's `databases` | Database exists (`psql -l`), container ID unchanged, `service_url_analytics` added, existing keys unchanged |
| U3 | Change a consumer's other annotations (no `params`) | No runner call, container ID unchanged |
| U4 | Give a consumer different `params` | `ParamsConflict=True` naming both declarers; container ID unchanged |
| U5 | Delete the declarer, keep consumers | Claim stays `Ready`, `NoDeclarer=True`, `appliedParams` unchanged, no runner call |
| U6 | New namespace, consumer applied first | Claim `Pending` with `AwaitingDeclarer`; after the declarer is applied, `Ready` |
| U7 | Remove a database, or change `postgres_db` | `UpdateRefused` naming the key; nothing applied |
| U8 | Set `maxmemory: banana` | `UpdateRefused` for an invalid value; no runner call |
| U9 | Stop the runner, then change a param | Phase `Ready`, `UpdateFailed=True`; after two more ticks still one attempt; restart runner and edit again: converges |
| U10 | Kill the controller during an apply, restart | `Updating` cleared within one tick; the claim re-evaluates |
| U11 | Upgrade the controller with `Ready` claims present | No container IDs change; `appliedParams` backfilled |
| U12 | Namespace delete after U2 | Destroy succeeds; finalizer released; namespace gone |
| U13 | Two consumers set different `softDeleteTTL` | `spec.softDeleteTTL` is the larger; no runner call |

U9 injects failure at the runner's HTTP boundary, not through a bad param, because tofu applies bad values green. U12 exists because the Postgres provider is new on the destroy path.

## Roads not taken

| Alternative | Why not | Would win if |
| --- | --- | --- |
| Every reference an equal writer (unanimity or first-writer-wins) | N-file edits, a conflict window on every rollout, an accidental owner | Consumers needed different settings, which one container cannot serve |
| Shared ConfigMap via `paramsFrom` | A new watch and a new object; the lease and the definition split across two kinds | Params grow large, or no Deployment is a natural owner |
| Kustomize component stamping one annotation on all | Hides the duplication; the conflict window remains | Never needed controller changes, as a stopgap only |
| Drift-only (immutable claims) | Leaves the tenant no working change path: re-adding inside the TTL resurrects old params, waiting it out destroys the volume | The spike shows even the allowed replaces are unacceptable; then this design with an empty allowlist |
| Console-owned settings | A second write surface for state that ADR 0001 keeps derived | Tenants stop authoring manifests |
| Automatic promotion of a consumer when the declarer goes | A Deployment deletion would silently re-apply someone else's params | Never |
| `tofu plan`-gated updates | A runner plan endpoint for a three-module demo | A fourth module arrives and the hand-kept table starts to rot |
| `prevent_destroy` on databases | Blocks the legitimate TTL and namespace destroy | Never, on this destroy path |

## Open questions

- [ ] Consumer requirements: should a consumer be able to state what it needs (`"requires":{"databases":["analytics"]}`) so a missing database is a condition, not a pod crash?
- [ ] Roles and grants per consuming app: in scope once databases work, or wait for real credential management?
- [ ] Provider download: does the runner fetch `cyrilgdn/postgresql` from the registry at `tofu init`, or does it need a mirror or a baked image?
- [ ] Secret key naming for extra databases: `service_url_<db>` or a Secret per database?
- [ ] pgadmin: register new databases automatically, or leave it to the user?
- [ ] Several declarers that agree: allow indefinitely, or warn that one should become a consumer?

## Build order and effort

1. **Spike, half a day.** Confirm whether `call_runner` blocks the kopf event loop; time a redis and a postgres container replace; count votes lost; check that `vote` and `worker` reconnect. The result decides whether redis `maxmemory` stays mutable.
2. **Runner, half a day.** Success cache keyed on params; `tofu state rm` of `postgresql_*` before destroy.
3. **CRD, a quarter day.** `appliedParams`, `attemptedParamsHash`, `declaredBy`.
4. **Controller, 2 days.** Declarer resolution, contract and validation, the update flow, conditions, backfill, stale-`Updating` recovery.
5. **Postgres module, 1 day.** Provider, health check, `databases`, settings flags, the import of the initial database, new Secret keys.
6. **Docs, in the same step.** `jit-infra-flows.md` gets the update sequence and a state-machine note; also fix its `Failed → Pending: retry with backoff` line, which the code does not do. Answer the open question in `jit-infra-poc.md` and fix its tenant-surface examples, which put `maxmemory` outside `params`.
7. **S22 check, 1 day.** U1 to U13.

About 5 to 6 days after the spike (an estimate, not a measurement).
