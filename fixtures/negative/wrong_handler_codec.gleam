// Negative fixture: a definition with an Int input codec cannot bind a
// String handler.
import json/blueprint/codec
import relay/tool

fn count_input() -> codec.Codec(Int) {
  use count <- codec.field("count", codec.int(), get: fn(count: Int) { count })
  codec.success(count)
}

pub fn invalid() -> tool.Tool(Nil) {
  let definition = tool.define("mismatch_tool", count_input(), codec.string())
  tool.handle(definition, fn(input: String) -> Result(String, String) {
    Ok(input)
  })
}
