# Relay Wave 2 Progress Log

Status: Implementation remains incomplete and unaccepted; the rereview's single HIGH progress/backpressure finding is resolved with regressions, and independent acceptance is pending.
Starting checkpoint: `ce718db` with interrupted agy changes preserved and audited.

## Verified pins and environment

- Blueprint: `d3f0708b61eddb4a4789c0476ab5384267814a51`, version `1.7.1`, MIT.
- Sinal: `dd09933e5466628f7d46fa896c389f31ba7d4cb6`, version `0.1.0`, Apache-2.0.
- Mist: `6.0.2` exact; `6.0.3` does not resolve with Sinal's current `gleam_stdlib <1.0.0` constraint.
- Gun: `2.6.0` exact; the thin Erlang FFI exposes raw bounded transport bytes and Gun lifecycle/flow control only. Gleam owns JSON-RPC and Blueprint value parsing.
- `agent-lsp` exists at `/etc/profiles/per-user/edgar/bin/agent-lsp`; its `doctor` ran. The MCP Gleam LSP was started on this workspace and used for blast-radius and file-change notifications; compiler diagnostics remain the authoritative gate.

## Wave 1 review findings

- [x] F1: Git is in the declared shell; sibling provenance checks pass inside it.
- [x] F2: A 50-digit integer survives protocol admission, dispatch inspection, and response JSON as an unquoted number.
- [x] F3: Stdio uses bounded raw chunk reads; process tests cover a split UTF-8 scalar, one-byte reads, multi-frame input, frame limit and EOF.
- [x] F4: Registration rejects unavailable output schemas before handlers can run; admitted output schemas drive declarations.
- [x] F5: Accepted runtime admission emits Sinal observations with the committed exchange identity.
- [x] F6: Writer failures are typed, and the [idle-stdin subprocess regression](test/relay/stdio_test.gleam) proves that asynchronous broken stdout terminates the stdio transport while the child remains blocked on input.
- [x] F7: Handler crash observations redact the panic reason.
- [x] F8: Present malformed client-info and progress-token metadata reject; valid values are retained.
- [x] F9: Writer/runtime startup failures and stdin-open errors return typed outcomes without assertions.
- [~] F10: Real process tests cover partial reads/UTF-8, multiple frames, configured frame bounds, EOF, broken stdout with idle stdin, and duplicate exchange capacity accounting. Broken owner/child behavior, broader cleanup races, and bounded process/mailbox counts remain incomplete.

## Modern server families

- [x] Rich text, image, audio, resource-link and embedded-resource encoders have serializer tests.
- [x] Resources/templates list/read, prompts list/get and completion have service tests.
- [x] Handler-driven progress is delivered over live request-scoped SSE. Each `report_progress` call waits for runtime write completion, Mist acknowledges each `send_event` before the broker accepts another frame, and a rejected delivery closes the runtime and kills active workers. The broker latches its first failure, so later frames reject without waiting on the dead SSE actor. A parked-writer test holds the first write for 100 ms during a 128-value burst and proves the runtime owner mailbox stays at or below one queued message. A loopback TCP test waits for the first SSE `data:` event before resetting the peer and proves the burst worker exits within one second without completing. The adapter bounds total response bytes and send duration, probes idle connections with SSE comments, and closes the runtime on disconnect, overflow, timeout, or final response; the pinned suite covers progress and multiple SSE streams.
- [x] Modern request metadata validates `io.modelcontextprotocol/logLevel`; the obsolete `logging/setLevel` route and process-wide threshold state are absent. Relay does not advertise `logging` because it has no approved message-emission API. Automatic review rejected an attempted API that would expose arbitrary tool-provided JSON to a connected client.
- [x] Pagination traverses tools/resources/prompts, rejects invalid and cross-family cursors, and survives fresh request-scoped HTTP runtimes through per-server authenticated cursors.
- [~] Cache fields are serialized as private with zero TTL; cache ownership, revisions and conditional behavior are not implemented.
- [ ] Resource subscribe/unsubscribe requests, resource/list change notifications and dynamic registry notifications are not wired. `subscriptions.gleam` is only a pure owner-scoped registry.
- [x] Multi-round tool and prompt input uses signed request state, client capability filtering, continuation responses, and rejection of forged state. `resources/read` rejects continuation fields because that handler family has no continuation callback.
- [x] The frozen schema gate validates eleven actual wire messages, including all six delivered service-result families, and rejects 34 single-field mutations. It is supplemented by the official harness, not treated as a substitute for it.

