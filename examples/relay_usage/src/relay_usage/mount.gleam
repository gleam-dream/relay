//// Mount the endpoint in an application. `http.handler` starts the endpoint
//// without a listener. `http.handle` takes a `gleam_http` request and returns
//// a buffered response, so it mounts in Wisp in one line; `http.mist_handler`
//// mounts the streaming endpoint in Mist. The context builder sees the
//// request, so a context can carry the tenant or the caller.
////
//// Run: `gleam run -m relay_usage/mount`

import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/io
import gleam/json
import gleam/string
import json/blueprint/codec
import relay/http
import relay/server
import relay/testing
import relay/tool

pub type Tenant {
  Tenant(id: String)
}

// snips-start: mount
pub fn mount(service: server.Server(Tenant)) -> http.Handler(Tenant) {
  let assert Ok(mcp) =
    http.new_with_context(service, fn(req) {
      case request.get_header(req, "x-tenant") {
        Ok(id) -> Ok(Tenant(id))
        Error(Nil) ->
          Error(response.new(400) |> response.set_body(bytes_tree.new()))
      }
    })
    |> http.with_allowed_hosts(["mcp.example.com", "127.0.0.1"])
    |> http.handler
  mcp
}

// snips-end: mount

// In a Wisp router the mounted handler is one clause. Buffered mounting drops
// progress notifications, cannot observe client disconnects and answers
// `subscriptions/listen` with 406; use `http.mist_handler` for those.
//
//   ["mcp"] -> {
//     use body <- wisp.require_bit_array_body(req)
//     http.handle(mcp, request.set_body(req, body)) |> response.map(wisp.Bytes)
//   }

pub fn run() -> Nil {
  let whoami =
    tool.define("whoami", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(call, _) {
      let Tenant(id) = tool.context(call)
      Ok(tool.complete(id))
    })
  let mcp = mount(server.new([whoami]))
  let call =
    testing.request("tools/call", [
      #("name", json.string("whoami")),
      #("arguments", json.object([])),
    ])
  let answered = http.handle(mcp, request.set_header(call, "x-tenant", "acme"))
  let assert 200 = answered.status
  let assert True = string.contains(testing.body_text(answered), "acme")
  // The builder refuses a request without a tenant before any tool runs.
  let assert 400 = http.handle(mcp, call).status
  // The application owns the endpoint: stop it when the router stops.
  http.stop(mcp)
}

pub fn main() -> Nil {
  run()
  io.println("mount: ok")
}
