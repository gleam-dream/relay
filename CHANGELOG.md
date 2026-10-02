# Changelog

## Unreleased — initial release candidate

Relay has no published release yet. This section describes the current implementation, not a released version.

### Available

- MCP `2026-07-28` server and client on Erlang, with local stdio and Streamable HTTP transports.
- Native typed tool definitions, content-only tools, rich content, resources, resource templates, prompts, completion, progress, input rounds, subscriptions, and raw checked JSON-RPC access.
- Configured clients can call a discovered tool with exact Blueprint JSON values, or call a native definition with its codecs. Tool calls retain distinct application, protocol, and transport outcomes.
- Pure server reduction and runtime exchange events for custom transports, with caller-owned dispatch and resource-template matching extensions.
- Bounded transport, response, and paginated-listing settings; optional annotation hints independently preserve omitted, true, and false values.

### Changed

- `authorization.BearerToken` stores its raw value inside a closure, so `string.inspect`, crash reports and logger metadata print a function reference instead of the token. The opaque API is unchanged. No other public Relay value holds a credential: the HTTP client rejects URLs with userinfo, and telemetry metadata carries only ids, methods and reasons.
- `http.start` fails closed: it refuses a non-loopback host when the listener has no authorization protection, and its error names the host and the fix. `http.allow_unauthenticated(listener)` opts in, and is unsafe outside a trusted network or an authenticating proxy. Loopback hosts (`localhost`, `127.0.0.0/8`, `::1`) start as before. New `http.validate`, `http.ListenerError` and `http.describe_listener_error` expose the refusal as a typed value; `start` keeps its `Result(HttpServer, String)` signature.

### Supported environment and limits

- The package target is Erlang. `gleam.toml` admits Gleam `>= 1.18.0`; the GitHub workflow configures Gleam 1.18.1, Erlang/OTP 28, and rebar3 3.27.0. It does not establish support for other compiler or OTP combinations.
- The Blueprint and Sinal dependency heads for this candidate are recorded in [`sibling-revisions.txt`](sibling-revisions.txt). The GitHub workflow checks out each sibling at that commit beside Relay; the private `gleam-dream/sinal` checkout needs a `SIBLINGS_READ_TOKEN` secret with read access. The provenance tests and checksum script fail on a head mismatch when `CI` is set and only warn for a local sibling checkout that has moved past its pin. These source pins do not replace published dependency constraints.
- Both bundled listeners are unprotected. Authorization primitives exist, but these listeners do not enforce bearer grants. The HTTP listener starts on a non-loopback host only after `http.allow_unauthenticated`. Use trusted local deployment boundaries.
- The implementation targets the frozen `2026-07-28` schema. It does not implement legacy `2025-11-25`, `logging/setLevel`, or resource-read continuation, and it does not claim full MCP conformance or production readiness.
- The built-in resource-template matcher accepts one simple variable per slash segment, including embedded forms like `{id}.png`. Other operators or composite variables require an explicit application matcher. Native tool admission requires an object-root input schema; structured tools also require an output schema. Remote discovery preserves arbitrary JSON Schema documents but does not turn them into native codecs.
- The pinned `@modelcontextprotocol/conformance@0.2.0-alpha.10` Streamable HTTP server run previously reported 109 passed checks, zero failures, and one scenario with no checks. That result covers the exercised server scenarios only.

### Before publishing

1. Publish compatible `json_blueprint` and `sinal` releases or establish another reproducible dependency source. Replace Relay's `../json_blueprint` and `../sinal` path dependencies in `gleam.toml` with the selected released dependencies. Do not choose versions from this unreleased note.
2. Verify a standalone checkout can resolve dependencies. The GitHub workflow supplies the path dependencies by checking out the pinned siblings, so a hosted green run does not establish that a standalone checkout resolves.
3. Run the documented format, build, test, negative-fixture, frozen-schema, checksum, conformance, and Nix checks on the final dependency set. Review the actual CI result and package contents before choosing a version and publishing.
