# Wave 5 migration

Wave 5 makes one request followable from a Relay client to a Relay server,
gives a verifier the request's correlation, adds an optional idempotency
key, gives a handler the JSON-RPC request id, and lets a verifier report a
token issued for another resource.

Breaking changes, each with its section below:

| Item                                 | Before                                          | After                                                           |
| ------------------------------------ | ----------------------------------------------- | --------------------------------------------------------------- |
| `authorization.verifier`             | `verifier(name, fn(BearerToken) -> Result(..))` | `verifier(name, fn(BearerToken, Correlation) -> Result(..))`    |
| `authorization.admit`                | `admit(verifier, token, protection)`            | `admit(verifier, token, protection, correlation)`               |
| `tool.correlation`                   | `-> Option(Correlation)`                        | `-> Correlation`                                                |
| `reducer.invocation_correlation`     | `-> Option(Correlation)`                        | `-> Correlation`                                                |
| `telemetry.ExchangeClosedMeta`       | `ExchangeClosedMeta(exchange_id:, listener:)`   | `ExchangeClosedMeta(exchange_id:, correlation:, listener:)`     |
| `correlation` of 9 telemetry records | `correlation: Option(Correlation)`              | `correlation: Correlation` (see `relay/telemetry`)              |
| `authorization.VerificationError`    | 3 variants                                      | adds `IssuedForAnotherResource` (exhaustive matches add an arm) |

## The correlation carrier

MCP `2026-07-28` defines no correlation or trace field. Relay uses the
gleam-dream ecosystem's correlation carrier:

- the request `_meta` key `io.github.gleam-dream/correlation`, on every
  transport; and
- over HTTP, also the header `x-correlation-id`, which the endpoint reads
  before the body, so the authorization decision and the verifier see the
  same value as the handler.

A Relay client sends the correlation of its view (`client.with_correlation`,
or the correlation of its HTTP Gun view). A receiver accepts a carried value
only when `sinal/correlation.from_string` accepts it (1 to 128 bytes) and
every byte is visible ASCII (`!` to `~`); anything else is ignored. The
client sends only such values.

Each request now has exactly one correlation, chosen in this order:

| Transport                          | First                              | Then                          | Then                   |
| ---------------------------------- | ---------------------------------- | ----------------------------- | ---------------------- |
| `relay/http`                       | the `with_correlation` builder     | the `x-correlation-id` header | `correlation.unique()` |
| stdio, in-process, custom runtimes | the transport's `send_frame` value | the `_meta` key               | `correlation.unique()` |

Relay never uses the value to authorize anything. It is client input: two
clients can send the same value, and a client can send another client's.

## `relay/tool`

### `correlation` returns a `Correlation` (breaking)

Every request has a correlation, so the `Option` is gone.

```gleam
// before
let correlation =
  option.lazy_unwrap(tool.correlation(call), correlation.unique)
// after
let correlation = tool.correlation(call)
```

A caller that passed `tool.correlation(call)` on as an `Option` wraps it:
`Some(tool.correlation(call))`.

### `idempotency_key` (added)

```gleam
pub fn idempotency_key(call: Call(context)) -> Option(String)
```

The key the client sent in `_meta` under
`io.github.gleam-dream/idempotency-key`, set with
`client.with_idempotency_key`. A retry that carries the same key is the
client's promise that it is the same request. The key is untrusted and
bounded: Relay accepts 1 to 128 visible ASCII characters and refuses a
request with any other value as invalid params (`-32602`), because
dropping it would turn a retry into new work. Key idempotent work by the
principal the server authenticated together with the key.

```gleam
// before: a retried call started a second run
let id = run.new_id()
// after
let id = case tool.idempotency_key(call) {
  Some(key) -> run_id_for(principal, key)
  None -> run.new_id()
}
```

### `request_id` and `RequestId` (added)

```gleam
pub type RequestId {
  StringId(String)
  IntegerId(Int)
}

pub fn request_id(call: Call(context)) -> RequestId
```

The JSON-RPC `id` exactly as the client sent it. MCP `2026-07-28` has no
session: the id is unique only among the client's own requests in flight,
may repeat across clients, and is fresh on a retry, so it does not identify
one; use `idempotency_key`. `tool.invocation_id(call)` is unchanged; its
doc now states that it is Relay's own id, new for every request.

## `relay/client`

### `with_idempotency_key` (added)

