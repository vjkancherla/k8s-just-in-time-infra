# 0022. Runner destroy accepts structured params, so the postgres teardown completes

Date: 2026-09-29
Status: accepted

## Context

S29's gate runs the J-suite. Its `reset_ns` tears both tenants down by removing the claims'
finalizers and deleting them, which fires the controller's delete handler and the runner's
`DELETE /v1/runs/<workspace>`. For `voting-a/postgres` the destroy body carries the claim's
applied params, including `databases` as a JSON list. `DestroyRequest.params` was still typed
`Dict[str, str]` (`jit-runner/main.py`), so FastAPI rejected the request with **422 before the
handler ran**: the container and the `postgresql_*` state leaked. The J-suite then re-applied
`voting-a` fresh, and `tofu apply` tried to refresh `postgresql_database.this["analytics"]`
against the address of the removed container - `dial tcp 172.19.0.100:5432: connect: no route
to host` - so J1 failed and the gate stopped.

This is the latent bug S24's review named and parked (concern 1): "`DestroyRequest.params` was
not widened with `RunRequest.params` ... a cold destroy ... is rejected with a 422 before the
handler runs", which "does not fire today ... no client sends non-string destroy params". S26
made the controller send structured values, so it fires now. `_var_args` already JSON-encodes
lists and objects for `-var`, so widening the type is the fix S24 prescribed.

## Decision

Change `jit-runner/main.py`'s `DestroyRequest.params` to `Dict[str, Any]`, the same type as
`RunRequest.params` and what `docs/designs/runner-api.md` documents ("Same as POST"). No
handler change: `delete_run` already passes `params` through `_var_args`.

## Consequences

**Easy.** A cold or warm destroy carrying `databases`/`settings` reaches the handler and
completes; the J-suite's reset tears postgres down cleanly, so its state no longer leaks into
the next apply. The destroy body finally matches the documented "Same as POST" contract.

**Hard / ruled out.** Destroy now accepts arbitrary JSON param values; the runner's own
`_var_args` still decides how each reaches tofu, and the controller still overwrites
`name`/`network`/`ip` after the tenant params, so a malformed value cannot redirect the
teardown at the wrong container. The runner image must be rebuilt (the Python is baked in).
