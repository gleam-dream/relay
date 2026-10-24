//// Frame builders and response readers shared by the reducer tests.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None}
import gleam/string
import relay/reducer.{type Effect, type ExchangeId, type State}

/// The `_meta` object of a `2026-07-28` request, plus `extra` members.
pub fn meta(extra: List(#(String, json.Json))) -> json.Json {
  json.object([
    #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
    #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ..extra
  ])
}

/// A request frame with this id, the default metadata and these params.
pub fn request(
  id: json.Json,
  method: String,
  fields: List(#(String, json.Json)),
) -> BitArray {
  request_with_meta(id, method, meta([]), fields)
}

/// A request frame with explicit `_meta`.
pub fn request_with_meta(
  id: json.Json,
  method: String,
  request_meta: json.Json,
  fields: List(#(String, json.Json)),
) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id),
    #("method", json.string(method)),
    #("params", json.object([#("_meta", request_meta), ..fields])),
  ])
  |> json.to_string
  |> bit_array.from_string
}

/// A `tools/call` frame with a string id and these arguments.
pub fn call(
  id: String,
  tool: String,
  arguments: List(#(String, json.Json)),
) -> BitArray {
  request(json.string(id), "tools/call", [
    #("name", json.string(tool)),
    #("arguments", json.object(arguments)),
  ])
}

/// A `notifications/cancelled` frame for a string request id.
pub fn cancel(id: String) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("notifications/cancelled")),
    #("params", json.object([#("requestId", json.string(id))])),
  ])
  |> json.to_string
  |> bit_array.from_string
}

/// A `subscriptions/listen` frame with this notification filter object.
pub fn listen(id: String, notifications: json.Json) -> BitArray {
  request(json.string(id), "subscriptions/listen", [
    #("notifications", notifications),
  ])
}

/// Steps one frame on a fresh exchange.
pub fn receive(
  state: State(context),
  context: context,
  bytes: BitArray,
) -> #(State(context), ExchangeId, List(Effect(context))) {
  let exchange = reducer.new_exchange_id()
  let #(state, effects) =
    reducer.step(state, reducer.Received(exchange, context, bytes, None))
  #(state, exchange, effects)
}

/// A progress callback that drops every report.
pub fn ignore_progress(
  _progress: Float,
  _total: Option(Float),
  _message: Option(String),
) -> Nil {
  Nil
}

/// The JSON text of one written frame, without its trailing newline.
pub fn text(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes)
  let assert True = string.ends_with(text, "\n")
  string.drop_end(text, 1)
}

/// One written frame, parsed.
pub fn parse(bytes: BitArray) -> Dynamic {
  let assert Ok(parsed) = json.parse(text(bytes), decode.dynamic)
  parsed
}

/// The value at `path` in a written frame.
pub fn at(
  bytes: BitArray,
  path: List(String),
  decoder: decode.Decoder(a),
) -> a {
  let assert Ok(found) = decode.run(parse(bytes), decode.at(path, decoder))
  found
}

/// Whether the frame has a member at `path`.
pub fn has(bytes: BitArray, path: List(String)) -> Bool {
  case decode.run(parse(bytes), decode.at(path, decode.dynamic)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// The JSON-RPC error code of a written error response.
pub fn error_code(bytes: BitArray) -> Int {
  at(bytes, ["error", "code"], decode.int)
}
