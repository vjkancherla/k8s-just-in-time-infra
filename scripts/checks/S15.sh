#!/usr/bin/env bash
set -euo pipefail

# S15 checkpoint - the voting app runs on JIT infra.
#
# Turned into assertions from docs/build-plan.md S15, "Checkpoint" (FROZEN - see
# build-plan.md S-1: if this is wrong, raise it as a design question, do not
# adjust it to match the code):
#
#   1. `kubectl apply` into an empty namespace -> three containers appear, app
#      reaches Ready
#   2. vote -> result works end to end
#   3. `kubectl kustomize app/kustomize` and the registry overlay both build
#   4. no PVC and no StatefulSet exist in the namespace
#
# Two more come from the same step's "Do" list, because assertion 4 alone would
# not notice the migration happening while the credentials stayed behind:
#   - an overlay per environment parameterises the namespace
#   - the credentials arrive from the controller-written jit-postgres Secret, and
#     postgres-secret.env is gone
#
# OBSERVED 2026-10-09, before S15 was implemented - assertion 1's registry clause
# cannot pass with the current layout, and this is NOT asserted away:
#
#   $ kubectl kustomize app/kustomize/overlays/registry
#   error: accumulating resources: ... 'app/kustomize' must resolve to a file:
#   cycle detected: candidate root '.../app/kustomize' contains visited root
#   '.../app/kustomize/overlays/registry'
#
# `resources: - ../..` puts the overlay inside the base's own tree, which
# kustomize rejects. R12 in app/scripts/verify.sh does not build the overlay -
# it builds the base and seds the registry hostname in - so the overlay's
# brokenness is currently invisible to `make verify`. Raised as a design
# question rather than adjusted here (build-plan S-1: frozen, and a checkpoint
# that turns out to be wrong is a design question, not an edit).

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

NS="s15-test"
CTRL_NS="default"
CONTROLLER="deployment/jit-controller"
CLUSTER="${CLUSTER:-voting-app}"
BASE_DIR="app/kustomize"
REGISTRY_OVERLAY="app/kustomize/overlays/registry"

# Container names the modules produce for `name = "<ns>-<module>"`:
#   redis/main.tf:23   "${var.name}-redis"
#   postgres/main.tf:29 "${var.name}-postgres"
#   pgadmin/main.tf:45 "${var.name}-pgadmin"
REDIS_CONTAINER="${NS}-redis-redis"
POSTGRES_CONTAINER="${NS}-postgres-postgres"
PGADMIN_CONTAINER="${NS}-pgadmin-pgadmin"

BUILD_OUT=""
BUILD_ERR=""
OVERLAY_OUT=""

cleanup() {
  kubectl delete job s15-e2e -n "$NS" --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete -n "$NS" -f "$BUILD_OUT" --ignore-not-found --wait=false 2>/dev/null || true
  docker rm -f "$REDIS_CONTAINER" "$POSTGRES_CONTAINER" "$PGADMIN_CONTAINER" 2>/dev/null || true
  # Finalizers first, or namespace deletion hangs on live claims.
  for ic in $(kubectl get infraclaims -n "$NS" -o name 2>/dev/null || true); do
    kubectl patch "$ic" -n "$NS" --type=json \
      -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' 2>/dev/null || true
  done
  kubectl delete infraclaims -n "$NS" --all --ignore-not-found 2>/dev/null || true
  kubectl delete ns "$NS" --ignore-not-found --timeout=30s 2>/dev/null || true
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    kubectl get ns "$NS" -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
      | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - 2>/dev/null || true
  fi
  # Return the controller to its normal watch set.
  kubectl set env "$CONTROLLER" -n "$CTRL_NS" WATCH_NAMESPACES=default 2>/dev/null || true
  kubectl rollout status "$CONTROLLER" -n "$CTRL_NS" --timeout=120s 2>/dev/null || true
  rm -f "$BUILD_OUT" "$BUILD_ERR" "$OVERLAY_OUT" 2>/dev/null || true
}
trap cleanup EXIT

BUILD_OUT="$(mktemp)"
BUILD_ERR="$(mktemp)"
OVERLAY_OUT="$(mktemp)"

# ── Preconditions ────────────────────────────────────────────────────────────

kubectl get crd infraclaims.jit.io >/dev/null 2>&1 || fail "InfraClaim CRD not installed"
docker inspect jit-runner >/dev/null 2>&1 || fail "jit-runner container not running"
kubectl get "$CONTROLLER" -n "$CTRL_NS" >/dev/null 2>&1 || fail "controller not deployed"


# ═════════════════════════════════════════════════════════════════════════════
# Phase 1: the manifests build, and the migration is visible in the built output
#          (assertion 3, plus the "Do" list's credentials + overlay items)
# ═════════════════════════════════════════════════════════════════════════════

