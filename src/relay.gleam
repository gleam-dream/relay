import gleam/dict.{type Dict}
import gleam/json
import gleam/option.{type Option}
import json/blueprint/codec.{type Codec}
import json/blueprint/value.{type Value}
import relay/content.{type ContentBlock}
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

pub type ToolAnnotations =
  tool.ToolAnnotations

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

pub type ToolOutput =
  tool.ToolOutput

pub type InputRequest =
  tool.InputRequest

pub type InputHandlerResult(output) =
  tool.InputHandlerResult(output)

pub fn input_request(method: String, params: json.Json) -> InputRequest {
  tool.InputRequest(method, params)
}

pub fn complete_output(output: output) -> InputHandlerResult(output) {
  tool.CompleteOutput(output)
}

pub fn request_input(
  requests: Dict(String, InputRequest),
) -> InputHandlerResult(output) {
  tool.RequestInput(requests)
}

pub type ProgressReporter =
  tool.ProgressReporter

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

pub fn tool_metadata_with_title(
  description: String,
  title: String,
) -> ToolMetadata {
  tool.tool_metadata_with_title(description, title)
}

pub fn tool_metadata_with_annotations(
  metadata: ToolMetadata,
  annotations: ToolAnnotations,
) -> ToolMetadata {
  tool.tool_metadata_with_annotations(metadata, annotations)
}

pub fn tool_annotations(
  title: Option(String),
  read_only_hint: Option(Bool),
  destructive_hint: Option(Bool),
  idempotent_hint: Option(Bool),
  open_world_hint: Option(Bool),
) -> ToolAnnotations {
  tool.tool_annotations(
    title,
    read_only_hint,
    destructive_hint,
    idempotent_hint,
    open_world_hint,
  )
}

pub fn empty_annotations() -> ToolAnnotations {
  tool.empty_annotations()
}

pub fn tool_metadata_requiring_client_capabilities(
  description: String,
  capabilities: List(String),
) -> ToolMetadata {
  tool.tool_metadata_requiring_client_capabilities(description, capabilities)
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

/// Constructs a typed contextual tool while preserving a caller-supplied input
/// schema document, including vocabulary not expressible by Blueprint codecs.
pub fn context_tool_with_input_schema(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  input_schema: Value,
  handler: fn(context, input) -> Result(output, application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  tool.context_tool_with_input_schema(
    name,
    metadata,
    input,
    output,
    error,
    input_schema,
    handler,
  )
}

/// Constructs a tool that returns rich content and optional typed structured output.
pub fn context_tool_with_content(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  handler: fn(context, input) ->
    Result(#(Option(output), List(ContentBlock)), application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  tool.context_tool_with_content(name, metadata, input, output, error, handler)
}

/// Constructs a typed tool that can emit validated progress during execution.
pub fn context_tool_with_progress(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  handler: fn(context, input, ProgressReporter) ->
    Result(output, application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  tool.context_tool_with_progress(name, metadata, input, output, error, handler)
}

/// Constructs a typed tool handler that may request and receive client input.
pub fn context_tool_with_inputs(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  handler: fn(context, input, Option(Value)) ->
    Result(InputHandlerResult(output), application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  tool.context_tool_with_inputs(name, metadata, input, output, error, handler)
}

/// Builds an immutable heterogeneous tool registry, enforcing unique tool names.
pub fn registry(
  tools: List(ContextTool(context)),
) -> Result(Registry(context), RegistryError) {
  tool.registry(tools)
}

/// Adds a tool to an existing registry, failing if the tool name is already registered.
pub fn register(
  registry: Registry(context),
  tool: ContextTool(context),
) -> Result(Registry(context), RegistryError) {
  tool.register(registry, tool)
}

/// Removes a tool from an existing registry by name.
pub fn unregister(
  registry: Registry(context),
  name: ToolName,
) -> Registry(context) {
  tool.unregister(registry, name)
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
