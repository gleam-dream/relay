# relay

A strongly-typed, production-grade Model Context Protocol (MCP) implementation in Gleam.

## Current Status (Wave 1: MCP 2026-07-28 Typed Tools Server over Stdio)

Relay provides an authoritative, strongly-typed MCP `2026-07-28` tools server designed for local execution over standard input and output (`stdio`).

### What Works Today

- **Local Unprotected Stdio Tools Server**: Spawnable as an OS child process or run directly via `relay/transport/stdio.run_local_unprotected_stdio_server`. Communicates using newline-delimited (`\n` or `\r\n`) JSON-RPC 2.0 frames over `stdin` and `stdout`.
- **Pure Sans-I/O Protocol Reducer**: `relay/server` implements deterministic state transitions and pure effects (`Write`, `StartInvocation`, `CancelInvocation`, `CloseExchange`, `Ignore`).
- **Authoritative OTP Runtime Owner**: `relay/runtime` supervises handler processes, isolates handler crashes as sanitized internal errors, enforces invocation timeouts, cancels in-flight work on `notifications/cancelled`, and maintains bounded tombstones to prevent late/stale responses.
- **Heterogeneous Typed Registry with Blueprint Schemas**: `relay.context_tool` preserves input, output, error codecs, and contextual handlers. Tools with unrelated native types safely coexist in a single registry. Input schemas enforce JSON Schema 2020-12 object-root contracts.
- **Native Sinal Telemetry**: `relay/telemetry` emits structured `:telemetry` observations via `sinal` using package-owned trusted atoms and typed metadata groups (`frame_rejected`, `request_admitted`, `invocation_started`, `invocation_completed`, `invocation_cancelled`, `invocation_crashed`, `exchange_closed`).
- **Chunk-Buffering Framer & Isolated Diagnostics**: Safely buffers partial frames, handles multi-byte UTF-8 split across OS read boundaries, bounds frame byte length, serializes stdout through a dedicated actor, and isolates all diagnostics and logging to `stderr`.

> [!WARNING]
> **Local Unprotected Transport Notice**: The stdio transport is an explicitly local, unprotected process transport. It does not perform bearer token verification, TLS termination, or public network security. It must not be exposed to untrusted network environments.

### What Remains Unimplemented (Deferred to Later Waves)

The following components and protocol families are not implemented in Wave 1 and have deliberate public scaffolds with named `todo as "wave N: ..."` markers:

- **Streamable HTTP & SSE Transport** (Wave 3): HTTP endpoints, Mist adapter, request headers (`MCP-Protocol-Version`, `Mcp-Method`), and HTTP disconnect cancellation.
- **Official Frozen Conformance Harness Run** (Wave 3): The official `@modelcontextprotocol/conformance@0.2.0-alpha.10` test harness requires an HTTP URL endpoint.
- **Resource-Server Authorization** (Wave 4): Bearer token verification, RFC 9728 OAuth 2.0 protected resource metadata, WWW-Authenticate challenges, JWT/JWKS verifiers, and protected HTTP routing.
- **Typed MCP Client & Public Test-Kit** (Wave 5): Outbound client method/result pairs, raw checked calls, scripted peer, paired transport, and fake clock.
- **Legacy Revision Support** (Wave 7): MCP `2025-11-25` revision wire codecs, handshake/initialize typestate, and older transport conventions.
- **Additional Modern Server Families** (Wave 2): Resources, prompts, completion, pagination, subscriptions, progress notifications, and logging levels.

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
# 1. Full test suite (52 tests: unit, reducer, runtime, stdio, child process, Sinal telemetry, property, race)
nix develop --command gleam test

# 2. Negative compiler fixture check (asserts wrong handler/codec pairing fails at compile time)
nix develop --command python3 scripts/check_negative_fixtures.py

# 3. Official frozen MCP 2026-07-28 JSON Schema validation and single-mutation negative tests
nix develop --command python3 scripts/relay_schema_check.py

# 4. Deterministic upstream schema & sibling dependency pin checksum verification
./scripts/verify_checksums.sh

# 5. Full repository formatting and flake check
nix develop --command gleam format --check src test
nix flake check
```