```gleam
pub fn with_idempotency_key(client: Client, key: String) -> Client
```

A view whose requests carry `key`. Use one view per logical request and its
retries. A key that is not 1 to 128 visible ASCII characters fails each
request with `InvalidArguments` before it is sent.

### Per-call correlation (behaviour)

A view without a correlation now mints `correlation.unique()` for each
request, sends it like a view correlation, and puts it on its own
`[relay, client, call]` event and HTTP Gun events, which before carried
`None`. A handler of client events that treated `correlation: None` as
"untagged" sees `Some(..)` instead; two calls through the same untagged view
get two correlations.

### Verifier 403

No `VerificationError` variant for 403 is added. Warden's `Forbidden` arises
only from a missing required scope, and Relay already answers that with 403
`insufficient_scope` naming the endpoint's scopes: leave warden's
`with_required_scopes` unset, attest the token's scopes, and put the
required ones in `authorization.protection(resource, scopes)`.

### `with_correlation` (behaviour)

The view's correlation now travels to the server in the `_meta` key and,
over HTTP, the `x-correlation-id` header. The signature is unchanged. The
in-process client (`client.in_process`, `testing.connect`) now passes the
correlation through `_meta`, like a wire client, instead of handing it to
the runtime directly; a correlation that is not visible ASCII therefore no
longer reaches an in-process handler, which gets a fresh one instead.

## `relay/http`

### `with_correlation` (behaviour)

```gleam
// before: None meant "no correlation"
http.with_correlation(fn(_request) { Some(correlation.unique()) })
// after: the default already falls back to the client's header, then a
// fresh value; delete the builder unless it reads another header
http.new(service)
```

A builder that returns `None` now falls through to the client's
`x-correlation-id` header and then to `correlation.unique()`. A builder that
always returns `Some(correlation.unique())` hides the client's correlation;
delete it.

## `relay/authorization`

### `IssuedForAnotherResource` (added variant)

```gleam
pub type VerificationError {
  BearerRejected
  VerifierUnavailable
  VerifierUnmapped
  IssuedForAnotherResource
}
```

A verifier that checks the audience itself returns
`IssuedForAnotherResource` for a valid token issued for another resource.
`challenge` renders it exactly as it renders `ResourceNotGranted`: 401 with
`error="invalid_token", error_description="The access token was issued for
another resource"` and the metadata URL. `[relay, authorization, decided]`
reports `WrongResource`.

A `case` that matches `VerificationError` exhaustively must add the arm;
branch on `verification_kind` instead.

### `VerificationKind`, `verification_kind`, `describe_verification_error` (added)

```gleam
pub type VerificationKind {
  InvalidToken
  Unavailable
}

pub fn verification_kind(error: VerificationError) -> VerificationKind
pub fn describe_verification_error(error: VerificationError) -> String
```

The stable classification of the growing `VerificationError` union:
`InvalidToken` answers 401, `Unavailable` answers 503.

### `verifier` and `admit` take the correlation (breaking)

```gleam
// before
pub fn verifier(
  name: String,
  verify: fn(BearerToken) -> Result(Attestation(principal), VerificationError),
) -> Verifier(principal)
pub fn admit(verifier, token, protection) -> Result(Grant(principal), AdmissionError)
// after
pub fn verifier(
  name: String,
  verify: fn(BearerToken, Correlation) ->
    Result(Attestation(principal), VerificationError),
) -> Verifier(principal)
pub fn admit(verifier, token, protection, correlation) -> Result(Grant(principal), AdmissionError)
```

```gleam
// before
use token <- authorization.verifier("introspection")
introspect(client, token)
// after: the introspection call joins the MCP request
use token, correlation <- authorization.verifier("introspection")
introspect(warden.with_correlation(client, correlation), token)
// a verifier that does not need it
use token, _correlation <- authorization.verifier("jwt")
```

`http.new_protected` passes the request's correlation, the one its events
and handler carry. A custom transport passes its request's correlation to
`admit`, or `correlation.unique()` when it has none. The correlation may
come from the client and never decides admission.

## `relay/telemetry`

### `ExchangeClosedMeta.correlation` (breaking for positional patterns)

```gleam
// before
ExchangeClosedMeta(exchange_id: Int, listener: Option(String))
// after
ExchangeClosedMeta(
  exchange_id: Int,
  correlation: Option(Correlation),
  listener: Option(String),
)
```

