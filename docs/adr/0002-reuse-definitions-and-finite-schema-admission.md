# Reuse native definitions and admit application schemas explicitly

<a id="adr-0002"></a>

## Decision

- A `Definition(input, output)` owns name and codecs once, then binds through `handle`, `handle_with_error_renderer` or `handle_call`. Content-only definitions have no fabricated output codec; ordinary generic application errors need no error codec.
- Source definition mistakes panic with the offending name. Runtime construction uses typed `try_define`, `try_define_content`, `try_template` or registration errors.
- Protocol schemas, application schema contracts and provider lowering have distinct owners. Relay's modern codec follows the frozen MCP schema; Blueprint owns exact values, native codecs and finite runtime-contract admission; provider-specific lowering belongs outside Relay.

## Rationale and alternatives

- Earlier root facades, three-codec constructors, separate content-definition families and overlapping binders asked callers for information already retained or discarded. Erasing heterogeneous handlers after binding keeps caller-native types without spreading Dynamic or private runtime state through consumers.
- Ordinary `handle` hides private errors. An explicit renderer is justified when the application chooses safe public detail; retaining an unused error codec would imply a contract that discovery and generic failure handling do not use.
- Remote schemas are preserved as documents. Silently narrowing a valid open schema or trusting arbitrary schema documents as locally validated would change admitted behavior without evidence.
- Input schema root admission and output schema-document admission differ: MCP arguments are objects, while a structured output codec may produce a string or other value whose schema document is itself an object.
- An explicit `with_input_schema` publishes an object schema document while retaining the original codec for every call. It is an authored declaration override, not a runtime-contract replacement or evidence that the document and codec agree.

## Evidence and limits

- The implementation redesign is [ffb6d37](https://github.com/gleam-dream/relay/commit/ffb6d37ea88ebab39b1d9a491cea7cd009b5431b), with [source-definition policy](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/release-api/DECISIONS.md#4-definition-bugs-typed-error-or-panic). Earlier refinements appear in [the pre-release contract](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/implementation/pre-release-api/contract.md#relay).
- Current contracts are grounded in [tool admission/binding](../../src/relay/tool.gleam), [schema admission](../../src/relay/internal/schema.gleam), [tool tests](../../test/relay/tool_test.gleam), [negative handler fixture](../../fixtures/negative/wrong_handler_codec.gleam) and [service tests](../../test/relay/service_test.gleam).
- Blueprint's finite profile can reject valid MCP JSON Schema, and the broader review reproduced default-open schema misclassification in Blueprint. This documentation does not authorize schema expansion or mark the defect acceptable. The native layer exposes the interoperability decision.
- Compiler agreement proves native types fit. It cannot prove arbitrary remote schemas are supported or that a provider accepts a lowered schema.

## Current contract

- [Definitions and service catalog](../design/design.typ#definitions-and-service-catalog) owns the public construction/binding behavior. [Protocol and schema boundaries](../design/design.typ#protocol-and-schema-boundaries) owns the distinction among schema roles.
