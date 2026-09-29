# S29 Review

Reviewer model: deepseek-v4-pro
Verdict: CONCERNS

## Blockers

None.

The twelve review questions are intact in the prompt. Mechanical checks 1-5 pass:
the range touches only the eight allowed paths (four ADRs, `docs/evidence/S29.log`,
`jit-controller/main.py`, `jit-runner/main.py`, `scripts/checks/S29.sh`);
`scripts/checks/S29.sh` is amended by ADR 0019 (`982dc05`) and ADR 0021 (`346a9ad`),
each committed with its edit before `scripts/checkpoint.sh 29` ran, and the amendments
are locator/setup corrections, not softenings (U1's IP now compares the per-network
address against `status.allocatedIP`, which is the IP the design names; U5 restores the
deleted declarer; U6's declarer gains `params:{}`; the gate reorders the suites instead
of racing a demo-mode toggle). No new dependency was added (`Any` was already imported in
the runner; `re`/`json` in the controller). No existing test was deleted or weakened.
No file outside the list was created or edited. `docs/todo.md` was not touched.

## Concerns

1. **`patch_applied_params` clears only top-level removed keys, so a dropped nested
   `settings` key survives in `appliedParams`** (`jit-controller/main.py:832-855`). It
   nulls `{k: None for k in old if k not in params}` and then `patch.update(params)`.
   A JSON merge patch merges nested objects, so changing postgres `settings` from
   `{"max_connections":"200","work_mem":"8MB"}` to `{"max_connections":"300"}` leaves
   `work_mem` in `appliedParams`. Desired `{"max_connections":"300"}` then never equals
   applied `{"max_connections":"300","work_mem":"8MB"}` under `_normalize_params`, so the
   resync re-applies on every tick — the exact container-replace loop ADR 0020's top-level
   fix was meant to close, one level down. It is not exercised by the U-table (no settings
   edit), and `voting-b`/`voting-a` carry no `settings`, so the checkpoint stays green; it
   is a latent defect in the v1 mutable surface (`settings.max_connections`, `shared_buffers`,
   `work_mem`), not a blocker for this gate.

2. **The create path no longer refuses an unknown/typo'd key.** ADR 0020 gates
   `validate_params` behind `provisioned`, so a brand-new claim projects its declarer params
   and provisions them unvalidated. This is rule-3-aligned ("create behaviour is unchanged")
   and ADR-sanctioned, and it is what lets `voting-b`'s pgadmin `http_port:5051` through —
   but it means the design table's "a key the module does not declare → Refused; tofu only
   warns on unknown `-var`s, so a typo would be recorded as applied" guard is now absent on
   create. A typo in a *new* declarer annotation is silently recorded as applied. ADR 0020
   lists this under "Hard / ruled out", so it is a deliberate tradeoff, not a hidden defect;
   flagging it because a future reader of the mutability table will expect the refusal to
   apply everywhere.

3. **The committed evidence was captured against a dirty tree.** `docs/evidence/S29.log`
   records `# commit 346a9ad` and `# pending 10 uncommitted change(s)`: the checkpoint ran
   before the controller/runner code and ADRs 0020/0022 were committed (they land together
   with the log at `b27f374`). The run is still trustworthy — I re-ran the checkpoint on the
   final tree and it passes — but the "commit the code and that log in the same commit" rule
   produced an evidence header that predates the code it certifies.

## Notes

- `make test-up` (the documented precondition) does not complete green on a clean host.
  `make verify NS=voting-b` fails R2/R6/R8 (`code=302, LLEN 0 -> 0`, "vote did not appear",
  "no vote queued") because `app/scripts/verify.sh` hardcodes
  `VOTE_URL=https://vote.localhost:8082`, which is `voting-a`'s Ingress; `voting-b`'s
  Ingress is `vote-b.localhost`. So the check posts to `voting-a`'s vote app while reading
  `voting-b-redis-redis`. This is pre-existing app/verify behaviour, not a consequence of
  the S29 diff (no `app/` or overlay file is in the range), and the S29 gate correctly runs
  only `NS=voting-a`. I reproduced it across three cold paths.
- The S29.sh U13 test annotates `voting-b`'s vote with `jit.infra/redis` **without** a
  `params` key, which turns the declarer into a consumer while setting `softDeleteTTL:45m`;
  combined with the worker's consumer `10m`, this is exactly the design's "two consumers,
  different TTL → the larger" (rule 7, role-independent). The EXIT trap restores only
  `voting-a`, so `voting-b`'s vote is left a redis consumer after the run — consistent with
  the prompt's "re-establish both tenants afterwards" postcondition, which I did.
- The CRD schema already carries `spec.softDeleteTTL` and `status.appliedParams`
  (`deploy/crd/infraclaim.yaml`), so the new TTL patch and the `patch_applied_params` write
  are in-schema and will not be pruned.

## Checkpoint assessment

`scripts/checkpoint.sh 29 /tmp/S29-review.log` passed on my clean run (HEAD `535f5ac`,
`pending 0 uncommitted change(s)`): `U1-U11, U13 ok`, `gate ok: make jit-verify reports
J1-J11 all PASS`, `gate ok: make verify NS=voting-a reports 17 PASS, 0 FAIL`, `U12 ok`,
`PASS S29: U1-U13 asserted live`. It asserts the step's goal rather than a stub: U1 requires
the controller to change the redis container command and keep the allocated IP; U2 requires a
real in-place `postgresql_database` add; U3/U4/U7/U8 require the role rule, conflict and
refusal conditions; U5/U6 the NoDeclarer/AwaitingDeclarer branches; U9/U10 the failure and
crash-recovery paths; U11 the backfill; U13 rule 7's TTL maximum; U12 the destroy finalizer;
and the gate re-runs the frozen J- and R-suites in full. Deleting or stubbing the controller's
update flow, the runner, or the modules would fail it readably on every U.

Verdict: CONCERNS
