//// A stdio child for the unframed-input test, launched with
//// `erl -pa build/dev/erlang/*/ebin -noinput -run relay_stdio_backlog_runner main`.
//// Its standard output may stall for 2 s before a write counts as broken,
//// and it holds at most 64 KiB of standard input it has not framed. When
//// `serve_with` stops with an error it prints the error's description on
//// standard error and exits 1.

import gleam/string
import gleam/time/duration
import json/blueprint/codec
import relay/runtime
import relay/server
import relay/stdio
import relay/tool

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "relay_ffi", "write_stderr")
fn write_stderr(text: String) -> Result(Nil, String)

pub fn main() -> Nil {
  // An answer larger than any pipe buffer, so its write stalls.
  let big =
    tool.define(
      "big",
      {
        use bytes <- codec.field("bytes", codec.int(), get: fn(bytes) { bytes })
        codec.success(bytes)
      },
      codec.string(),
    )
    |> tool.handle(fn(bytes) { Ok(string.repeat("x", bytes)) })
  let config =
    stdio.Config(
      runtime: runtime.config() |> runtime.with_max_frame_bytes(4096),
      write_timeout: duration.seconds(2),
      max_unframed_bytes: 65_536,
    )
  case stdio.serve_with(server.new([big]), Nil, config) {
    Ok(Nil) -> halt(0)
    Error(error) -> {
      let _ = write_stderr("stopped: " <> stdio.describe_error(error) <> "\n")
      halt(1)
    }
  }
}
