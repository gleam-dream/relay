//// A stdio child for the output-pressure tests, launched with
//// `erl -pa build/dev/erlang/*/ebin -noshell -run relay_stdio_pressure_runner main`.
//// It admits one exchange at a time. When `serve_with` stops with an error
//// it prints the error's description on standard error and exits 1.

import gleam/erlang/process
import gleam/string
import gleam/time/duration
import json/blueprint/codec.{type Codec}
import relay/runtime
import relay/server
import relay/stdio
import relay/tool

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "relay_ffi", "write_stderr")
fn write_stderr(text: String) -> Result(Nil, String)

fn property(name: String, inner: Codec(a)) -> Codec(a) {
  use value <- codec.field(name, inner, get: fn(value) { value })
  codec.success(value)
}

fn tools() -> List(tool.Tool(Nil)) {
  let slow =
    tool.define("slow", property("ms", codec.int()), codec.string())
    |> tool.handle(fn(delay) {
      process.sleep(delay)
      Ok("slow response")
    })
  // An answer larger than any pipe buffer.
  let big =
    tool.define("big", property("bytes", codec.int()), codec.string())
    |> tool.handle(fn(bytes) { Ok(string.repeat("x", bytes)) })
  [slow, big]
}

pub fn main() -> Nil {
  let config =
    stdio.config()
    // One-byte reads: a larger read waits until that many bytes arrived.
    |> stdio.with_chunk_size(1)
    |> stdio.with_write_timeout(duration.milliseconds(300))
    |> stdio.with_runtime(
      runtime.config() |> runtime.with_max_live_exchanges(1),
    )
  case stdio.serve_with(server.new(tools()), Nil, config) {
    Ok(Nil) -> halt(0)
    Error(error) -> {
      let _ = write_stderr("stopped: " <> stdio.describe_error(error) <> "\n")
      halt(1)
    }
  }
}
