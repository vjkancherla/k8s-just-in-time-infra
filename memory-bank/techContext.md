# Tech Context

## Stack
- Runtime: k3d (k3s on Docker), arm64.
- Infra provisioning: Terraform (`tofu`) modules — redis, postgres, pgadmin, minio.
- State store: MinIO (S3-compatible) for Terraform state, one object per namespace-module.
- Control plane: Python controller (kopf) + custom CRD `InfraClaim` (`jit.io/v1alpha1`).
  Code lives in jit-controller/ (`main.py`, `ipam.py`), shipped via the `jit-controller-code`
  ConfigMap with subPath volume mounts; force-delete the pod to pick up new code.
- App: a "voting" app (vote → redis → worker → postgres → result), Kustomize, Traefik.
- Orchestration: root Makefile + bash checkpoint scripts.

## Commands
- Install: `tofu`, `k3d`, `kubectl`, `docker` — verify versions before use.
- Build: `kubectl kustomize app/kustomize` (and the registry overlay).
- Test all: `make verify` → parse `.workflow/verify.md` for `17 PASS, 0 FAIL` (do NOT trust
  verify.sh's exit code — it is 0 even when checks fail).
- Test single file: `make check STEP=NN` → runs `scripts/checks/SNN.sh` (PASS/FAIL, exits
  non-zero on failure). Added by S17 and committed; `bash scripts/checks/SNN.sh` works too.
- Test the lifecycle: `make jit-verify` → `scripts/verify-jit.sh`, J1-J11, writes
  `.workflow/verify-jit.md`. Green as of S17 (see memory-bank/activeContext.md).
- Stack: `make jit-up` (MinIO + runner + CRD + controller), `make jit-down`.
- Update controller code: `kubectl create configmap jit-controller-code -n default
  --from-file=main.py=jit-controller/main.py --from-file=ipam.py=jit-controller/ipam.py
  --dry-run=client -o yaml | kubectl apply -f -`, then force-delete the pod (subPath mounts
  do not refresh).
- Lint: none defined yet.
- Run locally: `cd app && make all` (deploy + verify) on the fixed-subnet cluster.

## Dependencies
- Whole design rests on one assumption: a pod can reach a container by its k3d-network IP
  (proven in S1 — the hard gate).
- `set -euo pipefail` in checkpoint scripts; `verify.sh` deliberately omits `-e`.

## Constraints
- All work inside `k8s-just-in-time-infra/`; one namespace per app; Namespaces managed by platform
  team, not tenants.
- Fixed subnet `172.19.0.0/16` on the `k3d-voting-app` network; ~10 IPs per namespace.
- Avoid host port 5000 (AirPlay conflict).

## Do not touch
- `local-ai-dev-workflow-voting-app/` — read-only reference; copy into `app/` before editing.
- Anything outside `k8s-just-in-time-infra/`.

