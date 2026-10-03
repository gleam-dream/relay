//// Test support: an in-process client, MCP HTTP requests for a mounted
//// handler, and verifiers with fixed answers.
////
//// `connect(server, context)` returns a `relay/client.Client` wired to the
//// server through its own runtime: no port, no mist, the same wire
//// messages. For other client settings, build the configuration with
//// `relay/client.in_process` and connect it yourself.
////
//// `request(method, params)` builds the `Request(BitArray)` a Streamable
//// HTTP client sends, with the protocol metadata and routing headers, for
//// `relay/http.handle`; `body_text` reads the response. `verifier` and
//// `unavailable_verifier` stand in for a token validator.
////
//// ```gleam
//// import json/blueprint/codec
//// import relay/client
//// import relay/server
//// import relay/testing
//// import relay/tool
////
//// pub fn say_test() {
////   let input = {
////     use text <- codec.field("text", codec.string(), get: fn(text) { text })
////     codec.success(text)
////   }
////   let say = tool.define("say", input, codec.string())
////   let peer = testing.connect(server.new([tool.handle(say, Ok)]), Nil)
////   let assert Ok(client.Succeeded("hi", _)) = client.call(peer, say, "hi")
////   client.close(peer)
//// }
//// ```

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/uri
import relay/authorization.{type Attestation, type Verifier}
import relay/client
import relay/server.{type Server}

/// A client connected to `server` in this VM, with each request's context.
/// Panics when the runtime cannot start.
pub fn connect(server: Server(context), context: context) -> client.Client {
  case client.connect(client.in_process(server, context)) {
    Ok(peer) -> peer
    Error(error) ->
      panic as { "relay/testing.connect: " <> client.describe_error(error) }
  }
}

@external(erlang, "relay_ffi", "unique_integer")
fn unique_integer() -> Int

/// A Streamable HTTP POST for `method` with these params, as an MCP client
/// sends it: a fresh request id, the `2026-07-28` metadata, `Accept` for
/// JSON and event streams, and the `Mcp-Method`, `Mcp-Name` and
/// `MCP-Protocol-Version` headers. The host is `127.0.0.1`. A
/// `notifications/...` method is sent without an id.
pub fn request(
  method: String,
  params: List(#(String, json.Json)),
) -> Request(BitArray) {
  let meta =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ])
  let id = case method {
    "notifications/" <> _ -> []
    _ -> [#("id", json.string("test-" <> int.to_string(unique_integer())))]
  }
  let body =
    json.object(
      list.flatten([
        [#("jsonrpc", json.string("2.0"))],
        id,
        [
          #("method", json.string(method)),
          #("params", json.object([#("_meta", meta), ..params])),
        ],
      ]),
    )
    |> json.to_string
    |> bit_array.from_string
  let base =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host("127.0.0.1")
    |> request.set_path("/")
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", "application/json, text/event-stream")
    |> request.set_header("mcp-protocol-version", "2026-07-28")
    |> request.set_header("mcp-method", method)
  case routing_name(method, params) {
    Some(name) -> request.set_header(base, "mcp-name", uri.percent_encode(name))
    None -> base
  }
}

fn routing_name(
  method: String,
  params: List(#(String, json.Json)),
) -> Option(String) {
  let key = case method {
    "tools/call" | "prompts/get" -> Ok("name")
    "resources/read" -> Ok("uri")
    _ -> Error(Nil)
  }
  use key <- option.then(option.from_result(key))
  list.key_find(params, key)
  |> result.try(fn(found) {
    json.parse(json.to_string(found), decode.string)
    |> result.replace_error(Nil)
  })
  |> option.from_result
}

/// A response body as text.
pub fn body_text(response: Response(BytesTree)) -> String {
  bytes_tree.to_bit_array(response.body)
  |> bit_array.to_string
  |> result.unwrap("")
}

/// A verifier that accepts exactly these raw tokens, each with its
/// attestation, and rejects every other token.
pub fn verifier(
  tokens: List(#(String, Attestation(principal))),
) -> Verifier(principal) {
  authorization.verifier("relay-testing", fn(token, _correlation) {
    list.key_find(tokens, authorization.token_value(token))
    |> result.replace_error(authorization.BearerRejected)
  })
}

/// A verifier that can never decide, as when the key set or the
/// introspection endpoint is down.
pub fn unavailable_verifier() -> Verifier(principal) {
  authorization.verifier("relay-testing", fn(_, _) {
    Error(authorization.VerifierUnavailable)
  })
}
