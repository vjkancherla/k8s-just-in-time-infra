#!/usr/bin/env bash
# Probe: do two namespaces created back-to-back get two *distinct* IP blocks?
#
# namespace_lock serialises allocation within one namespace. It is keyed per namespace, so
# it cannot serialise the read-modify-write of the single jit-ipam ConfigMap between two
# different namespaces - and the release paths take no lock at all. The README's first-run
# instructions apply overlays/voting-a and overlays/voting-b back to back, which is exactly
# the interleaving this looks for: both read the ledger before either writes it.
set -uo pipefail
cd /Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra
A=voting-a
B=voting-b
L=/tmp/block-race.log
: > "$L"
log() { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$L"; }

render() {
  kubectl kustomize "app/kustomize/overlays/$1" \
    | sed 's/"softDeleteTTL":"10m"/"softDeleteTTL":"2m"/g'
}

for i in 1 2; do
  bash /tmp/clean-slate.sh >/dev/null 2>&1
  kubectl patch cm jit-ipam -n default --type=merge -p '{"data":{"allocations":"{}"}}' >/dev/null 2>&1
  kubectl create ns "$A" >/dev/null 2>&1
  kubectl create ns "$B" >/dev/null 2>&1
  # Back to back, no wait between them: this is the whole point of the probe.
  render "$A" | kubectl apply -f - >/dev/null 2>&1
  render "$B" | kubectl apply -f - >/dev/null 2>&1

  for _ in $(seq 1 60); do
    n="$(kubectl get infraclaims -A -o jsonpath='{range .items[*]}{.status.allocatedIP}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
    [[ "$n" == "6" ]] && break
    sleep 3
  done
  sleep 5

  ledger="$(kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}')"
  ips="$(kubectl get infraclaims -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.allocatedIP} {end}')"
  phased="$(kubectl get infraclaims -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.status.phase} {end}')"
  withip="$(kubectl get infraclaims -A -o jsonpath='{range .items[*]}{.status.allocatedIP}{"\n"}{end}' | grep -c . || true)"
  uniq="$(kubectl get infraclaims -A -o jsonpath='{range .items[*]}{.status.allocatedIP}{"\n"}{end}' | sort -u | grep -c . || true)"
  log "iteration $i withip=$withip distinct=$uniq"
  log "    ledger=$ledger"
  log "    ips=[$ips]"
  log "    phases=[$phased]"
done

bash /tmp/clean-slate.sh >/dev/null 2>&1
log done
