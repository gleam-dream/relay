# relay

Relay implements the frozen MCP `2026-07-28` revision in Gleam: typed tools,
resources, prompts and completion on the server; a typed client; Streamable
HTTP and stdio transports; bearer-token protection; and a pure reducer for
custom transports.

## Serve a tool and call it

One `Definition` serves both sides: the server binds a handler to it, and
the client calls it and decodes the output with the same codecs.

```gleam
import gleam/int
import json/blueprint/codec
import relay/client
import relay/http
import relay/server
import relay/tool

pub fn greet() -> tool.Definition(String, String) {
  let input = {
    use name <- codec.field("name", codec.string(), get: fn(name) { name })
    codec.success(name)
  }
  tool.define("greet", input, codec.string())
  |> tool.with_description("Greets the user by name")
  |> tool.with_read_only_hint(True)
}

pub fn main() {
  let service =
    server.new([tool.handle(greet(), fn(name) { Ok("Hello, " <> name <> "!") })])
  let assert Ok(mcp) = http.start(http.new(service))
  let url = "http://127.0.0.1:" <> int.to_string(http.port(mcp)) <> "/"

  let assert Ok(config) = client.http(url)
  let assert Ok(peer) = client.connect(config)
  let assert Ok(client.Succeeded("Hello, Ada!", _)) =
    client.call(peer, greet(), "Ada")
  client.close(peer)
  http.stop(mcp)
}
```

`client.call` returns `Ok(Succeeded(output, content))`, `Ok(ToolFailed(..))`
when the tool reported a failure, `Ok(InputRequired(..))` when the tool asks
the client for input first, or `Error(client.Error)`. The error carries the
HTTP status, the JSON-RPC error, or the transport failure with its
submission evidence; branch on `client.kind(error)` and
`client.evidence(error)`, and log `client.describe_error(error)` with
`client.error_correlation(error)`, the correlation the call was sent with.

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
is not seen (the request timeout bounds the call), and `subscriptions/listen`
answers 406. `http.start`, `http.supervised` and `http.mist_handler` stream
server-sent events, send keepalives, and cancel a call when its client
disconnects, which is how MCP `2026-07-28` cancels over HTTP.

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

Every `client.Error` variant ends with that `correlation`; match payloads
with `..` (`HttpStatus(401, Some(challenge), ..)`). An error from
`client.http` or `client.connect` precedes any call and carries a fresh
correlation that no server saw.

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

Every wait, read and queue is bounded.

| Setting                                     | Default                             | Change with                                                       |
| ------------------------------------------- | ----------------------------------- | ----------------------------------------------------------------- |
| HTTP bind                                   | `127.0.0.1`, ephemeral port         | `http.with_bind`                                                  |
| HTTP bind off loopback without protection   | `start` fails                       | `http.new_protected`, or `http.allow_unauthenticated`             |
| Host and Origin allow-lists                 | loopback names and the bind host    | `http.with_allowed_hosts`, `http.with_allowed_origins`            |
| HTTP request body                           | 1 MiB, then 413                     | `http.with_max_body_bytes`                                        |
| HTTP response, or one stream's events       | 1 MiB                               | `http.with_max_response_bytes`                                    |
| HTTP request and handler timeout            | 30 s                                | `http.with_request_timeout`                                       |
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

## Release status

Relay targets Erlang. The manifest admits Gleam `>= 1.18.0`; CI runs Gleam
1.18.1 with Erlang/OTP 28 and rebar3 3.27.0. Relay depends on its siblings
`json_blueprint`, `sinal` and `http_gun` through local paths, pinned in
[`sibling-revisions.txt`](sibling-revisions.txt), so a standalone checkout or
Hex installation cannot resolve it yet.

Relay implements `2026-07-28` only. Legacy `2025-11-25` sessions,
`logging/setLevel`, resource-read continuation, MCP client authorization
flows and tasks are outside this release. The built-in resource-template
matcher supports one simple `{name}` variable per segment; other syntax
needs `resources.template_with_matcher`. The pinned
`@modelcontextprotocol/conformance@0.2.0-alpha.10` server suite reports
108 passed checks and no failures; the result covers the exercised
scenarios only.

See [CHANGELOG.md](CHANGELOG.md) and the migration guides for
[wave 4](docs/migration-wave-4.md) and [wave 5](docs/migration-wave-5.md).

## Verification

```bash
nix develop --command gleam format --check src test dev
nix develop --command gleam build --warnings-as-errors
nix develop --command gleam test
nix develop --command python3 scripts/check_negative_fixtures.py
nix develop --command python3 scripts/relay_schema_check.py
nix develop --command ./scripts/verify_checksums.sh
./scripts/conformance/run-server-suite.sh
nix flake check
```
