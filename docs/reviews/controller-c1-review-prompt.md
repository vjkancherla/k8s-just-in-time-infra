# Review prompt — controller create validation + nested-key clearing (ADR 0025; ADR 0023 concerns 2-3)

You are reviewing work you did not do and have no stake in.

A different model fixed two controller items from `docs/HANDOFF.md` P0.3. Your job is to
find what is wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no "while I
was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If it
has fewer, or reads like a summary, stop and write a findings file with verdict BLOCKED and
the single blocker "review prompt was abbreviated".

## What the step was supposed to do

1. **Nested `settings` key never clears.** `patch_applied_params` (and its sibling
   `_project_spec_params`) cleared only top-level removed keys, so a dropped nested
   `settings` key survived a JSON merge patch; the resync saw applied != desired and
   re-applied every tick.
2. **Create path unvalidated.** `validate_params` was called only when a claim was already
   provisioned, so a brand-new claim with an unknown/typo'd key was silently recorded as
   applied (ADR 0020 accepted this consequence). Fix it without breaking pgadmin's
   module-declared `http_port`, which the voting-b overlay pins.

The step carries `docs/decisions/0025-create-validation-and-nested-clear.md`, which
supersedes ADR 0020's create-scope consequence and extends its appliedParams-clearing
decision. `scripts/checkpoint.sh 26` passes; its log is committed.

## What the step was allowed to touch

```
jit-controller/main.py
docs/decisions/0025-create-validation-and-nested-clear.md
docs/evidence/S26.log
```

## What to read

- `docs/HANDOFF.md` P0.3 - the two items, in full
- `docs/decisions/0025-create-validation-and-nested-clear.md` - the ADR under review
- `docs/decisions/0020-s29-ttl-maximum-and-create-contract-scope.md` - the decision being
  superseded
- `jit-controller/main.py` - `validate_params`, `_merge_patch`, `patch_applied_params`,
  `_project_spec_params`, and the validation call in `reconcile_claim`
- `git diff 4051846..b4e7a7c` - what was actually done
- `scripts/checks/S26.sh` - the checkpoint that passed

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required.
2. Did it add a dependency the step did not name? Blocker. (Stdlib is not a dependency.)
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
5. Did it tick a box in `docs/todo.md`? Blocker.

## Then, run it

6. **Run `scripts/checkpoint.sh 26 /tmp/S26-review.log` yourself.** Does it pass *now*? A
   pass for the implementer that fails for you usually means leftover state. (S26 scales the
   in-cluster controller to 0 for the duration and always scales it back.)
7. **Read S26.** Does it assert either fix? Would it still pass with the nested-clear change
   reverted, or with `on_create` forced to the update allowlist? Say what is and is not
   gated.

## Then, on substance

8. **`_merge_patch`.** Is the recursion correct JSON-merge-patch semantics for clearing
   removed keys at every depth? Test edge cases: a key present in both where old is a dict
   and new is a scalar and vice versa; `new = {}`; `new = {"settings": {}}`; a key added at
   depth; a non-dict `new`. Does it ever leave a removed nested key behind, or null a key
   that should survive?
9. **Create validation.** Is the two-allowlist split (`_UPDATE_ALLOWED` vs `_CREATE_ALLOWED`)
   sound? Does `on_create=not provisioned` match the ADR's intent? Is pgadmin's `http_port`
   the *only* module-declared param the create path needs (check every annotation in
   `app/kustomize/` and every `scripts/checks/S29.sh` create)? Does the value check (integer
   1-65535) hold? Are identity keys still refused on create?
10. **Behaviour change.** Where does the new create refusal surface, and what does a refused
    brand-new claim do (phase? condition? does it retry forever?). Does it reach the runner
    at all? Quote the paths.
11. **ADR 0025.** Is its supersession of ADR 0020 accurate and complete? Does it state a
    consequence the diff does not implement, or miss one the diff introduces? Is reading
    rule 3 as "the module's declared params on create" fair to the design?
12. **Would you be able to maintain this?** One line.

## Output

Write `docs/reviews/controller-c1-review-findings.md`:

    # controller create-validation/nested-clear review (4051846..b4e7a7c)

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S26 pass on your clean run? does it assert this step's fixes? one paragraph.>

Verdict rules:
- Any mechanical finding (1-5) → BLOCKED
- A checkpoint fails when you run it → BLOCKED
- A checkpoint would pass with the logic removed **and the step claimed it asserted the
  fix** → BLOCKED; the step made no such claim, so say it as a Concern instead
- A design disagreement that changes behaviour → BLOCKED
- Everything else → CONCERNS or CLEAR

If you find nothing, say CLEAR and say what you checked. "Looks good" is not a review.

Do not start the next step. Do not offer to.
