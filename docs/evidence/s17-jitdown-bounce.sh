#!/usr/bin/env bash
# S17 review concern 1, exercised end to end: does `make jit-down` leave the IPAM ledger
# behind, and does the stack come back clean?
#
# Three claims in one run:
#   1. `jit-ipam` is absent after `jit-down` (before the fix it survived with stale counts,
#      so a namespace's block was never freed);
#   2. `make jit-up` is re-runnable on a stack that has just been taken down;
#   3. the ledger is rebuilt from nothing once a tenant's claims are re-created.
#
# The tenant comes back by *touching* the annotated Deployment. That is not obvious and
# was found by running this: kopf does not replay create for Deployments that already
# existed, and re-applying an unchanged overlay is a no-op, so nothing else re-triggers
# claim creation after a bounce.
set -uo pipefail
cd /Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra
NS=voting-a
ledger() { kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}' 2>/dev/null || echo '<absent>'; }
claims() { kubectl get infraclaims -n "$NS" --no-headers 2>/dev/null | grep -c Ready || true; }
log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

log "ledger before: $(ledger)"
log "claims Ready before: $(claims)"

log "--- make jit-down"
make jit-down 2>&1 | tail -4
log "ledger after jit-down (must be <absent>): $(ledger)"
log "claims cluster-wide right after jit-down: $(kubectl get infraclaims -A --no-headers 2>/dev/null | wc -l | tr -d ' ') - jit-down deletes them with --wait=false, so these may still be terminating"
for _ in $(seq 1 24); do
  [[ "$(kubectl get infraclaims -A --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] && break
  sleep 5
done
log "claims cluster-wide once the deletes have settled (must be 0): $(kubectl get infraclaims -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"

log "--- make jit-up"
make jit-up 2>&1 | tail -3
log "ledger after jit-up with no claims yet (must be <absent>): $(ledger)"

# Nothing from the bounce may be left behind: a stale claim keeps its phase *Ready*
# with no container behind it, and Ready is what the controller checks before it
# provisions - so a leftover claim blocks the tenant's recovery silently. jit-down
# waits for the claims to go now; this loop is the assertion that it did.
for _ in $(seq 1 30); do
  [[ "$(kubectl get infraclaims -A --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] && break
  sleep 5
done
log "claims left over from the bounce (must be 0): $(kubectl get infraclaims -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"

log "--- touch the tenant Deployment: the only thing that re-creates the claims"
kubectl rollout restart deployment/voting-app-vote -n "$NS" >/dev/null
for _ in $(seq 1 60); do
  [[ "$(claims)" == "3" ]] && break
  sleep 5
done
log "claims: $(kubectl get infraclaims -n "$NS" --no-headers 2>/dev/null | tr -s ' ' | tr '\n' '|')"
log "ledger rebuilt: $(ledger)"
log "containers up: $(docker ps --format '{{.Names}}' | grep -c "^${NS}-") of 3"
for c in "${NS}-redis-redis" "${NS}-postgres-postgres" "${NS}-pgadmin-pgadmin"; do
  docker container inspect "$c" >/dev/null 2>&1 || log "MISSING container $c"
done

# Through a file, not a pipe: a pipeline into `tail` buffers, so a run cut short
# prints nothing at all and the evidence loses its verdict.
log "--- make verify (R1-R17 in $NS)"
(cd app && NS="$NS" ./scripts/verify.sh) > /tmp/s17-jitdown-verify.log 2>&1
tail -4 /tmp/s17-jitdown-verify.log
log done
