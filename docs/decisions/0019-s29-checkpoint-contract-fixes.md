# 0019. S29 checkpoint contract fixes after the first end-to-end run

Date: 2026-09-29
Status: accepted

## Context

S29 is Stage H's gate: its **Do** is "nothing new - run the frozen checkpoint", and
`scripts/checks/S29.sh` is the design's U1-U13 table (`docs/designs/declarers-and-consumers.md`
§Verification). The checkpoint was written and frozen in S22 and, unlike S23-S28, had never
been executed to completion against a built controller and a running pair of tenants.
Running it now against the S28 tenant shape and the S26-S27 controller exposed four places
where the frozen script cannot pass a correct implementation, independent of the code:

1. **U1's IP assertion can never be true.** It compared
   `docker inspect -f '{{.NetworkSettings.IPAddress}}'` with `status.endpoint`. The former is
   empty because both module containers sit on the user-defined `k3d-voting-app` network (the
   address is only under `.NetworkSettings.Networks`), and the controller writes
   `status.endpoint` as `<address>:<port>` (`jit-controller/main.py`, the
   `"endpoint": f"{address}:{port}"` patch). The design's U1 asserts the **IP** is unchanged;
   that IP is `status.allocatedIP`.
2. **U5 deletes `voting-app-vote` and never restores it.** U9, U10, U11 and the suite gate
   below all annotate or drive that same Deployment, so from U5 onward every step that names
   it fails on `NotFound`. The EXIT trap's `annotate`/`scale` cannot recreate a deleted
   Deployment.
3. **U6's "declarer" is not a declarer.** The `declarer-comes` Deployment annotates redis as
   `{"module":"redis","softDeleteTTL":"10m"}` - no `params` key. The design's role rule is that
   the **presence** of `params` (including `params:{}`) declares and its absence consumes
   (§Terms), and "no consumer is ever promoted to declarer" (rule 4). So the claim it is
   supposed to drive to `Ready` stays `Pending`+`AwaitingDeclarer` forever.
4. **The suite gate runs R3 with the demo toggle on.** The precondition is `make demo-up`,
   which sets `ALLOW_MULTIPLE_VOTES=true` after its own verify. R3 asserts the
   one-vote-per-browser behaviour, so under the demo toggle every click is a new voter and R3
   fails by design. The gate must run the R-suite in the mode R3 tests, not the demo mode.
5. **The trap restores the pre-S28 shape.** It re-annotates `vote`'s redis and `worker`'s
   postgres without `params`, which by the role rule turns the S28 declarers into consumers -
   the opposite of the migration S28 committed.

## Decision

Amend `scripts/checks/S29.sh` through this ADR, exactly as follows, and commit it with the
edit. Every change is a correction to a locator or a setup error, not a softening: the
assertions' intent and failure messages are unchanged, and U1-U13 still fail readably with
nothing implemented.

- **U1** ranges over `.NetworkSettings.Networks` and compares against
  `status.allocatedIP` (the IP the design names). The `status.endpoint` comparison is
  dropped; the existing Secret-bytes omission remains parked by ADR 0005.
- **U5** snapshots the `voting-app-vote` Deployment to `/tmp/s29-vote.json` before deleting
  it, and after the `NoDeclarer`/`appliedParams`/no-runner assertions re-applies it with the
  server-side metadata stripped. The restored annotation is the U1 one
  (`maxmemory: 128mb`), which equals `appliedParams`, so the restore makes no runner call and
  U9-U11 and the gate can run.
- **U6** gives `declarer-comes` `"params":{}` - a declarer of the module defaults, which is
  what the check's own `Ready once declared` line requires.
- **The gate** disables `ALLOW_MULTIPLE_VOTES` on `voting-app-vote`, waits for the rollout,
  runs `make verify NS=voting-a`, then restores the demo toggle. The trap also restores it.
- **The trap** re-annotates `vote` redis and `worker` postgres with `"params":{}`, the S28
  declarer shape.

## Consequences

**Easy.** A correct S26-S28 implementation can satisfy the gate; the U-table is runnable end
to end for the first time; the trap leaves the tenant in the shape S28 committed rather than
silently demoting its declarers.

**Hard / ruled out.** `scripts/checks/` is frozen; this is the ADR that changes S29 and no
other checkpoint. ADR 0005's parked concerns (U1's Secret-byte check, U7's `postgres_db`
variant, U3/U13 timestamps) remain parked - this decision fixes the four defects that stop a
correct implementation from passing, not the U-table's coverage. Any further S29 change needs
another ADR.
