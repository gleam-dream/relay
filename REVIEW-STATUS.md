# Relay Wave 4 focused rereview

## Verdict

- **PASS — accept the focused correction subset.** The four HIGH findings in
  `relay-wave4-review.md` are closed in the dirty Relay tree based on checkpoint
  `c293b53`. No new blocking finding was found within those repaired surfaces.
- This verdict accepts the pure authorization contract, exact typed declaration
  preservation, and the repaired stdio subscription lifetime and buffering
  behavior. It does not accept the full Wave 4 work order, full MCP coverage,
  package completion, release readiness, or production authorization.
- Protected HTTP routing, bearer extraction, RFC 9728 metadata and challenges,
  JWT/JWKS or introspection, client authorization, `2025-11-25` compatibility,
  Tasks/Apps, direct TS/Python client fixtures, full test helpers, logging, and
  release hardening remain deferred. In particular, the constructible verifier
  attestation is a trusted pure adapter assertion; it does not prove token
  parsing, signature validation, issuer/expiry checks, key rotation, or HTTP
  enforcement.

## Closure of the prior HIGH findings

### Accepted · verifier attestation, exact admission, and registry-use rechecks

- `src/relay/authorization.gleam:69-75,94-135` makes the verifier return an
  explicit attestation containing the principal, audiences, and actual scopes.
- `src/relay/authorization.gleam:207-225` admits only a singleton audience equal
  to the configured resource, checks every configured endpoint scope, rejects
  absent, duplicate, additional, and wrong audiences, and retains the complete
  attested scope list in the opaque grant.
- `src/relay/authorization.gleam:242-253,272-335` checks the grant against the
  protected registry's resource and endpoint scopes before tool lookup, policy,
  argument decoding, or handler dispatch. Listing and dispatch both use this
  check. Unknown, hidden, and execution-denied tools remain distinct outcomes.
- `test/relay/authorization_test.gleam:11-116` exercises successful admission,
  verifier rejection, wrong and additional audiences, retention of extra
  attested scopes, cross-resource reuse rejection, and a stronger registry's
  missing-scope rejection. The source ordering supplies the decisive
  before-policy and before-dispatch guarantee.

### Accepted · complete valid frozen declaration fields

- `src/relay/client.gleam:81-167` separates frozen `Icon`, generic
  `Annotations`, and `ToolAnnotations` models. Tool, resource, resource-template,
  and prompt declarations retain all fields in their frozen `2026-07-28`
  shapes, including icons and `_meta`; arbitrary schemas and metadata remain
  ordinary `json.Json`.
- `src/relay/client.gleam:1290-1414,1631-1749` decodes generic
  `lastModified`, every tool behavior hint, every icon field, optional prompt
  arguments, and prompt-argument `title`. A missing prompt `arguments` member
  becomes an empty list, which is an accepted representation of the optional
  frozen member.
- `test/fixtures/stdio/declaration-peer` and
  `test/relay/client_test.gleam:338-390` provide a direct peer regression with
  tool hints, generic annotations, all icon variants, arbitrary schema and
  metadata members, and a conforming prompt without `arguments`.

### Accepted · stdio subscription cancellation and shared-child continuity

- `src/relay/client.gleam:745-753` routes stdio close through the owning actor.
  `src/relay/transport/stdio_client.gleam:398-425,754-794` sends a correlated
  `notifications/cancelled` frame, records the subscription as closed, removes
  only its buffered notifications and frames, and makes repeated close
  idempotent.
- `test/fixtures/stdio/subscription-lifecycle-peer` remains alive after the
  subscription handshake and answers discovery only after observing a
  cancellation. `test/relay/client_test.gleam:392-439` proves cancellation,
  closed-handle rejection, and successful follow-up discovery on the shared
  child.

### Accepted · FIFO retention, timeout preservation, bounds, and cleanup

- `src/relay/transport/stdio_client.gleam:60-68,350-395,567-721` carries the
  evolved actor state in `AwaitError`, preserves it on notification timeout,
  appends retained notifications in arrival order, and removes a matching
  notification without reordering the rest.
- `src/relay/transport/stdio_client.gleam:428-457,724-751` applies the 256-frame
  bound and closes the retained child port before resetting state on idle
  overflow or child exit. Active request, subscription, and notification waits
  also close the retained port on terminal framing or buffer errors before
  clearing the client state.
- `test/fixtures/stdio/subscription-lifecycle-peer` emits two ordered
  notifications for subscription B while subscription A is waiting.
  `test/relay/client_test.gleam:392-439` proves A's timeout preserves both B
  events and that B receives them FIFO. `test/fixtures/stdio/overflow-peer` and
  `test/relay/client_test.gleam:441-455` exercise a deterministic 257-frame
  burst and prove the owned client becomes terminal after cleanup.

## Independent gates

- `nix develop -c gleam test --target erlang`: **107 passed, 0 failed**. The
  expected untrusted-CA and broken-child diagnostics appeared.
- `./scripts/conformance/run-server-suite.sh`: **109 passed, 0 failed across 40
  scenarios**. `input-required-result-missing-input-response` emitted the
  documented zero checks. This suite covers the unprotected HTTP server and is
  regression evidence, not evidence for the deferred protected HTTP surface.
- `nix develop -c gleam check --target erlang`: pass.
- `nix develop -c gleam format --check`: pass.
- `nix develop -c python3 scripts/relay_schema_check.py`: **17 valid messages
  passed; 40 malformed single-field mutations rejected**.
- `nix develop -c python3 scripts/check_negative_fixtures.py`: **1/1 compiler
  negative fixture passed**.
- `nix develop -c ./scripts/verify_checksums.sh`: frozen MCP schema and sibling
  dependency pins passed.
- `nix flake check`: pass for the available `aarch64-darwin` checks; Nix reported
  the other systems as incompatible and omitted them.
- `git diff --check c293b53`: pass.

## Review limits

- The rereview read the complete dirty Relay working tree, including the new
  untracked authorization test and stdio fixtures. It made no Relay source
  edits, commits, remote changes, provider calls, or credential use.
- The installed implementation-review skill could not run its prescribed
  four-agent process because this task explicitly prohibited subagents and the
  skill's referenced primitive files were absent. This report therefore uses a
  direct focused rereview against the four prior HIGH findings and the supplied
  acceptance boundary.
