// Negative fixture: Wrong handler/codec pairing must fail at compile time.
import json/blueprint/codec
import relay

pub fn invalid() {
  let assert Ok(name) = relay.tool_name("mismatch_tool")
  relay.context_tool(
    name,
    relay.tool_metadata("Mismatched handler and input codec"),
    codec.field("count", codec.int()),
    codec.string(),
    codec.field("reason", codec.string()),
    fn(_ctx: Nil, input: String) -> Result(String, String) { Ok(input) },
  )
}
