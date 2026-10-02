//// Typed MCP tool definitions, handlers, and the registry a server dispatches
//// to.
////
//// `tool_name` admits a name. `definition(name, input_codec, output_codec)`
//// builds a `Definition` from Blueprint codecs, and `content_definition` builds
//// one for a tool that returns only content. `handle` and its variants bind a
//// handler and return a `ContextTool`; `registry` collects tools for
//// `relay/server.server`. The same definition drives
//// `relay/client.call_definition`. Description, title, annotation, metadata
//// and input-schema modifiers adjust the published declaration.
////
//// ```gleam
//// import json/blueprint/codec
//// import relay/tool
////
//// pub fn greet() -> tool.ContextTool(Nil) {
////   let assert Ok(name) = tool.tool_name("greet")
////   let assert Ok(definition) =
////     tool.definition(name, codec.field("name", codec.string()), codec.string())
////   definition
////   |> tool.with_description("Greets the user by name")
////   |> tool.handle(fn(name) { Ok("Hello, " <> name <> "!") })
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec.{
  type Codec, type DecodeError, type EncodeError, type Schema,
}
import json/blueprint/value.{type Value}
import relay/content.{type ContentBlock}
import relay/internal/schema

/// Validated, opaque tool identifier.
pub opaque type ToolName {
  ToolName(String)
}

pub type ToolNameError {
  EmptyName
  NameTooLong(max: Int, actual: Int)
  InvalidCharacters(String)
}

/// Validates and constructs a ToolName.
/// Admitted grammar: 1..128 characters, non-empty, consisting of ASCII letters, digits,
/// '.', '_', '-', and '/' (no control characters, whitespace, or newlines).
pub fn tool_name(raw: String) -> Result(ToolName, ToolNameError) {
  let len = string.length(raw)
  case len {
    0 -> Error(EmptyName)
    _ if len > 128 -> Error(NameTooLong(128, len))
    _ ->
      case is_valid_tool_name(raw) {
        True -> Ok(ToolName(raw))
        False -> Error(InvalidCharacters(raw))
      }
  }
}

pub fn tool_name_to_string(tool_name: ToolName) -> String {
  let ToolName(name) = tool_name
  name
}

fn is_valid_tool_name(name: String) -> Bool {
  let chars = string.to_graphemes(name)
  list.all(chars, is_valid_name_grapheme)
}

fn is_valid_name_grapheme(grapheme: String) -> Bool {
  case grapheme {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "_"
    | "-"
    | "."
    | "/" -> True
    _ -> False
  }
}

/// Annotations providing hints to clients about a tool's behavior and environment.
pub type ToolAnnotations {
  ToolAnnotations(
    title: Option(String),
    read_only_hint: Option(Bool),
    destructive_hint: Option(Bool),
    idempotent_hint: Option(Bool),
    open_world_hint: Option(Bool),
  )
}

pub fn empty_annotations() -> ToolAnnotations {
  ToolAnnotations(
    title: None,
    read_only_hint: None,
    destructive_hint: None,
    idempotent_hint: None,
    open_world_hint: None,
  )
}

/// Changes one annotation hint while preserving all other hints.
pub fn with_read_only_hint(
  annotations: ToolAnnotations,
  hint: Option(Bool),
) -> ToolAnnotations {
  ToolAnnotations(..annotations, read_only_hint: hint)
}

pub fn with_destructive_hint(
  annotations: ToolAnnotations,
  hint: Option(Bool),
) -> ToolAnnotations {
  ToolAnnotations(..annotations, destructive_hint: hint)
}

pub fn with_idempotent_hint(
  annotations: ToolAnnotations,
  hint: Option(Bool),
) -> ToolAnnotations {
  ToolAnnotations(..annotations, idempotent_hint: hint)
}

pub fn with_open_world_hint(
  annotations: ToolAnnotations,
  hint: Option(Bool),
) -> ToolAnnotations {
  ToolAnnotations(..annotations, open_world_hint: hint)
}

