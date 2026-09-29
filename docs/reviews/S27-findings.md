# S27 Review

Reviewer model: deepseek-v4-pro
Verdict: CONCERNS

## Blockers

None.

Mechanical checks (1-5) all pass: the range touches `scripts/checks/S27.sh` only via
ADR 0015 (`bf14673`) and ADR 0017 (`eb95115`), both committed with their edits and both
assessed below as sound mechanics fixes that strengthen, not weaken, the frozen
assertions; the `cyrilgdn/postgresql` provider is named by the design
(`declarers-and-consumers.md:167`) and by S27's Read/Do; no test or assertion is deleted
(redis/postgres dropping their `ports` block is the ADR 0007 side-finding fix, not a
removed assertion); every file in the range is on the allowed list (or is the review
prompt, exempt); and there is no `docs/todo.md` change.

The checkpoint passes on my clean run (see Checkpoint assessment), and it asserts the
step's goal rather than a stub. The one design disagreement — the import block — is
handled by ADR 0016, whose reasoning is measured and correct, and whose replacement
preserves the design's intent.

## Concerns

1. **Two producers of the same Secret key, with a password-encoding asymmetry that can
   become a spurious `OutputsChanged`.** The module now emits a `service_url` output
   (`jit-modules/modules/postgres/outputs.tf:36-40`) built from the *raw* password
   (`local.pg_password`), while the controller independently rebuilds the same key at
   `jit-controller/main.py:495` from the *percent-encoded* password
   (`quote(password, safe="")`). The controller's value wins (it overwrites the module's
   output in `_write_k8s_resources`), so the module's `service_url` value is dead weight
   in production — it exists only to satisfy the runner-level checkpoint. The risk is in
   `_existing_outputs_changed` (`jit-controller/main.py:358-364`): it compares the
   runner's raw `service_url` against the stored (encoded) `service_url` *before* the
   controller's overwrite, so if `postgres_password` ever contains a URL-special
   character, the two diverge and a perfectly normal update would set `OutputsChanged`.
   It is latent today only because `secrets.token_urlsafe(24)`
   (`jit-controller/main.py:293`) never emits `@ : / % # ?`, so raw == encoded. Worth
   reconciling (either drop the module's `service_url` output and have the checkpoint
   assert the controller-built key, or stop double-producing the key).

2. **`service_url_<db>` keys carry the unencoded password.** The `service_urls` map
   (`outputs.tf:41-47`) flattens to `service_url_<db>` with the raw password, and the
   controller never touches those keys, so they differ from the encoded `service_url` by
   construction. For the current `token_urlsafe` password this is harmless; for any
   password that needs percent-encoding the flattened DSNs would be malformed while the
   initial database's `service_url` stays correct. The same latent divergence as concern 1,
   on the consumer-facing keys.

3. **The runner hardcodes a magic output name.** `_flatten_outputs_json`
   (`jit-runner/main.py:253`) special-cases `key == "service_urls"` to flatten with the
   singular `service_url` prefix, while every other map output flattens as `key_sub`. This
   is the only way to reach the design's `service_url_<db>` naming from a map output, but
   it means any future module that happens to name a map output `service_urls` for an
   unrelated purpose is silently rewritten. A more explicit mechanism (a typed output
   contract, or a marker) would be easier to maintain than a name collision.

## Notes

- `service_name` defaults to `"jit-postgres"` (`variables.tf:39-44`) and is never passed
  by the controller; the module therefore cannot know its own Service name and relies on
  the module always being `postgres`. Correct for this repo, but a hidden coupling between
  the module and the controller's `svc_name = f"jit-{module}"`.
- The `url` output stays `sensitive = true` and is now read through `-json`, where the
  runner maps it to `<sensitive>` (`jit-runner/main.py:245-247`), preserving its prior
  placeholder — so `_existing_outputs_changed` sees no false change on it.
- ADR 0015's volume-grep fix turned a silently-vacuous assertion (`$WS-pg-data` matched
  nothing) into a real one (`$WS-pg-postgres-data`), a strengthening; ADR 0017's one-key-
  per-line change makes `grep -qx "service_url"` satisfiable without altering pattern,
  exactness, or message. Both are judged sound, not violations.
- The build plan's "redis `maxmemory` unchanged in the module" is honored: the redis diff
  is only the `ports` block removal plus a comment, nothing else.
- ADR 0016 is sound: an import block is evaluated at plan time, before the same-apply
  container exists, and the measured `tofu` in the runner image is 1.8.1, so `for_each`
  is available but the import genuinely cannot succeed in a single apply. The
  `setsubtract` replacement preserves the design's additive-only, removals-refused intent.

## Checkpoint assessment

`scripts/checkpoint.sh 27 /tmp/S27-review.log` passes on a clean working tree (commit
`c400793`, 0 pending changes): groups 2, 3, and 4 report ok and the run ends `PASS ...`
with exit 0. The checkpoint does assert the step's goal — it would fail if the
`postgresql_database` wiring were removed ("analytics" would not be created in place),
if `remove_volumes = false` or the named volume were dropped (the probe table would not
survive the settings replace), if the settings `-c` wiring were removed (the container
would not be replaced), or if the `state rm postgresql_*` destroy path were removed (the
pre-removed-container destroy would fail). It also pins the `service_url` /
`service_url_analytics` output-key contract. It is a real assertion, not a stub.

Verdict: CONCERNS
