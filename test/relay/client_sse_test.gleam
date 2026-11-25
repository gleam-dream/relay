//// The HTTP client against a server that answers ordinary requests with a
//// request-scoped server-sent event stream.

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import json/blueprint/codec.{type Codec}
import mist
import relay/client
import relay/http
import relay/server
import relay/tool

fn named_input() -> Codec(String) {
  use value <- codec.field("name", codec.string(), get: fn(value) { value })
  codec.success(value)
}

fn echo_definition() -> tool.Definition(String, String) {
  tool.define("echo", named_input(), codec.string())
}

fn echo_server() -> server.Server(Nil) {
  server.new([
    echo_definition() |> tool.handle(fn(name) { Ok("echo: " <> name) }),
  ])
}

const progress =
  "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"t\",\"progress\":1}}"

type StreamStep {
  Write
}

/// How the stream ends after the final response.
type Ending {
  /// The server ends the stream, as the specification recommends.
  Ends
  /// The server keeps the stream open; the client must still return.
  StaysOpen
}

/// Starts a server that computes each answer with a Relay endpoint and
/// delivers it as an event stream: a comment, a progress notification, then
/// the response. `seen` receives the `Accept` header of every request.
fn start_streaming_server(seen: Subject(String), ending: Ending) -> Int {
  let assert Ok(relay) = http.handler(http.new(echo_server()))
  let ports = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(incoming: Request(mist.Connection)) -> Response(
      mist.ResponseData,
    ) {
      let assert Ok(buffered) = mist.read_body(incoming, 1_000_000)
      let assert Ok(accept) = request.get_header(buffered, "accept")
      process.send(seen, accept)
      let answer = http.handle(relay, buffered)
      let assert Ok(text) =
        bit_array.to_string(bytes_tree.to_bit_array(answer.body))
      let events =
        ": keepalive\n\n"
        <> "event: message\ndata: "
        <> progress
        <> "\n\n"
        <> "event: message\r\ndata: "
        <> text
        <> "\r\n\r\n"
      mist.chunked(
        request: incoming,
        response: response.new(200)
          |> response.set_header("content-type", "text/event-stream"),
        init: fn(self) { process.send(self, Write) },
        loop: fn(state, _step: StreamStep, connection) {
          let assert Ok(Nil) =
            mist.send_chunk(connection, bit_array.from_string(events))
          case ending {
            Ends -> mist.chunk_stop()
            StaysOpen -> mist.chunk_continue(state)
          }
        },
      )
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _interface) {
      process.send(ports, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(ports, 2000)
  port
}

fn connect_port(port: Int) -> client.Client {
  let assert Ok(config) =
    client.http("http://127.0.0.1:" <> int.to_string(port) <> "/")
  let assert Ok(peer) = client.connect(config)
  peer
}

fn media_types(accept: String) -> List(String) {
  string.split(accept, ",") |> list.map(string.trim)
}

pub fn call_reads_an_event_stream_response_test() {
  let seen = process.new_subject()
  let peer = connect_port(start_streaming_server(seen, Ends))

  let assert Ok(client.Succeeded("echo: sse", _)) =
    client.call(peer, echo_definition(), "sse")

  let assert Ok(accept) = process.receive(seen, 1000)
  media_types(accept) |> list.contains("application/json") |> should.be_true
  media_types(accept) |> list.contains("text/event-stream") |> should.be_true
  client.close(peer)
}

pub fn call_returns_at_the_response_when_the_stream_stays_open_test() {
  let seen = process.new_subject()
  let peer = connect_port(start_streaming_server(seen, StaysOpen))

  let assert Ok(client.Succeeded("echo: open", _)) =
    client.call(peer, echo_definition(), "open")
  // The connection is released, so a second call succeeds too.
  let assert Ok(client.Succeeded("echo: again", _)) =
    client.call(peer, echo_definition(), "again")
  client.close(peer)
}
