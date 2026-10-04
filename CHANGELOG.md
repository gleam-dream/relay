# Changelog

## Unreleased

Relay has no published release yet. This section describes the first
release candidate. Wave 4 redesigned the public API before publication; the
[wave 4 migration guide](docs/migration-wave-4.md) lists every removed and
changed item with its replacement. Wave 5 carries a client's correlation
to the server and adds idempotency keys, request ids and audience
refusals; the
[wave 5 migration guide](docs/migration-wave-5.md) lists its changes.

### Changed (breaking)

- **One correlation per request (wave 5).** `tool.correlation(call)` and
  `reducer.invocation_correlation` return a `Correlation`, not an `Option`:
  a request uses the transport's correlation, else the one the client sent,
  else a fresh one, and every server event of the request carries it.
  `telemetry.ExchangeClosedMeta` gains `correlation` (TH-7). The
  `correlation` field of every telemetry record that has one (request,
  invocation, exchange, HTTP rejection, authorization and client call) is a
  `Correlation`, not an `Option`.
- **Verifiers receive the correlation (wave 5).** `authorization.verifier`
  takes `fn(BearerToken, Correlation)` and `admit` takes the request's
  correlation as a fourth argument, so an introspection call joins the
  request (SMCP-9).

- **Modules.** `relay/transport/http` and `relay/transport/stdio` became
  `relay/http` and `relay/stdio`. The pure reducer moved from `relay/server`
  to `relay/reducer`; `relay/server` describes a server only. The protocol
  machinery (`relay/protocol/*`, `relay/logging`, the `*_to_json` encoders,
  the stdio framer and writer, `telemetry.emit_*`) is internal, and the
  conformance fixture server moved to `dev/`, so it is not published.
- **Durations.** Every timeout, interval and grace period takes a
  `gleam/time/duration.Duration`.
- **Tools.** `tool.define(name, input, output)` is the one definition step;
  it panics with the tool name on a definition mistake, and `try_define`
  returns a typed `DefineError` for definitions built at runtime. Names are
  `String`s. Content-only tools are `Definition(input, List(ContentBlock))`
  from `define_content`. Metadata and the four annotation hints are setters
  on the definition. Three binders replace eight: `handle`,
  `handle_with_error_renderer` (the renderer returns a `ToolError`) and
  `handle_call`, whose opaque `Call` carries the context, input responses,
  progress with total and message, a cancellation selector, the invocation
  id, the correlation and the client info. `Declaration` is one read record
  for server and client listings; its schemas are exact Blueprint values,
  and `input_contract` loads the input schema as a contract.
- **Server.** `server.new(tools)` replaces `tool.registry` and
  `server.server`; static resources and templates share
  `with_resources`; `with_dispatch` is replaced by `with_tool_access`, which
  hides and refuses tools per context. Hidden, refused and unknown tools all
  answer the same JSON-RPC error immediately.
- **Services.** One opaque `Resource(ctx)` with shared setters for static
  resources and templates; `prompts.prompt_call` mirrors `tool.handle_call`;
  one `completion.completion` receives a `Request` with the other
  arguments' values.
- **Protocol data.** Content blocks, annotations (`audience`, `priority`,
  `lastModified`), icons, resource links and declarations follow the frozen
  `2026-07-28` schema and carry `_meta`. Image, audio and blob data are
  bytes; base64 is confined to the wire.
- **Runtime.** An opaque `runtime.Config` with `with_*` setters replaces
  `RuntimeConfig`; `send_frame` takes the frame's correlation; one
  `notify(runtime, Notification)` replaces four `notify_*` functions.
- **HTTP.** `http.new`, `new_with_context` and `new_protected` describe an
  endpoint; `start`, `supervised`, `named`, `port` and `stop` run a mist
  listener; `handler` and `handle` mount it in any `gleam_http` server, and
  `mist_handler` mounts the streaming endpoint in a mist application. The
  context builder sees the request. `start` returns a typed `StartError`.