if ! kubectl kustomize "$BASE_DIR" > "$BUILD_OUT" 2> "$BUILD_ERR"; then
  echo "--- kustomize error ---"; cat "$BUILD_ERR"
  fail "kubectl kustomize $BASE_DIR did not build"
fi
[[ -s "$BUILD_OUT" ]] || fail "kubectl kustomize $BASE_DIR produced no output"
echo "PASS: kubectl kustomize $BASE_DIR builds"

if ! kubectl kustomize "$REGISTRY_OVERLAY" > /dev/null 2> "$BUILD_ERR"; then
  echo "--- kustomize error ---"; cat "$BUILD_ERR"
  fail "kubectl kustomize $REGISTRY_OVERLAY did not build (R12 asserts this)"
fi
echo "PASS: kubectl kustomize $REGISTRY_OVERLAY builds"

# Assertion 4, static half: the stateful workloads are gone from the source, not
# merely absent from the namespace.
if grep -qE '^kind: StatefulSet$' "$BUILD_OUT"; then
  fail "built output still contains a StatefulSet"
fi
if grep -qE '^kind: PersistentVolumeClaim$' "$BUILD_OUT"; then
  fail "built output still contains a PersistentVolumeClaim"
fi
echo "PASS: no StatefulSet and no PersistentVolumeClaim in the built output"

# The stateful manifests themselves should be gone, not just unreferenced.
for stale in postgres-statefulset.yaml postgres-service.yaml redis-deployment.yaml \
             redis-service.yaml postgres-secret.env; do
  [[ -e "${BASE_DIR}/${stale}" ]] && fail "${BASE_DIR}/${stale} still exists - the migration deletes it"
done
[[ -e "app/scripts/deploy.sh" ]] || fail "app/scripts/deploy.sh is missing"
if grep -q 'openssl rand' "app/scripts/deploy.sh"; then
  fail "app/scripts/deploy.sh still generates credentials with openssl - the module generates the password now"
fi
echo "PASS: stateful manifests and the openssl credential step are gone"

# Credentials: no committed literal, and the pods read the controller's Secret.
if grep -qE 'POSTGRES_PASSWORD[[:space:]]*:' "$BUILD_OUT"; then
  fail "built output contains a literal POSTGRES_PASSWORD - credentials must come from the jit-postgres Secret"
fi
grep -q 'jit-postgres' "$BUILD_OUT" \
  || fail "no workload references the controller-written jit-postgres Secret"
echo "PASS: no literal password; workloads reference the jit-postgres Secret"

