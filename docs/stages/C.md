# Stage C - The full e2e job

## What works now

One hosted job builds the controller, runs the whole cold path to seventeen green checks, then the console suites and the eleven lifecycle checks, all inside a three-quarter-hour ceiling. When anything fails, the logs and reports are uploaded where the failure can be read afterwards.

## Steps

- [CI04 - The e2e job runs the cold path](../steps/CI04.md)
- [CI05 - The e2e job runs the console and J suites](../steps/CI05.md)

## Checks

CI04 9 of 9 and CI05 11 of 11 on their checkpoint runs (see `docs/evidence/CI04.log`, `docs/evidence/CI05.log`).

## Checks that changed

None. The failure-evidence check was satisfied by an earnest red run rather than a staged one — stronger proof of the same claim.

## Plan changes

None.

## Different from the design

- The object-storage image comes from an actively maintained mirror: the upstream image is unpullable from every anonymous registry, which broke fresh hosts, not just CI. Chosen by the maintainer over mirroring the cached image or wiring a login.
- The runner container now receives the secrets-file credentials instead of relying on its baked-in defaults, which only ever matched one secrets file. Without this no fresh set of credentials could provision anything.
- A failed run also dumps the cluster state (pods, claims, runner and controller logs) into the evidence, because the first red cold path could not be read from the step logs alone.
- One check stopped racing its own pipe: it now reads the whole stream instead of quitting early, which failed only on the faster machine.

## For you to decide

Nothing.

## Review

Different model, new session:

    Read and follow docs/REVIEW-PROMPT.md for b4fe07d..73de9eb
