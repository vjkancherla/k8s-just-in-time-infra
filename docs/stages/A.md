# Stage A - The pipeline skeleton and the risky substrate

## What works now

The pipeline file exists with its two jobs, and both have gone green on an ordinary hosted machine. The fast checks reproduce the local baseline there, and the cluster's fixed network addresses work there too — the one thing about the whole design that was genuinely unknown is now known.

## Steps

- [CI01 - The fast half is green locally, and the runner can be dispatched](../steps/CI01.md)
- [CI02 - A stock runner can host the cluster's fixed network](../steps/CI02.md)

## Checks

CI01 6 of 6 and CI02 11 of 11, each green on its own checkpoint run (see `docs/evidence/CI01.log`, `docs/evidence/CI02.log`).

## Checks that changed

- CI02 - corrected: expected `SUCCESS` from the runner tool, which actually reports `success`. Proves the same.

## Plan changes

None.

## Different from the design

- The console's read model now tolerates a missing secrets file instead of crashing on it: the hosted machine has none, the maintainer's machine always did, and the fast job found the gap in its first red run.
- The fast job installs the build tool the hosted machine lacks; the design assumed the image had everything but the test runner.

## For you to decide

Nothing.

## Review

Different model, new session:

    Read and follow docs/REVIEW-PROMPT.md for 4bf350a..3be107b