# Namespace parameterisation: at least one overlay other than registry/, and it
# must set a namespace (build-plan S15: "an overlay per environment").
shopt -s nullglob
ENV_OVERLAYS=()
for d in "${BASE_DIR}"/overlays/*/; do
  [[ "$(basename "$d")" == "registry" ]] && continue
  ENV_OVERLAYS+=("$d")
done
shopt -u nullglob

[[ "${#ENV_OVERLAYS[@]}" -ge 1 ]] \
  || fail "no per-environment overlay under ${BASE_DIR}/overlays/ - the namespace is not parameterised"
for d in "${ENV_OVERLAYS[@]}"; do
  if ! kubectl kustomize "$d" > "$OVERLAY_OUT" 2> "$BUILD_ERR"; then
    echo "--- kustomize error ---"; cat "$BUILD_ERR"
    fail "overlay $d did not build"
  fi
  grep -qE '^  namespace: ' "$OVERLAY_OUT" \
    || fail "overlay $d does not set a namespace"
done
echo "PASS: environment overlay(s) build and set a namespace: ${ENV_OVERLAYS[*]}"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 2: apply into an empty namespace -> three containers appear, app Ready
#          (assertion 1, plus the runtime half of assertion 4)
# ═════════════════════════════════════════════════════════════════════════════

kubectl delete ns "$NS" --ignore-not-found --timeout=30s 2>/dev/null || true
for _ in $(seq 1 60); do
  kubectl get ns "$NS" >/dev/null 2>&1 || break
  sleep 2
done
if kubectl get ns "$NS" >/dev/null 2>&1; then
  kubectl get ns "$NS" -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
    | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - >/dev/null 2>&1 || true
fi
if kubectl get ns "$NS" >/dev/null 2>&1; then
  fail "namespace $NS exists but could not be cleaned up"
fi

kubectl create ns "$NS" >/dev/null || fail "could not create namespace $NS"

# Drop any stale IPAM allocation left by an earlier run.
python3 -c "
import json, subprocess
try:
    raw = subprocess.check_output(
        ['kubectl','get','configmap','jit-ipam','-n','default','-o','jsonpath={.data.allocations}'],
        stderr=subprocess.DEVNULL)
    allocs = json.loads(raw)
except Exception:
    allocs = {}
allocs.pop('$NS', None)
body = {'apiVersion':'v1','kind':'ConfigMap',
        'metadata':{'name':'jit-ipam','namespace':'default'},
        'data':{'allocations':json.dumps(allocs)}}
subprocess.run(['kubectl','apply','-f','-'], input=json.dumps(body).encode(), check=False)
" 2>/dev/null || true

# The controller only reconciles the namespaces it is told to watch.
kubectl set env "$CONTROLLER" -n "$CTRL_NS" "WATCH_NAMESPACES=default,$NS" 2>/dev/null
kubectl rollout status "$CONTROLLER" -n "$CTRL_NS" --timeout=120s >/dev/null
sleep 3

# `-n` rather than an overlay: this asserts the base is namespace-agnostic,
# which is what parameterising the namespace is for. A base that hardcodes a
# namespace drops its resources elsewhere and fails here.
kubectl apply -n "$NS" -f "$BUILD_OUT" >/dev/null || fail "kubectl apply into $NS failed"
echo "PASS: applied app/kustomize into the empty namespace $NS"

DEPLOY_COUNT="$(kubectl get deploy -n "$NS" -o name | wc -l | tr -d ' ')"
[[ "$DEPLOY_COUNT" == "3" ]] || fail "expected 3 Deployments in $NS, found $DEPLOY_COUNT"
[[ -z "$(kubectl get statefulset -n "$NS" -o name)" ]] || fail "a StatefulSet exists in $NS"
[[ -z "$(kubectl get pvc -n "$NS" -o name)" ]] || fail "a PersistentVolumeClaim exists in $NS"
echo "PASS: no StatefulSet and no PVC in namespace $NS"

# Three containers, courtesy of the controller + runner.
for name in "$REDIS_CONTAINER" "$POSTGRES_CONTAINER" "$PGADMIN_CONTAINER"; do
  FOUND=false
  for _ in $(seq 1 150); do
    if docker container inspect "$name" >/dev/null 2>&1; then FOUND=true; break; fi
    sleep 2
  done
  if [[ "$FOUND" != "true" ]]; then
    kubectl get infraclaims -n "$NS" 2>/dev/null || true
    kubectl get infraclaims -n "$NS" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"  phase="}{.status.phase}{"  "}{.status.message}{"\n"}{end}' 2>/dev/null || true
    fail "container $name never appeared"
  fi
done

RUNNING="$(docker ps --filter "name=^${NS}-" --format '{{.Names}}' | wc -l | tr -d ' ')"
[[ "$RUNNING" == "3" ]] || fail "expected 3 running containers matching ${NS}-*, found $RUNNING"
echo "PASS: three containers are running: $REDIS_CONTAINER, $POSTGRES_CONTAINER, $PGADMIN_CONTAINER"

# require_deploy: assert the component is Ready, echo its Deployment name.
require_deploy() {
  local comp="$1" name
  name="$(kubectl get deploy -n "$NS" -l "app.kubernetes.io/component=${comp}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$name" ]] || fail "no Deployment labelled app.kubernetes.io/component=$comp in $NS"
  kubectl rollout status "deployment/$name" -n "$NS" --timeout=300s >/dev/null 2>&1 \
    || fail "deployment $name (component=$comp) never became Ready"
  echo "$name"
}

VOTE_DEPLOY="$(require_deploy vote)"
WORKER_DEPLOY="$(require_deploy worker)"
RESULT_DEPLOY="$(require_deploy result)"
echo "PASS: app is Ready ($VOTE_DEPLOY, $WORKER_DEPLOY, $RESULT_DEPLOY)"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 3: vote -> result end to end (assertion 2)
# ═════════════════════════════════════════════════════════════════════════════

svc_for() {
  local comp="$1" dep="$2" name
  name="$(kubectl get svc -n "$NS" -l "app.kubernetes.io/component=${comp}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$name" ]] || name="$dep"
  echo "$name"
}

VOTE_SVC="$(svc_for vote "$VOTE_DEPLOY")"
RESULT_SVC="$(svc_for result "$RESULT_DEPLOY")"
kubectl get svc "$VOTE_SVC" -n "$NS" >/dev/null 2>&1 || fail "no vote Service in $NS"
kubectl get svc "$RESULT_SVC" -n "$NS" >/dev/null 2>&1 || fail "no result Service in $NS"

# Postgres is out of cluster now, so the tally is read with docker exec. The
# database must be `voting` - `votingdb` was the never-populated placeholder.
TALLY_BEFORE=""
for _ in $(seq 1 60); do
  TALLY_BEFORE="$(docker exec "$POSTGRES_CONTAINER" psql -U postgres -d voting -t -A \
    -c 'SELECT COUNT(*) FROM votes' 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$TALLY_BEFORE" ]] && break
  sleep 2
done
if [[ -z "$TALLY_BEFORE" ]]; then
  docker exec "$POSTGRES_CONTAINER" psql -U postgres -d voting -c '\dt' 2>&1 | head -10 || true
  fail "cannot read the votes table from $POSTGRES_CONTAINER (is the database named 'voting'?)"
fi
echo "PASS: votes table readable via docker exec (count $TALLY_BEFORE)"

kubectl delete job s15-e2e -n "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: s15-e2e
  namespace: $NS
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: e2e
        image: curlimages/curl:8.10.1
        command: ["sh", "-c"]
        args:
        - |
          set -e
          VOTE="http://${VOTE_SVC}"
          RESULT="http://${RESULT_SVC}"
          code=\$(curl -s -o /tmp/vote.html -w '%{http_code}' "\$VOTE/")
          [ "\$code" = "200" ] || { echo "FAIL: GET \$VOTE/ -> \$code"; exit 1; }
          opts=\$(grep -o 'name="choice" value="[^"]*"' /tmp/vote.html | sed 's/.*value="\([^"]*\)".*/\1/')
          n=\$(printf '%s\n' "\$opts" | grep -c . || true)
          [ "\$n" -eq 2 ] || { echo "FAIL: expected 2 vote options, got \$n"; exit 1; }
          first=\$(printf '%s\n' "\$opts" | head -1)
          second=\$(printf '%s\n' "\$opts" | tail -1)
          echo "options: \$first / \$second"
          rcode=000
          for i in \$(seq 1 30); do
            rcode=\$(curl -s -o /tmp/result.html -w '%{http_code}' "\$RESULT/" || echo 000)
            [ "\$rcode" = "200" ] && break
            sleep 1
          done
          [ "\$rcode" = "200" ] || { echo "FAIL: GET \$RESULT/ -> \$rcode"; exit 1; }
          vcode=\$(curl -s -o /dev/null -w '%{http_code}' -X POST "\$VOTE/vote" --data-urlencode "choice=\$first")
          case "\$vcode" in 2??|3??) ;; *) echo "FAIL: POST \$VOTE/vote -> \$vcode"; exit 1;; esac
          echo "posted vote: choice=\$first (http \$vcode)"
          ok=0
          for i in \$(seq 1 30); do
            curl -s -o /tmp/result.html "\$RESULT/" || true
            if grep -qE '[0-9]+(\.[0-9]+)?%' /tmp/result.html \
              && grep -qF "\$first" /tmp/result.html \
              && grep -qF "\$second" /tmp/result.html; then ok=1; break; fi
            sleep 1
          done
          if [ "\$ok" -ne 1 ]; then
            echo "FAIL: result page never showed percentages and both option labels"
            head -20 /tmp/result.html
            exit 1
          fi
          echo "PASS: vote -> result end to end"
