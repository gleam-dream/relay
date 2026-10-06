# Serialize subscription activation and intentional listener shutdown

<a id="adr-0006"></a>

## Decision

- Hold subscription acknowledgement until endpoint-owner registration and current-generation reconciliation succeed. Reconcile the complete current catalog rather than retaining lifetime mutation history.
- Preserve FIFO stdio notifications and evolved owner state on timeout. Closing one subscription cancels only that request; buffer overflow closes the retained child before clearing its handle.
- Keep the running listener linked to endpoint and caller. Immediately before intentional listener termination, disconnect the listener's failure link; unexpected listener failure still propagates.

## Rationale and alternatives

- Snapshot comparison by names missed remove-and-reregister under the same name with a different handler or metadata. A monotonic generation exposes any accepted mutation; complete current-state reconciliation handles replacement without comparing closures or retaining a change journal.
- Publishing acknowledgement before registration let owner failure expose a ghost stream. Held initial frames and ordered unregister cleanup avoid acknowledging unavailable stream ownership.
- Prepending retained events reversed delivery. Returning stale owner state after timeout lost events for another subscription; evicting an overflowing port without closing it orphaned the child. These failures required ownership-aware fixtures rather than one successful acknowledgement.
- Intentional listener shutdown previously propagated a linked `shutdown` exit while the endpoint waited to resume its stop path. Unlinking a running listener or ignoring all exits would suppress unexpected failures; disconnecting only at intentional termination preserves both lifecycle meanings.

## Evidence and limits

- [Generation correction acceptance](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/implementation/relay-llm-wire/relay-wave3-final-review.md) records same-name barriers, empty catalog, churn and owner failure. The exact correction commit is not identified in that review.
- [Stdio correction acceptance](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/implementation/relay-llm-wire/relay-wave4-rereview.md) records FIFO, timeout, per-subscription cancellation and 257-frame overflow. Current source is [stdio child owner](../../src/relay/internal/transport/stdio_client.gleam); fixtures remain in [stdio fixtures](../../test/fixtures/stdio).
- Intentional shutdown repair is [2e015df](https://github.com/gleam-dream/relay/commit/2e015df87d816f5187ce0e5f09730eabe5657899), with explanatory follow-up [d448fe2](https://github.com/gleam-dream/relay/commit/d448fe2e1dd7898d699fa2f13bf5cc5d86beaff5). [HTTP lifecycle tests](../../test/relay/http_lifecycle_test.gleam) force the actual listener-exit order and retain the unexpected-failure control.
- Historical initial-flush failure inspection did not have a dedicated subscription-specific injection. General delivery failure and disconnect tests remain useful evidence, not a retrospective claim that every branch was measured.

## Current contract

- [Subscriptions and live registry changes](../design/design.typ#subscriptions-and-live-registry-changes) and [HTTP lifetime](../design/design.typ#http-endpoint-and-limits) own activation, queue and link ordering.
