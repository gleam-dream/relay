# Relay Wave 1 Progress Log

Status: Complete (Ready for Sol Medium Review)
Target: MCP 2026-07-28 typed tools server over stdio

## Verified Starting Baseline

- Relay: `master` at `75ce50dd1ba180c382c239901ee8e0b8508070a3` (`relay 0.1.0`)
- Blueprint: `implementation/schema-aware-core` at `d3f0708b61eddb4a4789c0476ab5384267814a51` (`json_blueprint 1.7.1`)
- Sinal: `master` at `dd09933e5466628f7d46fa896c389f31ba7d4cb6` (`sinal 0.1.0`)
- Dependency additions in `gleam.toml` and `manifest.toml` preserved as partial progress per dispatch contract.
- Environment & LSP: `agent-lsp` initialized and active for Gleam workspace.

## Milestones Roadmap

- [x] Milestone 0: Baseline verification, environment & toolchain readiness
- [x] Milestone 1: Public scaffold and typed contract definitions (scaffold modules with named later-wave TODOs)
- [x] Milestone 2: Tool admission and Blueprint schema integration (`ToolName`, `ToolMetadata`, `context_tool`, `registry`, schema checks)
- [x] Milestone 3: MCP 2026-07-28 protocol codecs and JSON-RPC envelopes (standard Gleam JSON envelopes, `server/discover`, `tools/list`, `tools/call`, `_meta.io.modelcontextprotocol/serverInfo`)
- [x] Milestone 4: Pure sans-I/O server reducer (`ServerInput`, `ServerEffect`, `step`, state transitions)
- [x] Milestone 5: Authoritative OTP runtime owner (`relay/runtime`, process actor, exchange/invocation lifecycle, crash isolation, cancellation, idempotency)
- [x] Milestone 6: Real stdio process boundary (newline framing, incremental reads, UTF-8 chunk handling, stderr isolation, writer serialization)
- [x] Milestone 7: Native Sinal telemetry observations (package-owned atoms, typed field groups, post-transition emission)
- [x] Milestone 8: Test suite, race conditions, property/process tests, upstream checksum verification
- [x] Milestone 9: Documentation, verification gate, and WAVE-1-REPORT.md

## Completed Summary

All milestones for Wave 1 have been implemented, verified, and gated:

1. Pure sans-I/O server reducer (`relay/server`) and MCP 2026-07-28 wire codecs (`relay/protocol/v2026_07_28`).
2. Authoritative OTP runtime owner (`relay/runtime`) supervising handlers and managing lifecycle.
3. Dedicated stdio transport (`relay/transport/stdio`) with chunk-buffering framer, serialized writer actor, and stderr diagnostic isolation.
4. Spawned child OS process test over real OS pipes (`test/relay/stdio_test.gleam`).
5. Native Sinal telemetry events (`relay/telemetry`) verified with real Erlang `:telemetry` attachment.
6. 52 comprehensive unit, reducer, runtime, stdio, child process, Sinal telemetry, property, and race condition tests passing.
7. Negative compiler fixture test passing (`scripts/check_negative_fixtures.py`).
8. Official frozen MCP 2026-07-28 JSON Schema Draft 2020-12 agreement and 14 mutation negative tests passing (`scripts/relay_schema_check.py`).
9. Upstream checksum and sibling git/version pin verification passing (`scripts/verify_checksums.sh`).
10. `nix develop --command gleam format --check src test` and `nix flake check` passing with zero errors.
