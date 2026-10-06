# Keep one Relay distribution with separate protocol strategies

<a id="adr-0001"></a>

## Decision

- Relay owns typed MCP server/client, transports, resource-server admission and MCP client authorization in one package with internal responsibility boundaries.
- The implemented target is Erlang and MCP `2026-07-28`. Retained `2025-11-25` compatibility has an independent codec and session lifecycle; `2025-03-26` and `2025-06-18` remain deferred targets, and earlier revisions are excluded.
- Preserve the intended full capability scope while reporting unbuilt work in the native pending ledger. Tasks, Apps, optional deprecated HTTP+SSE, DPoP/mTLS, workload identity and JavaScript core verification require scoped contracts and evidence.

## Rationale and alternatives

- The original eight-distribution proposal created release/dependency coordination before an independent consumer proved a reason to split. Internal pure-core, codec, server, client, HTTP, stdio, authorization and test-support boundaries retain those capabilities.
- Reusing a legacy initialization state for the modern revision would invent sessions and prerequisite handshakes. Modern requests carry version/capabilities individually, while legacy initialization negotiates session state and legacy results omit modern `resultType`.
- A later physical split remains possible when target, dependency or release cadence differs. Warden web login, Fabric runs, Saga settlement and general authorization-server operation remain independent responsibilities.

## Evidence and provenance

- The recorded boundary decision appears in [Oversight protocol research at its preserved revision](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/research/protocol-auth-boundaries.md) and [the full source design](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/relay-design.md). The research records 19 September 2026; an earlier owner approval date for the eight-package baseline is unknown.
- [MCP authority](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/5f5440bb26a62e2cf3440b92da5a667efa03b267) is the released `2026-07-28` tag under MIT. [Current manifest](../../gleam.toml) and [modern codec](../../src/relay/internal/protocol/v2026_07_28.gleam) establish the implemented target and wire strategy.
- [Original modern laboratory](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/playground/interface_lab/MODERN-RELAY.md) proved parsed-value composition only; it did not prove runtime conformance.

## Documentation consequence

- Current architecture and complete scope live in [the native design](../design/design.typ#protocol-and-schema-boundaries) and [retained strategies](../design/design.typ#retained-protocol-strategies). Historical signatures and construction schedules are superseded, not compatibility promises for a published release.
