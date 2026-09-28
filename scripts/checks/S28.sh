#!/usr/bin/env bash
# S28 - Tenant migration and the doc amendments: one declarer per module with
# consumers, the three design documents amended, `tofu fmt` clean.
# No cluster needed; `kubectl kustomize` builds manifests without one.
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }

# --- 1. both overlays build ---------------------------------------------------
kubectl kustomize app/kustomize/base >/tmp/s28-base.yaml 2>/tmp/s28-base.err \
  || fail "base overlay does not build: $(cat /tmp/s28-base.err)"
kubectl kustomize app/kustomize/overlays/voting-b >/tmp/s28-b.yaml 2>/tmp/s28-b.err \
  || fail "voting-b overlay does not build: $(cat /tmp/s28-b.err)"

# --- 2. the built base carries the declarer/consumer shape ----------------------
# role(mod) prints declarer|noparams|NOANNOT|UNPARSED for jit.infra/<mod>; the
# pairs checked are exactly the design's migration table. Plain-text parser on
# the built YAML: split on the `---` separators, pick the Deployment document
# whose name is <who>, and inspect its annotation line for the params key.
role() { python3 - "$1" "$2" /tmp/s28-base.yaml <<'EOF'
import json,sys
who, mod, path = sys.argv[1], sys.argv[2], sys.argv[3]
needle="jit.infra/%s:"%mod
for d in open(path).read().split("\n---\n"):
    lines=d.splitlines()
    if "kind: Deployment" not in d: continue
    if not any(l.strip()=="name: %s"%who for l in lines): continue
    for l in lines:
        if l.strip().startswith(needle):
            raw=l.split(":",1)[1].strip().strip("'\"") or ""
            try: p=json.loads(raw)
            except Exception: print("UNPARSED"); break
            print("declarer" if "params" in p else "noparams")
            break
    else:
        print("NOANNOT")
    break
else: print("NODEPLOY")
EOF
}
role voting-app-worker redis | grep -qx noparams \
  || fail "worker must CONSUME redis (no params key) - actual: $(role voting-app-worker redis)"
role voting-app-worker postgres | grep -qx declarer \
  || fail "worker must DECLARE postgres (params key present) - actual: $(role voting-app-worker postgres)"
role voting-app-vote redis | grep -qx noparams \
  || fail "vote must CONSUME redis - actual: $(role voting-app-vote redis)"
role voting-app-vote pgadmin | grep -qx declarer \
  || fail "vote must DECLARE pgadmin - actual: $(role voting-app-vote pgadmin)"
role voting-app-result postgres | grep -qx noparams \
  || fail "result must CONSUME postgres - actual: $(role voting-app-result postgres)"
# softDeleteTTL stays on every reference, declarer or consumer
git grep -q "softDeleteTTL" -- app/kustomize/base/result-deployment.yaml \
  || fail "a consumer may still carry softDeleteTTL - lifecycle data, not a setting"

# --- 3. git scans: params only in the declarers' files ------------------------------
with_params="$(git grep -l '"params"' -- app/kustomize/base || true)"
echo "$with_params" | grep -q "worker-deployment.yaml" \
  || fail "no declarer params survive for postgres/redis in the base"
echo "$with_params" | grep -q "vote-deployment.yaml" \
  || fail "vote's pgadmin declarer params are gone from the base"
echo "$with_params" | grep -q "result-deployment.yaml" \
  && fail "result is a consumer - it must not carry params"
echo "3 ok base annotations: one declarer per module, consumers carry none"

# --- 4. the three design documents are amended, the lineage records it ---------------
grep -q "update sequence" docs/designs/jit-infra-flows.md \
  || fail "jit-infra-flows.md has no update sequence"
grep -q "Failed → Pending: retry with backoff" docs/designs/jit-infra-flows.md \
  && fail "jit-infra-flows.md still carries the retry-with-backoff line the code never had"
grep -qiE "declarer|consumer" docs/designs/README.md \
  || fail "docs/designs/README.md lineage does not record declarers-and-consumers.md"
grep -qiE "declarer|params key" docs/designs/annotation-to-state.md \
  || fail "annotation-to-state.md does not reflect the params-key role rule"
grep -q "params" docs/designs/jit-infra-poc.md \
  || fail "jit-infra-poc.md's tenant-surface examples were not fixed (maxmemory outside params)"
echo "4 ok design docs: flows sequence present, poc answered, role rule recorded"

# --- 5. formatting ------------------------------------------------------------------
tofu fmt -check -recursive jit-modules/modules/postgres jit-modules/modules/redis \
  || fail "changed modules are not tofu-formatted"
echo "PASS S28: migration shape asserted; three design docs amended; modules formatted"
