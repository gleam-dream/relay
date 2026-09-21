# Relay Wave 1 Implementation Report

**Target**: MCP `2026-07-28` Typed Tools Server over Stdio  
**Status**: Complete — Ready for Sol Medium Review  
**Date**: 2026-09-20

---

## 1. Verified Starting Baseline & Environment

- **Repository**: `/code/gleam-dream/relay` on `master` at commit `75ce50dd1ba180c382c239901ee8e0b8508070a3`
- **Sibling Repositories** (Read-Only):
  - `../json_blueprint` on branch `implementation/schema-aware-core` at commit `d3f0708b61eddb4a4789c0476ab5384267814a51` (package version `1.7.1`, MIT)
  - `../sinal` on `master` at commit `dd09933e5466628f7d46fa896c389f31ba7d4cb6` (package version `0.1.0`, Apache-2.0, `telemetry == 1.4.2`)
  - `../oversight` (Read-only design authority)
- **Protocol Authority**:
  - Official MCP repository tag `2026-07-28` at commit `5f5440bb26a62e2cf3440b92da5a667efa03b267` (MIT)
  - Frozen JSON Schema artifact SHA-256: `ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203`
- **Toolchain & Bridge**:
  - Dev shell: Nix flake providing Gleam `>= 1.18.0`, Erlang/OTP 28, `rebar3`, `lefthook`, treefmt
  - Language server: `/etc/profiles/per-user/edgar/bin/agent-lsp`

---

## 2. Architecture & Seam Shapes

Relay Wave 1 establishes a layered, modular, decoupled architecture:

```
┌─────────────────────────────────────────────────────────────┐
│                       relay.gleam                           │
│ (Public facade: tool definition, registry, server, runtime) │
└──────────────────────────────┬──────────────────────────────┘
                               │
       ┌───────────────────────┴───────────────────────┐
       ▼                                               ▼
┌──────────────┐                               ┌──────────────┐
│  relay/tool  │ (Validated ToolName,          │ relay/schema │ (Object-root
│              │  context_tool, registry,      │              │  validation,
│              │  declarations, dispatch)      │              │  materialize)
└──────┬───────┘                               └──────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│                        relay/server                         │
│  (Pure sans-I/O reducer: ServerInput, ServerEffect, step)   │
└──────────────────────────────┬──────────────────────────────┘
                               │
       ┌───────────────────────┴───────────────────────┐
       ▼                                               ▼
┌──────────────────────────────┐       ┌──────────────────────────────┐
│        relay/runtime         │       │    relay/transport/stdio     │
│ (Authoritative OTP process   │       │ (Chunk-buffering framer,     │
│  owner, supervision, timeout,│◄─────►│  serialized writer actor,    │
│  crash isolation, tombstones)│       │  stderr logger, child pipe)  │
└──────────────┬───────────────┘       └──────────────────────────────┘
               │
               ▼
┌──────────────────────────────┐
│       relay/telemetry        │
│ (Native Sinal observations,  │
│  package-owned trusted atoms)│
└──────────────────────────────┘
```

### Core Seams Implemented

1. **Tool Definition & Registry** (`relay/tool.gleam`):

   ```gleam
   pub fn context_tool(
     name: ToolName,
     metadata: ToolMetadata,
     input: Codec(input),
     output: Codec(output),
     error: Codec(application_error),
     handler: fn(context, input) -> Result(output, application_error),
   ) -> Result(ContextTool(context), ToolAdmissionError)

   pub fn registry(
     tools: List(ContextTool(context)),
   ) -> Result(Registry(context), RegistryError)

   pub fn declarations(
     registry: Registry(context),
     context: context,
   ) -> List(ToolDeclaration)

   pub fn dispatch(
     registry: Registry(context),
     context: context,
     name: ToolName,
     arguments: Value,
   ) -> Result(Value, DispatchError)
   ```

2. **Pure Sans-I/O Reducer** (`relay/server.gleam`):

   ```gleam
   pub type ServerInput(context) {
     MessageReceived(exchange: ExchangeId, context: context, bytes: BitArray)
     InvocationFinished(invocation: InvocationId, outcome: InvocationOutcome)
     InvocationProgress(invocation: InvocationId, value: Int)
     ExchangeClosed(exchange: ExchangeId)
   }

   pub type ServerEffect(context) {
     Write(exchange: ExchangeId, bytes: BitArray)
     StartInvocation(Invocation(context))
     CancelInvocation(InvocationId)
     CloseExchange(ExchangeId)
     Ignore(UnhandledMessage)
   }

   pub fn step(
     server: Server(context),
     input: ServerInput(context),
   ) -> #(Server(context), List(ServerEffect(context)))
   ```

