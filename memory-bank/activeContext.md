Updated: 2026-09-10

## Current focus
S14 is complete: blockers, concerns 1-10, IPAM, postgres and the tfstate/leak defect are all
fixed; S13 + S14 checkpoints PASS on the final code. Standing at the review gate.

## Done (verified this pass)
- IPAM per-claim addressing + the claim-count fix (a count had reached 193, so namespace
  blocks were never freed). 8 new unit tests; 27 total.
- postgres `output "url"` → `sensitive = true`; it failed every apply before.
- All three modules declare `backend "s3" {}`. Without it the runner's `-backend-config` args
  were ignored, tofu used local state in a throwaway temp dir, and a cold destroy reported
  `destroyed` while leaving the container running. Proven now: a fresh work dir lists
  `docker_container.redis` from MinIO, and a cold destroy takes the container 1 → 0.
- `scripts/checks/S14.sh` Step 4 restarts the runner (so the sweep's destroy is cold) and
  asserts the container is gone — the gate previously checked only the claim and the Secret.
- Live: redis 172.19.0.100 + postgres 172.19.0.101 both Ready in one namespace, two containers.

## Checkpoints (final code)
- `PASS: S13 IPAM verified` (0 FAIL) — /tmp/s13-b.log
- `PASS: S14 real provisioning verified` (0 FAIL) — /tmp/s14-backend.log

## Commits
9184a7b step · 2e74e04 blockers · b9945bd concerns 1-10 · 08d2911 prompt · 020f899 IPAM +
postgres · b2e7c57 memory bank · plus the backend + gate commit.

## Next step
A different model re-reviews against the newest commit (the prompt's range is updated). Do not
start S15.

## Watch out
- S13.sh's `kubectl set env` leaves the controller mutated (empty RUNNER_TOKEN, wrong
  WATCH_NAMESPACES) — re-apply deploy/controller.yaml before running S14.
