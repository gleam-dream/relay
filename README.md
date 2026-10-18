# relay

Relay provides MCP servers and clients for Gleam, with typed tool calls over
stdio or Streamable HTTP. It implements the frozen `2026-07-28` revision and
targets Erlang.

## Installation

Relay has no published release. It requires Gleam `>= 1.18.0`. Its unpublished
siblings, Sinal, HTTP Gun and JSON Blueprint, are Git dependencies on `main`;
`manifest.toml` locks the resolved commits, and `gleam update <package>` moves
one by hand. Application manifests import Relay and Blueprint the same way.

Overriding only Relay with a path does not override its transitive Git
requirements. A coordinated change across siblings is tested by capturing the
whole source graph from the [Oversight](https://github.com/gleam-dream/oversight)
checkout:

```sh
nix develop --command python3 -B scripts/local_sources.py --output /tmp/relay-local-sources  # run in the Oversight checkout
```

Choose a new output directory for each capture. The capture leaves the source
manifests and recorded revisions unchanged.

## Serve a tool and call it

Every recipe below mirrors a module in [examples/relay_usage](examples/relay_usage/README.md),
which the gate compiles and runs, so a recipe cannot drift from the API.
This one is `serve_and_call`.

One `Definition` holds the input and output codecs used by both the server
handler and the client call.

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

The example binds an ephemeral loopback port and closes the client and endpoint
after the call. In application code, handle each `Result` and close resources
you created when a later operation fails.

`client.call` distinguishes success, tool failure, a request for input and a
client error. Read `client.kind(error)` and `client.evidence(error)` before
retrying: `MaybeSent` means the operation may have run. Relay never retries
automatically. Log `client.describe_error(error)` with
`client.error_correlation(error)`.

## Serve over stdio

Example: `stdio_server`.

```gleam
import relay/server
import relay/stdio

pub fn main() {
  let assert Ok(Nil) = stdio.serve(server.new([]), Nil)
}
```

A client launches the server with `client.stdio("my_server", ["--flag"])`.
Stdio enforces no authorization: run it under a trusted parent process.

## Mount the endpoint in an application

Example: `mount`.

`http.handler` starts the endpoint without a listener. `http.handle` takes a
`gleam_http` `Request(BitArray)` and returns a buffered `Response(BytesTree)`,
so it mounts in Wisp in one line; `http.mist_handler` mounts the streaming
endpoint in Mist. Buffered mounting drops progress notifications, cannot
observe client disconnects and answers `subscriptions/listen` with 406.

```gleam
// In a wisp router:
["mcp"] -> {
  use body <- wisp.require_bit_array_body(req)
  http.handle(mcp, request.set_body(req, body)) |> response.map(wisp.Bytes)
}
```

`http.new_with_context` builds a native context from each request, for example
a tenant. Call `http.stop(mcp)` when the router or supervisor stops.

## Protect the endpoint

Example: `protect`.

`http.new_protected` reads the bearer token, asks your verifier, admits the
request for the protected resource and its scopes, answers refusals with the
RFC 6750 challenge and serves the RFC 9728 metadata document. Relay never
parses tokens; the verifier owns signatures, expiry and issuers.

```gleam
let verifier = {
  use token, _correlation <- authorization.verifier("jwt")
  validate(authorization.token_value(token))
  |> result.map(fn(c) { authorization.attestation(c, c.audiences, c.scopes) })
  |> result.replace_error(authorization.BearerRejected)
}
http.new_protected(service, verifier, protection, fn(_request, grant) {
  Ok(authorization.grant_principal(grant))
})
```

## Call with a deadline, cancellation and headers

Example: `call_controls`.

```gleam
use token <- cancellation.with_token
peer
|> client.with_deadline(deadline.after(duration.seconds(10)))
|> client.with_cancellation(token)
|> client.call(definition, "Ada")
```

`client.with_headers` adds headers to every request. The request budget covers
header acquisition, so a blocked callback ends on timeout or cancellation.
`client.with_correlation` and `client.with_idempotency_key` carry the
correlation and an optional idempotency key through every transport.

## Follow a call and compose results

`client.with_correlation` carries a correlation and `client.with_idempotency_key`
an optional idempotency key through every transport. The handler reads
`tool.correlation(call)` and `tool.idempotency_key(call)`; both are untrusted
client input. Example: `correlation`.

`relay/client/output` folds a call result and a client error into one `Result`
for non-interactive callers, keeping the evidence of whether a request may have
run. Example: `typed_output`.

## Defaults and scope

HTTP binds `127.0.0.1` on an ephemeral port. Binding off loopback without
protection requires `http.allow_unauthenticated`. Request and response bodies
default to 1 MiB, and the admitted-request deadline and client request timeout
default to 30 seconds. The design lists every default with its setter.

Relay implements MCP `2026-07-28` only. Legacy `2025-11-25` sessions,
`logging/setLevel`, resource-read continuation, MCP client authorization flows
and tasks are unimplemented. The built-in resource-template matcher supports
one simple `{name}` variable per segment; other syntax needs
`resources.template_with_matcher`.

The pinned `@modelcontextprotocol/conformance@0.2.0-alpha.10` server suite
supplies evidence for its emitted assertions ([docs/ORACLE.md](docs/ORACLE.md)). Client, authorization and legacy
conformance need separate evidence.

## Development

```sh
nix develop --command python3 -B scripts/check.py fast
nix develop --command python3 -B scripts/check.py full
```

[AGENTS.md](AGENTS.md) describes the gate. The [design](docs/design/design.typ)
states responsibilities and contracts, [CONTEXT.typ](docs/design/CONTEXT.typ)
defines the vocabulary, [COVERAGE.md](docs/COVERAGE.md) maps repository parts
to design owners, and [docs/adr/](docs/adr/) records decisions and their
rationale.

## References

[docs/ORACLE.md](docs/ORACLE.md) records the frozen schema, the pinned
conformance suite and the other references Relay is compared with. Relay has no
benchmark harness and makes no latency claim.
