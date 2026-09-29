# controller create-validation/nested-clear review (4051846..b4e7a7c)

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Verdict: CONCERNS

Prompt integrity: `docs/reviews/controller-c1-review-prompt.md` carries all twelve numbered
questions (Q1-Q5 mechanical, Q6-Q7 checkpoint, Q8-Q12 substance) and reads as a prompt, not a
summary. Range is one commit — `b4e7a7c`, parent `4051846` — touching exactly
`docs/decisions/0025-create-validation-and-nested-clear.md` (+55), `docs/evidence/S26.log`
(+3/-3), `jit-controller/main.py` (+80/-33); `git show --name-only b4e7a7c` returns those
three and nothing else. `git status --porcelain` shows only the two pre-existing untracked
files (`docs/HANDOFF.md`, the review prompt), so my run left the tree as I found it.

## Blockers

None.

1. No mechanical finding (Q1-Q5): nothing under `scripts/checks/`, `.clinerules/`, CI or
   scanner config (diff stat is the three files above); no dependency added (the diff adds no
   import — `_merge_patch` and the allowlist dicts are stdlib/plain literals); no test or
   assertion deleted or weakened (`jit-controller/test_declarers.py` and
   `scripts/checks/S26.sh` are byte-unchanged in the range; the 23 unit tests still pass,
   run read-only); no file created or edited outside the allowed list; no `docs/todo.md` tick.
