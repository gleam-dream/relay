// Negative fixture: an admitted Int input codec cannot bind a String handler.
import json/blueprint/codec
import relay/tool

pub fn invalid() {
  let assert Ok(name) = tool.tool_name("mismatch_tool")
  let input = {
    use count <- codec.field("count", codec.int(), fn(count: Int) { count })
    codec.success(count)
  }
  let assert Ok(definition) = tool.definition(name, input, codec.string())
  tool.handle(definition, fn(input: String) -> Result(String, String) {
    Ok(input)
  })
}
