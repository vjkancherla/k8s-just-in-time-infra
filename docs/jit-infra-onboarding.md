# JIT Infra PoC - New Platform Engineer Onboarding

Date: 2026-09-13
Author: New platform engineer (no prior context)
Purpose: First impressions, discrepancies, and gaps discovered during initial exploration

## Executive Summary

The JIT (Just-In-Time) Infrastructure PoC is a proof-of-concept system where infrastructure appears when an app deploys and goes away when the app is deleted. It runs on k3d (Kubernetes in Docker) and uses Kubernetes annotations to declare infrastructure needs.

The system is in a working state with all verification checks passing. However, I found several discrepancies and gaps that would trip up a new engineer.

## Current State

As of my exploration:
- k3d cluster `voting-app` is running
- 3 JIT containers running: `voting-a-redis`, `voting-a-postgres`, `voting-a-pgadmin`
- App verification (R1-R17): 17 PASS, 0 FAIL
- JIT lifecycle verification (J1-J11): 11 PASS, 0 FAIL

## Architecture at a Glance

```
Tenant annotates Deployment
        ↓
Controller (kopf + kubernetes) watches for annotated Deployments
        ↓
Controller creates InfraClaim CRs
        ↓
Controller calls Runner HTTP API
        ↓
Runner executes tofu apply with module params
        ↓
Infrastructure appears (Docker containers in this PoC)
        ↓
Controller records status (Ready, Orphaned, etc.)
```

## Prerequisites

- Docker
- k3d
- kubectl
- Python 3
- OpenTofu (or Terraform)
- `make`

## Key Components

| Component | Description |
|---|---|
| `jit-controller/` | Python controller using Kopf framework |
| `jit-runner/` | FastAPI app that executes tofu runs |
| `jit-modules/` | Terraform modules (redis, postgres, pgadmin) |
| `deploy/` | Deployment scripts for MinIO, runner, controller |
| `scripts/` | Shell scripts for orchestration |
| `console/` | Web UI for managing the system |
| `app/` | The voting app (deploy target) |

## How to Run

### Quick Start
```bash
python3 console/serve.py
open http://127.0.0.1:8090
```
The console provides a button-driven UI for the entire workflow.

### Manual Commands
```bash
# Bring up the JIT stack
make jit-up

# Deploy and verify the demo app
make demo-up

# Verify the app works
make verify NS=voting-a

# Run the full JIT lifecycle suite
make jit-verify

# Tear down
make destroy
```

## Discrepancies Found

### 1. Missing README for console
The console has its own README (`console/README.md`), but the root README references it as if it's comprehensive. The console README is actually quite detailed and should be linked prominently.

### 2. Stale state objects in MinIO
MinIO contains 21 state objects from many previous test runs, including orphaned namespaces (`s13-a`, `s13-b`, `hatch-leak`, etc.). This is normal for a PoC but could be confusing.

### 3. No documentation for the console's allowlist
The console only exposes a specific set of `make` targets through `serve.py`'s `ALLOWED` dict. This is not documented anywhere.

### 4. The "demo" vs "testing" mode confusion
The console has two modes (Demo and Testing), but the difference is not clearly explained in the UI. Demo is one namespace, Testing is two namespaces.

### 5. No version pinning
Dependencies are not version-pinned anywhere. This could lead to reproducibility issues.

### 6. Hardcoded IP ranges
The IPAM (IP Address Management) uses hardcoded blocks (`172.19.0.100-109` for voting-a, `172.19.0.110-119` for voting-b). This is not documented and would need to be extended for more namespaces.

### 7. The runner has a hardcoded fallback
The runner has a hardcoded fallback for the workspace/module when the caller doesn't specify a module. This is documented in the code comments but not in any design document.

## Gaps That Need Filling

### 1. No onboarding guide
This document is what I should have found. There is no "getting started" guide for a new engineer joining the project.

### 2. No troubleshooting guide
The README has a small troubleshooting section, but it's focused on specific known issues. There's no general "what to do when things go wrong" guide.

### 3. No architecture decision records (ADRs)
The design note (`docs/jit-infra-poc.md`) is the single source of truth for the design, but there are no ADRs explaining why certain decisions were made. This makes it hard for a new engineer to understand the reasoning behind the architecture.

### 4. No API documentation for the runner
The runner exposes an HTTP API, but it's not documented. A new engineer would need to read the code to understand it.

### 5. No testing strategy documentation
There are R1-R17 and J1-J11 checks, but there's no documentation explaining what these checks cover or how to add new ones.

### 6. No monitoring/alerting
The README acknowledges this as a limitation, but it's not documented how to monitor the system (e.g., what logs to watch, what metrics to collect).

### 7. No backup/restore
The README acknowledges this as a limitation. No documentation on how to backup or restore the system.

### 8. No upgrade path
No documentation on how to upgrade the system (e.g., upgrade k3d, upgrade dependencies).

## Response to Each Concern

