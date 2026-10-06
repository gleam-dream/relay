# Preserve explicit transport ownership and bounded execution

<a id="adr-0003"></a>

## Decision

- Keep a framework-neutral buffered HTTP handler and a streaming Mist adapter in one package. Use HTTP Gun for outbound HTTP, retaining the distinction between Relay-owned and caller-injected clients.
- The runtime owns one serialized reducer history and isolated handlers. Progress delivery is acknowledged through the sink; cancellation signals the handler, allows cleanup grace and kills only after that grace.
- Defaults bound admitted request/stream counts, frames, depth, response bytes, handler time, tombstone retention and stdio queues. State where each limit applies; a post-read or post-allocation rejection is not a universal allocation bound.

## Rationale and alternatives

- Requiring Relay to bind its own listener prevented application routers from mounting it. A buffered Request/Response interface solves ordinary mounting but cannot observe socket closure, stream progress or run subscriptions. Streaming adapters require actual transport lifetime ownership.
- A separate `relay_mist` distribution was considered; the accepted package shape keeps a small adapter behind the framework-neutral endpoint. Mist remains a dependency cost for stdio-only users, not a shared business-runtime dependency.
- Direct outbound Gun FFI duplicated protocol-neutral HTTP ownership now supplied by HTTP Gun. Injected clients permit shared pools, policy and cassettes; stopping such a client during Relay close would cancel resources the caller owns.
- Unacknowledged progress allowed a fast handler to grow the runtime mailbox and delay cancellation behind queued writes. The retained producer acknowledgement and first-delivery-failure memory make backpressure and disconnect cleanup consequential runtime behavior.
- The accepted default table changed unbounded requests to 1,024, listen streams to 64, keepalive to 15 seconds and nonloopback protection to fail closed. These values are configurable policy, not proof of production capacity.

## Evidence and limits

- [Release API rationale](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/release-api/relay.md), [default decision](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/release-api/DECISIONS.md#5-default-numbers), and [ffb6d37 implementation](https://github.com/gleam-dream/relay/commit/ffb6d37ea88ebab39b1d9a491cea7cd009b5431b) establish the mount/client redesign. The exact earlier backpressure repair commit is not recorded in the original focused review.
- [Focused backpressure acceptance](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/implementation/relay-llm-wire/relay-wave2-final-review.md) accepted held-writer mailbox and burst-disconnect evidence, not complete package conformance.
- Current owners are [HTTP](../../src/relay/http.gleam), [runtime](../../src/relay/runtime.gleam), [Mist adapter](../../src/relay/internal/http_mist.gleam), [client](../../src/relay/client.gleam), [stdio framer](../../src/relay/internal/stdio_frames.gleam) and [FFI](../../src/relay_ffi.erl). [Runtime](../../test/relay/runtime_test.gleam), [HTTP](../../test/relay/http_test.gleam), [HTTP lifecycle](../../test/relay/http_lifecycle_test.gleam) and [stdio tests](../../test/relay/stdio_test.gleam) retain executable evidence.
- Mist body reads precede Relay slot acquisition. Mounted callers allocate the body before `handle`. Incomplete body-reader count and full network allocation remain unmeasured; two FFI helpers inspect Mist's Connection record and require upgrade-specific regression checks.
- [Admission timing](0008-admission-budget-remains-unresolved.md) remains unresolved; existing limits do not establish a whole-request callback bound.

## Current contract

- [Runtime ownership](../design/design.typ#reducer-and-runtime-ownership), [HTTP](../design/design.typ#http-endpoint-and-limits), [stdio](../design/design.typ#stdio-transport) and [client ownership](../design/design.typ#client-calls-and-submission-evidence) own the standing contracts.
