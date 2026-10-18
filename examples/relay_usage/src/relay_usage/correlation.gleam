//// Follow a call from client to server.
////
//// Relay carries the ecosystem correlation in the request `_meta` key
//// `io.github.gleam-dream/correlation` on every transport, and over HTTP also
//// in the `x-correlation-id` header. The server tags the request's events with
//// it and hands it to the verifier and the handler. The value is untrusted
//// client input and never authorizes anything. An optional idempotency key
//// travels the same way; a handler keys its work by the authenticated
//// principal together with the key.
////
//// Run: `gleam run -m relay_usage/correlation`

import gleam/io
import gleam/option.{None, Some}
import gleam/string
import json/blueprint/codec
import relay/client
import relay/server
import relay/testing
import relay/tool
import sinal/correlation.{type Correlation}

fn describe() -> tool.Definition(String, String) {
  let input = {
    use name <- codec.field("name", codec.string(), get: fn(name) { name })
    codec.success(name)
  }
  tool.define("describe", input, codec.string())
}

/// The handler sees the correlation, the optional idempotency key, the
/// client's JSON-RPC id and Relay's own per-request invocation id.
fn inspecting_tool() -> tool.Tool(Nil) {
  tool.handle_call(describe(), fn(call, name) {
    let key = case tool.idempotency_key(call) {
      Some(key) -> key
      None -> "none"
    }
    let _client_chosen_id = tool.request_id(call)
    let _relay_chosen_id = tool.invocation_id(call)
    Ok(tool.complete(
      name
      <> " correlation="
      <> correlation.to_string(tool.correlation(call))
      <> " key="
      <> key,
    ))
  })
}

pub fn ask(
  peer: client.Client,
  question: Correlation,
) -> Result(client.ToolResult(String), client.Error) {
  peer
  |> client.with_correlation(question)
  |> client.with_idempotency_key("order-1001")
  |> client.call(describe(), "Ada")
}

pub fn run() -> Nil {
  let peer = testing.connect(server.new([inspecting_tool()]), Nil)
  let question = correlation.from_key("question-7")
  let assert Ok(client.Succeeded(answer, _)) = ask(peer, question)
  let assert True = string.contains(answer, "correlation=question-7")
  let assert True = string.contains(answer, "key=order-1001")

  // Without a client correlation the server mints one, so a handler always
  // sees a value. A failed call also reports which correlation it carried.
  let assert Ok(client.Succeeded(unkeyed, _)) =
    client.call(peer, describe(), "Ada")
  let assert True = string.contains(unkeyed, "key=none")
  client.close(peer)
}

pub fn main() -> Nil {
  run()
  io.println("correlation: ok")
}
