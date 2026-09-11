#!/usr/bin/env bash
# The build plan's last Done item, exercised: "`make all` and `make jit-verify` both green
# from a cold `make destroy`". S17 never ran it. It is not merely missing evidence - the
# cold start has an order problem, and this records it.
#
#   bash s17-cold-path.sh gaps   # destroy -> deploy -> jit-down -> jit-up, tolerating failures
#   bash s17-cold-path.sh full   # the cold recipe that works, ending green
#
# What a cold start runs into, in the order it hits it:
#   1. `app/scripts/deploy.sh` creates the cluster and *then* refuses to apply the app until
#      the InfraClaim CRD exists ("the JIT stack must be up first"), while `scripts/jit-up.sh`
#      refuses to start without the cluster. So the cluster is created by a `deploy` that
#      fails on purpose, and the app is applied by a later `make all`.
#   2. `cd app && make destroy` deletes the cluster - so the cluster's containerd goes with
#      it, and `jit-controller:latest` is no longer in it. `jit-up.sh` assumes S8 imported it.
#   3. The cluster is not the only state: the JIT module containers live on the *host*, and
#      `make destroy` does not touch them (the JIT stack's own `make jit-down` does). Left
#      behind, they hold the addresses the new, empty IPAM ledger is about to hand out again.
set -uo pipefail
cd /Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra

PHASE="${1:-full}"
log() { echo "[$(date -u '+%H:%M:%S')] $*"; }
run() {  # run <label> <logfile> <command string> - never aborts; the exit code is the finding
  log "--- $1"
  bash -c "$3" > "$2" 2>&1
  local rc=$?
  log "    exit $rc"
  tail -3 "$2" 2>/dev/null | sed 's/^/    | /'
  return 0
}
clusters() { k3d cluster list 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' '; }
jit_containers() { docker ps -a --format '{{.Names}}' | grep -cE -- '-(redis-redis|postgres-postgres|pgadmin-pgadmin)$' || true; }
state() {
  log "    clusters=[$(clusters)] jit-containers=$(jit_containers) claims=$(kubectl get infraclaims -A --no-headers 2>/dev/null | wc -l | tr -d ' ') ledger=$(kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}' 2>/dev/null || echo '<none>')"
}

log "phase=$PHASE"
# Delete the reports first: reading a summary is only evidence if the file came from this
# run, and a stale app/.workflow/verify.md is exactly what the first attempt tripped over.
rm -f app/.workflow/verify.md .workflow/verify-jit.md
state

run "1  cd app && make destroy"  /tmp/cold-1-destroy.log "cd app && make destroy"
state

run "2  cd app && make deploy   (creates the cluster; stops until the CRD exists)" \
                                 /tmp/cold-2-deploy.log  "cd app && make deploy"
state

if [[ "$PHASE" == "gaps" ]]; then
  run "3  make jit-down   (the JIT stack's own teardown, which is what removes the module containers)" \
                                 /tmp/cold-3-jitdown.log "make jit-down"
  state
  run "4  make jit-up"           /tmp/cold-4-jitup.log   "make jit-up"
  log "    controller: $(kubectl get pods -n default -l app=jit-controller --no-headers 2>/dev/null | tr -s ' ' | cut -d' ' -f1-3 | tr '\n' ' ')"
  state
  log "phase=gaps: stopping before the app and the suite"
else
  # The order below is the cold recipe this run establishes. Two steps look wrong and are
  # not: `make deploy` in phase=gaps exists only to create the cluster (it stops by design
  # before applying anything, because the CRD it wants comes from `make jit-up`); and
  # `make all` targets the voting-a overlay, not the base. The base has no namespace, so a
  # bare `make all` lands the app in `default` with an Ingress claiming vote.localhost -
  # and the suite's PREREQ then refuses to run, correctly, because one namespace per demo
  # host. The first run of this script is kept as s17-cold-path-order.log for exactly that.
  run "3  make jit-down   (the module containers outlive the cluster; this removes them)" \
                                 /tmp/cold-3a-jitdown.log "make jit-down"
  state
  run "4  make jit-up"           /tmp/cold-4-jitup.log   "make jit-up"
  log "    controller: $(kubectl get pods -n default -l app=jit-controller --no-headers 2>/dev/null | tr -s ' ' | cut -d' ' -f1-3 | tr '\n' ' ')"
  run "5  kubectl create ns voting-a   (the overlay sets a namespace; it does not create one)" \
                                 /tmp/cold-5a-ns.log     "kubectl create ns voting-a"
  run "6  cd app && make all   (bare: the Makefile now defaults to the voting-a overlay)" \
                                 /tmp/cold-5-all.log     "cd app && make all"
  log "    verify: $(grep -E '^===== [0-9]+ PASS, [0-9]+ FAIL =====$' app/.workflow/verify.md 2>/dev/null | tail -1)"
  run "7  make jit-verify"       /tmp/cold-6-jitverify.log "make jit-verify"
  log "    suite: $(grep -E '^===== [0-9]+ PASS, [0-9]+ FAIL =====$' .workflow/verify-jit.md 2>/dev/null | tail -1)"
  state
fi
log done
