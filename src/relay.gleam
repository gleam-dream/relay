import json/blueprint/codec.{type Codec}
import json/blueprint/value.{type Value}
import relay/tool

/// Package version.
pub fn version() -> String {
  "0.1.0"
}

pub type ToolName =
  tool.ToolName

pub type ToolNameError =
  tool.ToolNameError

pub type ToolMetadata =
  tool.ToolMetadata

pub type ContextTool(context) =
  tool.ContextTool(context)

pub type ToolDeclaration =
  tool.ToolDeclaration

pub type ToolAdmissionError =
  tool.ToolAdmissionError

pub type Registry(context) =
  tool.Registry(context)

pub type RegistryError =
  tool.RegistryError

pub type DispatchError =
  tool.DispatchError

/// Validates and constructs a ToolName.
pub fn tool_name(raw: String) -> Result(ToolName, ToolNameError) {
  tool.tool_name(raw)
}

/// Converts a ToolName to its string representation.
pub fn tool_name_to_string(name: ToolName) -> String {
  tool.tool_name_to_string(name)
}

/// Constructs metadata with an optional description.
pub fn tool_metadata(description: String) -> ToolMetadata {
  tool.tool_metadata(description)
}

/// Constructs empty tool metadata.
pub fn empty_metadata() -> ToolMetadata {
  tool.empty_metadata()
}

/// Constructs a typed contextual tool after validating input schema object root.
pub fn context_tool(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  handler: fn(context, input) -> Result(output, application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  tool.context_tool(name, metadata, input, output, error, handler)
}

/// Builds an immutable heterogeneous tool registry, enforcing unique tool names.
pub fn registry(
  tools: List(ContextTool(context)),
) -> Result(Registry(context), RegistryError) {
  tool.registry(tools)
}

/// Returns tool declarations for the given context.
pub fn declarations(
  registry: Registry(context),
  context: context,
) -> List(ToolDeclaration) {
  tool.declarations(registry, context)
}

/// Dispatches a tool call by name with Blueprint Value arguments.
pub fn dispatch(
  registry: Registry(context),
  context: context,
  name: ToolName,
  arguments: Value,
) -> Result(Value, DispatchError) {
  tool.dispatch(registry, context, name, arguments)
}
