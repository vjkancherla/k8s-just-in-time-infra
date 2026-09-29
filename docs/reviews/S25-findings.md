# S25 Review

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Verdict: CONCERNS

## Blockers

None. Mechanical items 1-5 are clean:

1. `git diff 5ae9ba7..8910113` touches four files — `deploy/crd/infraclaim.yaml`,
   `docs/decisions/0011-s25-checkpoint-roundtrip-namespace.md`, `docs/evidence/S25.log`,
   `scripts/checks/S25.sh`. The only file under `scripts/checks/` is `S25.sh`, sanctioned
   by ADR 0011, committed with its edit in `3c92691` (ADR + script in one commit), no
   assertion deleted or weakened: the three field names, the `probe` payload, the three
   read-backs and every failure message are byte-identical; only the claim locator
   (`:28-37`, `:43`) plus a resolution guard changed. No `.clinerules/`, CI or scanner
   config touched.
2. No new dependency (no package/import/manifest change).
3. No assertion deleted or weakened (diff reviewed line by line).
4. No file outside the allowed list; working tree clean at review time (`git status
   --porcelain` empty), range is exactly two commits `3c92691`, `8910113`.
5. `docs/todo.md` untouched — S25's `check`/`review` boxes are still unchecked
   (`docs/todo.md:125`).

## Concerns

1. **The `conditions.type` enum is stricter than anything the design states, and its
   failure mode is silent.** `deploy/crd/infraclaim.yaml:70-77` turns `type` from an open
   `string` into a closed enum of exactly the seven names. The design's Conditions table
   (`docs/designs/declarers-and-consumers.md:147-155`) *lists* those seven but never says
   other types must be rejected — so this is an interpretation, not a contradiction, and
   it is not mentioned in the build plan's S25 goal either. What makes it worth raising:
   `set_condition` patches the whole `conditions` array in one merge patch
   (`jit-controller/main.py:615-623`) and swallows the `ApiException` with a warning
   (`jit-controller/main.py:626`). I confirmed with a server dry-run that one condition
   type outside the seven makes the API server reject the *entire* array
   (`Unsupported value: "S25EnumProbe"`), so a single out-of-enum type — a ninth condition
   added later, or the advisory `AppRestartRequired`-style condition the stage rules
   describe (`.opencode/rules/s22-declarers.md:43`) — would drop every legitimate condition
   write on that claim into a log line nobody watches. No checkpoint covers it. Action:
   record the closed set where the design's next amendment can name it, or drop the enum;
   either way the hazard should be visible to whoever adds an eighth condition.
2. **The checkpoint leaves fake state on a live claim, which defeats the design's
   backfill precondition.** The run leaves `appliedParams={"probe":"s25"}`,
   `attemptedParamsHash="s25-probe-hash"`, `declaredBy=["probe-s25"]` on
   `voting-a/voting-a-pgadmin`, whose `spec.params` is `{}` — verified after my run, and
   `kubectl get infraclaims -n voting-a` now prints `["probe-s25"]` under `DECLARED`. The
   design's backfill rule (`declarers-and-consumers.md:143`: "a `Ready` claim with no
   `appliedParams` adopts its normalized `spec.params` without calling the runner") can no
   longer be tested on that claim, and S26's first resync will see demanded ≠ applied on a
   claim whose applied params never came from a runner — a spurious apply on a claim the
   next step did not intend to touch. The prompt anticipates the non-cleanup, so this is
   not a blocker, but S26/U11 (`appliedParams` backfilled) must either clear the probe
   values or pick a claim the checkpoint never touched.
3. **ADR 0011's locator is two list calls where one would do.**
   `scripts/checks/S25.sh:28` takes the name from `-o name | head -1` and `:33` takes the
   namespace from a second `-A` call's `.items[0]`; the ADR asserts they select "the same
   object" via "kubectl's default ordering" without pinning `--sort-by`. They agree on this
   cluster (I checked: `infraclaim.jit.io/voting-a-pgadmin` vs `voting-a/voting-a-pgadmin`),
   and a mismatch fails loudly (NotFound), not silently — so not a blocker. A single
   `kubectl get infraclaims -A -o jsonpath=...` reading namespace *and* name from one
   response would remove the assumption the ADR has to argue for.
