# Changelog

## Unreleased — initial release candidate

Relay has no published release yet. This section describes the current implementation, not a released version.

### Available

- MCP `2026-07-28` server and client on Erlang, with local stdio and Streamable HTTP transports.
- Native typed tool definitions, content-only tools, rich content, resources, resource templates, prompts, completion, progress, input rounds, subscriptions, and raw checked JSON-RPC access.
- Configured clients can call a discovered tool with exact Blueprint JSON values, or call a native definition with its codecs. Tool calls retain distinct application, protocol, and transport outcomes.
- Pure server reduction and runtime exchange events for custom transports, with caller-owned dispatch and resource-template matching extensions.
- Bounded transport, response, and paginated-listing settings; optional annotation hints independently preserve omitted, true, and false values.

### Supported environment and limits

- The package target is Erlang. `gleam.toml` admits Gleam `>= 1.18.0`; the GitHub workflow configures Gleam 1.18.1, Erlang/OTP 28, and rebar3 3.27.0. It does not establish support for other compiler or OTP combinations.
- The local Blueprint and Sinal dependency heads for this candidate are recorded in [`sibling-revisions.txt`](sibling-revisions.txt) and checked by both the provenance tests and checksum script. These source pins do not replace published dependency constraints.
- Both bundled listeners are unprotected. Authorization primitives exist, but these listeners do not enforce bearer grants. Use trusted local deployment boundaries.
- The implementation targets the frozen `2026-07-28` schema. It does not implement legacy `2025-11-25`, `logging/setLevel`, or resource-read continuation, and it does not claim full MCP conformance or production readiness.
- The built-in resource-template matcher accepts one simple variable per slash segment, including embedded forms like `{id}.png`. Other operators or composite variables require an explicit application matcher. Native tool admission requires an object-root input schema; structured tools also require an output schema. Remote discovery preserves arbitrary JSON Schema documents but does not turn them into native codecs.
- The pinned `@modelcontextprotocol/conformance@0.2.0-alpha.10` Streamable HTTP server run previously reported 109 passed checks, zero failures, and one scenario with no checks. That result covers the exercised server scenarios only.

### Before publishing

1. Publish compatible `json_blueprint` and `sinal` releases or establish another reproducible dependency source. Replace Relay's `../json_blueprint` and `../sinal` path dependencies in `gleam.toml` with the selected released dependencies. Do not choose versions from this unreleased note.
2. Verify a standalone checkout can resolve dependencies. The current GitHub workflow checks out only Relay before `gleam deps download`, so its path dependencies are unavailable there and a hosted green run is not established.
3. Run the documented format, build, test, negative-fixture, frozen-schema, checksum, conformance, and Nix checks on the final dependency set. Review the actual CI result and package contents before choosing a version and publishing.