Read fields by label (`m.exchange_id`, `m.correlation`). Every server event
of an admitted request, `exchange.closed` included, now carries the
request's correlation; before, a request without `http.with_correlation`
had none.

### `correlation` is a `Correlation` on every record (breaking)

Every request has a correlation and the client mints one per call, so the
`correlation` field of these records is `Correlation`, not
`Option(Correlation)`, and the events write it with
`sinal/correlation.required_field()`: `RequestAdmittedMeta`,
`InvocationStartedMeta`, `InvocationCompletedMeta`,
`InvocationCancelledMeta`, `InvocationCrashedMeta`, `ExchangeClosedMeta`,
`HttpRejectedMeta`, `AuthorizationDecidedMeta` and `ClientCallMeta`.
`FrameRejectedMeta` has no correlation field, as before. Relay has no
listener start or stop event, so no record keeps an `Option`.

```gleam
// before
case m.correlation {
  Some(correlation) -> correlation.to_string(correlation)
  None -> "-"
}
// after
correlation.to_string(m.correlation)
```

An `HttpRejectedMeta` for a refusal before the endpoint reads the request
(a body over the limit or unreadable at the mist layer) carries a fresh
correlation; one for a 503 over the request or stream cap carries the
client's `x-correlation-id`, else a fresh one. A handler that reads these
events with `correlation.field()` still works and sees `Some(..)`.

## `relay/reducer` and `relay/runtime`

```gleam
// before
pub fn invocation_correlation(invocation) -> Option(Correlation)
// after
pub fn invocation_correlation(invocation) -> Correlation
```

`reducer.Received(.., correlation: None)` and `runtime.send_frame(.., None)`
now use the frame's `_meta` correlation, else a fresh one, instead of
leaving the request without one.

## Dependents

Grep of `/code/gleam-dream/*/{src,test,integrations,consumers,examples}` and
`oversight/apps` on 3 October 2026. No package outside the apps and warden's
recipe check uses the changed items; fabric has no Relay dependency yet.

| Dependent                                                                                                       | Uses                                                                                | Effect                                                                                                                                                                                             |
| --------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `oversight/apps/tool_hub/src/tool_hub/assistant.gleam:221`                                                      | `option.lazy_unwrap(relay_tool.correlation(call), correlation.unique)`              | **breaks** (type): use `relay_tool.correlation(call)`                                                                                                                                              |
| `oversight/apps/tool_hub/src/tool_hub/assistant.gleam:229`                                                      | `http.with_correlation(fn(_request) { Some(correlation.unique()) })`                | compiles; delete it so the external caller's correlation reaches the assistant server (the default mints one when none is sent)                                                                    |
| `oversight/apps/tool_hub/src/tool_hub/telemetry.gleam:272`                                                      | `exchange_closed_event` with `ExchangeKey(m.exchange_id)`                           | compiles; can key by `m.correlation` now. With the agent's inventory client sending the question's correlation, the inventory server's 12 events and the closed exchanges join the question (TH-7) |
| `oversight/apps/tool_hub` handler                                                                               | a retried `ask_assistant` starts a second run                                       | can derive the run id from `relay_tool.idempotency_key(call)` when the caller uses `client.with_idempotency_key`                                                                                   |
| `oversight/apps/secure_mcp/src/secure_mcp/tools.gleam:79`                                                       | `tool.correlation(call)` passed as `Option(Correlation)`                            | **breaks** (type): pass `tool.correlation(call)` and make `generate_report` take a `Correlation`, or wrap it in `Some`                                                                             |
| `oversight/apps/secure_mcp/src/secure_mcp/auth.gleam:20`                                                        | `authorization.verifier("warden-jwt", resource.verifier(..))`                       | **breaks** (arity): wrap as `fn(token, _correlation) { verify(token) }`, or have warden's `resource.verifier` return a two-argument function                                                       |
| `oversight/apps/secure_mcp/src/secure_mcp/auth.gleam:44`                                                        | `use token <- authorization.verifier("warden-introspection")`                       | **breaks** (arity): `use token, correlation <- ..`, and introspect through `warden.with_correlation(client, correlation)` (SMCP-9)                                                                 |
| `oversight/apps/tool_hub/src/tool_hub/telemetry.gleam:205,217,235,247,259,271,292`                              | `key_of(m.correlation, ..)` with `key_of(Option(Correlation), Key)` on relay events | **breaks** (type): pass `Some(m.correlation)`, or key relay events by `m.correlation` directly                                                                                                     |
| `oversight/apps/secure_mcp/src/secure_mcp/telemetry.gleam:78,90,102,116,132,143,155,177`                        | `optional(m.correlation)` on relay events                                           | **breaks** (type): `correlation.to_string(m.correlation)`                                                                                                                                          |
| `fabric/integrations/fabric_relay/src/fabric_relay.gleam:483`                                                   | `Some(relay_tool.correlation(call))` into fabric's own record                       | unaffected: reads no Relay telemetry record                                                                                                                                                        |
| `oversight/apps/secure_mcp/src/secure_mcp/app.gleam:119`                                                        | `http.with_correlation(request_correlation)` reading `x-request-id`                 | compiles; when the header is absent the request now uses a client's `x-correlation-id` before minting                                                                                              |
| `warden/relay_consumer/src/recipe.gleam:20`                                                                     | `authorization.verifier("warden-jwt", resource.verifier(..))`                       | **breaks** (arity): as for secure_mcp's `auth.gleam:20`                                                                                                                                            |
| `warden/relay_consumer/src/recipe.gleam:44`                                                                     | `use token <- authorization.verifier("warden-introspection")`                       | **breaks** (arity): `use token, correlation <- ..` with `warden.with_correlation(client, correlation)`                                                                                             |
| `warden/relay_consumer/test/relay_consumer_test.gleam:47`                                                       | `authorization.admit(verifier, token, protection())`                                | **breaks** (arity): `authorization.admit(verifier, token, protection(), correlation.unique())`                                                                                                     |
| `warden/README.md:193,217`, `warden/src/warden/resource.gleam:77,101` (doc recipe mirrored into `recipe.gleam`) | the same two verifier forms                                                         | the same changes; warden can map its audience failure to `IssuedForAnotherResource`                                                                                                                |
| `oversight/playground/interface_lab`                                                                            | its own `lab/relay_*` modules and an older Relay API                                | not affected; it does not compile against the wave 4 API either                                                                                                                                    |

