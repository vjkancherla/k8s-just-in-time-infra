# 0029. The frozen checkpoints leak anonymous Docker volumes; `docker rm -f` needs `-v`

Date: 2026-10-02
Status: proposed

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

`-v` removes **anonymous** volumes only. Named volumes are untouched, so the cold-path rule
that the captured evidence depends on — the postgres volume must go with its container, and
must *not* be reattached by a later stack — is unaffected. `S15.sh:64` and `S24.sh:107` remove
postgres containers; the named `<ns>-postgres-postgres-data` volumes they create are still
cleared by the explicit `docker volume rm` calls already present in those scripts.

No assertion changes. Every `ok`/`fail` line, every measured value and every assertion in the
seven checkpoints is untouched; only the cleanup verb changes.

## Consequences

- Checkpoint runs stop accumulating one anonymous volume per probe container per run.
- The captured evidence in `docs/evidence/` was produced **before** this amendment and no
  longer reflects the files that produced it. Each amended checkpoint's log should be
  re-captured on its next run (`make gate STEP=NN`) so the evidence stays truthful; until
  then, treat those seven logs as predating the edit, the same caveat ADR 0028 records for
  S18.
- This does not reclaim the existing backlog. The 238 volumes found on the workstation
  predate every one of these edits and need a separate, deliberate prune — a machine-wide
  `docker volume prune` would also destroy stopped-but-unreferenced volumes belonging to
  other projects, including ones explicitly labelled `backup:required`.
- A container that is killed rather than removed (`docker kill`, a daemon restart, an OOM) is
  still reaped with `-v` on the next pass, so the fix is not limited to the orderly path. It
  does mean an anonymous volume is now destroyed wherever these scripts run, which is the
  intent: for a just-in-time stack the redis queue and the pgAdmin config DB are disposable,
  and Postgres — the only state that is not — is the one module with a managed volume.