- **Client.** The client runs on HTTP Gun. One opaque `Config` from `http`,
  `stdio` or `in_process`, and one `connect`. Every operation returns
  `Result(_, client.Error)`; the error carries the HTTP status and
  `WWW-Authenticate` challenge, the JSON-RPC error, or the transport failure
  with its `Evidence` (`NotSent`, `MaybeSent`, `Completed`), and has `kind`,
  `evidence`, `is_retryable`, `name` and `describe_error`. `call` returns
  `Succeeded`, `ToolFailed` or `InputRequired`. Listings return the
  servers' declaration records.
- **Authorization.** `Protection`, `ProtectedResource`, `Grant` and an
  opaque `Attestation` replace `ProtectionConfig`, `Resource`,
  `GrantedRequest` and `VerifierAttestation`; `verifier(name, verify)` is the
  one constructor. The protected registry and tool policy are replaced by
  `http.new_protected` and `server.with_tool_access`.
- **Telemetry.** Invocation events carry the method, the tool name, the
  correlation and the listener label; statuses and reasons are enums.

### Added

- **Correlation across the wire (wave 5).** A client view's correlation
  travels in the request `_meta` key `io.github.gleam-dream/correlation` and,
  over HTTP, in the `x-correlation-id` header. The server accepts 1 to 128
  visible ASCII characters, ignores anything else and never uses the value
  to authorize (TH-7). A view without a correlation mints a fresh one per
  request, sends it and tags its own `[relay, client, call]` event with it,
  so the client's and the server's events always share one (SMCP).
- `authorization.IssuedForAnotherResource`: a verifier that checks the
  audience itself gets the same `invalid_token` "issued for another
  resource" challenge and `WrongResource` decision as an attestation for
  another audience. `VerificationKind`, `verification_kind` and
  `describe_verification_error` classify `VerificationError`.
- An optional idempotency key: `client.with_idempotency_key(view, key)`
  sends it in `_meta` under `io.github.gleam-dream/idempotency-key`, and
  `tool.idempotency_key(call)` reads it. A retry with the same key is the
  client's promise that it is the same request. The server accepts 1 to 128
  visible ASCII characters and refuses any other value; key work by the
  authenticated principal and the key together.
- `tool.request_id(call)` with `RequestId` (`StringId`, `IntegerId`): the
  JSON-RPC id as sent. MCP `2026-07-28` has no session, so it may repeat
  across clients and does not identify a retry.
- A mountable HTTP endpoint (`http.handler`, `handle`, `mist_handler`) with
  a request-aware context (RELAY-R1, SMCP-2).
- Bearer protection on the HTTP endpoint: `http.new_protected` reads the
  token, admits it with the application's verifier, answers RFC 6750
  challenges and serves the RFC 9728 metadata document;
  `authorization.token_value`, `scope_name`, `resource_uri`, `challenge`,
  `resource_metadata`, `metadata_path`, `metadata_url` and
  `parse_authorization` (RELAY-R5, SMCP-3).
- Client headers computed per request, per-call deadlines, cancellation and
  correlation as client views; a deadline or a cancellation that ends an
  HTTP call closes that call's connection, which cancels the call on the
  server (RELAY-R3, SMCP-6, TH-2).
- `tool.cancelled(call)`: a cancelled or timed-out handler is told before it
  is killed after a grace period (TH-3).
- `http.with_cancellation_grace` (default 5 s) and the `CancellationGrace`
  config field set the grace of the endpoint's cancelled handlers.
- Supervision: `http.supervised` and `runtime.supervised` with `named`
  handles that stay valid across restarts.
- `relay/testing`: an in-process client, MCP requests for a mounted handler,
  and test verifiers (RELAY-R15).
- Telemetry events `[relay, http, rejected]`,
  `[relay, authorization, decided]` and `[relay, client, call]`.
- `server.with_info` and `with_instructions` for `server/discover`.
- A documentation gate: every public module has a module doc and every
  public definition a doc comment; the README and module examples compile
  as tests.

### Fixed