## Round 7: every `client.Error` carries its call's correlation

secure_mcp found that a refused call, `Error(HttpStatus(401, _))`, does not
say which correlation the call was sent with. A view without a correlation
mints one per call, so the caller could not tie the failure to the server's
rejection event or logs.

| Item                                 | Before                                      | After                                                            |
| ------------------------------------ | ------------------------------------------- | ---------------------------------------------------------------- |
| `client.error_correlation`           | none                                        | `error_correlation(error: Error) -> Correlation` (added)         |
| every `client.Error` variant         | `HttpStatus(status, www_authenticate)`, ... | each ends with `correlation: Correlation` (breaking, positional) |
| `client.listen`, `next_notification` | errors carry no correlation                 | carry the stream's correlation                                   |

### The choice: an accessor over a field on every variant

`Error` is a public union that callers match, and a Gleam variant cannot
gain data without gaining a field, so no accessor can be added to the
existing variants without changing their arity. A side channel (a process
dictionary, a lookup table) would not survive a retry on another process
and would hide the value from `string.inspect` and from equality. The change
therefore does two things:

- every variant ends with a labelled `correlation: Correlation`, the same
  name and position (last) in all 16 variants, so a future variant follows
  one rule;
- `error_correlation(error)` reads it, so callers do not match 16 variants
  to find it. Gleam cannot read a field shared by variants of different
  arity, which is why the accessor is the supported way.

Matches that bind the payload break once; the fix is mechanical. Matches
that end in `..`, such as `RpcError(code: -32_602, ..)`, and every use of
`kind`, `evidence`, `name`, `describe_error` and `is_retryable` are
unaffected. The doc comment of `Error` already told callers to branch on
`kind` and `evidence`; it now says to end payload patterns with `..`.

```gleam
// before
case client.discover(peer) {
  Error(client.HttpStatus(401, Some(challenge))) -> reauthorize(challenge)
  Error(client.TimedOut(client.MaybeSent)) -> retry()
  _ -> Nil
}
// after: `..` skips the correlation
case client.discover(peer) {
  Error(client.HttpStatus(401, Some(challenge), ..) as refused) -> {
    log.warning(
      "refused, correlation "
      <> correlation.to_string(client.error_correlation(refused)),
    )
    reauthorize(challenge)
  }
  Error(client.TimedOut(client.MaybeSent, ..)) -> retry()
  _ -> Nil
}
```

