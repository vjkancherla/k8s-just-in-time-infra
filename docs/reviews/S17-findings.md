# S17 Review

Reviewer model: Claude (Cline)
Verdict: CONCERNS

## Blockers
None.

## Concerns

1. **S17's implementation commit (`99a1397`) creates three files not in the allowed
   list.** The allowed list names `Makefile`, `README.md`, `scripts/verify-jit.sh`,
   `scripts/checks/S17.sh`, and the two kustomization overlays. The implementation
   commit also adds `RUNBOOK.md`, `scripts/jit-down.sh`, and `scripts/jit-up.sh`. All
   three are necessary for the Makefile targets the step was told to add (`jit-up` wraps
   `jit-up.sh`, `jit-down` wraps `jit-down.sh`, and `RUNBOOK.md` is referenced by the
   README). The allowed list appears incomplete rather than the implementation
   over-scoped — but the list should have been wider, or the commit split, so the
   mechanical test is ambiguous. No new dependencies, no weakened assertions, no
   checkpoint modifications.

2. **The diff range `a82a6a9..e7ef515` spans eight commits across multiple steps, not
   just S17.** It includes `15991b5` (committing S01-S07 checkpoint scripts and the
   voting app sources), `9f72b30` (pinning the demo to the voting-a overlay), and four
   post-S17 bug fixes. This makes the mechanical checks (Q1–Q5) harder to attribute
   cleanly. The `scripts/checks/S01-S07.sh` additions and the `app/` source additions
   are from the repo chore commit, not from S17. A narrower range (e.g. `99a1397` only,
   or `99a1397..e7ef515` to include the fixes) would have been clearer.

3. **`docs/todo.md` was modified beyond ticking the check box.** The diff adds a new
   "Tenants never run in `default`" item to the top-level checklist, rewrites S16's
   evidence paths from `/tmp/` to `docs/evidence/`, and adds extensive S17 documentation
   (the checkpoint run, race-test evidence, cold-path evidence, the volume fix, the
   `var.share_dir` decision). The review box `[ ]` is correctly left unticked. The
   documentation is useful but exceeds "tick a box."

4. **The `verify-jit.sh` script (613 lines) is long for a single file.** The J11 MinIO
   check alone embeds ~60 lines of inline Python with AWS SigV4 signing. A maintainer
   who did not write it would need time to locate any given J-check. The helpers at the
   top (render_ns, wait_phase, etc.) are well factored; the J-check bodies are linear
   and readable. Intent is recoverable, but the file would benefit from being broken into
   per-check functions or a helper library if the suite grows.

## Notes

- The diff's Q4 concern about out-of-scope files is dominated by the repo chore commit
  (`15991b5`), which committed the voting app sources and the S01-S07 gates — work from
  steps that predated S17. Those files are not S17's responsibility.
- The `app/Makefile` default change (`NS ?= voting-a`, `KUSTOMIZE_DIR ?=
  ./kustomize/overlays/voting-a`) is from `9f72b30`, a post-S17 fix. It prevents a bare
  `make all` from landing in `default` and fighting voting-a for the Ingress host. This
  is a correctness fix, not scope creep.
- `namespace_lock(ns)` in `ipam.py` fixes a real race: J1 intermittently handed two
  claims the same IP address. The lock is process-local (not cluster-wide), which is
  correct for the PoC's single-controller setup but would need rethinking for HA.
- J11's two repairs (S3 prefix encoding `ns%2F` instead of `ns/`, and adding a `pass`
  line for a check whose assertions are all negative-fail) are well-documented in the
  commit message and the todo.md review section.
- The `var.share_dir` default (`/tmp`) is a deliberate PoC shortcut documented in the
  README's escape-hatch section. It would be wrong in any non-single-host deployment.

## Checkpoint assessment

`scripts/checks/S17.sh` passed on a clean run of the current working tree with
`EXIT_CODE=0`. Output (tail):

```
PASS: make jit-verify exited 0 and wrote .workflow/verify-jit.md
PASS: J1-J11 all PASS in .workflow/verify-jit.md
PASS: voting-a runs the migrated app on three containers, no StatefulSet, no PVC
PASS: ===== 17 PASS, 0 FAIL ===== in voting-a
PASS: S17 - two namespaces, J1-J11 and the R-checks both green
```

J1–J11 all PASS, R1–R17 all PASS in voting-a. The checkpoint asserts S17's goal: it
requires the root Makefile to declare `jit-up`, `jit-verify`, `jit-down` and `check`;
it requires `make check STEP=15` to route to `scripts/checks/S15.sh`; it runs the full
J1-J11 suite and requires all eleven to pass; and it runs `make verify` in `voting-a`
and requires `17 PASS, 0 FAIL`. It would not pass with S17's core logic removed: without
`verify-jit.sh`, `make jit-verify` would fail; without the Makefile targets, the
precondition checks would fail. The checkpoint was written in S-1 (before S17), is
frozen, and was not modified by S17. It is a genuine gate.
