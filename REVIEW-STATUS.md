# Relay Wave 1 implementation review

## Verdict

- **FAIL — Wave 1 is not accepted.** The staged implementation at Relay baseline `75ce50dd1ba180c382c239901ee8e0b8508070a3` does not satisfy the frozen work order. A checkpoint commit may preserve the work, but it must not represent acceptance.

## Adherence

- **HIGH · Exact Blueprint numbers are not preserved.** The design requires ordinary envelopes to use `gleam_json` while preserving exact Blueprint values, and the work order says to stop on a numeric boundary collision. Inbound tool arguments are parsed into `Dynamic`, re-encoded by Erlang `json:encode`, and reparsed by Blueprint ([`src/relay/protocol/v2026_07_28.gleam:336`](/code/gleam-dream/relay/src/relay/protocol/v2026_07_28.gleam:336), [`src/relay_ffi.erl:25`](/code/gleam-dream/relay/src/relay_ffi.erl:25)); outbound non-integer numbers are converted to `Float`, or emitted as a JSON string when exact float conversion fails ([`src/relay/protocol/v2026_07_28.gleam:519`](/code/gleam-dream/relay/src/relay/protocol/v2026_07_28.gleam:519)). This can change a declared JSON number into a string and can lose decimal precision before handler decoding. Proposed `(in-place-fix, now)`.

- **HIGH · The authoritative stdio boundary is line-buffered rather than incrementally read.** `read_stdin/1` ignores `ChunkSize` and calls `io:get_line` ([`src/relay_ffi.erl:51`](/code/gleam-dream/relay/src/relay_ffi.erl:51)). The pure framer can accept split chunks, but the real process boundary cannot produce them, so the README claim that partial UTF-8 is handled across OS read boundaries is unsupported. Proposed `(in-place-fix, now)`.

- **HIGH · Request-admitted telemetry exists only as a callable helper.** The runtime emits frame, invocation, and close observations, but no accepted request path calls `emit_request_admitted`; repository search finds calls only in the telemetry unit test. The design requires Sinal to observe committed Relay facts, and acceptance criterion 9 requires real lifecycle observation after transitions. Proposed `(in-place-fix, now)`.

## Spec

- **HIGH · Missing output schemas are silently admitted.** `context_tool` converts any output `codec.schema` failure to `None` and returns a usable tool ([`src/relay/tool.gleam:189`](/code/gleam-dream/relay/src/relay/tool.gleam:189)). The work order requires the actual output schema to be retained and unavailable schemas to produce a typed refusal before a handler can run. No unavailable-schema, unsupported-feature, invalid-output, or error-encoding-failure acceptance test exists. Proposed `(in-place-fix, now)`.

- **HIGH · Broken stdout cannot terminate the transport explicitly.** The stdio adapter discards `write_bytes` failures in the runtime sink ([`src/relay/transport/stdio.gleam:207`](/code/gleam-dream/relay/src/relay/transport/stdio.gleam:207)) and again for refusal responses ([`src/relay/transport/stdio.gleam:280`](/code/gleam-dream/relay/src/relay/transport/stdio.gleam:280)). `run_local_unprotected_stdio_server` can therefore return success after losing a protocol response, contrary to the required explicit broken-stdout terminal outcome. Proposed `(in-place-fix, now)`.

- **HIGH · Required process and race evidence is absent.** The sole child-process test sends four complete newline-terminated frames ([`test/relay/stdio_test.gleam:153`](/code/gleam-dream/relay/test/relay/stdio_test.gleam:153)); partial UTF-8, partial reads, multiple frames in one OS chunk, configured maximum frame, EOF shutdown, broken child/owner, crash, and timeout are only unit/runtime cases or absent. Race cases execute once, depend on sleeps (for example [`test/relay/race_test.gleam:163`](/code/gleam-dream/relay/test/relay/race_test.gleam:163)), and do not assert process or mailbox cleanup. This fails acceptance criteria 7 and 8. Proposed `(in-place-fix, now)`.

- **MEDIUM · Optional request metadata is not validated to the final schema.** `parse_metadata` validates the protocol version and that client capabilities is an object, then ignores `io.modelcontextprotocol/clientInfo`; an invalid present client-info value is accepted despite the final `Implementation` schema requiring string `name` and `version` ([`src/relay/protocol/v2026_07_28.gleam:185`](/code/gleam-dream/relay/src/relay/protocol/v2026_07_28.gleam:185)). An invalid present progress token is also treated as absent ([`src/relay/protocol/v2026_07_28.gleam:239`](/code/gleam-dream/relay/src/relay/protocol/v2026_07_28.gleam:239)). Proposed `(in-place-fix, now)`.

- **MEDIUM · Crash observations can disclose handler data.** The FFI formats the raw caught reason ([`src/relay_ffi.erl:38`](/code/gleam-dream/relay/src/relay_ffi.erl:38)); runtime forwards it to Sinal ([`src/relay/runtime.gleam:431`](/code/gleam-dream/relay/src/relay/runtime.gleam:431)); the public descriptor records it as free text ([`src/relay/telemetry.gleam:166`](/code/gleam-dream/relay/src/relay/telemetry.gleam:166)). A handler panic containing an argument or credential would violate the required observation redaction. Proposed `(in-place-fix, now)`.

## Standards

- **HIGH · The required test gate fails in the declared dev shell.** Independent execution of `nix develop --command gleam test` produced `50 passed, 2 failures`: both sibling provenance tests received `error: tool 'git' not found`. The tests invoke `git` through `os:cmd`, while the dev shell package list omits Git ([`flake.nix:35`](/code/gleam-dream/relay/flake.nix:35)). This contradicts `WAVE-1-REPORT.md`'s 52/52 result and fails the work-order gate. Proposed `(in-place-fix, now)`.

## Craft

- **MEDIUM · Transport setup uses assertions and loses typed startup failure.** Writer and runtime startup are destructured with `let assert` inside a function returning `Result(Nil, StdioError)` ([`src/relay/transport/stdio.gleam:199`](/code/gleam-dream/relay/src/relay/transport/stdio.gleam:199), [`src/relay/transport/stdio.gleam:212`](/code/gleam-dream/relay/src/relay/transport/stdio.gleam:212)). A startup failure crashes instead of producing an explicit terminal outcome. Proposed `(in-place-fix, now)`.

## Independent checks

- **PASS:** `nix develop --command gleam check` completed with deferred-TODO and unused-constructor warnings.
- **FAIL:** `nix develop --command gleam test` — 50 passed, 2 failed because Git is unavailable inside the dev shell.
- **PASS:** `nix develop --command python3 scripts/relay_schema_check.py` — 5 corpus messages and 14 mutation negatives. This validates only the five authored corpus values, not every runtime error or numeric boundary.
- **PASS:** `nix develop --command python3 scripts/check_negative_fixtures.py` — one negative fixture rejected.
- **PASS:** `./scripts/verify_checksums.sh` — schema checksum and sibling heads/versions matched when run outside the dev shell.
- **PASS:** `nix develop --command gleam format --check src test`.
- **PASS:** `nix flake check` for the current host; incompatible systems were omitted.

## Routing

- Proposed routes: ten `(in-place-fix, now)` findings. Frontdesk may route them after the checkpoint if desired.
