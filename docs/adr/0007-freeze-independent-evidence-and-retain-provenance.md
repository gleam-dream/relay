# Freeze protocol evidence and retain independent acceptance boundaries

<a id="adr-0007"></a>

## Decision

- Freeze protocol acceptance at the MCP schema/requirements revision, retain raw upstream bytes and licenses, and keep client, server, authorization, legacy and extension acceptance independent.
- Preserve executable tests, malformed peer fixtures, compiler negatives, conformance harness, sibling pins and current reproduction instructions. Keep the reference pins, comparison classification and limits in the retained [oracle document](../ORACLE.md), and condense obsolete construction reports and unpublished migration guides into these ADRs and the standing native layer.
- The public testing surface uses the real in-process wire/runtime and mounted-request/verifier helpers. Complete paired transport, fake-clock/scripted scheduler and authorization-server tooling remains intended scope rather than marker-based support claims.

## Rationale and alternatives

- Valid schema output establishes shape, not transport behavior. A clean server harness establishes its emitted assertions, not untested client/auth/legacy features or a scenario that emits no checks.
- Historical selected-scenario and expected-failure milestones are development evidence only. Full frozen acceptance has no expected-failure claim; uncovered requirements need independent local assertions.
- Keeping each implementation report beside current design created competing status and public-signature descriptions. Retaining immutable original revision links preserves the complete old records while one native layer describes responsibilities and one ADR set describes rationale.
- Logging emission requires a typed approved data-exposure contract. The historical arbitrary handler-JSON callback was automatically rejected and reverted; this migration does not restore or indirectly approve it.

## Source pins

[docs/ORACLE.md](../ORACLE.md) holds the pin table: the MCP schema commit and checksum, the conformance package pin, the scoped peers and the sources that supply feature descriptions only, each with its evidence limit. Do not silently advance the acceptance pin: the conformance source inspected separately reports alpha.11, while acceptance stays at `0.2.0-alpha.10`.

## Evidence and reproduction

- [Oracle references and pins](../ORACLE.md), [fixture note](../../test/fixtures/mcp_2026/README.md), [raw schema](../../test/fixtures/mcp_2026/schema.json.source), [MIT license](../../test/fixtures/mcp_2026/LICENSE), [schema checker](../../scripts/relay_schema_check.py), [compiler fixture checker](../../scripts/check_negative_fixtures.py), [provenance test](../../test/relay/provenance_test.gleam), [conformance runner](../../scripts/conformance/run-server-suite.sh), [package lock](../../scripts/conformance/pnpm-lock.yaml) and [protocol corpus](../../test/relay_protocol_corpus.gleam) remain unchanged.
- [Verification instructions](../../AGENTS.md) use the appropriate Nix shell and supply the pinned design renderer/check/context tools; generated local projection is ignored rather than authored.
- Older reports vary between 106, 109 and later 108 emitted conformance checks; the historical zero-check `input-required-result-missing-input-response` caveat remains a limits statement. Current counts belong to an actual run, not the timeless layer. [Preserved final source design](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/relay-design.md) retains the full original matrix and provenance.
- No live provider, token verification, runtime gate or protocol suite is executed by this documentation task. Native render/check/context success proves artifact integrity and serialization only.

## Current contract

- [Validation and extension ownership](../design/design.typ#validation-and-extension-ownership) and [retained strategies](../design/design.typ#retained-protocol-strategies) own current evidence obligations.
