# Relay oracles

Relay compares its behavior with independent references and pinned evidence.
Each reference below has a recorded source, a pin and a stated limit. Relay has
no benchmark harness and makes no latency claim, so there is no `BENCHMARKS.md`.

The [design](design/design.typ#validation-and-extension-ownership) states which
evidence layer proves what. [ADR 0007](adr/0007-freeze-independent-evidence-and-retain-provenance.md)
records why the evidence is frozen and independent, and
[ADR 0012](adr/0012-gate-with-one-registry-of-fast-ci-and-design-profiles.md)
records how the gate runs it. [AGENTS.md](../AGENTS.md) lists the commands.

## References

| Reference                    | Source and pin                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Role                                                                             | Limit of the claim                                                                                                                                 |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| MCP `2026-07-28` JSON Schema | [modelcontextprotocol](https://github.com/modelcontextprotocol/modelcontextprotocol), tag `2026-07-28`, commit `5f5440bb26a62e2cf3440b92da5a667efa03b267`, path `schema/2026-07-28/schema.json`, MIT. SHA-256 `ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203`. Fetched at run time from `raw.githubusercontent.com` at that commit into `.artifacts/oracle-inputs/` (gitignored) and never committed; the checker fails on any other bytes. | Structural oracle for the wire messages Relay emits.                             | Shape only. It proves neither transport behavior nor complete conformance.                                                                         |
| jsonschema                   | Python `jsonschema` 4.26.0, Draft 2020-12 validator, pinned in the Nix shell.                                                                                                                                                                                                                                                                                                                                                                                  | Validates the corpus and the mutations against the frozen schema.                | Validates structure, not semantics.                                                                                                                |
| MCP conformance harness      | npm `@modelcontextprotocol/conformance` `0.2.0-alpha.10`, locked in [`scripts/conformance/pnpm-lock.yaml`](../scripts/conformance/pnpm-lock.yaml).                                                                                                                                                                                                                                                                                                             | Official server suite for spec `2026-07-28`, run against a local Relay endpoint. | Emitted assertions only. Client, authorization and legacy behavior need separate evidence. A newer alpha is inspected but is not adopted silently. |
| Compiler controls            | Positive and negative Gleam fixtures in [`fixtures/`](../fixtures).                                                                                                                                                                                                                                                                                                                                                                                            | Native codec and handler agreement, and public construction boundaries.          | Compile-time contracts only.                                                                                                                       |
| Scoped peers                 | TypeScript SDK `2.0.0` (`cc4b41617ce3601b1290d67216ea0b194a3cd9ac`) and Python SDK `2.0.0` (`6f69a3758ebf2ee55ce050f58b470ce11af71133`), both MIT, from the [TypeScript](https://github.com/modelcontextprotocol/typescript-sdk) and [Python](https://github.com/modelcontextprotocol/python-sdk) SDK repositories.                                                                                                                                            | Intended direct interoperability oracles in both directions.                     | Not executed by the gate. The conformance package is not this pin.                                                                                 |
| Feature references           | `mcp_toolkit` `0.3.1` (`7085e9dd64490d06e338935b3f497b85bb82d068`, Apache-2.0) and `mcp_client` `0.1.0` (`8dce5d3819bd8ac0cccadc68bb8b3773398ba38f`, Apache-2.0).                                                                                                                                                                                                                                                                                              | Scenario ideas for typed builders and child-port ownership.                      | Older wire revisions (2025-06-18 and 2024-11-05). No conformance is inherited.                                                                     |
| Anubis                       | Reported LGPL-v3, source revision unknown.                                                                                                                                                                                                                                                                                                                                                                                                                     | Feature descriptions only.                                                       | Tests were not inspected. Copying code needs a license review.                                                                                     |

## What is compared and how outcomes are classified

- **Frozen schema corpus.** `scripts/relay_schema_check.py` verifies the schema
  checksum, runs `gleam run -m relay_protocol_corpus` and validates each emitted
  message against its `$defs` entry. It also validates delivered service results
  against their result definition and applies mutations (missing `jsonrpc`,
  missing `resultType`, missing cache members). A message that fails validation,
  or a mutation the schema accepts, fails the check.
- **Conformance suite.** `scripts/conformance/run-server-suite.sh` starts the
  fixture server `dev/relay_conformance_server.gleam` and runs every server
  scenario of spec `2026-07-28`. `scripts/check_conformance_results.py` then
  classifies each result by its `checks.json`. A scenario is evidence only when it
  emitted at least one `SUCCESS` or `FAILURE` assertion. The validator rejects a
  missing or skipped scenario, any `FAILURE` or `WARNING`, an empty selection and
  a scenario with zero assertions. A zero-assertion scenario is reported as
  non-evidence and fails the gate.
- **Compiler controls.** `scripts/check_negative_fixtures.py` requires every
  positive control to compile and every negative fixture to fail with the
  diagnostic fragments listed beside it.
- **Schema checksum.** `scripts/relay_schema_check.py` fetches the pinned schema,
  requires its SHA-256 to match the pin and only then validates Relay's output.

## Exclusions and deliberate differences

- No scenario selection or expected-failure file narrows the server suite. An
  uncovered requirement needs an independent local assertion.
- Historical selected-scenario milestones are development evidence only. Counts
  of emitted checks belong to an actual run, kept under `.artifacts/`, not to this
  document.
- Client, authorization, legacy `2025-11-25` and extension acceptance remain
  independent from the server suite.

## Run

```sh
nix develop --command python3 -B scripts/check.py ci
```

Focused commands:

```sh
nix develop --command sh scripts/conformance/run-server-suite.sh
nix develop --command python3 -B scripts/relay_schema_check.py
nix develop --command python3 -B scripts/check_negative_fixtures.py
nix develop --command python3 -B scripts/check.py pins
```

The suite keeps structured results and the server log under
`build/conformance-results/` for a direct run, or under `.artifacts/PROFILE/server-suite`
for a profile run.

## Limits

A pass establishes the assertions that were emitted and the shapes that were
validated. It does not establish production authorization, provider behavior or
the features the suite does not emit.