EOF
echo "PASS: launched the s15-e2e Job"

JOB_STATE=""
for _ in $(seq 1 150); do
  SUCCEEDED="$(kubectl get job s15-e2e -n "$NS" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  FAILED="$(kubectl get job s15-e2e -n "$NS" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
  if [[ "${SUCCEEDED:-0}" -ge 1 ]]; then JOB_STATE="ok"; break; fi
  if [[ "${FAILED:-0}" -ge 1 ]]; then JOB_STATE="failed"; break; fi
  sleep 2
done

if [[ "$JOB_STATE" != "ok" ]]; then
  echo "--- s15-e2e logs ---"
  kubectl logs job/s15-e2e -n "$NS" --tail=40 2>/dev/null || true
  kubectl get pods -n "$NS" -l job-name=s15-e2e 2>/dev/null || true
  fail "the vote -> result Job did not succeed (${JOB_STATE:-timed out})"
fi
kubectl logs job/s15-e2e -n "$NS" 2>/dev/null | sed 's/^/  /'
echo "PASS: vote -> result works end to end"

TALLY_AFTER=""
for _ in $(seq 1 30); do
  TALLY_AFTER="$(docker exec "$POSTGRES_CONTAINER" psql -U postgres -d voting -t -A \
    -c 'SELECT COUNT(*) FROM votes' 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$TALLY_AFTER" ]] && [[ "$TALLY_AFTER" -gt "$TALLY_BEFORE" ]]; then break; fi
  sleep 2
done
[[ "${TALLY_AFTER:-0}" -gt "$TALLY_BEFORE" ]] \
  || fail "the vote never reached Postgres: count ${TALLY_BEFORE} -> ${TALLY_AFTER:-unreadable}"
echo "PASS: the vote reached Postgres (votes ${TALLY_BEFORE} -> ${TALLY_AFTER})"

echo "PASS: S15 voting app migrated onto JIT infra"
