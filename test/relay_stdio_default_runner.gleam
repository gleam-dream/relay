//// A stdio child that serves with the default settings, launched with
//// `erl -pa build/dev/erlang/*/ebin -noinput -run relay_stdio_default_runner main`.
//// It exits 0 on a clean EOF and 1 on any error.

import gleam/string
import json/blueprint/codec.{type Codec}
import relay/server
import relay/stdio
import relay/tool

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

fn text_input() -> Codec(String) {
  use value <- codec.field("text", codec.string(), get: fn(value) { value })
  codec.success(value)
}

pub fn main() -> Nil {
  let size =
    tool.define("size", text_input(), codec.int())
    |> tool.handle(fn(text) { Ok(string.byte_size(text)) })
  case stdio.serve(server.new([size]), Nil) {
    Ok(Nil) -> halt(0)
    Error(_) -> halt(1)
  }
}
