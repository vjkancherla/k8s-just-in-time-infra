# S08 Review Findings

**Step:** S8 — CRD and claim creation
**Goal:** an annotation produces a claim owned by the Namespace.
**Commit:** d8c709a (feat(jit): S8 CRD + controller scaffold)
**Files:** deploy/crd/infraclaim.yaml, jit-controller/main.py, jit-controller/requirements.txt, scripts/checks/S08.sh

## Verdict: CLEAR

## Checkpoint

```
deployment.apps/s8-test-deploy created
deployment.apps/s8-test-deploy unchanged
PASS: CRD + claim creation, ownerRef → Namespace, finalizer
deployment.apps "s8-test-deploy" deleted from default namespace
infraclaim.jit.io "default-redis" deleted from default namespace
secret "jit-redis" deleted from default namespace
```

Exit 0. The pass is genuine: `jit-controller` deployment is running 1/1 in `default`
(verified `kubectl get deploy -A`), so the controller really created the claim, set
`status.phase=Ready`, stamped the Namespace ownerReference, and created the Secret. The
`phase==Ready` assertion is a real gate — the create body passes `status: {}`, so the
claim cannot be Ready unless `ensure_ready` patched it.

## What was reviewed

- **CRD** (`deploy/crd/infraclaim.yaml`): Namespaced; `v1alpha1` served+storage;
  spec `{module, moduleVersion, params, softDeleteTTL}`; status
  `{phase, referencedBy[], expiresAt, outputsSecret, endpoint, message}`; status
  subresource present; printer columns PHASE/EXPIRES/REFS. Matches S8 design.
- **Controller** (`jit-controller/main.py`): `parse_annotations` filters the
  `jit.infra/` prefix and extracts the module from the key; `handle_deployment` reacts
  to create+update and no-ops on unannotated Deployments; `ensure_claim` creates
  `<namespace>-<module>` with `ownerReference → Namespace` (uid + `blockOwnerDeletion`,
  correct for a cluster-scoped owner) and finalizer `jit.infra/teardown`, catching only
  409; `ensure_ready` creates Secret `jit-<module>` and patches status to Ready.
- **Idempotence**: claim name is derived from namespace+module, not the Deployment, so
  re-apply computes the same name and the create returns `AlreadyExists` → no-op. The
  checkpoint asserts exactly one claim after re-apply, which passes.
- **Diff scope**: `git show --stat d8c709a` touches exactly the four listed files
  (266 insertions). No stray changes.

## CONCERNS (raised, not acted on — out of S8 scope)

1. **Conflicting params not surfaced.** The design note ("Claim identity and
   idempotence") says conflicting params should be first-writer-wins *and* record a
   warning condition naming both Deployments. S8 does first-writer-wins silently — the
   second annotator's create 409s and the controller no-ops, with no warning condition.
   This matches the design's "Open questions" list and is outside the S8 checkpoint, but
   worth confirming it's an intentional S8 omission rather than a miss.

2. **Idempotence coverage.** The checkpoint re-applies the *identical* annotation. A
   Deployment edited to a *different* param set would not update the existing claim
   (first-writer-wins), but that is the documented open question, not an S8 assertion.

Neither concern blocks the step; the checkpoint gates the S8 properties and they hold.

## Not started

S9 not started, per instructions.