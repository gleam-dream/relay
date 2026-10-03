# Wave 5 migration

Wave 5 makes one request followable from a Relay client to a Relay server,
gives a verifier the request's correlation, gives a handler the JSON-RPC
request id, and lets a verifier report a token issued for another resource.
Most changes are additive. Three are breaking: `tool.correlation` returns a
`Correlation` instead of an `Option`, `reducer.invocation_correlation`
likewise, and `telemetry.ExchangeClosedMeta` gains a `correlation` field.

## The correlation carrier

MCP `2026-07-28` defines no correlation or trace field, so Relay carries its
own:

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

### `request_id` and `RequestId` (added)

```gleam
pub type RequestId {
  StringId(String)
  IntegerId(Int)
}

pub fn request_id(call: Call(context)) -> RequestId
```

The JSON-RPC `id` exactly as the client sent it. MCP `2026-07-28` has no
session and no idempotency key, so nothing in the protocol marks a retry:
the id is unique only among the client's own requests in flight, may repeat
across clients, and a retry carries it only when the client reuses it on
purpose. Key idempotent work by the id together with the principal the
server authenticated. `tool.invocation_id(call)` is unchanged; its doc now
states that it is Relay's own id, new for every request, retries included.

## `relay/client`

### `with_request_id` (added)

```gleam
pub fn with_request_id(client: Client, id: String) -> Client
```

A view whose requests use `id` as their JSON-RPC id, so a server sees a
retry as `tool.StringId(id)`. Use one view per logical call and its
retries.

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

### `correlated_verifier` and `admit_with_correlation` (added)

```gleam
pub fn correlated_verifier(
  name: String,
  verify: fn(BearerToken, Correlation) ->
    Result(Attestation(principal), VerificationError),
) -> Verifier(principal)

pub fn admit_with_correlation(
  verifier: Verifier(principal),
  token: BearerToken,
  protection: Protection,
  correlation: Correlation,
) -> Result(Grant(principal), AdmissionError)
```

```gleam
// before: an introspection verifier could not tag its HTTP call
use token <- authorization.verifier("introspection")
introspect(client, token)
// after
use token, correlation <- authorization.correlated_verifier("introspection")
introspect(warden.with_correlation(client, correlation), token)
```

`http.new_protected` passes the request's correlation. `admit` is unchanged
and gives a correlated verifier a fresh correlation; a custom transport that
has the request's correlation calls `admit_with_correlation`.

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

| Dependent                                                  | Uses                                                                                             | Effect                                                                                                                                                                                             |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `oversight/apps/tool_hub/src/tool_hub/assistant.gleam:221` | `option.lazy_unwrap(relay_tool.correlation(call), correlation.unique)`                           | **breaks** (type): use `relay_tool.correlation(call)`                                                                                                                                              |
| `oversight/apps/tool_hub/src/tool_hub/assistant.gleam:229` | `http.with_correlation(fn(_request) { Some(correlation.unique()) })`                             | compiles; delete it so the external caller's correlation reaches the assistant server (the default mints one when none is sent)                                                                    |
| `oversight/apps/tool_hub/src/tool_hub/telemetry.gleam:272` | `exchange_closed_event` with `ExchangeKey(m.exchange_id)`                                        | compiles; can key by `m.correlation` now. With the agent's inventory client sending the question's correlation, the inventory server's 12 events and the closed exchanges join the question (TH-7) |
| `oversight/apps/tool_hub` handler                          | a retried `ask_assistant` starts a second run                                                    | can derive the run id from `relay_tool.request_id(call)` when the caller uses `client.with_request_id`                                                                                             |
| `oversight/apps/secure_mcp/src/secure_mcp/tools.gleam:79`  | `tool.correlation(call)` passed as `Option(Correlation)`                                         | **breaks** (type): pass `tool.correlation(call)` and make `generate_report` take a `Correlation`, or wrap it in `Some`                                                                             |
| `oversight/apps/secure_mcp/src/secure_mcp/auth.gleam:43`   | `authorization.verifier("warden-introspection", ..)`                                             | compiles; `correlated_verifier` lets the introspection call carry the request's correlation (SMCP-9)                                                                                               |
| `oversight/apps/secure_mcp/src/secure_mcp/app.gleam:119`   | `http.with_correlation(request_correlation)` reading `x-request-id`                              | compiles; when the header is absent the request now uses a client's `x-correlation-id` before minting                                                                                              |
| `warden/relay_consumer` (`src/recipe.gleam`, its test)     | `authorization.verifier`, `admit/3`, `BearerRejected`, `VerifierUnavailable`, `VerifierUnmapped` | compiles and passes unchanged (checked against this head); warden can map its audience failure to `IssuedForAnotherResource`                                                                       |
| `warden/src/warden/resource.gleam` (doc recipe)            | as above                                                                                         | unchanged                                                                                                                                                                                          |
| `oversight/playground/interface_lab`                       | its own `lab/relay_*` modules and an older Relay API                                             | not affected; it does not compile against the wave 4 API either                                                                                                                                    |
