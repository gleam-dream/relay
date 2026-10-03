//// The stdio child program the stdio tests launch with
//// `erl -pa build/dev/erlang/*/ebin -noshell -run relay_stdio_runner main`
//// (see `test/fixtures/stdio/relay-stdio`). It serves a small server over
//// `relay/stdio.serve_with` with 1-byte reads, a 1,024-byte frame limit and
//// a nesting depth of 16, and exits 0 on a clean EOF, 3 on trailing bytes,
//// and 1 on any other error.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/time/duration
import json/blueprint/codec.{type Codec}
import relay/runtime
import relay/server
import relay/stdio
import relay/tool

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "persistent_term", "put")
fn put_marker(key: String, value: Bool) -> Dynamic

@external(erlang, "persistent_term", "get")
fn get_marker(key: String, default: Bool) -> Bool

const cancelled_marker = "relay_stdio_runner_cancelled"

fn property(name: String, inner: Codec(a)) -> Codec(a) {
  use value <- codec.field(name, inner, get: fn(value) { value })
  codec.success(value)
}

fn tools() -> List(tool.Tool(String)) {
  let greet =
    tool.define("greet", property("name", codec.string()), codec.string())
    |> tool.with_description("Greets user")
    |> tool.handle_call(fn(call, user) {
      Ok(tool.complete(tool.context(call) <> ": hello " <> user))
    })
  let fail =
    tool.define("fail_tool", property("msg", codec.string()), codec.string())
    |> tool.with_description("Fails with tool error")
    |> tool.handle_with_error_renderer(
      fn(msg) { Error("application error: " <> msg) },
      fn(error) { tool.error_message(error) },
    )
  let slow =
    tool.define("slow", property("ms", codec.int()), codec.string())
    |> tool.with_description("Delays its response")
    |> tool.handle(fn(delay) {
      process.sleep(delay)
      Ok("slow response")
    })
  // Waits for its cancellation and records that it saw it.
  let wait =
    tool.define("wait", property("ms", codec.int()), codec.string())
    |> tool.handle_call(fn(call, delay) {
      case process.selector_receive(tool.cancelled(call), delay) {
        Ok(Nil) -> {
          let _ = put_marker(cancelled_marker, True)
          Ok(tool.complete("cancelled"))
        }
        Error(Nil) -> Ok(tool.complete("waited"))
      }
    })
  let was_cancelled =
    tool.define("was_cancelled", codec.success(Nil), codec.bool())
    |> tool.handle(fn(_) { Ok(get_marker(cancelled_marker, False)) })
  [greet, fail, slow, wait, was_cancelled]
}

pub fn main() -> Nil {
  let config =
    stdio.config()
    |> stdio.with_chunk_size(1)
    |> stdio.with_runtime(
      runtime.config()
      |> runtime.with_max_frame_bytes(1024)
      |> runtime.with_max_json_depth(16)
      |> runtime.with_cancellation_grace(duration.milliseconds(500)),
    )
  case stdio.serve_with(server.new(tools()), "child-server", config) {
    Ok(Nil) -> halt(0)
    Error(stdio.InvalidTrailingData(_)) -> halt(3)
    Error(_) -> halt(1)
  }
}
