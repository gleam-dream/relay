import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import json/blueprint/codec.{
  type Codec, type DecodeError, type EncodeError, type Schema,
}
import json/blueprint/value.{type Value}
import relay/content.{type ContentBlock}
import relay/schema

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

/// Unchecked constructor for internal trusted tool names.
pub fn tool_name_from_trusted(name: String) -> ToolName {
  ToolName(name)
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

/// Metadata associated with a tool definition.
pub type ToolMetadata {
  ToolMetadata(
    description: Option(String),
    title: Option(String),
    required_client_capabilities: List(String),
  )
}

pub fn tool_metadata(description: String) -> ToolMetadata {
  ToolMetadata(
    description: Some(description),
    title: None,
    required_client_capabilities: [],
  )
}

pub fn tool_metadata_requiring_client_capabilities(
  description: String,
  capabilities: List(String),
) -> ToolMetadata {
  ToolMetadata(
    description: Some(description),
    title: None,
    required_client_capabilities: capabilities,
  )
}

pub fn empty_metadata() -> ToolMetadata {
  ToolMetadata(description: None, title: None, required_client_capabilities: [])
}

pub type ToolAdmissionError {
  MissingInputSchema
  InputSchemaMustBeObject(String)
  MissingOutputSchema
  UnsupportedSchemaFeature(String)
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

/// Result returned by a handler that can pause for client-provided input.
pub type InputHandlerResult(output) {
  CompleteOutput(output)
  RequestInput(Dict(String, InputRequest))
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
  ApplicationFailure(Value)
  ContentOnlyOutput
  InvalidOutput(EncodeError)
  ErrorEncodingFailure(EncodeError)
  InputRequiredOutput
}

/// Constructs a typed contextual tool after validating input schema object root and output schema.
pub fn context_tool(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  handler: fn(context, input) -> Result(output, application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  case schema.validate_input_schema(codec.schema(input)) {
    Error(schema.MissingSchema) -> Error(MissingInputSchema)
    Error(schema.SchemaMustBeObject(kind)) ->
      Error(InputSchemaMustBeObject(kind))
    Ok(admitted_input_schema) -> {
      case schema.validate_output_schema(codec.schema(output)) {
        Error(schema.MissingSchema) -> Error(MissingOutputSchema)
        Error(schema.SchemaMustBeObject(kind)) ->
          Error(UnsupportedSchemaFeature(kind))
        Ok(admitted_output_schema) -> {
          let decl =
            ToolDeclaration(
              name: name,
              metadata: metadata,
              input_schema: admitted_input_schema,
              input_schema_override: None,
              output_schema: Some(admitted_output_schema),
            )
          let invoke_fn = fn(
            ctx: context,
            raw_input: Value,
            _input_responses: Option(Value),
            _report_progress: ProgressReporter,
          ) -> Result(ToolOutput, DispatchError) {
            case codec.decode(input, raw_input) {
              Error(dec_err) -> Error(InvalidInput(dec_err))
              Ok(typed_input) ->
                case handler(ctx, typed_input) {
                  Ok(typed_output) ->
                    case codec.encode(output, typed_output) {
                      Ok(encoded_val) ->
                        Ok(StructuredWithContent(encoded_val, []))
                      Error(enc_err) -> Error(InvalidOutput(enc_err))
                    }
                  Error(app_err) ->
                    case codec.encode(error, app_err) {
                      Ok(encoded_err) -> Error(ApplicationFailure(encoded_err))
                      Error(enc_err) -> Error(ErrorEncodingFailure(enc_err))
                    }
                }
            }
          }
          Ok(ContextTool(name: name, declaration: decl, invoke: invoke_fn))
        }
      }
    }
  }
}

/// Constructs a tool that returns content blocks and optionally structured output.
/// The output codec remains required so any structured response is schema checked.
pub fn context_tool_with_content(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  handler: fn(context, input) ->
    Result(#(Option(output), List(ContentBlock)), application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  case schema.validate_input_schema(codec.schema(input)) {
    Error(schema.MissingSchema) -> Error(MissingInputSchema)
    Error(schema.SchemaMustBeObject(kind)) ->
      Error(InputSchemaMustBeObject(kind))
    Ok(admitted_input_schema) ->
      case schema.validate_output_schema(codec.schema(output)) {
        Error(schema.MissingSchema) -> Error(MissingOutputSchema)
        Error(schema.SchemaMustBeObject(kind)) ->
          Error(UnsupportedSchemaFeature(kind))
        Ok(admitted_output_schema) -> {
          let declaration =
            ToolDeclaration(
              name: name,
              metadata: metadata,
              input_schema: admitted_input_schema,
              input_schema_override: None,
              output_schema: Some(admitted_output_schema),
            )
          let invoke = fn(
            ctx: context,
            raw_input: Value,
            _input_responses: Option(Value),
            _report_progress: ProgressReporter,
          ) -> Result(ToolOutput, DispatchError) {
            case codec.decode(input, raw_input) {
              Error(dec_err) -> Error(InvalidInput(dec_err))
              Ok(typed_input) ->
                case handler(ctx, typed_input) {
                  Ok(#(None, blocks)) -> Ok(ContentOnly(blocks))
                  Ok(#(Some(value), blocks)) ->
                    case codec.encode(output, value) {
                      Ok(encoded) -> Ok(StructuredWithContent(encoded, blocks))
                      Error(enc_err) -> Error(InvalidOutput(enc_err))
                    }
                  Error(app_err) ->
                    case codec.encode(error, app_err) {
                      Ok(encoded_err) -> Error(ApplicationFailure(encoded_err))
                      Error(enc_err) -> Error(ErrorEncodingFailure(enc_err))
                    }
                }
            }
          }
          Ok(ContextTool(name, declaration, invoke))
        }
      }
  }
}

/// Constructs a typed tool whose handler can report progress while it runs.
pub fn context_tool_with_progress(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  handler: fn(context, input, ProgressReporter) ->
    Result(output, application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  case schema.validate_input_schema(codec.schema(input)) {
    Error(schema.MissingSchema) -> Error(MissingInputSchema)
    Error(schema.SchemaMustBeObject(kind)) ->
      Error(InputSchemaMustBeObject(kind))
    Ok(admitted_input_schema) ->
      case schema.validate_output_schema(codec.schema(output)) {
        Error(schema.MissingSchema) -> Error(MissingOutputSchema)
        Error(schema.SchemaMustBeObject(kind)) ->
          Error(UnsupportedSchemaFeature(kind))
        Ok(admitted_output_schema) -> {
          let declaration =
            ToolDeclaration(
              name: name,
              metadata: metadata,
              input_schema: admitted_input_schema,
              input_schema_override: None,
              output_schema: Some(admitted_output_schema),
            )
          let invoke = fn(
            ctx: context,
            raw_input: Value,
            _input_responses: Option(Value),
            report_progress: ProgressReporter,
          ) -> Result(ToolOutput, DispatchError) {
            case codec.decode(input, raw_input) {
              Error(dec_err) -> Error(InvalidInput(dec_err))
              Ok(typed_input) ->
                case handler(ctx, typed_input, report_progress) {
                  Ok(typed_output) ->
                    case codec.encode(output, typed_output) {
                      Ok(encoded_val) ->
                        Ok(StructuredWithContent(encoded_val, []))
                      Error(enc_err) -> Error(InvalidOutput(enc_err))
                    }
                  Error(app_err) ->
                    case codec.encode(error, app_err) {
                      Ok(encoded_err) -> Error(ApplicationFailure(encoded_err))
                      Error(enc_err) -> Error(ErrorEncodingFailure(enc_err))
                    }
                }
            }
          }
          Ok(ContextTool(name, declaration, invoke))
        }
      }
  }
}

/// Constructs a typed tool handler that can request input and resume with client responses.
pub fn context_tool_with_inputs(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  handler: fn(context, input, Option(Value)) ->
    Result(InputHandlerResult(output), application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  case schema.validate_input_schema(codec.schema(input)) {
    Error(schema.MissingSchema) -> Error(MissingInputSchema)
    Error(schema.SchemaMustBeObject(kind)) ->
      Error(InputSchemaMustBeObject(kind))
    Ok(admitted_input_schema) ->
      case schema.validate_output_schema(codec.schema(output)) {
        Error(schema.MissingSchema) -> Error(MissingOutputSchema)
        Error(schema.SchemaMustBeObject(kind)) ->
          Error(UnsupportedSchemaFeature(kind))
        Ok(admitted_output_schema) -> {
          let declaration =
            ToolDeclaration(
              name: name,
              metadata: metadata,
              input_schema: admitted_input_schema,
              input_schema_override: None,
              output_schema: Some(admitted_output_schema),
            )
          let invoke = fn(
            ctx: context,
            raw_input: Value,
            input_responses: Option(Value),
            _report_progress: ProgressReporter,
          ) -> Result(ToolOutput, DispatchError) {
            case codec.decode(input, raw_input) {
              Error(dec_err) -> Error(InvalidInput(dec_err))
              Ok(typed_input) ->
                case handler(ctx, typed_input, input_responses) {
                  Ok(CompleteOutput(typed_output)) ->
                    case codec.encode(output, typed_output) {
                      Ok(encoded) -> Ok(StructuredWithContent(encoded, []))
                      Error(enc_err) -> Error(InvalidOutput(enc_err))
                    }
                  Ok(RequestInput(input_requests)) ->
                    Ok(InputRequired(input_requests))
                  Error(app_err) ->
                    case codec.encode(error, app_err) {
                      Ok(encoded_err) -> Error(ApplicationFailure(encoded_err))
                      Error(enc_err) -> Error(ErrorEncodingFailure(enc_err))
                    }
                }
            }
          }
          Ok(ContextTool(name, declaration, invoke))
        }
      }
  }
}

/// Constructs a typed tool with an explicit input schema document.
///
/// The codec still validates every invocation. This constructor preserves schema
/// vocabulary that a codec cannot express, such as custom annotations and
/// Draft 2020-12 composition keywords.
pub fn context_tool_with_input_schema(
  name: ToolName,
  metadata: ToolMetadata,
  input: Codec(input),
  output: Codec(output),
  error: Codec(application_error),
  input_schema: Value,
  handler: fn(context, input) -> Result(output, application_error),
) -> Result(ContextTool(context), ToolAdmissionError) {
  case input_schema {
    value.Object(_) ->
      case context_tool(name, metadata, input, output, error, handler) {
        Error(admission_error) -> Error(admission_error)
        Ok(context_tool) -> {
          let ContextTool(tool_name, declaration, invoke) = context_tool
          Ok(ContextTool(
            tool_name,
            ToolDeclaration(
              ..declaration,
              input_schema_override: Some(input_schema),
            ),
            invoke,
          ))
        }
      }
    _ -> Error(InputSchemaMustBeObject("non-object"))
  }
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
