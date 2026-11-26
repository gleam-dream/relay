//// Measures one HTTP `tools/call` through a mounted endpoint for a small and
//// a large request body. Run with `gleam run -m relay_decode_bench`; see
//// `docs/BENCHMARKS.md` for what the numbers mean and how to compare them.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/string
import json/blueprint/codec.{type Codec}
import relay/http
import relay/server
import relay/testing
import relay/tool

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn monotonic_ms() -> Int

fn text_input() -> Codec(String) {
  use value <- codec.field("text", codec.string(), get: fn(value) { value })
  codec.success(value)
}

fn size_tool() -> tool.Tool(Nil) {
  tool.define("size", text_input(), codec.int())
  |> tool.handle(fn(text) { Ok(string.byte_size(text)) })
}

// The argument mixes strings and numbers so decoding builds real terms.
fn argument(bytes: Int) -> String {
  string.repeat("relay 12345 \"quoted\" ", bytes / 21 + 1)
  |> string.slice(0, bytes)
}

fn measure(handler: http.Handler(Nil), bytes: Int, requests: Int) -> Nil {
  let request =
    testing.request("tools/call", [
      #("name", json.string("size")),
      #("arguments", json.object([#("text", json.string(argument(bytes)))])),
    ])
  // Warm up code loading and the endpoint.
  let assert 200 = http.handle(handler, request).status
  let started = monotonic_ms()
  list.each(list.repeat(Nil, requests), fn(_) {
    let assert 200 = http.handle(handler, request).status
  })
  let elapsed = monotonic_ms() - started
  io.println(
    "body "
    <> int.to_string(bit_array.byte_size(request.body))
    <> " bytes, "
    <> int.to_string(requests)
    <> " requests: "
    <> float.to_string(float.to_precision(
      int.to_float(elapsed) /. int.to_float(requests),
      3,
    ))
    <> " ms/request",
  )
}

pub fn main() -> Nil {
  let assert Ok(handler) =
    http.handler(
      http.new(server.new([size_tool()]))
      |> http.with_max_body_bytes(2_000_000),
    )
  measure(handler, 1000, 2000)
  measure(handler, 100_000, 200)
  measure(handler, 1_000_000, 40)
  http.stop(handler)
}
