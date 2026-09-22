// Negative fixture: an admitted Int input codec cannot bind a String handler.
import json/blueprint/codec
import relay/tool

pub fn invalid() {
  let assert Ok(name) = tool.tool_name("mismatch_tool")
  let assert Ok(definition) =
    tool.definition(name, codec.field("count", codec.int()), codec.string())
  tool.handle(definition, fn(input: String) -> Result(String, String) {
    Ok(input)
  })
}
