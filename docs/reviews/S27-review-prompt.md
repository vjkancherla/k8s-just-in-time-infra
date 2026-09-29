# S27 Review - review prompt (generated, do not abbreviate)

Copied from `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` with the six slots substituted
verbatim: the step (S27), the step number (27), the topic
(`designs/declarers-and-consumers.md`), the goal (word for word from
`docs/build-plan.md` S27), the commit range (`48b7ee5..b7fc0cc`), and the files the
step named as its scope (one path per line), plus the ADR-sanctioned files below.
Deviations, marked inline: ADR 0015 and ADR 0017 notes on Q1 (two checkpoint
amendments), ADR 0016 on Q8/Q9 (the design's initial-database import), and a Q10 note
on `b7fc0cc` (the post-fix `service_urls` output). Add nothing else.

=== BEGIN REVIEW PROMPT ===
You are reviewing work you did not do and have no stake in.

A different model implemented step S27 of a build plan. Your job is to find what is
wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no
"while I was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If
it has fewer, or reads like a summary, stop and write a findings file with verdict
BLOCKED and the single blocker "review prompt was abbreviated - regenerate from template
verbatim".

## What the step was supposed to do

**Goal:** the mutability contract becomes executable: postgres databases as
`postgresql_database` `for_each` resources against the running server, allowlisted
settings as `-c` flags in the command, `service_url_<db>` Secret keys, and the v2
destroy path proven against the real runner.

## What the step was allowed to touch

jit-modules/modules/postgres/main.tf
jit-modules/modules/postgres/variables.tf
jit-modules/modules/postgres/outputs.tf
jit-modules/modules/redis/main.tf
jit-runner/main.py
docs/evidence/S27.log
docs/decisions/0015-s27-checkpoint-mechanics-fixes.md
docs/decisions/0016-postgres-initial-database-managed-additively.md
docs/decisions/0017-s27-checkpoint-service-url-word-match.md
scripts/checks/S27.sh

`docs/reviews/S27-review-prompt.md` is review machinery (it is the file you are reading);
it appears in the range because the prompt is regenerated after the code commit and does
not count against Q4.

## What to read

- `docs/designs/declarers-and-consumers.md` - the design this must conform to
- `docs/build-plan.md` - step S27, its checkpoint, its gate
- `git diff 48b7ee5..b7fc0cc` - what was actually done
- `scripts/checks/S27.sh` - the assertion that passed
- `docs/decisions/0015-s27-checkpoint-mechanics-fixes.md` and
  `docs/decisions/0017-s27-checkpoint-service-url-word-match.md` - the two checkpoint
  amendments this review must assess
- `docs/decisions/0016-postgres-initial-database-managed-additively.md` - the decision
  that supersedes the design's import block
- `docs/decisions/0007-maxmemory-mutable-despite-replace-cost.md` - the step's binding
  context: redis `maxmemory` is mutable, and its side finding (the `ports { external = 0 }`
  forced replacement) is the one S27/M-U2 had to address

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required. Checkpoints are frozen; a newly
   created one is still a finding worth raising.
   - *S27 note:* the range touches `scripts/checks/S27.sh`, sanctioned by ADR 0015 in
     `bf14673` (four unsatisfiable harness defects: the host cannot reach the runner at
     `172.19.0.10:8080`, only its published `127.0.0.1:8100`; the POST omitted
     `Content-Type: application/json`, which FastAPI 422s, as ADR 0008 recorded for S24;
     the postgres container/volume were named `$WS-pg`/`$WS-pg-data` where the module and
     every other consumer spell `-postgres`; the destroy status was grepped as `success`
     where the runner returns `destroyed`) and by ADR 0017 in `eb95115` (the output-key
     list was space-joined, so `grep -qx "service_url"` could never match a multi-key
     line; it is now one key per line). Both ADRs are committed with their edits. No
     assertion is deleted or weakened — fixing the volume pattern makes a check that
     silently matched nothing real. Judge the ADRs as decisions, not the edit as a
     violation.
2. Did it add a dependency the step did not name? Blocker.
3. Did it delete or weaken an existing test or assertion? Blocker.
   - *S27 note:* the postgres module now requires `cyrilgdn/postgresql`, which the design
     names (`declarers-and-consumers.md:167`) and S27's Read/Do name. The redis module
     drops its `ports` block and the runner loses no capability; no test or assertion is
     removed.
4. Did it create or edit files outside the list above? Blocker.
5. Did it tick a box in `docs/todo.md`? The review box is not the implementer's to tick.
   Blocker.
   - *S27 note:* no `docs/todo.md` change is in the range.

## Then, run it

6. **Run `scripts/checks/S27.sh` yourself.** Does it pass *now*, on the current working
   tree?
   - If it fails: **blocker**. A checkpoint that passed for the implementer and fails for
     you usually means the step only worked because of leftover state.
   - *S27 note:* the stated precondition is the runner container up (`make jit-up`) and
     docker reachable; no tenants and no cluster work is needed. It drives the runner at
     `127.0.0.1:8100` and creates a fresh `s27-check` workspace, so a clean run needs no
     leftover state. Run it with a private log:
     `scripts/checkpoint.sh 27 /tmp/S27-review.log`.
7. **Now read the checkpoint.** Would it still pass if the core logic of this step were
   deleted or stubbed out? If yes it is asserting nothing - **blocker**.
   - *S27 note:* the four groups assert a database added in place with the container id
     unchanged (`docker inspect .Created`), a settings change replacing the container with
     the named volume and its rows surviving, a destroy after the container is pre-removed
     (which only succeeds because the runner runs `tofu state rm postgresql_*` first), and
     the `service_url`/`service_url_analytics` keys. Judge whether the additive-database
     and volume-survival assertions fail if the `postgresql_database` wiring or
     `remove_volumes = false` were removed.
8. **Where does the implementation disagree with the design?** Quote both.
   - *S27 note (ADR 0016):* the design (`declarers-and-consumers.md:170`) says the initial
     database is brought into state by an **import block**. An import is evaluated during
     plan, before any resource is applied, and refuses a non-existent target; measured on
     this host with OpenTofu 1.8.1, an import for a volume the same apply creates fails
     `plan` with "Cannot import non-existent remote object". The module therefore leaves
     `postgres_db` initdb-owned and manages only `setsubtract(var.databases,
     [var.postgres_db])`; `tofu` in the runner image is 1.8.1 (`jit-runner/Dockerfile:7`),
     so `for_each` is supported and the import was dropped, not faked. Judge ADR 0016.
9. **What does the design require that the diff does not do?**
   - *S27 note:* the import block is the one named requirement not implemented; ADR 0016
     records why and what replaces it. The destroy path's `state rm` is S24's and is
     exercised, not changed.
10. **What does the diff do that the design does not mention?** Scope creep is a finding
    even when the code is good.
    - *S27 note:* the runner switched to `tofu output -json` and flattens a map output to
      `service_url_<db>`. The design names the Secret keys but not the mechanism; Terraform
      cannot name outputs dynamically, so the runner is the adapter. Judge whether that is
      in-scope and correct. Commit `b7fc0cc` narrows `service_urls` to
      `setsubtract(var.databases, [var.postgres_db])`, so the initial database is exposed
      only as the separate `service_url` key and no redundant
      `service_url_<postgres_db>` is added — matching the design's "existing keys,
      including `service_url` for the initial database" (`:172`) and the checkpoint's
      U2 shape. Judge that too.
11. **What are the failure modes of this code that neither the design nor the checkpoint
    covers?** And what would you attack first, if you wanted this to misbehave?
12. **Would you be able to maintain this?** One line. Not style preferences - whether the
    intent is recoverable by someone who did not write it.

## Output

Write `docs/reviews/S27-findings.md`:

    # S27 Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S27.sh pass on a clean run? does it actually assert the step's goal?
    one paragraph.>

Verdict rules:
- Any mechanical finding (1-5) → BLOCKED
- Checkpoint fails when you run it → BLOCKED
- Checkpoint would pass with the logic removed → BLOCKED
- Design disagreement that changes behaviour → BLOCKED
- Everything else → CONCERNS or CLEAR

If you find nothing, say CLEAR and say what you checked. "Looks good" is not a review.

Do not start the next step. Do not offer to.
=== END REVIEW PROMPT ===
