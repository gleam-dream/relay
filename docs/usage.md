# Relay usage

These recipes cover application mounting, bearer protection, client controls and
protocol results. Start with the [server and client example](../README.md#serve-a-tool-and-call-it)
for a complete local call.

## Handle failed calls

`client.call` returns `Ok(Succeeded(output, content))`, `Ok(ToolFailed(..))`
when the tool reported a failure, `Ok(InputRequired(..))` when the tool asks
the client for input first, or `Error(client.Error)`. The opaque error
carries the call's context; `client.reason(error)` is the HTTP status, the
JSON-RPC error, or the transport failure with its submission evidence.
Branch on `client.kind(error)` and `client.evidence(error)`, and log
`client.describe_error(error)` with `client.error_correlation(error)`, the
correlation the call was sent with.

## Serve over stdio

```gleam
import relay/server
import relay/stdio

pub fn main() {
  let assert Ok(Nil) = stdio.serve(server.new([]), Nil)
}
```

A client launches it with `client.stdio("my_server", ["--flag"])`. The stdio
transport enforces no authorization: run it under a trusted parent process.

## Mount the endpoint in your application

`http.handler` starts the endpoint without a listener. `http.handle` takes a
`gleam_http` `Request(BitArray)` and returns a buffered `Response(BytesTree)`,
so it mounts in wisp with one line; `http.mist_handler` mounts the full
streaming endpoint in a mist application. The context builder sees the
request, so a context can carry the tenant or the caller:

```gleam
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import relay/http
import relay/server

pub type Tenant {
  Tenant(id: String)
}

pub fn mount(service: server.Server(Tenant)) -> http.Handler(Tenant) {
  let assert Ok(mcp) =
    http.new_with_context(service, fn(req) {
      case request.get_header(req, "x-tenant") {
        Ok(id) -> Ok(Tenant(id))
        Error(Nil) ->
          Error(response.new(400) |> response.set_body(bytes_tree.new()))
      }
    })
    |> http.with_allowed_hosts(["mcp.example.com"])
    |> http.handler
  mcp
}
```

```gleam
// In a wisp router:
["mcp"] -> {
  use body <- wisp.require_bit_array_body(req)
  http.handle(mcp, request.set_body(req, body)) |> response.map(wisp.Bytes)
}
```

`handle` buffers: progress notifications are dropped, a client disconnect
is not seen, and `subscriptions/listen`
answers 406. `http.start`, `http.supervised` and `http.mist_handler` stream
server-sent events, send keepalives, and cancel a call when its client
disconnects, which is how MCP `2026-07-28` cancels over HTTP.

The endpoint timeout bounds handler execution and response waits after context
construction. Context builders and bearer verifiers run synchronously before
those budgets start; callers must bound their database or network work separately.
They can occupy an admitted slot and delay disconnect observation. A shared
admission deadline and callback ownership remain an [unresolved design decision](adr/0008-admission-budget-remains-unresolved.md).

The application owns the mounted endpoint. Call `http.stop(mcp)` when its
router or supervisor stops.

## Protect the endpoint

`http.new_protected` reads the bearer token, asks your verifier, admits the
request for the protected resource and its scopes, answers a refusal with
the RFC 6750 challenge, and serves the RFC 9728 metadata document. The
verifier is your function: Relay never parses tokens.

```gleam
import gleam/result
import relay/authorization
import relay/http
import relay/server

pub type Claims {
  Claims(subject: String, audiences: List(String), scopes: List(String))
}

pub fn protect(
  service: server.Server(Claims),
  validate: fn(String) -> Result(Claims, Nil),
) -> http.Config(Claims) {
  let assert Ok(resource) =
    authorization.protected_resource("https://mcp.example.com/mcp")
  let assert Ok(reports) = authorization.scope("reports")
  let protection =
    authorization.protection(resource, [reports])
    |> authorization.with_authorization_servers(["https://login.example.com"])
  let verifier = {
    use token, _correlation <- authorization.verifier("jwt")
    validate(authorization.token_value(token))
    |> result.map(fn(c) { authorization.attestation(c, c.audiences, c.scopes) })
    |> result.replace_error(authorization.BearerRejected)
  }
  http.new_protected(service, verifier, protection, fn(_request, grant) {
    Ok(authorization.grant_principal(grant))
  })
}
```

A token validator such as a local JWT or introspection client plugs in as
`validate`; it owns signatures, expiry and issuers. `server.with_tool_access`
then hides or refuses tools per principal. A refused request gets 401 with
`WWW-Authenticate: Bearer resource_metadata="..."`, 403 with
`error="insufficient_scope"`, or 503 when the verifier cannot decide.
A verifier that checks the audience itself returns
`authorization.IssuedForAnotherResource` for a token issued for another
resource, and the client gets the same `invalid_token` challenge as for an
attestation that names another audience. Branch on
`authorization.verification_kind(error)` rather than on the variants.

The verifier also receives the request's correlation, so an introspection
call joins the request's telemetry:

```gleam
use token, correlation <- authorization.verifier("introspection")
introspect(token, correlation)
```

## Call with a deadline, cancellation and headers

Per-call controls are views on the client; every operation honours them.

```gleam
import gleam/time/duration
import http_gun/cancellation
import http_gun/deadline
import relay/client
import relay/tool

pub fn call_with_budget(
  peer: client.Client,
  definition: tool.Definition(String, String),
) -> Result(client.ToolResult(String), client.Error) {
  use token <- cancellation.with_token
  peer
  |> client.with_deadline(deadline.after(duration.seconds(10)))
  |> client.with_cancellation(token)
  |> client.call(definition, "Ada")
}
```

A deadline or a cancellation that ends an HTTP call closes that call's
connection, so the server stops its handler; the next call reconnects.
`client.with_headers(config, fn() { [#("authorization", "Bearer " <> token())] })`
adds headers to every request, computed per request. Over plain `http://`
a client with headers reaches only loopback addresses unless
`client.allow_plaintext_headers`.

## Follow a call from client to server

Relay uses the gleam-dream ecosystem's correlation carrier: the request
`_meta` key `io.github.gleam-dream/correlation` on every transport, and over
HTTP also the `x-correlation-id` header. A client view's correlation
travels in both. The server tags the request's events with
it, `exchange.closed` included, and hands it to the verifier and the
handler. Without one, the server uses its `http.with_correlation` value or
mints a fresh one, so `tool.correlation(call)` always returns a value.

```gleam
import relay/client
import relay/tool
import sinal/correlation.{type Correlation}

pub fn ask(
  peer: client.Client,
  definition: tool.Definition(String, String),
  question: Correlation,
) -> Result(client.ToolResult(String), client.Error) {
  peer
  |> client.with_correlation(question)
  |> client.call(definition, "Ada")
}
```

The value is untrusted client input: Relay accepts 1 to 128 visible ASCII
characters, ignores anything else, and never uses it to authorize.

A failed call tells you which correlation it carried, including a minted
one, so a refusal such as `HttpStatus(401, ..)` joins the server's rejection
event and logs:

```gleam
case client.call(peer, definition, "Ada") {
  Error(error) ->
    log(
      client.describe_error(error)
      <> " correlation="
      <> correlation.to_string(client.error_correlation(error)),
    )
  Ok(_) -> Nil
}
```

Match the failure with `client.reason(error)`, for example
`client.HttpStatus(401, Some(challenge))`; context such as the correlation
lives on the opaque `Error`, so it never changes a match. An error from
`client.http` or `client.connect` precedes any call and carries a fresh
correlation that no server saw. Tests build an error with
`testing.error(reason)`, or `client.new_error(reason, correlation)`.

MCP `2026-07-28` has no session and no idempotency key, so Relay carries
an optional one of its own, in `_meta` under
`io.github.gleam-dream/idempotency-key`.
`client.with_idempotency_key(peer, "order-1001")` sends it on every request
through the view; the handler reads `tool.idempotency_key(call)`. A retry
that carries the same key is the client's promise that it is the same
request. The key is untrusted: Relay accepts 1 to 128 visible ASCII
characters and refuses any other value as invalid params, and a handler
keys its work by the authenticated principal together with the key, so one
client cannot replay or block another's work.

`tool.request_id(call)` returns the JSON-RPC id as the client sent it
(`StringId` or `IntegerId`); it may repeat across clients and is fresh on a
retry, so it does not identify one. `tool.invocation_id(call)` is Relay's
own id, new for every request, and joins the call's telemetry.

## Defaults

Configured transport reads, invocation waits and retained queues have explicit
bounds. Callback execution and host body allocation have separate owners, as
described above.

| Setting                                     | Default                             | Change with                                                       |
| ------------------------------------------- | ----------------------------------- | ----------------------------------------------------------------- |
| HTTP bind                                   | `127.0.0.1`, ephemeral port         | `http.with_bind`                                                  |
| HTTP bind off loopback without protection   | `start` fails                       | `http.new_protected`, or `http.allow_unauthenticated`             |
| Host and Origin allow-lists                 | loopback names and the bind host    | `http.with_allowed_hosts`, `http.with_allowed_origins`            |
| HTTP request body                           | 1 MiB, then 413                     | `http.with_max_body_bytes`                                        |
| HTTP response, or one stream's events       | 1 MiB                               | `http.with_max_response_bytes`                                    |
| HTTP invocation and response wait           | 30 s after context construction     | `http.with_request_timeout`                                       |
| SSE keepalive                               | 15 s                                | `http.with_sse_keepalive`                                         |
| concurrent HTTP requests                    | 1,024, then 503                     | `http.with_max_concurrent_requests`                               |
| concurrent `subscriptions/listen` streams   | 64, then 503                        | `http.with_max_listen_streams`                                    |
| JSON nesting depth                          | 64, then 400                        | `http.with_max_json_depth`, `runtime.with_max_json_depth`         |
| runtime live exchanges, frame size          | 100; 1 MiB                          | `runtime.with_max_live_exchanges`, `runtime.with_max_frame_bytes` |
| runtime handler timeout                     | 30 s                                | `runtime.with_invocation_timeout`                                 |
| cancelled handler grace before kill         | 5 s                                 | `runtime.with_cancellation_grace`                                 |
| tombstones                                  | 60 s, at most 10,000                | `runtime.with_tombstone_retention`, `runtime.with_max_tombstones` |
| closed exchange records per connection      | about 10,000                        | fixed                                                             |
| stdio read chunk                            | 4 KiB                               | `stdio.with_chunk_size`                                           |
| client request timeout                      | 30 s                                | `client.with_timeout`, per call `client.with_deadline`            |
| client connect                              | 10 s                                | `client.with_connect_timeout`                                     |
| client response size                        | 1 MiB                               | `client.with_max_response_bytes`                                  |
| client listings                             | 256 pages, 10,000 items             | `client.with_listing_limits`                                      |
| client stdio pending calls                  | 64, then `TooManyPendingCalls`      | `client.with_max_pending_calls`                                   |
| client input methods advertised             | none                                | `client.with_input_methods`                                       |
| client headers over plain HTTP off loopback | refused                             | `client.allow_plaintext_headers`                                  |
| client retries                              | none: decide with `client.evidence` | —                                                                 |
| request correlation                         | the client's, else a fresh one      | `http.with_correlation`, `client.with_correlation`                |
| request idempotency key                     | none                                | `client.with_idempotency_key`                                     |
| completion values per response              | 100                                 | `completion.Values(total:, has_more:)`                            |

## Modules

| Module                                                 | Purpose                                                                  |
| ------------------------------------------------------ | ------------------------------------------------------------------------ |
| `relay/tool`                                           | tool definitions, handlers, the `Call` a handler sees, declarations      |
| `relay/resources`, `relay/prompts`, `relay/completion` | the other server services                                                |
| `relay/content`, `relay/subscriptions`                 | protocol data                                                            |
| `relay/server`                                         | the server description                                                   |
| `relay/http`, `relay/stdio`                            | the transports                                                           |
| `relay/client`                                         | the client                                                               |
| `relay/authorization`                                  | bearer tokens, admission, challenges and metadata                        |
| `relay/telemetry`                                      | Sinal event descriptors                                                  |
| `relay/runtime`, `relay/reducer`                       | custom transports: the runtime actor and the pure reducer                |
| `relay/testing`                                        | an in-process client, MCP requests for a mounted handler, test verifiers |

## Composing typed tool calls

`relay/client/output` is an optional convenience boundary for non-interactive
callers that need the native answer:

```gleam
let result = client.call(peer, definition, input) |> output.require
case result {
  Ok(answer) -> use_answer(answer)
  Error(error) -> {
    output.error_kind(error)  // transport failure, tool refusal, needs input
    output.evidence(error)    // preserves MaybeSent, NotSent or Completed
    output.describe_error(error)
  }
}
```

Keep the original `client.ToolResult` for input continuations or media content.
For discovered tools, `client.call_discovered` returns `ToolResult(Option(Value))`:
`None` means no structured content; `Some(value.Null)` means explicit JSON null.
`output.require_discovered(result)` keeps every present structured value and
projects content-only text to a JSON string only when structured content is
absent. This choice does not depend on the declaration's output schema.
`content.text_of` joins text blocks; `output.meta(result, key)` reads application
metadata without assuming any ecosystem-specific key.

A handler can return `tool.complete_with_meta(answer, metadata)` to attach
application ids to its generated content blocks, including the normal text
mirror of structured answers. These are Relay capabilities; composition with
other libraries remains application code. Fabric documents compiled recipes
in its README and consumer package.

## Verification

Run the shared registry from the Relay checkout:

```bash
nix develop --command python3 -B scripts/check.py fast
nix develop --command python3 -B scripts/check.py full
```

| Profile  | Obligations and evidence                                                                                                                         |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `fast`   | Tree formatting, Ruff correctness lint, ShellCheck, actionlint, gate regressions, strict native/Gleam build and all root/consumer tests.         |
| `ci`     | All fast checks plus paired compiler controls, jsonschema 4.26.0 frozen corpus/mutations, checksums/pins and the complete official server suite. |
| `design` | Native render freshness, vocabulary, links and layer integrity.                                                                                  |
| `full`   | All `ci` and `design` obligations.                                                                                                               |

Builds use Gleam warnings as errors and independently compile authored Erlang
under `src`, `test` and `dev` with `erlc -Werror` and dependency includes.
Generated dependencies, frozen MCP/TLS fixtures, the pnpm lockfile and deliberate
negative compiler fixtures are excluded from authored formatting/lint. Ruff checks
syntax/imports/undefined names; it is not a Python type checker. Shell checks
include authored extensionless stdio peers. Gates check the
tree without repairing it. No benchmark harness or latency claim is introduced.

The server check invokes `scripts/conformance/run-server-suite.sh` with the
frozen pnpm lock, `@modelcontextprotocol/conformance` 0.2.0-alpha.10, all server
scenarios and spec 2026-07-28. It retains structured results and the local
server log on success or failure. A machine-result validator requires every
selected scenario, rejects missing/skipped cases, failures/warnings and empty
selections, and requires assertions from every selected scenario. Emitted server
assertions establish their tested scope; zero-assertion output establishes no
coverage and fails the gate. Client,
authorization and legacy certification require separate evidence.

Push, pull request and manual CI require both registry jobs. Profiles retain
per-check logs, results, dependency revisions and environment/lock metadata in
`.artifacts/PROFILE`; conformance results/server logs live inside its `server-suite`
directory, with a separate run directory and machine summary per invocation.
Existing direct script commands remain available for focused work.

Private Sinal and HTTP Gun checkout requires `vars.SIBLINGS_APP_CLIENT_ID` with
`secrets.SIBLINGS_APP_PRIVATE_KEY`, or `secrets.SIBLINGS_READ_TOKEN` restricted to
those two repositories. Public JSON Blueprint uses ordinary checkout. All
siblings use immutable `sibling-revisions.txt` refs; credentials are not persisted.
Fork pull requests receive no private credential and fail explicitly; verify
their changes from a trusted repository branch.
