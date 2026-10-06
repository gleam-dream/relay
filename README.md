# relay

Relay provides MCP servers and clients for Gleam, with typed tool calls over
stdio or Streamable HTTP. It implements the frozen `2026-07-28` revision and
targets Erlang.

## Installation

Relay has no published release. It requires Gleam `>= 1.18.0` and sibling
checkouts of `json_blueprint`, `sinal` and `http_gun`; the expected revisions are
recorded in [sibling-revisions.txt](sibling-revisions.txt). A standalone checkout
or Hex installation cannot resolve these local dependencies yet.

With your application beside these checkouts, add Relay and the Blueprint codecs
used by the example to `gleam.toml`:

```toml
[dependencies]
relay = { path = "../relay" }
json_blueprint = { path = "../json_blueprint" }
```

## Serve a tool and call it

One `Definition` contains the input and output codecs used by both the server
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
you created when a later operation fails. `http.stop` closes the endpoint
without terminating its linked caller; unexpected listener failure still
propagates through that link.

`client.call` distinguishes success, tool failure, a request for input, and a
client error. Read `client.kind(error)` and `client.evidence(error)` before
retrying: `MaybeSent` means the operation may have run. Relay does not retry
automatically. The [usage guide](docs/usage.md#handle-failed-calls) explains
failure details and result handling.

## Configuration and ownership

HTTP defaults to `127.0.0.1` on an ephemeral port. Binding an unprotected
endpoint off loopback requires `http.allow_unauthenticated`; use
`http.new_protected` to admit bearer tokens through your verifier. Stdio relies
on a trusted parent process and provides no authorization.

Requests and responses default to 1 MiB. The HTTP invocation and response waits
and client request timeout default to 30 seconds. Context builders and bearer
verifiers run before the HTTP budgets start, so callers must bound their work
separately. The [complete defaults](docs/usage.md#defaults) identify each limit
and its setting.

The [usage guide](docs/usage.md) retains examples for stdio, mounting in Wisp or
Mist, bearer protection, deadlines, cancellation, headers, correlation and
idempotency. Its [module map](docs/usage.md#modules) covers resources, prompts,
completion, subscriptions, testing and custom transports. For native output,
media and discovered tools, see [typed result composition](docs/usage.md#composing-typed-tool-calls).

## Supported scope

Relay implements MCP `2026-07-28` only. Legacy `2025-11-25` sessions,
`logging/setLevel`, resource-read continuation, MCP client authorization flows
and tasks are unimplemented. The built-in resource-template matcher supports
one simple `{name}` variable per segment; other syntax needs
`resources.template_with_matcher`.

The pinned `@modelcontextprotocol/conformance@0.2.0-alpha.10` server suite
supplies evidence for its emitted assertions. Client, authorization and legacy
conformance require separate evidence. Schema revision, checksum and license
remain beside the [frozen fixture](test/fixtures/mcp_2026/README.md).

## Verification

From the Relay checkout:

```bash
nix develop --command python3 -B scripts/check.py fast
nix develop --command python3 -B scripts/check.py full
```

The [full verification commands](docs/usage.md#verification) also cover compiler
negative fixtures, schemas, checksums and the pinned server conformance suite.

The [native design](docs/design/design.typ), [rendered design](docs/design/design-layer.pdf)
and [vocabulary](docs/design/CONTEXT.typ) describe responsibilities and retained
requirements. See [design coverage](docs/COVERAGE.md), [ADRs](docs/adr/) and
[CHANGELOG.md](CHANGELOG.md) for design ownership, decisions and release notes.
