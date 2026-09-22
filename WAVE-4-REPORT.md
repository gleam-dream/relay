# Relay Wave 4 report

Status: **focused Wave 4 delivery complete; full package completion is not claimed.**
The work started at clean baseline `c293b532158dade30dc85a1a9aef82adccaf31bb`.
No commit, push, remote mutation, live provider call, credential use, reset, or
sibling-repository edit was performed. Existing staged and unstaged work was
preserved.

## Implemented and tested

The modern client now exposes additive typed declaration APIs:
`list_tool_declarations`, `list_resource_declarations`,
`list_resource_template_declarations`, and `list_prompt_declarations`. Each
decoder validates required fields against the frozen `2026-07-28` declaration
shapes, retains optional prompt arguments, icons, generic resource annotations,
tool behavior hints, arbitrary schema documents, and `_meta` values. Those
arbitrary schema and `_meta` values remain ordinary `json.Json`. Explicit
`_json` compatibility methods remain available for callers that have not
migrated. List-page envelope decoding now uses ordinary Gleam JSON; Blueprint
remains in the schema-bearing structured-tool-value path.

The stdio client now supports `subscriptions/listen` over the existing owned
child process. The actor serializes the subscription handshake and notification
reads, retains unsolicited JSON-RPC notifications while another request is
waiting, correlates each event through the subscription ID, and reports timeout,
malformed peer, and child-exit failures. Notification retention is FIFO, a
timed-out read preserves notifications for other subscriptions, and closing a
stdio subscription sends `notifications/cancelled`, discards only that
subscription's buffered events, and leaves the shared child usable. Pending
frames and notifications have an explicit 256-frame bound; every overflow path
closes the retained port before evicting it. Deterministic fixtures cover
acknowledgement batches, declaration-shaped peers, ordered cross-subscription
timeout retention, cancellation with a follow-up request, and a 257-frame
overflow.

The authorization module now has an executable pure resource-server seam. A
verifier returns an explicit attestation containing the principal, exact
audience set, and actual scopes. Admission rejects absent, additional, or
wrong audiences and missing endpoint scopes, while grants retain every
attested scope. `visible_declarations` and `dispatch_granted` recheck the
registry resource and endpoint scopes before policy, decoding, or handler
execution. Unknown, hidden, and execution-denied tools remain distinct
inaccessible outcomes. The verifier remains responsible for token parsing and
external cryptographic verification; no fake JWT/JWKS implementation was
introduced.

The public test-kit constructors no longer crash on use: scripted-peer and
fake-clock markers are constructible, fake clocks can be advanced without
sleeping, and the existing paired-transport marker remains a compatibility
entry point. This is intentionally small; it does not pretend to provide a
general test transport.

## Oracle provenance and executable cases

The structural wire oracle is the frozen upstream MCP schema at
`test/fixtures/mcp_2026/schema.json.source`, upstream repository
`modelcontextprotocol/modelcontextprotocol`, tag `2026-07-28`, commit
`5f5440bb26a62e2cf3440b92da5a667efa03b267`, upstream path
`schema/2026-07-28/schema.json`, MIT license from the adjacent fixture
`LICENSE`, SHA-256
`ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203`.
`scripts/relay_schema_check.py` ran the executable corpus in
`test/relay_protocol_corpus.gleam`: 17 messages matched and 40 single-field
malformations were rejected.

The official peer oracle is
`@modelcontextprotocol/conformance@0.2.0-alpha.10`, pinned in
`scripts/conformance/pnpm-lock.yaml` (package license MIT; repository
`modelcontextprotocol/conformance`). `scripts/conformance/run-server-suite.sh`
ran its complete 40-scenario server suite against the local Relay endpoint:
109 checks passed and 0 failed. The conformance package's dependency graph
includes `@modelcontextprotocol/sdk@1.30.0`; this is the executable pinned
peer path used by the suite. The repository design retains separate pinned
TS/Python SDK source revisions for future direct client fixtures; this wave did
not add a second network or dependency harness because the local official
conformance suite already exercised the implemented HTTP server surface.

Direct local oracle cases are named and executable:

