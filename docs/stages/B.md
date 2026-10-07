# Stage B - Portability migration

## What works now

The images build natively on either chip and the image check judges broken images instead of foreign ones. A build on the maintainer's machine still produces the same chip as before, and the lifecycle suite's bar did not move.

## Steps

- [CI03 - The repo builds and the R-suite can pass on amd64](../steps/CI03.md)

## Checks

CI03 12 of 12 on its checkpoint run (see `docs/evidence/CI03.log`), including the shipped gate executed against stub answers for four scenarios.

## Checks that changed

None.

## Plan changes

None.

## Different from the design

Nothing. The three edits match the plan's table line for line.

## For you to decide

Nothing.

## Review

Different model, new session:

    Read and follow docs/REVIEW-PROMPT.md for 3be107b..b4fe07d