3. **Authoritative OTP Runtime Owner** (`relay/runtime.gleam`):
   - Supervised process per admitted invocation.
   - Translates handler crashes and panics into sanitized internal errors.
   - Enforces timeout (`invocation_timeout_ms`).
   - Retains tombstones for cancelled or timed-out invocations (`tombstone_retention_ms`).
   - Guarantees at most one terminal response per exchange.

4. **Stdio Transport Boundary** (`relay/transport/stdio.gleam`):
   - Chunk-buffering framer parsing `\n` and `\r\n` delimited JSON-RPC.
   - Handles multi-byte UTF-8 split across OS read boundaries.
   - Rejects oversized frames (`max_frame_bytes`).
   - Dedicated serialized stdout writer actor (`Writer`).
   - Isolated stderr logging (`log_stderr`).
   - Real OS process execution tested over standard pipes.

5. **Native Sinal Telemetry** (`relay/telemetry.gleam`):
   - Package-owned trusted atoms: `relay`, `frame_rejected`, `request_admitted`, `invocation_started`, `invocation_completed`, `invocation_cancelled`, `invocation_crashed`, `exchange_closed`.
   - Typed metadata field groups via `sinal/fields`.
   - Emits post-transition only; handler failures do not alter protocol outcomes.
   - Zero leakage of raw request bodies, arguments, results, or tokens.

---

## 3. Inventory of Deferred Public Scaffolds

All deferred public functions contain explicit named TODOs citing later waves:

| Module                       | Feature / Function                           | Owning Wave | Named Marker                                      |
| ---------------------------- | -------------------------------------------- | ----------- | ------------------------------------------------- |
| `relay/resources.gleam`      | Resources listing and read                   | Wave 2      | `todo as "wave 2: Complete modern server core"`   |
| `relay/prompts.gleam`        | Prompts listing and get                      | Wave 2      | `todo as "wave 2: Complete modern server core"`   |
| `relay/completion.gleam`     | Completion protocol                          | Wave 2      | `todo as "wave 2: Complete modern server core"`   |
| `relay/subscriptions.gleam`  | Subscriptions protocol                       | Wave 2      | `todo as "wave 2: Complete modern server core"`   |
| `relay/logging.gleam`        | Logging levels protocol                      | Wave 2      | `todo as "wave 2: Complete modern server core"`   |
| `relay/transport/http.gleam` | Streamable HTTP / Mist transport             | Wave 3      | `todo as "wave 3: Streamable HTTP"`               |
| `relay/authorization.gleam`  | Resource-server authorization & verification | Wave 4      | `todo as "wave 4: Resource-server authorization"` |
| `relay/client.gleam`         | Typed MCP client                             | Wave 5      | `todo as "wave 5: Typed client and test kit"`     |
| `relay/test_kit.gleam`       | ScriptedPeer & FakeClock                     | Wave 5      | `todo as "wave 5: Typed client and test kit"`     |

**Verification**:

- Zero `todo` on any accepted Wave 1 path (`tool`, `schema`, `server`, `runtime`, `transport/stdio`, `telemetry`, `protocol/*`, `relay.gleam`).
- Zero `panic` used for control flow in `src/`.
- Zero `Dynamic` types in public function signatures.
- Zero dependency on `llm_wire` or LLM provider concepts.

---

## 4. Verification Evidence & Test Results

### 4.1. Gleam Test Suite (52/52 Tests Passing)

```bash
$ nix develop --command gleam test
Compiling relay
Compiled in 0.24s
Running relay_test.main
.......................................Child stdio server starting
.............
52 passed, no failures
```

Test breakdown across modules:

