# Freeze protocol evidence and retain independent acceptance boundaries

<a id="adr-0007"></a>

## Decision

- Freeze protocol acceptance at the MCP schema/requirements revision, retain raw upstream bytes and licenses, and keep client, server, authorization, legacy and extension acceptance independent.
- Preserve executable tests, malformed peer fixtures, compiler negatives, conformance harness, sibling pins and current reproduction instructions. Condense obsolete construction reports and unpublished migration guides into these ADRs and the standing native layer.
- The public testing surface uses the real in-process wire/runtime and mounted-request/verifier helpers. Complete paired transport, fake-clock/scripted scheduler and authorization-server tooling remains intended scope rather than marker-based support claims.

## Rationale and alternatives

- Valid schema output establishes shape, not transport behavior. A clean server harness establishes its emitted assertions, not untested client/auth/legacy features or a scenario that emits no checks.
- Historical selected-scenario and expected-failure milestones are development evidence only. Full frozen acceptance has no expected-failure claim; uncovered requirements need independent local assertions.
- Keeping each wave report beside current design created competing status and public-signature descriptions. Retaining immutable original revision links preserves the complete old records while one native layer describes responsibilities and one ADR set describes rationale.
- Logging emission requires a typed approved data-exposure contract. The historical arbitrary handler-JSON callback was automatically rejected and reverted; this migration does not restore or indirectly approve it.

## Source pins

| Source           | Pin and role                                                                                                                           | Evidence limit                                                                                                                      |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| MCP `2026-07-28` | commit `5f5440bb26a62e2cf3440b92da5a667efa03b267`, MIT; schema hash `ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203` | TypeScript schema authority; JSON fixture is structural oracle                                                                      |
| Conformance      | `0.2.0-alpha.10` requirement anchor and executable lockfile                                                                            | Separately inspected source `7169291ec0b68eb370fddcd9947313ab0d5e4156` reports alpha.11; do not silently advance the acceptance pin |
| TypeScript SDK   | `2.0.0`, `cc4b41617ce3601b1290d67216ea0b194a3cd9ac`, MIT                                                                               | Scoped future direct interoperability oracle; package conformance dependency is not this source pin                                 |
| Python SDK       | `2.0.0`, `6f69a3758ebf2ee55ce050f58b470ce11af71133`, MIT                                                                               | Same scoped evidence boundary                                                                                                       |
| mcp_toolkit      | `0.3.1`, `7085e9dd64490d06e338935b3f497b85bb82d068`, Apache-2.0                                                                        | Typed builders/snapshots, older 2025-06-18 wire, no inherited conformance                                                           |
| mcp_client       | `0.1.0`, `8dce5d3819bd8ac0cccadc68bb8b3773398ba38f`, Apache-2.0                                                                        | Child-port ownership/buffering/reconnect scenarios, older 2024-11-05 wire                                                           |
| Anubis           | Baseline reported LGPL-v3; source revision unknown                                                                                     | Feature descriptions only; tests were uninspected and copying requires license review                                               |

## Evidence and reproduction

- [Fixture provenance](../../test/fixtures/mcp_2026/README.md), [raw schema](../../test/fixtures/mcp_2026/schema.json.source), [MIT license](../../test/fixtures/mcp_2026/LICENSE), [schema checker](../../scripts/relay_schema_check.py), [compiler fixture checker](../../scripts/check_negative_fixtures.py), [checksum verifier](../../scripts/verify_checksums.sh), [conformance runner](../../scripts/conformance/run-server-suite.sh), [package lock](../../scripts/conformance/pnpm-lock.yaml) and [protocol corpus](../../test/relay_protocol_corpus.gleam) remain unchanged.
- [Current test instructions](../../README.md#verification) use the appropriate Nix shell. [Native tooling instructions](../../AGENTS.md) supply the pinned design renderer/check/context tools; generated local projection is ignored rather than authored.
- Older reports vary between 106, 109 and later 108 emitted conformance checks; the historical zero-check `input-required-result-missing-input-response` caveat remains a limits statement. Current counts belong to an actual run, not the timeless layer. [Preserved final source design](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/relay-design.md) retains the full original matrix and provenance.
- No live provider, token verification, runtime gate or protocol suite is executed by this documentation task. Native render/check/context success proves artifact integrity and serialization only.

## Current contract

- [Validation and extension ownership](../design/design.typ#validation-and-extension-ownership) and [retained strategies](../design/design.typ#retained-protocol-strategies) own current evidence obligations.
