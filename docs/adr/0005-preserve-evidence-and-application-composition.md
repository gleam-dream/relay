# Preserve delivery evidence and keep composition in applications

<a id="adr-0005"></a>

## Decision

- Keep the full `ToolResult` union beside optional output projection. Opaque `client.Error` retains the outgoing correlation separately from detailed Reason; stable classification and submission evidence require no diagnostic parsing.
- Preserve absent structured content as `None` and explicit null as `Some(Null)`, including continuation rounds. `require_discovered` projects text only on actual absence.
- Expose generic output, evidence, content and metadata ports; applications translate agent/workflow/durable-run vocabulary. Do not restore the retired Fabric Relay bridge package.

## Rationale and alternatives

- A refused HTTP call needs the same correlation the server logged; placing context on an opaque error avoids changing every Reason match when future call context grows.
- Completed protocol exchange, tool failure, input-required result and uncertain delivery are independent of business effect success. Automatically treating a tool refusal as effect-free or automatically retrying MaybeSent mutations would lose meaningful evidence.
- Inferring structured presence from outputSchema replaced actual null with text and lost absence semantics. Presence must be read from the result itself, not a declaration that describes possible output.
- Protocol-neutral Fabric invoke owns principal+key reopening, bounded waits, cancellation and durable outcomes. A compiled application recipe maps native input/context, correlation, key and reply metadata; Relay owns no Fabric run type.
- Read-only annotations are peer assertions. A trusted local inventory service can supply the application policy; arbitrary discovered peers require their own trust admission before MaybeSent is classified safe to retry.

## Evidence and provenance

- Correlation/error changes are [a46a3da](https://github.com/gleam-dream/relay/commit/a46a3da4dc57c7dac1d51cbb4e6e80351f2b764d) and [166ddd6](https://github.com/gleam-dream/relay/commit/166ddd69367e463223045d74d6cf2b36a2d1052b). Generic output ports are [c51c66f](https://github.com/gleam-dream/relay/commit/c51c66f8417cb9dd23a73e5cd3f92644641a2632); presence repair is [7040678](https://github.com/gleam-dream/relay/commit/704067822be5523d53708abbb7168d0f44cbd041).
- [Round 9 owner decisions](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/release-api/DECISIONS.md) retain bridge-to-port rationale. [Current output port](../../src/relay/client/output.gleam), [client](../../src/relay/client.gleam), [tool metadata](../../src/relay/tool.gleam) and [presence/projection tests](../../test/relay/client_output_test.gleam) establish Relay behavior.
- Public recipes and external cases are retained in [Fabric's Relay consumer](https://github.com/gleam-dream/fabric/tree/main/consumers/relay_tools) and the preserved [tool_hub source](https://github.com/gleam-dream/oversight/tree/3baff7030a96d5b6cf78b2335c16d8c203727da5/apps/tool_hub). Secure authorization composition is in [secure_mcp](https://github.com/gleam-dream/oversight/tree/3baff7030a96d5b6cf78b2335c16d8c203727da5/apps/secure_mcp).
- The prior disposable review ran 23 public consumer tests at Relay `d448fe2e1dd7898d699fa2f13bf5cc5d86beaff5`. That observation supports the compiled mappings; it is not proof of general third-party schema or annotation trust. No consumer/runtime gate is rerun by this documentation migration.

## Current contract

- [Client evidence](../design/design.typ#client-calls-and-submission-evidence) and [composition ports](../design/design.typ#composition-ports-and-observations) own these rules. Repeated recipe drift or growing mapping complexity can justify a package later; a short recipe alone is not proof of correct policy.