pub fn tool_annotations_to_json(annotations: ToolAnnotations) -> json.Json {
  let fields = []
  let fields = case annotations.title {
    Some(t) -> [#("title", json.string(t)), ..fields]
    None -> fields
  }
  let fields = case annotations.read_only_hint {
    Some(b) -> [#("readOnlyHint", json.bool(b)), ..fields]
    None -> fields
  }
  let fields = case annotations.destructive_hint {
    Some(b) -> [#("destructiveHint", json.bool(b)), ..fields]
    None -> fields
  }
  let fields = case annotations.idempotent_hint {
    Some(b) -> [#("idempotentHint", json.bool(b)), ..fields]
    None -> fields
  }
  let fields = case annotations.open_world_hint {
    Some(b) -> [#("openWorldHint", json.bool(b)), ..fields]
    None -> fields
  }
  json.object(fields)
}

/// Metadata associated with a tool definition.
pub type ToolMetadata {
  ToolMetadata(
    description: Option(String),
    title: Option(String),
    annotations: Option(ToolAnnotations),
    required_client_capabilities: List(String),
  )
}

pub fn empty_metadata() -> ToolMetadata {
  ToolMetadata(
    description: None,
    title: None,
    annotations: None,
    required_client_capabilities: [],
  )
}

pub type ToolAdmissionError {
  MissingInputSchema
  InputSchemaMustBeObject(String)
  MissingOutputSchema
  UnsupportedSchemaFeature(String)
}

/// Admitted native tool contract. Codecs remain tied to the same definition
/// used for listing, registration, and typed client calls.
pub opaque type Definition(input, output) {
  Definition(
    name: ToolName,
    metadata: ToolMetadata,
    input: Codec(input),
    output: Codec(output),
    input_schema: Schema,
    input_schema_override: Option(Value),
    output_schema: Schema,
  )
}

/// An admitted tool whose result consists only of content blocks.
pub opaque type ContentDefinition(input) {
  ContentDefinition(
    name: ToolName,
    metadata: ToolMetadata,
    input: Codec(input),
    input_schema: Schema,
    input_schema_override: Option(Value),
  )
}

pub fn content_definition(
  name: ToolName,
  input: Codec(input),
) -> Result(ContentDefinition(input), ToolAdmissionError) {
  use input_schema <- result.try(admit_input(input))
  Ok(ContentDefinition(name, empty_metadata(), input, input_schema, None))
}

/// Reuses the same composable metadata value as a structured definition.
pub fn content_with_metadata(
  definition: ContentDefinition(input),
  metadata: ToolMetadata,
) -> ContentDefinition(input) {
  ContentDefinition(..definition, metadata: metadata)
}

pub fn content_definition_name(
  definition: ContentDefinition(input),
) -> ToolName {
  definition.name
}

pub fn content_definition_input_codec(
  definition: ContentDefinition(input),
) -> Codec(input) {
  definition.input
}

/// A caller supplied schema augments discovery; the codec still decodes calls.
pub fn with_input_schema_override(
  definition: Definition(input, output),
  input_schema: Value,
) -> Result(Definition(input, output), ToolAdmissionError) {
  case input_schema {
    value.Object(_) ->
      Ok(Definition(..definition, input_schema_override: Some(input_schema)))
    _ -> Error(InputSchemaMustBeObject("non-object"))
  }
}

/// Augments discovery for a content-only definition without an output codec.
/// The retained input codec still decodes every invocation.
pub fn content_with_input_schema_override(
  definition: ContentDefinition(input),
  input_schema: Value,
) -> Result(ContentDefinition(input), ToolAdmissionError) {
  case input_schema {
    value.Object(_) ->
      Ok(
        ContentDefinition(
          ..definition,
          input_schema_override: Some(input_schema),
        ),
      )
    _ -> Error(InputSchemaMustBeObject("non-object"))
  }
}

/// Validates the schemas once, before a handler is bound or a call is made.
pub fn definition(
  name: ToolName,
  input: Codec(input),
  output: Codec(output),
) -> Result(Definition(input, output), ToolAdmissionError) {
  use admitted_input <- result.try(admit_input(input))
  use admitted_output <- result.try(admit_output(output))
  Ok(Definition(
    name,
    empty_metadata(),
    input,
    output,
    admitted_input,
    None,
    admitted_output,
  ))
}

pub fn definition_name(definition: Definition(input, output)) -> ToolName {
  definition.name
}

pub fn definition_metadata(
  definition: Definition(input, output),
) -> ToolMetadata {
  definition.metadata
}

pub fn definition_input_codec(
  definition: Definition(input, output),
) -> Codec(input) {
  definition.input
}

pub fn definition_output_codec(
  definition: Definition(input, output),
) -> Codec(output) {
  definition.output
}

pub fn with_metadata(
  definition: Definition(input, output),
  metadata: ToolMetadata,
) -> Definition(input, output) {
  Definition(..definition, metadata: metadata)
}

/// Definition modifiers are independent and preserve unrelated metadata.
pub fn with_description(
  definition: Definition(input, output),
  description: String,
) -> Definition(input, output) {
  Definition(
    ..definition,
    metadata: ToolMetadata(
      ..definition.metadata,
      description: Some(description),
    ),
  )
}

pub fn with_title(
  definition: Definition(input, output),
  title: String,
) -> Definition(input, output) {
  Definition(
    ..definition,
    metadata: ToolMetadata(..definition.metadata, title: Some(title)),
  )
}

pub fn with_annotations(
  definition: Definition(input, output),
  annotations: ToolAnnotations,
) -> Definition(input, output) {
  Definition(
    ..definition,
    metadata: ToolMetadata(
      ..definition.metadata,
      annotations: Some(annotations),
    ),
  )
}

pub fn with_required_client_capabilities(
  definition: Definition(input, output),
  capabilities: List(String),
) -> Definition(input, output) {
  Definition(
    ..definition,
    metadata: ToolMetadata(
      ..definition.metadata,
      required_client_capabilities: capabilities,
    ),
  )
}

fn admit_input(input: Codec(input)) -> Result(Schema, ToolAdmissionError) {
  case schema.validate_input_schema(codec.schema(input)) {
    Error(schema.MissingSchema) -> Error(MissingInputSchema)
    Error(schema.SchemaMustBeObject(kind)) ->
      Error(InputSchemaMustBeObject(kind))
    Ok(admitted) -> Ok(admitted)
  }
}

fn admit_output(output: Codec(output)) -> Result(Schema, ToolAdmissionError) {
  case schema.validate_output_schema(codec.schema(output)) {
    Error(schema.MissingSchema) -> Error(MissingOutputSchema)
    Error(schema.SchemaMustBeObject(kind)) ->
      Error(UnsupportedSchemaFeature(kind))
    Ok(admitted) -> Ok(admitted)
  }
}

/// Retained tool declaration for discovery and tool listing.
pub type ToolDeclaration {
  ToolDeclaration(
    name: ToolName,
    metadata: ToolMetadata,
    input_schema: Schema,
    input_schema_override: Option(Value),
    output_schema: Option(Schema),
  )
}

/// A tool response may carry only typed content or structured data plus content.
pub type ToolOutput {
  ContentOnly(List(ContentBlock))
  StructuredWithContent(Value, List(ContentBlock))
  InputRequired(Dict(String, InputRequest))
}

/// A server-initiated input request embedded in an InputRequiredResult.
pub type InputRequest {
  InputRequest(method: String, params: json.Json)
}

/// Everything an advanced handler may need during one invocation.
pub type HandlerCallContext(context) {
  HandlerCallContext(
    application: context,
    input_responses: Option(Value),
    report_progress: ProgressReporter,
  )
}

/// A structured result may also carry rich content, or request another round.
pub type HandlerResult(output) {
  Complete(output, List(ContentBlock))
  Content(List(ContentBlock))
  NeedsInput(Dict(String, InputRequest))
}

/// Advanced content-only handlers can complete or request another input round.
pub type ContentHandlerResult {
  ContentComplete(List(ContentBlock))
  ContentNeedsInput(Dict(String, InputRequest))
}

/// Callback available to handlers that report ordered, non-negative progress.
pub type ProgressReporter =
  fn(Int) -> Nil

/// Heterogeneous contextual tool holding typed codecs and handler.
pub opaque type ContextTool(context) {
  ContextTool(
    name: ToolName,
    declaration: ToolDeclaration,
    invoke: fn(context, Value, Option(Value), ProgressReporter) ->
      Result(ToolOutput, DispatchError),
  )
}

pub type RegistryError {
  DuplicateToolName(ToolName)
  InvalidToolDeclaration(ToolName, ToolAdmissionError)
}

pub type DispatchError {
  UnknownTool(ToolName)
  InvalidInput(DecodeError)
  PublicApplicationFailure(String)
  ContentOnlyOutput
  InvalidOutput(EncodeError)
  InputRequiredOutput
}

/// Binds a native handler to an admitted definition. The default message is
/// deliberately independent of the handler's private error value.
pub fn handle(
  definition: Definition(input, output),
  handler: fn(input) -> Result(output, application_error),
) -> ContextTool(context) {
  handle_with_error_renderer(definition, handler, fn(_error) {
    "Tool execution failed."
  })
}

/// Renders an application error before its native type is erased by registration.
pub fn handle_with_error_renderer(
  definition: Definition(input, output),
  handler: fn(input) -> Result(output, application_error),
  render_error: fn(application_error) -> String,
) -> ContextTool(context) {
  let declaration =
    ToolDeclaration(
      name: definition.name,
      metadata: definition.metadata,
      input_schema: definition.input_schema,
      input_schema_override: definition.input_schema_override,
      output_schema: Some(definition.output_schema),
    )
  let invoke = fn(
    _context: context,
    raw_input: Value,
    _input_responses: Option(Value),
    _report_progress: ProgressReporter,
  ) -> Result(ToolOutput, DispatchError) {
    use typed_input <- result.try(
      codec.decode(definition.input, raw_input)
      |> result.map_error(InvalidInput),
    )
    use typed_output <- result.try(
      handler(typed_input)
      |> result.map_error(fn(error) {
        PublicApplicationFailure(render_error(error))
      }),
    )
    codec.encode(definition.output, typed_output)
    |> result.map(fn(value) { StructuredWithContent(value, []) })
    |> result.map_error(InvalidOutput)
  }
  ContextTool(definition.name, declaration, invoke)
}

/// Binds rich content, progress, and multi-round input to one admitted contract.
pub fn handle_advanced(
  definition: Definition(input, output),
  handler: fn(HandlerCallContext(context), input) ->
    Result(HandlerResult(output), application_error),
) -> ContextTool(context) {
  handle_advanced_with_error_renderer(definition, handler, fn(_error) {
    "Tool execution failed."
  })
}

pub fn handle_advanced_with_error_renderer(
  definition: Definition(input, output),
  handler: fn(HandlerCallContext(context), input) ->
    Result(HandlerResult(output), application_error),
  render_error: fn(application_error) -> String,
) -> ContextTool(context) {
  let declaration =
    ToolDeclaration(
      name: definition.name,
      metadata: definition.metadata,
      input_schema: definition.input_schema,
      input_schema_override: definition.input_schema_override,
      output_schema: Some(definition.output_schema),
    )
  let invoke = fn(
    context: context,
    raw_input: Value,
    input_responses: Option(Value),
    report_progress: ProgressReporter,
  ) -> Result(ToolOutput, DispatchError) {
    use typed_input <- result.try(
      codec.decode(definition.input, raw_input)
      |> result.map_error(InvalidInput),
    )
    use handler_result <- result.try(
      handler(
        HandlerCallContext(context, input_responses, report_progress),
        typed_input,
      )
      |> result.map_error(fn(error) {
        PublicApplicationFailure(render_error(error))
      }),
    )
    case handler_result {
      Complete(output, blocks) ->
        codec.encode(definition.output, output)
        |> result.map(fn(value) { StructuredWithContent(value, blocks) })
        |> result.map_error(InvalidOutput)
      Content(blocks) -> Ok(ContentOnly(blocks))
      NeedsInput(requests) -> Ok(InputRequired(requests))
    }
  }
  ContextTool(definition.name, declaration, invoke)
}

pub fn handle_content(
  definition: ContentDefinition(input),
  handler: fn(input) -> Result(List(ContentBlock), application_error),
) -> ContextTool(context) {
  handle_content_with_error_renderer(definition, handler, fn(_error) {
    "Tool execution failed."
  })
}

pub fn handle_content_with_error_renderer(
  definition: ContentDefinition(input),
  handler: fn(input) -> Result(List(ContentBlock), application_error),
  render_error: fn(application_error) -> String,
) -> ContextTool(context) {
  let declaration =
    ToolDeclaration(
      definition.name,
      definition.metadata,
      definition.input_schema,
      definition.input_schema_override,
      None,
    )
  let invoke = fn(
    _context: context,
    raw_input: Value,
    _input_responses: Option(Value),
    _report_progress: ProgressReporter,
  ) -> Result(ToolOutput, DispatchError) {
    use typed_input <- result.try(
      codec.decode(definition.input, raw_input)
      |> result.map_error(InvalidInput),
    )
    handler(typed_input)
    |> result.map(ContentOnly)
    |> result.map_error(fn(error) {
      PublicApplicationFailure(render_error(error))
    })
  }
  ContextTool(definition.name, declaration, invoke)
}

/// Content-only handler with per-invocation context, progress, and input replies.
pub fn handle_content_advanced(
  definition: ContentDefinition(input),
  handler: fn(HandlerCallContext(context), input) ->
    Result(ContentHandlerResult, application_error),
) -> ContextTool(context) {
  handle_content_advanced_with_error_renderer(definition, handler, fn(_error) {
    "Tool execution failed."
  })
}

pub fn handle_content_advanced_with_error_renderer(
  definition: ContentDefinition(input),
  handler: fn(HandlerCallContext(context), input) ->
    Result(ContentHandlerResult, application_error),
  render_error: fn(application_error) -> String,
) -> ContextTool(context) {
  let declaration =
    ToolDeclaration(
      definition.name,
      definition.metadata,
      definition.input_schema,
      definition.input_schema_override,
      None,
    )
  let invoke = fn(
    context: context,
    raw_input: Value,
    input_responses: Option(Value),
    report_progress: ProgressReporter,
  ) -> Result(ToolOutput, DispatchError) {
    use typed_input <- result.try(
      codec.decode(definition.input, raw_input)
      |> result.map_error(InvalidInput),
    )
    use handler_result <- result.try(
      handler(
        HandlerCallContext(context, input_responses, report_progress),
        typed_input,
      )
      |> result.map_error(fn(error) {
        PublicApplicationFailure(render_error(error))
      }),
    )
    case handler_result {
      ContentComplete(blocks) -> Ok(ContentOnly(blocks))
      ContentNeedsInput(requests) -> Ok(InputRequired(requests))
    }
  }
  ContextTool(definition.name, declaration, invoke)
}

pub fn tool_name_of(tool: ContextTool(context)) -> ToolName {
  tool.name
}

pub fn tool_declaration_of(tool: ContextTool(context)) -> ToolDeclaration {
  tool.declaration
}

/// Immutable heterogeneous tool registry.
pub opaque type Registry(context) {
  Registry(tools: List(ContextTool(context)))
}

/// Builds a tool registry, enforcing unique tool names.
pub fn registry(
  tools: List(ContextTool(context)),
) -> Result(Registry(context), RegistryError) {
  check_duplicate_names(tools, [])
}

/// Adds a tool to an existing registry, failing if the tool name is already registered.
pub fn register(
  registry: Registry(context),
  tool: ContextTool(context),
) -> Result(Registry(context), RegistryError) {
  let Registry(tools) = registry
  case list.any(tools, fn(t) { t.name == tool.name }) {
    True -> Error(DuplicateToolName(tool.name))
    False -> Ok(Registry([tool, ..tools]))
  }
}

/// Removes a tool from an existing registry by name.
pub fn unregister(
  registry: Registry(context),
  name: ToolName,
) -> Registry(context) {
  let Registry(tools) = registry
  Registry(list.filter(tools, fn(t) { t.name != name }))
}

/// Reports whether a tool with this name is present in the registry.
pub fn contains(registry: Registry(context), name: ToolName) -> Bool {
  let Registry(tools) = registry
  list.any(tools, fn(candidate) { candidate.name == name })
}

/// Returns the current tool values in the registry.
///
/// The values are used by the HTTP hub to reconcile a subscription against
/// the current registry at admission time. The registry itself remains
/// immutable and opaque to callers.
pub fn registered_tools(
  registry: Registry(context),
) -> List(ContextTool(context)) {
  let Registry(tools) = registry
  tools
}

fn check_duplicate_names(
  remaining: List(ContextTool(context)),
  seen: List(ToolName),
) -> Result(Registry(context), RegistryError) {
  case remaining {
    [] -> Ok(Registry(seen_to_tools(seen, remaining)))
    [first, ..rest] ->
      case list.contains(seen, first.name) {
        True -> Error(DuplicateToolName(first.name))
        False ->
          case check_duplicate_names(rest, [first.name, ..seen]) {
            Ok(_) -> Ok(Registry(remaining))
            Error(err) -> Error(err)
          }
      }
  }
}

fn seen_to_tools(
  _seen: List(ToolName),
  tools: List(ContextTool(context)),
) -> List(ContextTool(context)) {
  tools
}

/// Returns tool declarations for the given context.
pub fn declarations(
  registry: Registry(context),
  _context: context,
) -> List(ToolDeclaration) {
  let Registry(tools) = registry
  list.map(tools, fn(t) { t.declaration })
}

/// Returns the client capabilities required by a registered tool.
pub fn required_client_capabilities(
  registry: Registry(context),
  name: ToolName,
) -> List(String) {
  let Registry(tools) = registry
  required_capabilities_in(tools, name)
}

/// Returns the exact input schema document exposed to protocol peers.
pub fn input_schema_document(
  registry: Registry(context),
  name: ToolName,
) -> Option(Value) {
  let Registry(tools) = registry
  find_input_schema_document(tools, name)
}

fn find_input_schema_document(
  tools: List(ContextTool(context)),
  name: ToolName,
) -> Option(Value) {
  case tools {
    [] -> None
    [candidate, ..rest] ->
      case candidate.name == name {
        True ->
          Some(case candidate.declaration.input_schema_override {
            Some(raw_schema) -> raw_schema
            None ->
              schema.materialize_schema(candidate.declaration.input_schema)
          })
        False -> find_input_schema_document(rest, name)
      }
  }
}

fn required_capabilities_in(
  tools: List(ContextTool(context)),
  name: ToolName,
) -> List(String) {
  case tools {
    [] -> []
    [candidate, ..rest] ->
      case candidate.name == name {
        True -> candidate.declaration.metadata.required_client_capabilities
        False -> required_capabilities_in(rest, name)
      }
  }
}

/// Dispatches a tool call by name with Blueprint Value arguments.
pub fn dispatch(
  registry: Registry(context),
  context: context,
  name: ToolName,
  arguments: Value,
) -> Result(Value, DispatchError) {
  case
    dispatch_with_inputs(registry, context, name, arguments, None, fn(_value) {
      Nil
    })
  {
    Error(error) -> Error(error)
    Ok(StructuredWithContent(value, _content)) -> Ok(value)
    Ok(ContentOnly(_)) -> Error(ContentOnlyOutput)
    Ok(InputRequired(_)) -> Error(InputRequiredOutput)
  }
}

pub fn dispatch_with_content(
  registry: Registry(context),
  context: context,
  name: ToolName,
  arguments: Value,
) -> Result(ToolOutput, DispatchError) {
  dispatch_with_inputs(registry, context, name, arguments, None, fn(_value) {
    Nil
  })
}

pub fn dispatch_with_progress(
  registry: Registry(context),
  context: context,
  name: ToolName,
  arguments: Value,
  report_progress: ProgressReporter,
) -> Result(ToolOutput, DispatchError) {
  dispatch_with_inputs(
    registry,
    context,
    name,
    arguments,
    None,
    report_progress,
  )
}

pub fn dispatch_with_inputs(
  registry: Registry(context),
  context: context,
  name: ToolName,
  arguments: Value,
  input_responses: Option(Value),
  report_progress: ProgressReporter,
) -> Result(ToolOutput, DispatchError) {
  let Registry(tools) = registry
  find_and_invoke(
    tools,
    context,
    name,
    arguments,
    input_responses,
    report_progress,
  )
}

fn find_and_invoke(
  tools: List(ContextTool(context)),
  context: context,
  name: ToolName,
  arguments: Value,
  input_responses: Option(Value),
  report_progress: ProgressReporter,
) -> Result(ToolOutput, DispatchError) {
  case tools {
    [] -> Error(UnknownTool(name))
    [tool, ..rest] ->
      case tool.name == name {
        True ->
          tool.invoke(context, arguments, input_responses, report_progress)
        False ->
          find_and_invoke(
            rest,
            context,
            name,
            arguments,
            input_responses,
            report_progress,
          )
      }
  }
}
