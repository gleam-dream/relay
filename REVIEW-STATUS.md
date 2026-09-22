# Relay Wave 3 final focused review

## Verdict

- **PASS — the HTTP subscription-establishment and dynamic-registry subset is accepted.** The generation-based repair closes the last same-name replacement race while preserving the prior empty-registry, net-change, acknowledgement, cleanup, and bounded-retention guarantees.
- This review targets the repaired subset in the complete dirty Relay tree against checkpoint `20ad8af`. It does not accept full Wave 3 or package completion.
- The previously accepted Wave 3 subset remains accepted. The deferred package work listed in `WAVE-3-REPORT.md` remains outside this verdict.

## Final finding closure

### Same-name replacement during establishment

- The prior HIGH finding is closed. `HubState` now owns a monotonic registry generation, and `HubGetServer` returns that generation with the immutable server and tool snapshot.
- Accepted registration increments the generation at `src/relay/transport/http.gleam:161-177`. Accepted removal increments it at `src/relay/transport/http.gleam:180-193`; duplicate registration and absent-name removal leave it unchanged.
- `RegisterSubscription` compares the snapshot generation with the current generation inside the serialized hub actor. A changed generation causes the runtime to unregister every snapshot tool, register every current tool, and enqueue one tools-list notification before the hub reports successful registration.
- This complete current-state reconciliation preserves a removal followed by registration under the same name. It also covers net additions and removals without comparing handler closures or retaining mutation history.

## Direct regression evidence

- `http_subscription_reconciles_same_name_replacement_during_establishment_test` pauses the request context after the snapshot, removes `replace-me`, registers a replacement with changed metadata and handler output, and then releases admission.
- The regression proves the acknowledged filter retains `toolsListChanged`, the stream receives `ToolsListChanged`, a subsequent listing contains `replacement metadata` and excludes `old metadata`, and a call returns `replacement handler`.
- The empty-registry and populated-registry gate regressions still prove a net addition between snapshot and activation produces a notification and becomes visible to later requests.
- The 128-cycle churn regression still proves subscription admission depends on the current registry and generation rather than server-lifetime mutation history.
- The hub-death regression still proves `client.listen` returns an error when the hub stops during admission, so a failed registration cannot expose an acknowledged stream.

## Bound and cleanup guarantees

- `HubState` contains only the current server, active subscriptions, and one generation integer. No change journal, historical `ContextTool`, or removed handler closure remains retained.
- Reconciliation work is bounded by the snapshot and current registry sizes. A changed generation performs one pass over each list; prior churn count does not affect the work.
- The SSE broker continues to hold all initial subscription frames. The handler releases them only after successful hub registration.
- Registration timeout, hub death, and acknowledgement-release failure each queue `UnregisterSubscription` and stop the runtime, SSE actor, and broker. Same-sender mailbox ordering ensures a delayed successful registration is followed by its queued unregister cleanup.
- The suite retains post-write disconnect and response-bound regressions. It does not contain a deterministic subscription-specific initial-flush failure injection, so that branch remains established by direct code inspection rather than a dedicated regression.

## Independent evidence

- `nix develop --command gleam test --target erlang` passed: **99 tests, 0 failures**. Expected untrusted-CA and broken-child diagnostics appeared.
- `./scripts/conformance/run-server-suite.sh` passed: **109 emitted checks across 40 scenarios, 0 failed**. `input-required-result-missing-input-response` emitted zero checks and is not an independently asserted scenario pass.
- The preceding focused review ran `nix develop --command python3 scripts/relay_schema_check.py`: **17** Relay messages matched the frozen schema and **40** malformed single-field mutations were rejected. The final repair does not change protocol encoding or the schema corpus.
- `git diff --check 20ad8af` passed.

## Acceptance boundary

- Accepted: HTTP `subscriptions/listen` capability negotiation for empty and populated registries; atomic snapshot-to-activation reconciliation for net additions, net removals, and same-name replacement; dynamic tool list-change delivery; current-registry-bounded reconciliation without retained history; acknowledgement withholding until hub registration; and terminal cleanup for registration failure, timeout, hub death, release failure, and later disconnect.
- Previously accepted and unchanged: typed stdio request/response methods; explicit-CA HTTPS; the expanded modern wire corpus; retained HTTP backpressure and disconnect cancellation; and strict `2026-07-28` codec behavior.
- Still incomplete: typed stdio subscriptions, owner-death and comprehensive process-count cleanup, official-peer client fixtures, remaining modern families and admission, authorization, `2025-11-25` compatibility, the public test kit, target matrices, soak/fuzz, and release hardening. These are package-completion gaps rather than blockers for the accepted subset.
