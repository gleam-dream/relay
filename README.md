# relay

An MCP implementation in Gleam. Wave 2 source work is in progress and remains unaccepted. The five findings from the independent subset review are closed with regressions. The pinned official server HTTP requirements suite passes; this is not a claim of complete MCP conformance.

## Implemented surface

- MCP `2026-07-28` discovery, tool listing/calls, resource and template listing/reading, prompt listing/get, and completion are handled by the sans-I/O server core. It validates per-request log-level metadata; it does not implement `logging/setLevel` or advertise log-message emission. Typed contextual tools use JSON Blueprint codecs. Tool replies support structured output, content-only output, text, image, audio, resource links, and embedded resources.
- Local unprotected stdio uses newline-delimited JSON-RPC frames, bounded chunk reads, split UTF-8 handling, serialized stdout, and stderr diagnostics. The OTP runtime owns tool workers, timeouts, cancellation, terminal suppression, and Sinal observations. An asynchronous broken-stdout regression proves the transport stops while stdin is idle.
- A thin Mist adapter accepts bounded POST requests, checks JSON and MCP headers, Host/Origin allow-lists and media negotiation, and returns JSON or live request-scoped SSE responses. SSE writes apply acknowledgement backpressure, bounded response size and duration, and disconnect cancellation. Cursor tokens are opaque, server-bound and family-scoped.
- A Gun HTTP client supports revision discovery, checked raw JSON-RPC calls, paginated raw `tools/list` declarations, codec-typed tool calls, typed resource reads, prompt gets, and completion requests. Tool outcomes distinguish structured success, content-only success, tool failure, protocol failure, transport failure, and cancellation. Content decodes as typed text, image, audio, resource-link, and embedded-resource blocks, including annotations.

The pinned `@modelcontextprotocol/conformance@0.2.0-alpha.10` server suite runs all 40 HTTP requirement scenarios against the local endpoint: 106 checks pass and 0 fail. One scenario emits no checks for this specification version, so the result does not establish full conformance. Resource subscriptions/listen, list-change notifications, dynamic catalogue updates and log-message emission remain outstanding. Multi-round tool and prompt input is supported with signed continuation state and capability filtering; resource-read continuation is rejected. The typed client has no stdio transport or subscription methods. TLS is implemented for Gun but has not been exercised against a local TLS peer.

> [!WARNING]
> **Unprotected transport:** the available stdio and HTTP entry points do not verify bearer tokens or enforce resource authorization. Bind them only to trusted local environments until protected routing is implemented.

Resource-server and client authorization, legacy `2025-11-25` compatibility, later protocol extensions, and the public scripted test kit remain later-wave work. Relay does not yet claim full MCP conformance or production readiness.

## Usage Example

```gleam
import json/blueprint/codec
import relay
import relay/server
import relay/transport/stdio

pub fn main() {
  // 1. Define a tool with validated name and Blueprint codecs
  let assert Ok(greet_name) = relay.tool_name("greet")
  let assert Ok(greet_tool) =
    relay.context_tool(
      greet_name,
      relay.tool_metadata("Greets the user by name"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: String, name: String) { Ok("Hello, " <> name <> "!") },
    )

  // 2. Build the registry and pure server
  let assert Ok(reg) = relay.registry([greet_tool])
  let s = server.server(reg)

  // 3. Launch the local unprotected stdio server
  let config = stdio.default_stdio_config()
  let _ = stdio.run_local_unprotected_stdio_server(s, config, "my_app_context")
}
```

## Verification & Toolchain

All tests, schema validations, negative compiler checks, and checksum verifications run deterministically via the dev shell:

```bash
# 1. Full Erlang-targeted test suite
nix develop --command gleam test --target erlang

# 2. Negative compiler fixture check (asserts wrong handler/codec pairing fails at compile time)
nix develop --command python3 scripts/check_negative_fixtures.py

# 3. Official frozen MCP 2026-07-28 JSON Schema validation and single-mutation negative tests
nix develop --command python3 scripts/relay_schema_check.py

# 4. Deterministic upstream schema & sibling dependency pin checksum verification
nix develop --command ./scripts/verify_checksums.sh

# 5. Full repository formatting and flake check
nix develop --command gleam format --check src test
nix flake check

# 6. Pinned official Streamable HTTP server requirements
./scripts/conformance/run-server-suite.sh
```
