//// `Mcp-Name` and `Mcp-Method` travel as plain header values, or as the
//// `=?base64?...?=` form when a name is not a safe plain header value.

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/string
import mist
import relay/client
import relay/content
import relay/http
import relay/resources
import relay/server
import relay/testing

const spaced = "file:///notes/a%20b.md"

const accented = "memo://caf\u{e9}"

fn catalog() -> server.Server(Nil) {
  let resource = fn(uri) {
    resources.static(uri, "Note", fn(_context, uri) {
      Ok([content.text_resource(uri, "body")])
    })
  }
  server.new([])
  |> server.with_resources([
    resource(spaced),
    resource(accented),
    resource("memo://plain_name"),
    resource("=?base64?x?="),
  ])
}

fn read(uri: String, header: String) -> Response(String) {
  let assert Ok(handler) = http.handler(http.new(catalog()))
  let answer =
    http.handle(
      handler,
      testing.request("resources/read", [#("uri", json.string(uri))])
        |> request.set_header("mcp-name", header),
    )
  http.stop(handler)
  response.set_body(answer, testing.body_text(answer))
}

fn sentinel(text: String) -> String {
  "=?base64?"
  <> bit_array.base64_encode(bit_array.from_string(text), True)
  <> "?="
}

pub fn server_compares_a_plain_name_literally_test() {
  // A URI that itself contains a percent escape is sent as it is.
  let literal = read(spaced, spaced)
  assert literal.status == 200
  assert string.contains(literal.body, "\"result\"")

  // A percent-encoded header is a different value from the body's name.
  let escaped = read("memo://plain_name", "memo://plain%5Fname")
  assert escaped.status == 400
  assert string.contains(escaped.body, "-32020")
}

pub fn server_decodes_the_base64_form_before_comparing_test() {
  let encoded = read(accented, sentinel(accented))
  assert encoded.status == 200
  assert string.contains(encoded.body, "\"result\"")

  // A plain name may also arrive encoded.
  assert read("memo://plain_name", sentinel("memo://plain_name")).status == 200

  let other = read(accented, sentinel("memo://other"))
  assert other.status == 400
  assert string.contains(other.body, "-32020")

  let invalid = read(accented, "=?base64?***?=")
  assert invalid.status == 400
}

pub fn server_compares_the_method_literally_test() {
  let assert Ok(handler) = http.handler(http.new(catalog()))
  let escaped =
    http.handle(
      handler,
      testing.request("resources/list", [])
        |> request.set_header("mcp-method", "resources%2Flist"),
    )
  http.stop(handler)
  assert escaped.status == 400
  assert string.contains(testing.body_text(escaped), "-32020")
}

pub fn testing_request_sends_the_specified_form_test() {
  let header = fn(uri) {
    testing.request("resources/read", [#("uri", json.string(uri))])
    |> request.get_header("mcp-name")
  }
  assert header(spaced) == Ok(spaced)
  assert header(accented) == Ok(sentinel(accented))
}

/// Starts a server that reports each request's `Mcp-Name` header to `seen`
/// and answers with a Relay endpoint.
fn start_recording_server(seen: Subject(String)) -> Int {
  let assert Ok(relay) = http.handler(http.new(catalog()))
  let ports = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(incoming: Request(mist.Connection)) {
      let assert Ok(buffered) = mist.read_body(incoming, 1_000_000)
      let assert Ok(name) = request.get_header(buffered, "mcp-name")
      process.send(seen, name)
      http.handle(relay, buffered) |> response.map(mist.Bytes)
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

pub fn client_sends_a_plain_name_as_it_is_and_encodes_the_rest_test() {
  let seen = process.new_subject()
  let port = start_recording_server(seen)
  let assert Ok(config) =
    client.http("http://127.0.0.1:" <> int.to_string(port) <> "/")
  let assert Ok(peer) = client.connect(config)

  let assert Ok(_) = client.read_resource(peer, spaced)
  assert process.receive(seen, 1000) == Ok(spaced)

  let assert Ok(_) = client.read_resource(peer, accented)
  assert process.receive(seen, 1000) == Ok(sentinel(accented))

  // A plain value shaped like the base64 form is encoded to stay unambiguous.
  let assert Ok(_) = client.read_resource(peer, "=?base64?x?=")
  assert process.receive(seen, 1000) == Ok(sentinel("=?base64?x?="))
  client.close(peer)
}
