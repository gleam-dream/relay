# Relay Wave 4 progress

## Starting state

- Baseline: `c293b53` (`99` Erlang tests, `109` emitted checks / `0` failed in the pinned HTTP conformance suite, with the documented zero-check scenario).
- The working tree was clean at start. No reset, commit, remote, sibling, credential, or live-provider action is authorized.
- Wave 4 keeps ordinary Gleam JSON for protocol envelopes and uses Blueprint only for schema-aware values and typed tool contracts.
- The previous Wave 3 focused review is accepted for the HTTP subscription and dynamic-registry subset. Its package-completion boundary remains open.

## Initial gap map

- Typed stdio subscriptions and notification delivery are implemented through the existing owner-serialized child path, with cancellation, FIFO retention, timeout preservation, and bounded overflow cleanup.
- HTTP client listing methods return checked JSON declaration strings rather than typed tool/resource/template/prompt declaration values.
- Modern cache metadata, complete admission coverage, resource-server authorization, `2025-11-25` compatibility, public test helpers, official-peer client interoperability, and comprehensive owner/process cleanup remain incomplete.
- Tasks/Apps, client authorization, older revisions, and the arbitrary handler-JSON logging emitter remain separate scope or blocked by the recorded design/review boundary.

## Work order

1. Add typed declaration models and stdio notification/subscription support through the existing child owner and bounded framer, with real fixture regressions.
2. Close simple modern admission/cache and lifecycle evidence that fits the pinned `2026-07-28` codec without changing the established wire boundary.
3. Implement the smallest honest resource-server authorization seam that can be proven locally; record cryptographic verification, protected HTTP, and client authorization machinery that needs larger dependencies as complexity candidates.
4. Add practical paired/scripted test helpers and owner-death/cleanup evidence where the current actors permit a small direct implementation.
5. Run pinned schema, provenance, conformance, and local oracle gates, then update `WAVE-4-REPORT.md` with exact implemented scope, oracle provenance, blockers, and complexity register.

## Milestones

- [x] Typed declaration values and stdio subscription/notification reader.
- [x] Modern admission/cache and lifecycle gap closures within the existing
      modern server path; stdio pending frames and notifications are bounded.
- [x] Honest authorization boundary and focused admission evidence.
- [x] Test-kit constructors, owner-death behavior, and official-peer server
      conformance evidence.
- [x] Wave 4 report and all applicable synchronous gates.

## Delivered evidence

- `client.list_tool_declarations`, `list_resource_declarations`,
  `list_resource_template_declarations`, and `list_prompt_declarations` decode
  list pages into typed declaration values. Arbitrary schema and `_meta` values
  remain ordinary `json.Json`; explicit `_json` list functions remain
  available for compatibility.
- The stdio actor now has owner-serialized `subscribe`, `next_notification`,
  and cancellation operations. It retains unsolicited notifications while
  awaiting responses in FIFO order, preserves evolved state after timeout,
  matches subscription IDs, bounds queued frames and notifications at 256
  frames, and closes the retained port on overflow.
- `authorization.verifier`, explicit verifier attestations, `admit`,
  `visible_declarations`, `protect_registry_with_tools`, and
  `dispatch_granted` implement exact audience/scope admission and registry-use
  checks before policy or typed dispatch. JOSE/JWKS/introspection and protected
  HTTP adapters remain recorded complexity rather than being faked locally.
- `test/fixtures/stdio/subscription-peer`, the lifecycle and declaration peers,
  and their client tests exercise acknowledgement batches, exact frozen
  declaration fields, FIFO cross-subscription timeout retention, cancellation,
  and overflow cleanup. Authorization tests cover exact audience and scope
  admission plus cross-registry reuse rejection.
- The suite now passes `107` Erlang tests. The frozen schema corpus passes
  `17` messages and `40` malformed mutations; negative compiler fixtures pass;
  and the pinned official conformance runner passes `109` checks across `40`
  scenarios with zero failures.

## Complexity register (initial)

| Requirement                                                                              | Minimal machinery                                                        | Standard alternative                                               | Recommendation                                                                                                                                           |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stdio subscription stream over one request/response child pipe                           | One owner-serialized notification queue plus a typed subscription handle | A second child transport or a general event bus                    | Implement in the existing owner; do not add a new transport package.                                                                                     |
| Resource-server bearer verification, RFC 9728 metadata/challenges, JWT/JWKS and rotation | A verifier adapter plus protected registry can be local and pure         | Established JOSE/JWKS dependency and a full protected HTTP adapter | Implement pure grant/policy seams if already present; defer cryptographic/protected HTTP machinery unless the pinned dependency and tests make it small. |
| `2025-11-25` sessions and legacy HTTP/SSE                                                | A separate revision codec and lifecycle state                            | Reuse modern codec with conditionals                               | Defer or record explicitly; do not mix revision contracts.                                                                                               |
| Tasks/Apps and client authorization                                                      | Revision/extension-specific state machines and trust flows               | None that preserves the design boundary                            | Defer as substantial independent subsystems with exact requirements and cost.                                                                            |