| Case                                                                    | Evidence                                                                                                                            |
| ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `stdio_client_subscriptions_retain_ack_and_notifications_test`          | One stdio batch containing acknowledgement then list-change notification; typed filter and event returned in order.                 |
| `stdio_client_skips_notifications_and_rejects_unrelated_responses_test` | A valid notification is retained while an unrelated response ID still fails the request.                                            |
| `stdio_client_preserves_frozen_declaration_fields_test`                 | Tool hints, generic annotations, icons, arbitrary metadata, and a prompt without `arguments` survive typed decoding.                |
| `stdio_subscription_is_ordered_cancellable_and_timeout_safe_test`       | FIFO delivery, timeout preservation for another subscription, cancellation frame, closed-handle rejection, and follow-up discovery. |
| `stdio_frame_overflow_closes_the_owned_child_test`                      | A deterministic 257-frame burst reaches the configured bound and leaves the owned client closed.                                    |
| `admits_verified_principal_and_configured_scope_test`                   | An attested principal, exact audience, and actual scopes become an opaque grant.                                                    |
| `rejects_verifier_failure_without_grant_test`                           | A typed verifier rejection is returned without a grant.                                                                             |
| `rejects_wrong_and_additional_audiences_test`                           | Admission rejects a wrong audience and an additional audience.                                                                      |
| `retains_attested_scopes_and_rechecks_registry_requirements_test`       | Cross-resource reuse and insufficient endpoint scopes fail before protected listing or dispatch.                                    |
| `gun_http_client_discovery_and_typed_call_test`                         | Live local HTTP peer returns 107 legacy declarations and 107 typed tool declarations.                                               |
| `relay_schema_check.py`                                                 | Frozen upstream schema and malformed-message mutations.                                                                             |
| `run-server-suite.sh`                                                   | Pinned official MCP conformance peer.                                                                                               |

## Complexity register and remaining scope

| Area                                                                                     | Smallest honest next step                                                                                                                  | Wave 4 disposition                                                                                                   |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| JWT/JWKS rotation, introspection, RFC 9728 metadata/challenge, protected HTTP middleware | Adopt a pinned established BEAM JOSE/JWKS or introspection dependency and port its focused oracle cases behind the existing verifier seam. | Deferred as security machinery; no hand-rolled cryptography.                                                         |
| 2025-11-25 compatibility                                                                 | Add a separate revision codec and session lifecycle with its own fixtures.                                                                 | Deferred; modern and legacy contracts remain separate.                                                               |
| Client authorization                                                                     | Add explicit OAuth discovery/token/PKCE state machines with a pinned peer oracle.                                                          | Deferred; substantial independent subsystem.                                                                         |
| Tasks and Apps                                                                           | Add the frozen revision-specific models, lifecycle, and cancellation semantics.                                                            | Deferred; no honest minimal implementation was available from this wave's contract.                                  |
| Logging                                                                                  | Add only a typed, explicit logging contract after the design decision.                                                                     | Remains unimplemented; the previously rejected arbitrary handler-JSON emitter was not recreated.                     |
| Direct pinned TS/Python client fixtures                                                  | Add local fixtures using the design's pinned TS 2.0.0 and Python 2.0.0 revisions, with exact source paths and licenses.                    | Deferred; official conformance already supplies executable peer coverage for the delivered server surface.           |
| Full paired transport                                                                    | Replace the compatibility marker with an in-memory framed transport and deterministic scripted scheduler.                                  | Deferred; current stdio fixture and fake clock cover the direct regressions without inventing a transport framework. |

Modern cache metadata, zero-TTL policy, dynamic registry reconciliation,
subscription lifetime cleanup, SSE bounds, and the accepted Wave 3 races remain
covered by the inherited server implementation and gates. This report does not
claim full MCP feature coverage, 2025 compatibility, client authorization,
Tasks/Apps, cryptographic resource authorization, or release readiness.

## Correction-wave friction and complexity

The main implementation friction was preserving one actor-owned stdio history
while a synchronous wait consumes port messages. A timeout must return the
evolved actor state, queued calls must be replayed in arrival order, and a
subscription close must be represented in actor state because the public
subscription value is immutable. The smallest coherent solution stayed inside
the existing owner: FIFO lists, an explicit evolved-state await error, a
closed-subscription set, and one cancellation frame path. The bound remains a
deliberate terminal condition; the port is closed before state eviction so a
burst cannot orphan the child.

The authorization correction exposed a similar authority boundary. A
principal-only verifier result could not justify resource or scope claims, so
the adapter now returns an attestation and Relay performs exact admission and
registry-use checks. This records the pure contract without pretending to
verify JWTs, introspect tokens, or integrate protected HTTP.

## Verification

All commands were awaited synchronously:

| Command                                                     | Result                                                   |
| ----------------------------------------------------------- | -------------------------------------------------------- |
| `nix develop -c gleam check --target erlang`                | Pass.                                                    |
| `nix develop -c gleam format --check`                       | Pass.                                                    |
| `nix develop -c gleam test --target erlang`                 | **107 passed, 0 failed.**                                |
| `nix develop -c python3 scripts/relay_schema_check.py`      | **17 messages passed; 40 malformed mutations rejected.** |
| `nix develop -c python3 scripts/check_negative_fixtures.py` | **1/1 compiler-negative fixture passed.**                |
| `nix develop -c ./scripts/verify_checksums.sh`              | Frozen schema and sibling dependency pins passed.        |
| `./scripts/conformance/run-server-suite.sh`                 | **109 checks across 40 scenarios passed; 0 failed.**     |
| `git diff --check HEAD`                                     | Pass.                                                    |

The conformance run produced the expected zero-check report for
`input-required-result-missing-input-response`; the suite summary still had
109 passed checks and zero failures. The repository's current Nix target is the
available `aarch64-darwin` environment; incompatible target checks were not
claimed.