- A cancelled handler keeps its cancellation grace on every path: an HTTP
  disconnect, a client timeout, `notifications/cancelled`, the invocation
  timeout, `runtime.close`, `runtime.stop`, the end of stdio input, and the
  exit of the process that started the runtime. The runtime fires
  `tool.cancelled`, waits until the handler returns or its grace ends, kills
  it only then, and stops after the last one. Before, an HTTP disconnect
  killed the handler in the same step, so it could not cancel work it had
  started elsewhere (TH-3). `runtime.stop` now returns after that drain and
  waits at most the grace plus 5 s; the HTTP endpoint does not hold a
  response for it.
- `client.close` no longer waits about 5 s per in-flight HTTP call for
  HTTP Gun's drain. Closing a client stops its own HTTP Gun client without
  draining, so each open call's connection closes at once, which cancels it
  on the server, and the call ends with `Cancelled(MaybeSent)`, as over
  stdio. An in-process call ends the same way at once instead of at its
  timeout. A caller's client from `with_http_client` is not stopped; calls
  in flight through it run until they end.
- Client failures no longer arrive as `String`, `Dynamic` or a field-less
  configuration error; a 401 keeps its challenge and a JSON-RPC error its
  code and data (TH-4, SMCP-6).
- Tool declarations expose their input schema as an exact value instead of
  `json.Json`, so consumers no longer render and reparse it.
- The stdio client keeps its command in a closure, so the executable and
  its arguments do not print in `string.inspect` or crash reports.
- The completion `context` uses the frozen schema's
  `{"arguments": {...}}` shape on both sides.
- Pagination cursors and input-round state are signed by a key in the
  server description, so they stay valid across HTTP requests.
- Server-sent event responses use chunked encoding with
  `connection: close`, so a client never reuses a connection the stream
  closed.

### Defaults

- SSE keepalive 15 s (was 250 ms).
- At most 1,024 concurrent HTTP requests and 64 `subscriptions/listen`
  streams per endpoint, then 503 with `retry-after` (were unbounded).
- JSON nesting depth 64 at admission (was unbounded).
- At most 10,000 tombstones per runtime and about 10,000 closed exchange
  records per connection (were unbounded in count).
- A cancelled handler gets 5 s after its cancellation signal before it is
  killed.
- The stdio client accepts at most 64 pending calls (was unbounded); the
  client's connect wait is 10 s.
- A non-loopback bind without protection still fails closed;
  `http.allow_unauthenticated` opts in.

### Supported environment and limits

- The package target is Erlang. `gleam.toml` admits Gleam `>= 1.18.0`; the
  GitHub workflow configures Gleam 1.18.1, Erlang/OTP 28 and rebar3 3.27.0.
- The `json_blueprint`, `sinal` and `http_gun` heads are recorded in
  [`sibling-revisions.txt`](sibling-revisions.txt). The workflow checks out
  each sibling at that commit; the private checkouts need a
  `SIBLINGS_READ_TOKEN` secret. The provenance tests and checksum script
  fail on a head mismatch when `CI` is set and only warn for a local sibling
  checkout that has moved past its pin.
- The implementation targets the frozen `2026-07-28` schema. It does not
  implement legacy `2025-11-25`, `logging/setLevel`, resource-read
  continuation, MCP client authorization flows or tasks.
- The built-in resource-template matcher accepts one simple variable per
  slash segment, including embedded forms like `{id}.png`; other syntax
  needs `resources.template_with_matcher`.
- The pinned `@modelcontextprotocol/conformance@0.2.0-alpha.10` server suite
  reports 108 passed checks and no failures. Immediate answers are now JSON,
  so its multiple-stream scenario records that check as informational.

### Before publishing

1. Publish compatible `json_blueprint`, `sinal` and `http_gun` releases and
   replace the `../` path dependencies in `gleam.toml` with them.
2. Verify that a standalone checkout resolves its dependencies.
3. Run the documented format, build, test, negative-fixture, frozen-schema,
   checksum, conformance and Nix checks on the final dependency set.