- `test/relay/tool_test.gleam`: Tool admission, validation, metadata, error handling, dispatch (8 tests).
- `test/relay/protocol_test.gleam`: Protocol discovery, tools list, call, unsupported version -32022 (4 tests).
- `test/relay/server_test.gleam`: Reducer transitions, discovery, listing, invocation lifecycle, cancellation (4 tests).
- `test/relay/runtime_test.gleam`: Supervision, crash isolation, timeout, cancellation, bounds, repeated close (7 tests).
- `test/relay/telemetry_test.gleam`: Native Sinal observations with real Erlang `:telemetry` attachment (4 tests).
- `test/relay/stdio_test.gleam`: Chunk framer, partial frames, UTF-8 chunk splits, oversized frames, EOF, and spawned child OS process over real pipes (9 tests).
- `test/relay/provenance_test.gleam`: Upstream schema SHA-256 and sibling Git/version pins (3 tests).
- `test/relay/property_test.gleam`: Reducer determinism, single terminal response, admission preconditions, no output after terminal, invariants (6 tests).
- `test/relay/race_test.gleam`: Equal wire IDs, duplicate admission, cancel-before-start, cancel racing completion, late completion after cancel, stale callback after owner replacement, simultaneous handler completion, repeated close idempotency (7 tests).

### 4.2. Negative Compiler Fixture Check

```bash
$ nix develop --command python3 scripts/check_negative_fixtures.py
PASS: wrong_handler_codec rejected at compile time with expected diagnostics
All 1 negative compiler fixtures rejected as expected.
```

Confirms that mismatched handler input/output types fail at compile time during type checking.

### 4.3. Official MCP 2026-07-28 JSON Schema Validation & Single-Mutation Negatives

```bash
$ nix develop --command python3 scripts/relay_schema_check.py
PASS: 5 Relay wire messages match official frozen MCP schema; 14 malformed single-mutation negatives rejected.
```

Validates:

- `DiscoverResultResponse`
- `ListToolsResultResponse`
- `CallToolResultResponse` (success with `structuredContent` and text mirror)
- `CallToolResultResponse` (application error with `isError: true` and text content)
- `UnsupportedProtocolVersionError` (with `code: -32022`, requested and supported versions)
- 14 single-mutation negative cases (missing `jsonrpc`, missing `resultType`, missing `cacheScope`, missing `ttlMs`, missing `supported`, etc.) are rejected by Draft 2020-12 validator.

### 4.4. Upstream Checksum & Dependency Pin Verification

```bash
$ ./scripts/verify_checksums.sh
==> Verifying frozen MCP 2026-07-28 schema fixture checksum...
PASS: MCP 2026-07-28 schema checksum matches (ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203)
==> Verifying sibling dependency pins...
PASS: json_blueprint pin matches (commit d3f0708b61eddb4a4789c0476ab5384267814a51, version 1.7.1, MIT)
PASS: sinal pin matches (commit dd09933e5466628f7d46fa896c389f31ba7d4cb6, version 0.1.0, Apache-2.0)
All committed checksums and pins verified successfully.
```

### 4.5. Formatting & Flake Check

```bash
$ nix develop --command gleam format --check src test
# Exit code 0

$ nix flake check
evaluating flake...
running 1 flake checks...
building '/nix/store/dqa2my0bxdb8gxxm1yajca05nngqi96j-treefmt-check.drv'...
all checks passed!
```

---

## 5. Artifacts and Provenance Summary

- **Upstream Schema**: `/code/gleam-dream/relay/test/fixtures/mcp_2026/schema.json.source`
  - SHA-256: `ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203`
  - License: MIT (`test/fixtures/mcp_2026/LICENSE`)
  - Upstream Commit: `5f5440bb26a62e2cf3440b92da5a667efa03b267`
- **Sibling Pins**:
  - `json_blueprint`: `d3f0708b61eddb4a4789c0476ab5384267814a51` (v1.7.1, MIT)
  - `sinal`: `dd09933e5466628f7d46fa896c389f31ba7d4cb6` (v0.1.0, Apache-2.0)
- **Local Scripts**:
  - `scripts/verify_checksums.sh`: Deterministic network-free checksum & pin verifier
  - `scripts/check_negative_fixtures.py`: Compiler diagnostic verifier
  - `scripts/relay_schema_check.py`: Schema agreement & mutation negative runner

---

## 6. Handover

Wave 1 implementation and testing are complete. All 12 acceptance criteria from `relay-work-order.md` are satisfied. The code is ready for Sol Medium review and gate verification. No git commits, pushes, or remotes were modified.
