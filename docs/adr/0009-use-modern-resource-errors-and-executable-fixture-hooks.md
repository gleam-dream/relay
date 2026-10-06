# Use modern resource errors and executable fixture hooks

<a id="adr-0009"></a>

## Decision

- Modern resource read failures return invalid params (`-32602`) with the requested URI in `data.uri`. Private handler errors remain undisclosed; other error mappings and client decoding remain unchanged.
- The unpublished server fixture exposes the pinned suite's diagnostic hooks through existing endpoint ownership: tool registration changes the live catalog; prompt notification uses `http.notify`. Its elicitation handler requires the requested key and accepted response structure before completing.
- Require every selected pinned server scenario to emit assertions. Preserve raw machine results, counts, warnings and server logs; reject empty/missing/skipped/failing evidence rather than treating the upstream process exit as the whole contract.

## Rationale and alternatives

- The 2026-10-06 CI verification exposed six advisory records behind the upstream exit-0 summary. Two came from omitted notification hooks, two from an elicitation fixture that completed for any nonempty response dictionary, and two from the resource error renderer's older code and missing URI.
- The [versioned MCP 2026-07-28 resource contract](https://modelcontextprotocol.io/specification/2026-07-28/server/resources#error-handling) requires invalid params for nonexistent resources and shows the requested URI in error data. The pinned `0.2.0-alpha.10` scenario exercises that contract. Registering a resource for the harness's deliberately unknown URI or changing suite selection would conceal the defect.
- The server admits only `2026-07-28`; the reducer dispatches that codec directly and discovery advertises that revision. No legacy session server is implemented. Numeric errors received from remote peers keep their original client representation; the retained legacy design is unchanged.
- A blanket warning allowance would count unmet recommendations as clean evidence. The historical zero-assertion missing-input scenario in [ADR 0007](0007-freeze-independent-evidence-and-retain-provenance.md) instead receives a proper application-owned re-request from the corrected fixture.

## Evidence and limits

- [Resource renderer](../../src/relay/internal/jsonrpc.gleam), [modern reducer paths](../../src/relay/reducer.gleam), [resource regression](../../test/relay/service_test.gleam), [real HTTP check](../../test/relay/http_test.gleam), [fixture consumer](../../test/relay/conformance_fixture_test.gleam) and [machine-result validator](../../scripts/check_conformance_results.py) retain executable controls.
- The prompt diagnostic proves the public owner's notification contract. It does not introduce live prompt catalog replacement. Client, authorization, legacy and other oracle requirements retain their independent evidence boundaries.
- Raw MCP schema, upstream package/lock, negative compiler fixture and license bytes remain frozen. The full registry is the reproduction command in [usage verification](../usage.md#verification).
