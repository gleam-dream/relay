// Positive control: an Int input codec binds an Int handler.
import gleam/int
import json/blueprint/codec
import relay/tool

fn count_input() -> codec.Codec(Int) {
  use count <- codec.field("count", codec.int(), get: fn(count: Int) { count })
  codec.success(count)
}

pub fn valid() -> tool.Tool(Nil) {
  let definition = tool.define("mismatch_tool", count_input(), codec.string())
  tool.handle(definition, fn(input: Int) -> Result(String, String) {
    Ok(int.to_string(input))
  })
}
