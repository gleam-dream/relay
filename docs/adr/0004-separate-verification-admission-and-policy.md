# Separate token verification, resource admission and tool policy

<a id="adr-0004"></a>

## Decision

- A caller-selected verifier returns an attestation of native principal, audiences and actual scopes. Relay admits only the exact configured resource as the singleton audience and every required endpoint scope, retaining all actual scopes.
- HTTP protected admission constructs native application context. Current tool access policy independently filters listing and rechecks visibility and call permission before argument decoding; input-dependent permission remains inside the typed handler.
- Warden web identity and Relay resource grants remain distinct authority. Correlation and optional client keys never authenticate either one.

## Rationale and alternatives

- A principal-only verifier could not justify the resource/scopes copied from configuration into a grant. The attestation separates asserted claims from admission policy without hand-rolling cryptography or forcing a Warden dependency.
- The historical protected-registry wrapper proved per-use grant rechecks in a pure experiment. The release redesign replaced it with `http.new_protected` and `server.with_tool_access`; preserving an obsolete wrapper in the standing layer would create a second public path.
- Hiding a tool from listing does not protect a named call. Unknown, hidden and denied names therefore share one external inaccessible outcome, and every named call rechecks both callbacks.
- Strict exact audience/scope comparison avoids granting additional audiences or normalizing aliases without a policy contract. A broader multiple-audience or anonymous profile remains a decision rather than a silent relaxation.

## Evidence and limits

- [Original resource authorization contract](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/research/relay-resource-authorization-contract.md) and [laboratory evidence](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/playground/interface_lab/RESOURCE-AUTHORIZATION.md) retain the rationale and early trust limits.
- [Historical correction review](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/implementation/relay-llm-wire/relay-wave4-rereview.md) accepted pure claims/admission and queue corrections. It did not accept production cryptography. [ffb6d37](https://github.com/gleam-dream/relay/commit/ffb6d37ea88ebab39b1d9a491cea7cd009b5431b) replaced the historical wrapper.
- Current behavior is grounded in [authorization](../../src/relay/authorization.gleam), [HTTP wiring](../../src/relay/http.gleam), [tool policy](../../src/relay/server.gleam), [dispatch ordering](../../src/relay/reducer.gleam), [authorization tests](../../test/relay/authorization_test.gleam) and [HTTP tests](../../test/relay/http_test.gleam).
- Attestation construction proves no signature, issuer, expiry or introspection result. A native principal may retain arbitrary data; the token closure protects accidental inspection only. Policy callback evaluation is not atomic with application state/effects.
- Implemented cursor authentication binds key, family and offset. Input-round tokens bind family and nonce; they do not authenticate principal, arguments or expected response keys. Retained tenant/catalog/authorized-view binding and verifier-origin reuse remain explicit native rulings.

## Current contract

- [Bearer admission and tool policy](../design/design.typ#bearer-admission-and-tool-policy) owns the implemented path. [Pending updates](../design/design.typ#pending-updates) owns the unresolved authority refinements.