4. **Cluster-side coverage gap for half the goal.** The seven condition names
   (`scripts/checks/S25.sh:21-23`) and `DECLARED` (`:25`) are grepped against the YAML
   file only; nothing asserts the live CRD carries them, and the build plan's checkpoint
   text says "`kubectl get infraclaims` shows `DECLARED` as a printer column"
   (`docs/build-plan.md:917-918`), which the script never observes. The greps are
   pre-existing S22 shape, not introduced here, and I verified the substance myself: the
   deployed CRD (generation 2) matches the file including the enum and the column, and
   `kubectl get infraclaims -n voting-a` renders it. Still, a stale cluster CRD without
   the conditions or the column would pass this checkpoint.
5. **ADR 0011 cites evidence that is no longer in the repo.** Its Context says "The first
   live capture shows exactly this — `docs/evidence/S25.log` ends `Error from server
   (NotFound): ...`", but the committed log before the range (`5ae9ba7` version, commit
   `e8ab404`) ends `FAIL: CRD not present in the cluster`, and the NotFound capture was
   overwritten by the passing run. The claim itself is correct — I reproduced it verbatim
   with a server dry-run of the original locator
   (`Error from server (NotFound): infraclaims.jit.io "voting-a-pgadmin" not found`) — but
   the ADR's quoted proof is unverifiable from any committed artefact.

## Notes

- The ADR's mechanics check out: line references `:28/:30/:33/:36` are accurate for the
  pre-amendment script; kubectl is v1.36.3 as stated; the kubeconfig context namespace is
  unset (empty, so `default`) exactly as the ADR claims; the ADR and its edit are in one
  commit.
- Design conformance at schema level is complete: `spec.params` already exists
  (`infraclaim.yaml:29-31`), the three status fields match the design's State fields table
  (`declarers-and-consumers.md:136-141`), and all seven conditions from
  `declarers-and-consumers.md:147-155` are present. Nothing in the design's State fields
  or Conditions sections is missing from the diff.
- `x-kubernetes-preserve-unknown-fields: true` on `appliedParams` means the schema cannot
  enforce the design's "never credentials" rule (`declarers-and-consumers.md:139`) — that
  stays a controller-side write rule for S26, as the design intends.
- The `DECLARED` printer column and the enum are extra to the design's build-order item 3
  ("CRD, a quarter day. `appliedParams`, `attemptedParamsHash`, `declaredBy`",
  `declarers-and-consumers.md:265`); the printer column is sanctioned by the build-plan
  checkpoint text, the enum is not sanctioned by anything (see Concern 1).
- `docs/build-plan.md:911` tells S25 to read "`docs/lessons.md`'s CRD note" — `docs/lessons.md`
  contains no such note (no mention of status fields, pruning or the schema). Stale read
  pointer, not an S25 defect.
- The evidence log was captured with the CRD edit still uncommitted (`# commit 3c92691`,
  `# pending 1 uncommitted change(s)`) and committed together with it in `8910113`, which
  satisfies "code and log in the same commit".
- Pruning really is the mechanism the assertion rests on: I patched an unknown status field
  on a live claim and the API server warned `unknown field "status.s25SchemaProbe"` and
  reported `patched (no change)`, read-back empty. Had `appliedParams` been absent from the
  schema, the read-back loop at `S25.sh:42-45` would have failed.

## Checkpoint assessment

`scripts/checkpoint.sh 25 /tmp/S25-review.log` passed on my clean run — commit `1535d72`,
no pending changes, `PASS S25: schema fields survive pruning; DECLARED printer column
present`, exit 0 — with the cluster up (`make jit-up` state) and three live InfraClaims.
It does assert the step's core goal: the three field names are grepped in the CRD *and*
round-tripped through the live API server, so a schema entry that is missing, mistyped or
not applied to the cluster prunes the patch and fails the `grep -q "probe"` read-back — I
verified the pruning half empirically on this cluster. The seven conditions and the
`DECLARED` column are asserted against the YAML file only, not against the API server
(Concern 4), and the run mutates a live claim without cleaning up (Concern 2); neither
makes the pass meaningless. ADR 0011's amendment is accepted: it fixes a real claim-locator
defect (reproduced), changes no assertion, and the checkpoint still fails if the CRD
changes are removed.

Verdict: CONCERNS
