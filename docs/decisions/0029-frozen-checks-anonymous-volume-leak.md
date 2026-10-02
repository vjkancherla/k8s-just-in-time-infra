# 0029. The frozen checkpoints leak anonymous Docker volumes; `docker rm -f` needs `-v`

Date: 2026-10-02
Status: accepted (2026-10-02)

## Context

`dpage/pgadmin4:8.12` declares `VOLUME /var/lib/pgadmin` and `redis:7-alpine` declares
`VOLUME /data`. Neither `jit-modules/modules/redis/main.tf` nor
`jit-modules/modules/pgadmin/main.tf` overrides those paths, so Docker creates an
**anonymous** volume for each container. Terraform never records it — no module declares a
`docker_volume` for it — so nothing in the destroy path can remove it. `postgres` is immune:
`jit-modules/modules/postgres/main.tf` declares `docker_volume.postgres_data` explicitly.

`docker rm -f` removes the container and leaves the anonymous volume behind as dangling.
`docker volume prune` reports it as reclaimable, so the volumes accumulate silently until
someone goes looking. A survey of one workstation found **238 dangling volumes, 3.55 GB**,
dated from 2025-08 to the present, with **74 created on 2026-09-09 alone** — a single day of
checkpoint runs, not the demo.

The product paths (`jit-runner/main.py`, `scripts/jit-down.sh`, `scripts/verify-jit.sh`) were
fixed in the same session and carry their own comments. The remaining source is the frozen
checkpoints, which `AGENTS.md` and `.opencode/rules/s22-declarers.md` bar from editing except
through an approved ADR:

- `scripts/checks/S01.sh:26,33`
- `scripts/checks/S07.sh:28`
- `scripts/checks/S14.sh:19,65,72,283`
- `scripts/checks/S15.sh:64`
- `scripts/checks/S24.sh:107`
- `scripts/checks/S27.sh:81`

These are the largest single source: every gate run provisions redis, postgres and pgAdmin
probe containers and reaps them with a bare `docker rm -f`.

## Decision

Amend the ten sites above to `docker rm -f -v`, sanctioned by this ADR.

`-v` removes **anonymous** volumes only. `S15.sh:64` and `S24.sh:107` remove **postgres**
containers, but `jit-modules/modules/postgres/main.tf:40-41` gives postgres a *named* volume
(`docker_volume.postgres_data`, `name = "${var.name}-postgres-data"`) mounted by `volume_name`,
and `-v` does not touch named volumes at all. Those volumes disappear the way they always
have — `tofu destroy` acting on the `docker_volume` resource — which is exactly what the two
relevant assertions already test today: `S24.sh:120` and `S27.sh:87` both require
`<ns>-postgres-postgres-data` to be **absent** after destroy, and both pass without a
`docker volume rm` anywhere in those scripts. Nothing here changes who removes that volume.

No assertion changes. Every `ok`/`fail` line, every measured value and every assertion in the
six checkpoints is untouched; only the cleanup verb changes.

## Consequences

- Checkpoint runs stop accumulating one anonymous volume per probe container per run.
- Two of the six amended checkpoints have captured evidence: `docs/evidence/S24.log` and
  `docs/evidence/S27.log`, both ending in PASS. They were produced **before** this amendment
  and no longer match the files that produced them, so treat those two as predating the edit
  — the same caveat ADR 0028 records for S18. The other four (`S01`, `S07`, `S14`, `S15`) were
  never captured, so there is nothing to go stale. Re-capture is deliberately deferred rather
  than done here: `S14` already fails for a reason unrelated to volumes, so re-running it would
  overwrite the record with a FAIL that says nothing about this change. No log's PASS/FAIL
  outcome is actually in doubt either way — `-v` changes only the cleanup verb, and not one
  assertion in any of the six observes a volume.
- This does not reclaim the existing backlog. The 238 volumes found on the workstation
  predate every one of these edits and need a separate, deliberate prune — a machine-wide
  `docker volume prune` would also destroy stopped-but-unreferenced volumes belonging to
  other projects, including ones explicitly labelled `backup:required`.
- A container that is killed rather than removed (`docker kill`, a daemon restart, an OOM) is
  still reaped with `-v` on the next pass, so the fix is not limited to the orderly path. It
  does mean an anonymous volume is now destroyed wherever these scripts run, which is the
  intent: for a just-in-time stack the redis queue and the pgAdmin config DB are disposable,
  and Postgres — the only state that is not — is the one module with a managed volume.
