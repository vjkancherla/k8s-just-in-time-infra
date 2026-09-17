Updated: 2026-09-17

## Current focus
The plan is closed and nothing is in flight. This session added two standalone docs: controller-explained.html
(a deck on the JIT controller) and deletion-lifecycle.html (the lifecycle, with a clock simulator).

## Blocked
- Nothing blocks work. Stage G and the plan's Done list are closed; the nine unticked boxes are explained
  in docs/todo.md rather than ticked.

## Done (verified)
- docs/controller-explained.html: 14 slides, self-contained, reusing how-it-works-presentation.html's palette
  and deck JS. Every slide measures zero overflow at 1440x900, 1280x720 and 1024x768 (headless Chrome), and
  the tags balance (HTMLParser: no unclosed, no mismatched).
- The admission-controller question answered by inspection: no webhook, no ValidatingWebhookConfiguration, no
  ValidatingAdmissionPolicy anywhere. The gate is the absent jit-<module> Secret, leaving the pod in
  CreateContainerConfigError - a choice docs/jit-infra-poc.md:219-223 already recorded.
- Stage G's gate on a live cluster: `make demo-up` -> "17 PASS, 0 FAIL", then `make check STEP=18` -> 12 ok
  lines, PASS, exit 0 (docs/evidence/s18-stage-g-gate.log).
- Build-plan's Done list is closed and docs/todo.md has "The boxes". docs/timeline.html draws a real run on
  five lanes; docs/deletion-lifecycle.html draws the lifecycle with a clock simulator;
  docs/annotation-to-state.html resolves the naming chain for every namespace and module.

## Checkpoints
- S18 PASS (amended) at eecb02e. S19, S20, S21 each ticked + CLEAR. S17 untouched.

## Next step
Nothing is in flight. If work resumes, S22 (live lanes - kopf.info() in the controller plus a console step) is
the only unwritten item; write its checkpoint first.

## Watch out
- None of the three docs/*.html pages has a make target: S18's checkpoint asserts `make targets` prints
  exactly 14 names. README links all three in its walkthrough, Layout tree and Key documents table.
- S19's frozen checkpoint permits the page to call only /state, /claim, /log and /run, so a /timeline route
  fails it; live lanes (S22) also need kopf.info() in the controller.
- `make timeline` stays on demand: S21's checkpoint asserts it is not a key in the 2s /state poll.
- The host is clean after `make destroy`; a live-cluster checkpoint needs `make demo-up` (~3 min) first.
- Events sort by `t` as text, the frozen checkpoint's own order.
- `app/opencode.jsonc` is ignored but on disk with a live-looking DeepSeek key; rotate it if it moves.
- `refs/cline/checkpoints/*` snapshot `.env` and `terraform.tfstate`; never `git push --all`/`--mirror`.