2. The checkpoint passed on my own clean run (Q6) — see Checkpoint assessment.
3. No design disagreement that changes behaviour: refusing an undeclared key on create is
   what `docs/HANDOFF.md` P0.3 asks for, and the design's own contract row
   (`declarers-and-consumers.md:112`, "a key the module does not declare | Unknown |
   Refused; tofu only warns on unknown `-var`s, so a typo would be recorded as applied") and
   line 114 ("Values are validated before any runner call") support it. My objection to how
   ADR 0025 *justifies* it is Concern 4, not a blocker.

## Concerns

1. **Neither fix is gated (Q7).** S26 asserts neither behaviour change, so both can be
   reverted and S26 still prints PASS. (a) Create validation: every claim S26 creates is
   `module=redis` (the constant is even named `PGDECL`, S26.sh:78, but carries redis), and
   `_CREATE_ALLOWED["redis"] == _UPDATE_ALLOWED["redis"] == {"maxmemory"}`
   (`jit-controller/main.py:767-780`), so forcing `on_create=False` everywhere is
   observationally identical for S26; group 4's refusals (S26.sh:114-123) are on a
   provisioned claim and pass either way. (b) Nested clearing: S26 never uses a nested param
   — every assertion reads `.spec.params.maxmemory` or `.status.appliedParams.maxmemory` —
   and no group asserts that *any* removed key, top-level or nested, clears from
   `appliedParams`/`spec.params`. Restoring top-level-only nulling keeps all nine groups
   green. Per the verdict rules this is a Concern rather than a Blocker because ADR 0025
   does not claim S26 asserts the fixes (`docs/decisions/0025-...md:50-52` says S26 "creates
   redis claims with `maxmemory`/no params and asserts the update refusals, which the create
   allowlist preserves"), but the wording "S26 ... is the gate" invites exactly that
   misreading, and after this range no gate in the repo covers either change.

2. **The pgadmin create path this ADR exists to protect has no evidence in the range
   (Q9, Q11).** ADR 0025:45-47 asserts "pgadmin's `http_port` still provisions, so
   `voting-b` and the J-suite's J8 are unaffected", but S26 never creates a pgadmin claim and
   S29/J8 were not run in this range. A mistake in `_CREATE_ALLOWED["pgadmin"]` or in the new
   `http_port` value check (e.g. a range that rejects 5051) passes S26 silently — the same
   regression ADR 0020 caused and this ADR is careful not to repeat. Actionable: run
   `scripts/checkpoint.sh 29` (or J8 via `make jit-verify`) before treating that consequence
   line as verified.

3. **ADR 0025 describes a create surface the code does not implement (Q11).** Decision:
   "the create surface encodes exactly the declared params" (`0025:40`) and the code comment
   "The create surface: the module's declared inputs" (`main.py:771-772`) are both false as
   written: pgadmin also declares `share_dir`, `postgres_port`, `pgadmin_email`,
   `pgadmin_password` (`jit-modules/modules/pgadmin/variables.tf:22,41,59,65`) and postgres
   declares `service_name` (`jit-modules/modules/postgres/variables.tf:40`); none is in
   `_CREATE_ALLOWED`, so a declarer annotation carrying any of them is refused on create as
   "unknown key for module ...". ADR 0025:53-55 then says the surface is "deliberately the
   small, declared surface, not 'anything'", contradicting its own Decision line. Nothing
   live breaks — I checked every `jit.infra/*` params value in `app/kustomize/`
   (base `params:{}` ×3, voting-b `http_port:5051`) and every `params` in `scripts/checks/*.sh`
   and `scripts/verify-jit.sh` (only `maxmemory`, `databases`, `{}`, and runner-direct
   identity params that never pass through the controller) — so `http_port` *is* the only
   module-declared param a create needs today. The ADR/comment wording is what is wrong.

4. **The rule-3 reading is attributed to text that does not say it (Q11).** Design rule 3
   (`docs/designs/declarers-and-consumers.md:86`) is scoped to *disagreeing declarers* —
   "On a new claim, first-writer-wins stays as today, so create behaviour is unchanged" — it
   says nothing about validating keys. ADR 0025:37-40 re-reads that sentence as "the module's
   declared params are applied as given on create"; the fair citation for create validation
   is the contract table itself (`:112` unknown key → Refused, `:114` values validated before
   any runner call), which the ADR never quotes. The behaviour is defensible and sanctioned
   by HANDOFF P0.3; the justification as written will not survive a reader opening rule 3.
   Related: ADR 0020's *Decision* bullet "Call `validate_params` only when the claim is
   already provisioned" (`0020:45`) is what this range overturns, but ADR 0025 quotes only
   0020's Consequences sentence, and ADR 0020 itself carries no forward pointer to 0025 (it
   was outside the allowed-touch list). A reader of 0020 alone is still told create is exempt.

5. **A refused create's teardown sends the refused key to the runner (Q10, Q11 — a
   consequence the diff introduces and ADR 0025's consequence list does not mention).**
   `reconcile_claim` projects before it validates: `_project_spec_params` at `main.py:1060`,
   `validate_params` at `main.py:1096`. The refusal returns at `main.py:1098-1101` with no
   `status.appliedParams` ever written, while `spec.params` (also seeded from the annotation
   at claim creation, `main.py:157`) holds the refused key. `_destroy_params` is
   `appliedParams or spec.params` (`main.py:947`), so teardown falls back to the poisoned
   dict. Path: declarer Deployment deleted → resync sees no refs and `phase != "Orphaned"` →
   a never-provisioned claim is set `Orphaned` + `expiresAt` (`main.py:1375-1386`) → the sweep
   calls `destroy_infra(..., _destroy_params(status, spec))` (`main.py:1417-1418`), hard delete
   does the same (`main.py:1441-1442`) → the real module rejects the undeclared var →
   `main.py:1426-1429` "claim stays Deleting — will retry next tick" every 30s, forever, and
   `release_block` never runs. Before this diff the same typo'd create ended identically
   (it provisioned, and `appliedParams` itself carried the typo), so severity is unchanged —
   but the invariant the code states at `main.py:925-927` ("a refused key would then travel
   into the destroy call") still holds only for the update path, and ADR 0025 does not list
   what a refused claim's end of life looks like.

## Notes

- **`_merge_patch` is correct (Q8).** I ran eleven edge cases through the real function:
  old-dict→new-scalar returns the scalar (replace); old-scalar→new-dict returns the new
  dict; `new = {}` nulls every top-level key; `new = {"settings": {}}` yields
  `{"settings": {"work_mem": None}}`; a removal at depth 3 yields
  `{"a": {"b": {"d": None, "c": 1}}}`; a key added at depth is set; non-dict `new` is
  returned wholesale; a `None` value in `new` is preserved (not nulled). Applied under
  RFC 7386 these clear removed keys at every depth and never null a key present in `new`.
  Only oddity: an unchanged deep subtree is re-sent verbatim (`{"a": {"b": 1}}`) — a
  redundant write of identical values, harmless.
- **`http_port` value check (Q9)** accepts int and numeric string (`int(str(...))`),
  rejects bool/float/None (all raise `ValueError`), and range-checks 1-65535; voting-b pins
  integer `5051`. The check is unreachable on the update path (the allowlist loop rejects
  `http_port` for pgadmin before it, `main.py:796-800`) — dead but harmless.
- **Refused-create surface, quoted (Q10):** condition `UpdateRefused=True`, reason
  `RefusedKey`, message `f"{bad_key}: {reason}"` (`main.py:1099-1100`); phase is *not*
  written, so a declarer-first refused claim keeps the empty phase `ensure_claim` creates
  (`main.py:211`) and still holds the `allocatedIP` handed out at `main.py:242`. Re-runs come
  from Deployment events and the 30s timer (`main.py:1346`) but `set_condition` short-circuits
  an identical status+message (`main.py:1145-1146`) and the `return` precedes
  `claim_lock`/`provision_infra` (`main.py:1109-1128`) — no runner call, no status churn, no
  hot loop. A consumer-only new claim never reaches validation (early return
  `main.py:1025-1039`) and stays `Pending`/`AwaitingDeclarer`, which is unchanged.
- A `Failed` claim (apply never succeeded) is validated against the *create* surface, because
  `on_create = not provisioned` and `Failed` is not `Ready`/`Orphaned` — so an `http_port`
  edit on a failed pgadmin claim is admitted where the same edit on a `Ready` one is refused.
  Defensible (nothing was ever applied) but not stated by the ADR.
- S29's U7/U8 really do run on provisioned claims (`scripts/checks/S29.sh:130-149`), so
  ADR 0025:52's "unaffected" is accurate; I did not run S29 (S26 only, as instructed).
- The committed `docs/evidence/S26.log` header reads `commit 4051846, pending 3` — captured
  before the code was committed. My run at `commit b4e7a7c, pending 0`, exit 0, is the clean
  confirmation that the committed code passes.
- Maintaining this (Q12): yes — two explicit allowlist dicts and a 12-line pure
  `_merge_patch`, each docstring naming the exact failure it fixes.

## Checkpoint assessment

`scripts/checkpoint.sh 26 /tmp/S26-review.log` passed on my clean run: exit 0, nine groups
(`1 ok declarer resolution` … `9 ok stale Updating recovered`, `PASS S26: nine
resolution/contract/flow groups asserted against the stub`), header `commit b4e7a7c`,
`pending 0`; the in-cluster controller was restored to 1 replica and the `jit-stub`/
`jit-stub-consumer` scratch namespaces are gone (verified with kubectl), and
`docs/evidence/S26.log` is unchanged (`git diff` empty) — the run went only to my private
log. The checkpoint asserts this step's goal only indirectly: it gates the *update*
contract (group 4's `banana` value and `wikijunk` key refusals, group 5's `appliedParams`
write) that the two-allowlist split must not disturb, but it never creates a pgadmin claim,
never uses a nested param, and never drops a key from `appliedParams`, so it would still
pass with `on_create` forced to the update allowlist or with `_merge_patch` reverted to
top-level-only nulling (Concern 1). The step made no claim that S26 asserts the new
behaviour, so under the verdict rules that is a Concern, not a Blocker.

Verdict: CONCERNS
