import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import json/blueprint/codec.{
  type Codec, type DecodeError, type EncodeError, type Schema,
}
import json/blueprint/value.{type Value}
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
  ToolMetadata(description: Option(String), title: Option(String))
}

pub fn tool_metadata(description: String) -> ToolMetadata {
  ToolMetadata(description: Some(description), title: None)
}

pub fn empty_metadata() -> ToolMetadata {
  ToolMetadata(description: None, title: None)
}

pub type ToolAdmissionError {
  MissingInputSchema
  InputSchemaMustBeObject(String)
  UnsupportedSchemaFeature(String)
}

/// Retained tool declaration for discovery and tool listing.
pub type ToolDeclaration {
  ToolDeclaration(
    name: ToolName,
    metadata: ToolMetadata,
    input_schema: Schema,
    output_schema: Option(Schema),
  )
}

/// Heterogeneous contextual tool holding typed codecs and handler.
pub opaque type ContextTool(context) {
  ContextTool(
    name: ToolName,
    declaration: ToolDeclaration,
    invoke: fn(context, Value) -> Result(Value, DispatchError),
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
  InvalidOutput(EncodeError)
  ErrorEncodingFailure(EncodeError)
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
  case schema.validate_input_schema(codec.schema(input)) {
    Error(schema.MissingSchema) -> Error(MissingInputSchema)
    Error(schema.SchemaMustBeObject(kind)) ->
      Error(InputSchemaMustBeObject(kind))
    Ok(admitted_input_schema) -> {
      let admitted_output_schema = case codec.schema(output) {
        Ok(s) -> Some(s)
        Error(_) -> None
      }
      let decl =
        ToolDeclaration(
          name: name,
          metadata: metadata,
          input_schema: admitted_input_schema,
          output_schema: admitted_output_schema,
        )
      let invoke_fn = fn(ctx: context, raw_input: Value) -> Result(
        Value,
        DispatchError,
      ) {
        case codec.decode(input, raw_input) {
          Error(dec_err) -> Error(InvalidInput(dec_err))
          Ok(typed_input) ->
            case handler(ctx, typed_input) {
              Ok(typed_output) ->
                case codec.encode(output, typed_output) {
                  Ok(encoded_val) -> Ok(encoded_val)
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

/// Dispatches a tool call by name with Blueprint Value arguments.
pub fn dispatch(
  registry: Registry(context),
  context: context,
  name: ToolName,
  arguments: Value,
) -> Result(Value, DispatchError) {
  let Registry(tools) = registry
  find_and_invoke(tools, context, name, arguments)
}

fn find_and_invoke(
  tools: List(ContextTool(context)),
  context: context,
  name: ToolName,
  arguments: Value,
) -> Result(Value, DispatchError) {
  case tools {
    [] -> Error(UnknownTool(name))
    [tool, ..rest] ->
      case tool.name == name {
        True -> tool.invoke(context, arguments)
        False -> find_and_invoke(rest, context, name, arguments)
      }
  }
}
