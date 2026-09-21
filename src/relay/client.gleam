import json/blueprint/codec.{type Codec}
import json/blueprint/value.{type Value}
import relay/protocol/jsonrpc.{type RequestId}
import relay/tool.{type ToolName}

/// Opaque typed client handle.
pub opaque type Client {
  Client(id: String)
}

/// Client configuration.
pub type ClientConfig {
  ClientConfig(server_command: String)
}

/// Connects an MCP client to a server.
/// Deferred to Wave 5: Typed client and test kit.
pub fn connect(_config: ClientConfig) -> Result(Client, String) {
  todo as "wave 5: Typed client and test kit"
}

/// Invokes a tool by name with typed input and output codecs.
/// Deferred to Wave 5: Typed client and test kit.
pub fn call_tool(
  _client: Client,
  _name: ToolName,
  _input: input,
  _input_codec: Codec(input),
  _output_codec: Codec(output),
) -> Result(output, String) {
  todo as "wave 5: Typed client and test kit"
}
