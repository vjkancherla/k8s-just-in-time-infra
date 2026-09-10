# S14 Review Prompt

**Step:** S14
**Goal:** real containers, driven by the controller.

**Commit range:** 9184a7b → 2e74e04 → b9945bd → 020f899 → bed3dc0 (step, blockers, concerns,
IPAM/postgres defects, remote-state backend + gate)

**Files changed:**
- jit-controller/main.py (modified)
- jit-controller/ipam.py (modified — first_free_address; block_addresses)
- jit-controller/test_ipam.py (modified — 8 new tests, 27 total)
- deploy/crd/infraclaim.yaml (modified — status.conditions, spec.params preservation)
- deploy/controller.yaml (modified)
- deploy/runner.sh (modified — three deploy-script bug fixes)
- jit-runner/main.py (modified — now tracked; per-run lock, (workspace, module) keying)
- jit-modules/modules/*/main.tf (modified — `backend "s3" {}`; now tracked)
- jit-modules/modules/postgres/outputs.tf (modified — sensitive output)
- scripts/checks/S14.sh (new; Phase 2 uses the Service name, Phase 3 gates on the JIT Secret,
  Phase 4 restarts the runner and asserts the container is gone)
- docs/todo.md (check box ticked)

**Checkpoint to run:** `bash scripts/checks/S14.sh`

**Instructions:**
1. Read docs/build-plan.md S14
2. Review jit-controller/main.py `provision_infra`: replaces the fake provisioner with a runner call to `RUNNER_URL/v1/runs` using the bearer token from the `jit-runner-token` Secret. On success it writes the outputs Secret, a Service with no selector, and an EndpointSlice whose endpoint address is `status.allocatedIP`. Check the failure path sets phase `Failed` with the runner error as `status.message` and does not retry-storm.
3. Review `destroy_infra`: now passes `params` (name, network, and `ip` when `allocatedIP` is set) and returns True when `RUNNER_URL` is unset. Check the ip/params are complete enough for `tofu destroy` to succeed from a cold state.
4. Review the clusterwide watch: `WATCH_NAMESPACES=""` -> `kopf.run(clusterwide=True)`; confirm there is no code path that still assumes a fixed namespace list.
5. Review stale-Ready handling in `provision_infra`: a claim that is already `Ready` is re-provisioned when its Secret has no data. Check this cannot loop or fight with the resync timer.
6. Review `list_referencing_deployments` and the `resync_referenced_by` status read. Both now use the kubernetes client (`AppsV1Api.list_namespaced_deployment`, `get_namespaced_custom_object_status`). Note for context: an earlier revision made these direct raw HTTP calls to the API server to work around a suspected client-side cache returning stale Deployments. That diagnosis was wrong - the Deployment had never actually been deleted (see 8) - and the workaround has been reverted. The remaining concern is whether the fresh status read is genuinely needed, and whether `except client.exceptions.ApiException` is the right fallback boundary.
7. Review scripts/checks/S14.sh: Phase 1 annotate -> real container at the allocated IP plus Secret + Service + EndpointSlice; Phase 2 a pod resolves the Service and reaches Redis (`PONG`); Phase 3 runner stopped -> claim `Failed` with a readable message and the pod stays unstarted; Phase 4 the S10 soft-delete sequence end to end with real containers (Ready -> Orphaned with expiresAt and Secret alive -> resurrect with the same Secret uid and expiresAt cleared -> TTL sweep removes the claim and the Secret).
8. Note the checkpoint fix: Step 2 and Step 4 called `kubectl delete deployment "$DEPLOY_NAME"` without `-n "$NAMESPACE"`, so they acted on namespace `default` and `s14-deploy` in `s14-test` was never deleted. With `--ignore-not-found` the no-op was silent, the controller correctly kept `referencedBy=['s14-deploy']`, and the claim could never leave `Ready`. Judge whether fixing the gate here was legitimate, and whether the diff still earns its keep now that the workaround it motivated is gone.
9. S14 requires conflicting params between two Deployments to resolve first-writer-wins with a warning condition naming both. The checkpoint has no phase covering this and no reviewer-visible evidence for it. Treat as unverified - call it out.
10. Write docs/reviews/S14-findings.md with CLEAR / BLOCKED / CONCERNS
11. Judge three defects found after your previous pass, all outside the earlier findings, and
    the fixes now in place:
    (a) every InfraClaim in a namespace received the same `status.allocatedIP` — fixed with
    `first_free_address`, and `allocate_block` now runs only for a claim with no address so the
    namespace count tracks claims (one had reached 193, so blocks were never freed). Check the
    count semantics against `release_block`.
    (b) the postgres module could not be applied at all (`output "url"` referred to sensitive
    values) — now `sensitive = true`.
    (c) no module declared a remote backend, so the runner's `-backend-config` arguments were
    ignored, tofu ran on local state in a throwaway dir, and a *cold* destroy reported
    `destroyed` while leaving the container running. Now `backend "s3" {}` in all three
    modules, and S14.sh Phase 4 restarts the runner and asserts the container is gone. Check
    the new assertions are not vacuous and that the count/state fixes cannot regress.

Do not start S15.
