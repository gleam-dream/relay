//// Per-call controls on the client, and request deadlines on the server.
////
//// Per-call controls are views on the client: every operation honours them.
//// A deadline or cancellation that ends an HTTP call closes that call's
//// connection, so the server stops its handler; the next call reconnects.
////
//// Run: `gleam run -m relay_usage/call_controls`

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/time/duration
import http_gun/cancellation
import http_gun/deadline
import json/blueprint/codec
import relay/client
import relay/http
import relay/server
import relay/testing
import relay/tool

fn greet() -> tool.Definition(String, String) {
  let input = {
    use name <- codec.field("name", codec.string(), get: fn(name) { name })
    codec.success(name)
  }
  tool.define("greet", input, codec.string())
}

/// A deadline and a cancellation token bound one call.
pub fn call_with_budget(
  peer: client.Client,
  definition: tool.Definition(String, String),
) -> Result(client.ToolResult(String), client.Error) {
  // snips-start: call-controls
  use token <- cancellation.with_token
  peer
  |> client.with_deadline(deadline.after(duration.seconds(10)))
  |> client.with_cancellation(token)
  |> client.call(definition, "Ada")
  // snips-end: call-controls
}

/// `client.with_headers` adds headers to every request, computed per request
/// in a temporary request-owned process within the request budget, so a
/// refreshing token source plugs in. The server's context builder sees them.
pub fn headers_reach_the_server() -> Nil {
  let echo_header =
    tool.define("header", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(call, _) { Ok(tool.complete(tool.context(call))) })
  let assert Ok(mcp) =
    http.new_with_context(server.new([echo_header]), fn(req) {
      case request.get_header(req, "x-demo") {
        Ok(value) -> Ok(value)
        Error(Nil) ->
          Error(response.new(400) |> response.set_body(bytes_tree.new()))
      }
    })
    |> http.start
  let url = "http://127.0.0.1:" <> int.to_string(http.port(mcp)) <> "/"
  let assert Ok(config) = client.http(url)
  let config =
    client.with_headers(config, fn() { [#("x-demo", "from-client")] })
  let assert Ok(peer) = client.connect(config)
  let definition = tool.define("header", codec.success(Nil), codec.string())
  let assert Ok(client.Succeeded("from-client", _)) =
    client.call(peer, definition, Nil)
  client.close(peer)
  http.stop(mcp)
}

/// `http.with_request_timeout` sets one deadline from slot admission through
/// verification, context construction, execution and response writes. A tool
/// that outlives it does not get to answer.
pub fn request_deadline() -> Nil {
  let slow =
    tool.handle(greet(), fn(name) {
      process.sleep(500)
      Ok(name)
    })
  let assert Ok(mcp) =
    http.new(server.new([slow]))
    |> http.with_request_timeout(duration.milliseconds(100))
    |> http.handler
  let call =
    testing.request("tools/call", [
      #("name", json.string("greet")),
      #("arguments", json.object([#("name", json.string("Ada"))])),
    ])
  let timed_out = http.handle(mcp, call)
  let assert True = timed_out.status >= 500
  http.stop(mcp)
}

pub fn run() -> Nil {
  let peer =
    testing.connect(
      server.new([tool.handle(greet(), fn(name) { Ok("Hi " <> name) })]),
      Nil,
    )
  let assert Ok(client.Succeeded("Hi Ada", _)) = call_with_budget(peer, greet())
  client.close(peer)
  headers_reach_the_server()
  request_deadline()
}

pub fn main() -> Nil {
  run()
  io.println("call_controls: ok")
}
