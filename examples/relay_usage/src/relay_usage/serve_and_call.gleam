//// Serve a tool over Streamable HTTP and call it with the same definition.
////
//// Run: `gleam run -m relay_usage/serve_and_call`

import gleam/int
import gleam/io
import gleam/string
import json/blueprint/codec
import relay/client
import relay/http
import relay/server
import relay/tool

/// One `Definition` holds the input and output codecs used by both the server
/// handler and the client call.
pub fn greet() -> tool.Definition(String, String) {
  let input = {
    use name <- codec.field("name", codec.string(), get: fn(name) { name })
    codec.success(name)
  }
  tool.define("greet", input, codec.string())
  |> tool.with_description("Greets the user by name")
  |> tool.with_read_only_hint(True)
}

/// Binds an ephemeral loopback port, calls the tool and closes everything.
/// Application code handles each `Result` and closes resources it created when
/// a later operation fails.
pub fn serve_and_call() -> Nil {
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

/// `client.call` separates success, a tool that reported a failure, a request
/// for input and a client error. A refusal inside the tool is not a transport
/// failure, and a transport failure carries evidence of whether the request
/// may have reached the server.
pub fn handle_failed_calls() -> Nil {
  let refusing = tool.handle(greet(), fn(_name) { Error("private reason") })
  let peer = connect_in_process(server.new([refusing]))
  let assert Ok(client.ToolFailed(_content, _structured)) =
    client.call(peer, greet(), "Ada")
  client.close(peer)

  let service = server.new([tool.handle(greet(), fn(name) { Ok(name) })])
  let assert Ok(mcp) = http.start(http.new(service))
  let url = "http://127.0.0.1:" <> int.to_string(http.port(mcp)) <> "/"
  let assert Ok(config) = client.http(url)
  let assert Ok(peer) = client.connect(config)
  http.stop(mcp)
  let assert Error(error) = client.call(peer, greet(), "Ada")
  // Branch on the closed classification and the submission evidence, never on
  // the message text, and log the correlation the call was sent with.
  let _kind = client.kind(error)
  let _evidence = client.evidence(error)
  let line = client.describe_error(error)
  let assert True = string.length(line) > 0
  io.println("failed call: " <> line)
  client.close(peer)
}

fn connect_in_process(service: server.Server(Nil)) -> client.Client {
  let assert Ok(mcp) = http.start(http.new(service))
  let url = "http://127.0.0.1:" <> int.to_string(http.port(mcp)) <> "/"
  let assert Ok(config) = client.http(url)
  let assert Ok(peer) = client.connect(config)
  peer
}

pub fn run() -> Nil {
  serve_and_call()
  handle_failed_calls()
}

pub fn main() -> Nil {
  run()
  io.println("serve_and_call: ok")
}