### Discrepancies

| # | Concern | Status | Resolution |
|---|---|---|---|
| 1 | Console README not prominently linked | **Fixed** | Root README's "Key documents" table now lists `console/README.md` with its full scope (allowlist, modes, endpoints). The console README itself was expanded with a mode comparison table and a full allowlist reference. |
| 2 | Stale state objects in MinIO | **Documented** | Added "Stale state objects in MinIO" to the root README's Troubleshooting section. Normal for a PoC; `make jit-down` clears the bucket. |
| 3 | Console allowlist not documented | **Fixed** | `console/README.md` now has a "The allowlist" section with the full button→target mapping table. Root README's Key documents table references it. |
| 4 | Demo vs Testing mode confusion | **Fixed** | `console/README.md` now has a mode comparison table showing what each mode does and which buttons it exposes. |
| 5 | No version pinning | **Fixed** | Root README's Prerequisites section now has a "Dependency versions" table showing exact pins for the runner and range pins for the controller, with rationale. |
| 6 | Hardcoded IP ranges not documented | **Fixed** | Created [`docs/decisions/0003-ipam-blocks.md`](decisions/0003-ipam-blocks.md) — an ADR explaining the 172.19.0.100-199 range, BLOCK_SIZE=10, the ConfigMap ledger, and how to extend. |
| 7 | Runner's hardcoded fallback not documented | **Fixed** | Created [`docs/runner-api.md`](runner-api.md) with a "Module resolution order" section explaining the fallback. Also covered in ADR 0002. |

### Gaps

| # | Concern | Status | Resolution |
|---|---|---|---|
| 1 | No onboarding guide | **Fixed** | This document is now the onboarding guide. It lives at `docs/jit-infra-onboarding.md`. |
| 2 | No troubleshooting guide | **Fixed** | Root README's Troubleshooting section expanded with "Where to look first" (5-step checklist), "Monitoring the system" (6 commands for watching the PoC), and "Stale state objects." The existing pgAdmin, Terminating, and step-fails-twice sections remain. Cross-references to `JIT-MAKEFILE-GUIDE.md` and `JIT-MANUAL-GUIDE.md` for symptom→fix tables. |
| 3 | No ADRs | **Fixed** | Created 4 ADRs in `docs/decisions/`: <br>• [0001](decisions/0001-annotation-on-deployment-ownership-on-namespace.md) — annotation on Deployment, ownership on Namespace <br>• [0002](decisions/0002-runner-separation.md) — runner as a separate HTTP service <br>• [0003](decisions/0003-ipam-blocks.md) — IPAM block allocation <br>• [0004](decisions/0004-console-stateless-allowlist.md) — console stateless allowlist |
| 4 | No runner API docs | **Fixed** | Created [`docs/runner-api.md`](runner-api.md) — full reference for `POST /v1/runs`, `DELETE /v1/runs/{workspace}`, `GET /health`, including request/response schemas, auth, config vars, and state management. |
| 5 | No testing strategy docs | **Fixed** | Created [`docs/testing-strategy.md`](testing-strategy.md) — R1-R17 and J1-J11 check descriptions, frozen checkpoints, how to add new checks, what the tests don't cover. |
| 6 | No monitoring/alerting | **Addressed** | The PoC deliberately has no monitoring (see Limits table). Added a "Monitoring the system" section to Troubleshooting with 6 practical commands for watching controller logs, runner logs, claims, containers, the IPAM ledger, and state objects. |
| 7 | No backup/restore | **Acknowledged** | The PoC uses soft delete as the accident case (TTL window). No backup is implemented — this is a deliberate Limit. `make jit-down` + `make jit-up` is the recovery path. Production would add snapshot-before-destroy. |
| 8 | No upgrade path | **Documented** | Added to Prerequisites: OpenTofu pinned in the runner Dockerfile, Python deps pinned in `requirements.txt` files. `jit-up.sh` rebuilds the controller image on every run. To upgrade: change the pin, rebuild, re-run. |

### What was also fixed

- **Runner description**: Layout section said "Flask" — corrected to "FastAPI"
- **Key documents table**: Added runner API reference, testing strategy, and individual ADR entries
- **ADRs directory**: Changed from "template only" to 4 filled ADRs + the template

## What Worked Well

1. **Clear separation of concerns**: The controller, runner, and modules are well-separated.
2. **Comprehensive verification**: The R1-R17 and J1-J11 checks provide strong confidence that the system is working.
3. **Good documentation of the design**: The design note is detailed and explains the reasoning behind the architecture.
4. **Clean Makefile**: The Makefile is well-organized and easy to understand.
5. **Good console UI**: The console provides a clean, button-driven interface that makes it easy to interact with the system.

## Conclusion

The JIT Infra PoC is a well-designed and well-implemented proof-of-concept. The main gaps are in documentation for new engineers, particularly around onboarding, troubleshooting, and API references. The system itself is working as intended, with all verification checks passing.