## Streamable HTTP adapter

- [x] Mist 6.0.2 adapter consumes request bodies incrementally with a byte bound, checks content/accept negotiation, protocol and routing headers, and enforces Host/Origin allow-lists.
- [x] Local loopback tests cover JSON, live request-scoped SSE, progress delivery, burst disconnect cancellation, route-header disagreement, media quality zero, body limits, origin/host rejection, unsupported methods and notifications. Handler callbacks block through the runtime-to-writer acknowledgement; one SSE frame remains in flight until Mist's write acknowledges it; total bytes and socket send duration are bounded.
- [x] The pinned `@modelcontextprotocol/conformance@0.2.0-alpha.10` server suite runs all 40 scenarios against the local endpoint: 106 passed, 0 failed. The official DNS-rebinding scenario passes. TLS server mode and hostile-client interoperability outside these requirements remain unverified.

## Typed client

- [x] Gun 2.6.0 HTTP connection reuse, pull-style response credit, cancellation, total request deadline, response byte bounds, close, and client-era discovery are implemented.
- [x] Typed codec-backed tools/call distinguishes structured, content-only, tool, protocol, transport and cancellation outcomes; text, image, audio, resource-link and embedded-resource blocks decode with annotations. Exact structured Blueprint numbers round-trip in local HTTP tests.
- [x] Typed HTTP client methods read resources, get prompts and request completions. Local loopback tests exercise the encoded method/name headers and decoded results.
- [x] `raw_json_call` checks JSON-RPC version and correlation. `list_tools` preserves schema-bearing values through Blueprint and traverses pages with repeated-cursor and page-count guards.
- [~] The client exposes raw JSON strings for tool declarations. It has no subscription/log methods or stdio transport. Gun TLS verification is implemented but lacks a local TLS peer test.
- [ ] Pinned TypeScript/Python fixtures, reconnection/SSE parsing and server-initiated interactions remain untested.

## Latest verified commands

- `nix develop --command gleam check --target erlang`: pass (with the intentional Wave 4 authorization and Wave 5 test-kit TODO warnings).
- `nix develop --command gleam test --target erlang`: 88 passed, no failures. This includes `runtime_progress_backpressure_bounds_mailbox_test` and `live_sse_progress_burst_disconnect_cancels_worker_test`.
- `nix develop --command python3 scripts/relay_schema_check.py`: pass, 11 wire messages and 34 malformed single-mutation cases rejected.
- `nix develop --command python3 scripts/check_negative_fixtures.py`: pass, one wrong handler/codec fixture rejected.
- `nix develop --command ./scripts/verify_checksums.sh`: pass; schema, Blueprint and Sinal provenance match.
- `nix flake check`: pass on `aarch64-darwin`; Nix omitted `aarch64-linux`, `x86_64-darwin`, and `x86_64-linux` as incompatible.
- `git diff --check`: pass.
- `scripts/conformance/run-server-suite.sh`: pass, 40 pinned scenarios, 106 passed and 0 failed. The `input-required-result-missing-input-response` scenario emitted no checks at this spec version; all emitted checks passed. The runner recursively terminates its local Beam server process tree.
- The final format, type-check, test, schema, negative-fixture, provenance, flake, and official-suite commands were rerun after the report was updated; all passed.

## Still required

The Wave 2 acceptance claim is withheld. Remaining Wave 2 scope includes subscriptions/listen and change notifications, dynamic registry updates, typed tool declarations, client stdio transport and subscription methods, broader owner-death cleanup evidence, local TLS peers, and TypeScript/Python interoperability fixtures. The official HTTP suite is now integrated and passing. Automatic review blocked the proposed server logging emitter because it would send arbitrary tool data to the connected client; the capability remains unadvertised. No commit, push, publish, remote creation, credentials or live provider call has been used.