### Which correlation an error carries

| Where the error arises                                                                                                                          | Correlation                                                                                                                                   |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| any request: HTTP status, JSON-RPC error, malformed, too large, timeout, cancellation, connection closed, connect failed, pending-call overflow | the view's `with_correlation`, else the one minted for that call; the client's `[relay, client, call]` event and the server's events carry it |
| a failure after the response: wrong result shape, `UnsupportedVersion`, unadvertised input request                                              | the correlation of the request that was answered                                                                                              |
| a failure before the request: encoding, non-object arguments, bad idempotency key, `InvalidInputResponses`, a routing-name mistake              | the correlation the request would have carried; nothing was sent                                                                              |
| `client.http`, `client.connect`, a bad setting                                                                                                  | a fresh `correlation.unique()` that no server saw; there is no call yet                                                                       |
| `client.listen` and `next_notification`                                                                                                         | the stream's correlation, which `listen` sent                                                                                                 |

A correlation that is not visible ASCII stays local, as before (the server
mints its own); the error still carries the value the caller set.

### Behaviour: one correlation per listing, per call and `resume`

A view without a correlation now mints it once for a whole listing
(`list_tools`, `list_resources`, `list_resource_templates`, `list_prompts`,
`list_raw`), so its pages and its `ListingLimitExceeded` share it; before,
each page minted its own. A tool call that returns `InputRequired` and the
`resume` of its continuation share the call's correlation when the view has
none; before, the resume minted a new one. A handler of client events that
joined on "one correlation per request" sees the same value on every page
and round of one logical call. Views with `with_correlation` are unchanged.

### Dependents

Grep of `/code/gleam-dream/*/{src,test,integrations,consumers,examples}`
and `oversight/apps`, `oversight/playground` on 4 October 2026. Only
positional patterns of the changed variants break; nothing else outside
Relay constructs a `client.Error`.

| Dependent                                                                          | Uses                                                                                            | Effect                                                                                                                                                           |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `oversight/apps/secure_mcp/src/secure_mcp.gleam:136`                               | `Error(mcp.HttpStatus(status, challenge))`                                                      | **breaks** (arity): `mcp.HttpStatus(status, challenge, correlation)`; read it with the pattern, or `error_correlation` and put it in the `refusal` text (SMCP-6) |
| `oversight/apps/secure_mcp/test/secure_mcp_test.gleam:171,202,242,257,301,310,313` | `mcp.HttpStatus(401, Some(challenge))` patterns and one `==` against a constructed `HttpStatus` | **breaks** (arity): add `..`; the `==` at 171 cannot compare a correlation, so match the status and challenge and assert the correlation separately              |
| `oversight/apps/tool_hub/test/tool_hub_test.gleam:692,727`                         | `client.Cancelled(client.MaybeSent)`, `client.TimedOut(client.MaybeSent)`                       | **breaks** (arity): add `, ..`                                                                                                                                   |
| `oversight/apps/tool_hub/src/tool_hub.gleam:283`                                   | `client.describe_error(error)`                                                                  | compiles; can log `client.error_correlation(error)` beside it, which joins the inventory server's events (TH-7)                                                  |
| `fabric/integrations/fabric_relay/test/serve_test.gleam:392`                       | `Error(client.TimedOut(_))`                                                                     | **breaks** (arity): `client.TimedOut(_, ..)`                                                                                                                     |
| `fabric/integrations/fabric_relay/src/fabric_relay.gleam:165,295,299,319`          | `ListingFailed(client.Error)`, `CallFailed(client.Error)`, `describe_error`, `name`, `evidence` | compiles; its failure records can read `error_correlation` to name the call's correlation next to the run's                                                      |
| `fabric/integrations/fabric_relay/test/remote_tool_test.gleam:335`                 | `client.evidence(error)`                                                                        | unaffected                                                                                                                                                       |
| `oversight/playground/ecosystem_pilot`                                             | `client.InvalidInputResponses` and other pre-wave-4 names                                       | not affected; it already fails to compile against the wave 4 API                                                                                                 |
| `warden/relay_consumer`, `oversight/apps/*` other than the two above               | no `client.Error` pattern                                                                       | not affected                                                                                                                                                     |
