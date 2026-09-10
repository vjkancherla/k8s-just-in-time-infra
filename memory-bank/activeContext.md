Updated: 2026-09-10

## Current focus
S14 — blockers, concerns 1-10, IPAM per-claim addressing and the postgres module are done;
S13 + S14 checkpoints PASS. One NEW blocker surfaced (tfstate); decision needed.

## Done this session (on top of the earlier commits)
- IPAM: every claim in a namespace used to get the block base. `first_free_address` now gives
  each claim its own address, and `allocate_block` runs only for a NEW claim so the count
  tracks claims — it had reached 193 for one namespace and blocks were never freed.
- postgres module: `output "url"` is now `sensitive = true`; it failed every apply.
- Verified in one namespace: redis 172.19.0.100 + postgres 172.19.0.101 both Ready, two
  containers, `count: 2`. S13 `PASS: S13 IPAM verified`; S14 `PASS: S14 real provisioning
  verified` — 0 FAIL on both (logs /tmp/s13-run.log, /tmp/s14-post-ipam.log).

## NEW finding (raised, NOT fixed) — teardown does not remove containers
No module declares a `backend` block, so the runner's `-backend-config` args are ignored and
every tofu run uses local state in a throwaway temp dir. State dies with the dir, so a cold
`tofu destroy` finds nothing, returns `destroyed`, and the container leaks. Reproduced:
`{"status":"destroyed"}` while `s14-multi-postgres-postgres` stayed up; no state object
existed for either module key.
The `docker rm -f` safety cannot compensate — the runner image has no docker CLI and those
failures are swallowed by `except Exception: pass`. The S14 gate cannot see any of it: it
asserts on the claim and the Secret, never on the container.
Also: S13.sh's `kubectl set env` leaves the controller mutated (RUNNER_TOKEN empty,
WATCH_NAMESPACES=default) — re-apply deploy/controller.yaml before running S14.

## Next step
Decide on the tfstate finding (recommend: declare `backend "s3" {}` in the three modules —
it is exactly what the runner already passes and what systemPatterns documents), then have
the re-review run against the newest commit. Do not start S15.
