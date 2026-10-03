//// Typed MCP tools: a definition, its handler, and what the handler sees.
////
//// `define(name, input_codec, output_codec)` admits a tool from two
//// Blueprint codecs, and `define_content(name, input_codec)` admits one that
//// returns only content blocks. Both panic with the tool name on a
//// definition mistake, such as an empty name or a non-object input schema,
//// because tool definitions are written in source code; `try_define` and
//// `try_define_content` return a typed `DefineError` for definitions built
//// from runtime data. The `with_*` setters add a title, a description, the
//// four behavior hints, icons, `_meta`, required client capabilities and an
//// explicit input schema.
////
//// The same `Definition` serves the server and the client: bind a handler
//// with `handle`, `handle_with_error_renderer` or `handle_call` and pass the
//// tools to `relay/server.new`; call it with `relay/client.call`.
//// `declaration` returns what `tools/list` publishes, and `input_codec`,
//// `output_codec` and `name` let an adapter reuse the contract.
////
//// ```gleam
//// import json/blueprint/codec
//// import relay/tool
////
//// pub fn greet() -> tool.Tool(Nil) {
////   let input = {
////     use name <- codec.field("name", codec.string(), get: fn(name) { name })
////     codec.success(name)
////   }
////   tool.define("greet", input, codec.string())
////   |> tool.with_description("Greets the user by name")
////   |> tool.with_read_only_hint(True)
////   |> tool.handle(fn(name) { Ok("Hello, " <> name <> "!") })
//// }
//// ```
////
//// `handle` hides the handler's error behind the generic message
//// `Tool execution failed.`. `handle_with_error_renderer` publishes the
//// `ToolError` a renderer builds, and `handle_call` receives the `Call`:
//// application context, input responses, progress reporting, a
//// cancellation signal, the invocation id and the correlation.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec.{type Codec}
import json/blueprint/contract.{type Contract, type DocumentError}
import json/blueprint/value.{type Value}
import relay/content.{type ContentBlock, type Icon, type Meta}
import relay/internal/core
import relay/internal/schema
import relay/internal/wire
import sinal/correlation.{type Correlation}

/// An admitted tool contract: its name, metadata, input codec and output.
/// The same value drives listing, registration and typed client calls.
pub type Definition(input, output) =
  core.Definition(input, output)

/// A definition bound to a handler, ready for `relay/server.new`.
pub type Tool(context) =
  core.Tool(context)

/// One invocation as a `handle_call` handler sees it. Read it with
/// `context`, `input_responses`, `report_progress`, `cancelled`,
/// `invocation_id`, `correlation` and `client_info`.
pub type Call(context) =
  core.Call(context)

/// What a `handle_call` handler returns: `complete`,
/// `complete_with_content` or `request_input`.
pub type Reply(output) =
  core.Reply(output)

/// A tool failure the client receives as an `isError: true` result. Build it
/// with `error_message` or `error_with`.
pub type ToolError =
  core.ToolError

/// Why `try_define` refused a definition. `define` panics with the same
/// description.
pub type DefineError {
  EmptyName
  NameTooLong(name: String, max: Int, actual: Int)
  InvalidNameCharacter(name: String, character: String)
  /// The input codec has no schema, for example a `codec.custom` without one.
  MissingInputSchema(name: String)
  /// MCP tool arguments are a JSON object; the input schema's root is not.
  InputSchemaNotObject(name: String, kind: String)
  MissingOutputSchema(name: String)
  OutputSchemaNotObject(name: String, kind: String)
}

/// A one-line description of a definition error.
pub fn describe_define_error(error: DefineError) -> String {
  case error {
    EmptyName -> "the tool name is empty"
    NameTooLong(name, max, actual) ->
      "tool name \""
      <> name
      <> "\" has "
      <> int.to_string(actual)
      <> " characters; the limit is "
      <> int.to_string(max)
    InvalidNameCharacter(name, character) ->
      "tool name \""
      <> name
      <> "\" contains \""
      <> character
      <> "\"; use ASCII letters, digits, '.', '_', '-' and '/'"
    MissingInputSchema(name) ->
      "tool \"" <> name <> "\": the input codec has no schema"
    InputSchemaNotObject(name, kind) ->
      "tool \""
      <> name
      <> "\": the input schema must describe an object, not "
      <> kind
    MissingOutputSchema(name) ->
      "tool \"" <> name <> "\": the output codec has no schema"
    OutputSchemaNotObject(name, kind) ->
      "tool \""
      <> name
      <> "\": the output schema must be a JSON object, not "
      <> kind
  }
}

// --- definitions -------------------------------------------------------------

/// Admits a tool whose result is a structured value encoded by `output`.
/// Panics with the tool name when the name is invalid or a codec has no
/// schema; use `try_define` for definitions built at runtime.
pub fn define(
  name: String,
  input: Codec(input),
  output: Codec(output),
) -> Definition(input, output) {
  try_define(name, input, output) |> or_panic("define")
}

/// Admits a tool whose result is only content blocks. The output type is
/// `List(ContentBlock)`. Panics like `define`.
pub fn define_content(
  name: String,
  input: Codec(input),
) -> Definition(input, List(ContentBlock)) {
  try_define_content(name, input) |> or_panic("define_content")
}

/// `define` for definitions built from runtime data: returns the error
/// instead of panicking.
pub fn try_define(
  name: String,
  input: Codec(input),
  output: Codec(output),
) -> Result(Definition(input, output), DefineError) {
  use name <- result.try(validate_name(name))
  use input_schema <- result.try(admit_input(name, input))
  use output_schema <- result.try(admit_output(name, output))
  Ok(core.Definition(
    info: info(name, input_schema, Some(output_schema)),
    input: input,
    output: core.Structured(output, output_schema),
  ))
}

/// `define_content` for definitions built from runtime data.
pub fn try_define_content(
  name: String,
  input: Codec(input),
) -> Result(Definition(input, List(ContentBlock)), DefineError) {
  use name <- result.try(validate_name(name))
  use input_schema <- result.try(admit_input(name, input))
  Ok(core.Definition(
    info: info(name, input_schema, None),
    input: input,
    output: core.ContentOnly(fn(blocks) { blocks }, fn(blocks) { blocks }),
  ))
}

fn or_panic(
  admitted: Result(Definition(input, output), DefineError),
  caller: String,
) -> Definition(input, output) {
  case admitted {
    Ok(definition) -> definition
    Error(error) ->
      panic as {
        "relay/tool." <> caller <> ": " <> describe_define_error(error)
      }
  }
}

fn info(
  name: String,
  input_schema: Value,
  output_schema: Option(Value),
) -> core.ToolInfo {
  core.ToolInfo(
    name: name,
    title: None,
    description: None,
    input_schema: input_schema,
    output_schema: output_schema,
    hints: core.Hints(None, None, None, None),
    icons: [],
    meta: [],
    required_capabilities: [],
  )
}

const max_name_length = 128

fn validate_name(name: String) -> Result(String, DefineError) {
  let length = string.length(name)
  case length {
    0 -> Error(EmptyName)
    _ if length > max_name_length ->
      Error(NameTooLong(name, max_name_length, length))
    _ ->
      case
        list.find(string.to_graphemes(name), fn(g) { !valid_name_grapheme(g) })
      {
        Ok(character) -> Error(InvalidNameCharacter(name, character))
        Error(Nil) -> Ok(name)
      }
  }
}

fn valid_name_grapheme(grapheme: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/",
    grapheme,
  )
  && string.length(grapheme) == 1
}

fn admit_input(
  name: String,
  input: Codec(input),
) -> Result(Value, DefineError) {
  case schema.validate_input_schema(codec.schema(input)) {
    Error(schema.MissingSchema) -> Error(MissingInputSchema(name))
    Error(schema.SchemaMustBeObject(kind)) ->
      Error(InputSchemaNotObject(name, kind))
    Ok(admitted) -> Ok(schema.materialize_schema(admitted))
  }
}

fn admit_output(
  name: String,
  output: Codec(output),
) -> Result(Value, DefineError) {
  case schema.validate_output_schema(codec.schema(output)) {
    Error(schema.MissingSchema) -> Error(MissingOutputSchema(name))
    Error(schema.SchemaMustBeObject(kind)) ->
      Error(OutputSchemaNotObject(name, kind))
    Ok(admitted) -> Ok(schema.materialize_schema(admitted))
  }
}

fn update_info(
  definition: Definition(input, output),
  change: fn(core.ToolInfo) -> core.ToolInfo,
) -> Definition(input, output) {
  core.Definition(..definition, info: change(definition.info))
}

/// Sets the human-readable title clients show instead of the name.
pub fn with_title(
  definition: Definition(input, output),
  title: String,
) -> Definition(input, output) {
  use info <- update_info(definition)
  core.ToolInfo(..info, title: Some(title))
}

/// Sets the description a client or a model reads to choose the tool.
pub fn with_description(
  definition: Definition(input, output),
  description: String,
) -> Definition(input, output) {
  use info <- update_info(definition)
  core.ToolInfo(..info, description: Some(description))
}

/// Publishes `readOnlyHint`: whether the tool leaves its environment
/// unchanged. Unset hints are omitted.
pub fn with_read_only_hint(
  definition: Definition(input, output),
  hint: Bool,
) -> Definition(input, output) {
  use info <- update_info(definition)
  core.ToolInfo(..info, hints: core.Hints(..info.hints, read_only: Some(hint)))
}

/// Publishes `destructiveHint`: whether the tool may destroy data.
pub fn with_destructive_hint(
  definition: Definition(input, output),
  hint: Bool,
) -> Definition(input, output) {
  use info <- update_info(definition)
  core.ToolInfo(
    ..info,
    hints: core.Hints(..info.hints, destructive: Some(hint)),
  )
}

/// Publishes `idempotentHint`: whether repeating a call has no further
/// effect.
pub fn with_idempotent_hint(
  definition: Definition(input, output),
  hint: Bool,
) -> Definition(input, output) {
  use info <- update_info(definition)
  core.ToolInfo(..info, hints: core.Hints(..info.hints, idempotent: Some(hint)))
}

/// Publishes `openWorldHint`: whether the tool reaches outside systems.
pub fn with_open_world_hint(
  definition: Definition(input, output),
  hint: Bool,
) -> Definition(input, output) {
  use info <- update_info(definition)
  core.ToolInfo(..info, hints: core.Hints(..info.hints, open_world: Some(hint)))
}

/// Replaces the icons a client may show for the tool.
pub fn with_icons(
  definition: Definition(input, output),
  icons: List(Icon),
) -> Definition(input, output) {
  use info <- update_info(definition)
  core.ToolInfo(..info, icons: icons)
}

/// Replaces the declaration's `_meta` members.
pub fn with_meta(
  definition: Definition(input, output),
  meta: Meta,
) -> Definition(input, output) {
  use info <- update_info(definition)
  core.ToolInfo(..info, meta: meta)
}

/// Names client capabilities, such as `"elicitation"`, that a call needs. A
/// request whose metadata does not declare them fails with the MCP
/// missing-capability error before the handler runs.
pub fn with_required_client_capabilities(
  definition: Definition(input, output),
  capabilities: List(String),
) -> Definition(input, output) {
  use info <- update_info(definition)
  core.ToolInfo(..info, required_capabilities: capabilities)
}

/// Publishes this JSON Schema document as the input schema instead of the
/// one derived from the input codec; the codec still decodes every call.
/// Panics when the schema is not a JSON object.
pub fn with_input_schema(
  definition: Definition(input, output),
  input_schema: Value,
) -> Definition(input, output) {
  case input_schema {
    value.Object(_) -> {
      use info <- update_info(definition)
      core.ToolInfo(..info, input_schema: input_schema)
    }
    _ ->
      panic as {
        "relay/tool.with_input_schema: tool \""
        <> definition.info.name
        <> "\": the input schema must be a JSON object"
      }
  }
}

/// The tool's name.
pub fn name(definition: Definition(input, output)) -> String {
  definition.info.name
}

/// The codec that encodes call arguments and decodes them in the handler.
pub fn input_codec(definition: Definition(input, output)) -> Codec(input) {
  definition.input
}

/// The codec of the structured result, or `None` for a content-only tool.
pub fn output_codec(
  definition: Definition(input, output),
) -> Option(Codec(output)) {
  case definition.output {
    core.Structured(codec, _) -> Some(codec)
    core.ContentOnly(..) -> None
  }
}

/// What `tools/list` publishes for this definition.
pub fn declaration(definition: Definition(input, output)) -> Declaration {
  declaration_of(definition.info)
}

// --- declarations ------------------------------------------------------------

/// The annotations of a tool declaration. `None` means the server did not
/// publish the hint. Read fields by label.
pub type ToolAnnotations {
  ToolAnnotations(
    title: Option(String),
    read_only_hint: Option(Bool),
    destructive_hint: Option(Bool),
    idempotent_hint: Option(Bool),
    open_world_hint: Option(Bool),
  )
}

/// A tool as `tools/list` publishes it: local declarations come from
/// `declaration` and `tool_declaration`, remote ones from
/// `relay/client.list_tools`. The schemas are JSON Schema documents as exact
/// Blueprint values; `input_contract` loads the input schema for
/// validation. Read fields by label: a later revision may add fields.
pub type Declaration {
  Declaration(
    name: String,
    title: Option(String),
    description: Option(String),
    input_schema: Value,
    output_schema: Option(Value),
    annotations: ToolAnnotations,
    icons: List(Icon),
    meta: Meta,
  )
}

/// Loads the declaration's input schema as a Blueprint contract, to
/// validate arguments before a call. Fails for a schema outside the profile
/// Blueprint validates.
pub fn input_contract(
  declaration: Declaration,
) -> Result(Contract, DocumentError) {
  contract.load(declaration.input_schema)
}

fn declaration_of(info: core.ToolInfo) -> Declaration {
  Declaration(
    name: info.name,
    title: info.title,
    description: info.description,
    input_schema: info.input_schema,
    output_schema: info.output_schema,
    annotations: ToolAnnotations(
      title: None,
      read_only_hint: info.hints.read_only,
      destructive_hint: info.hints.destructive,
      idempotent_hint: info.hints.idempotent,
      open_world_hint: info.hints.open_world,
    ),
    icons: info.icons,
    meta: info.meta,
  )
}

/// What `tools/list` publishes for a bound tool.
pub fn tool_declaration(tool: Tool(context)) -> Declaration {
  declaration_of(tool.info)
}

// --- input requests ----------------------------------------------------------

/// A server-initiated method a tool or prompt may ask the client to answer.
pub type InputMethod {
  /// `elicitation/create`: ask the user to fill a form.
  Elicitation
  /// `sampling/createMessage`: ask the client's model for a completion.
  Sampling
  /// `roots/list`: ask for the client's filesystem roots.
  Roots
}

/// One request in an input round. `params` is the method's params object
/// as defined by the pinned revision.
pub type InputRequest {
  InputRequest(method: InputMethod, params: Value)
}

/// The wire name of an input method, such as `"elicitation/create"`.
pub fn input_method_name(method: InputMethod) -> String {
  case method {
    Elicitation -> "elicitation/create"
    Sampling -> "sampling/createMessage"
    Roots -> "roots/list"
  }
}

// --- binding handlers --------------------------------------------------------

const generic_failure = "Tool execution failed."

/// Binds a handler. An `Error` reaches the client as the generic message
/// `Tool execution failed.`, so the handler's private error never leaks.
pub fn handle(
  definition: Definition(input, output),
  handler: fn(input) -> Result(output, error),
) -> Tool(context) {
  handle_with_error_renderer(definition, handler, fn(_) {
    error_message(generic_failure)
  })
}

/// Binds a handler and publishes the `ToolError` that `render` builds from
/// its error, before registration erases the error type.
pub fn handle_with_error_renderer(
  definition: Definition(input, output),
  handler: fn(input) -> Result(output, error),
  render: fn(error) -> ToolError,
) -> Tool(context) {
  handle_call(definition, fn(_call, input) {
    case handler(input) {
      Ok(output) -> Ok(complete(output))
      Error(error) -> Error(render(error))
    }
  })
}

/// Binds a handler that receives the `Call` and returns a `Reply`: a result,
/// a result with explicit content, or another input round.
pub fn handle_call(
  definition: Definition(input, output),
  handler: fn(Call(context), input) -> Result(Reply(output), ToolError),
) -> Tool(context) {
  let core.Definition(info, input_codec, output) = definition
  core.Tool(info: info, invoke: fn(call, arguments) {
    case codec.decode(input_codec, arguments) {
      Error(error) -> core.InvalidArguments(error)
      Ok(input) ->
        case handler(call, input) {
          Error(core.ToolError(blocks, structured)) ->
            core.Failed(blocks, structured)
          Ok(core.NeedsInput(requests)) -> core.AwaitingInput(requests)
          Ok(core.Complete(value, blocks)) ->
            encode_output(output, value, blocks)
        }
    }
  })
}

fn encode_output(
  output: core.Output(output),
  value: output,
  blocks: Option(List(ContentBlock)),
) -> core.Outcome {
  case output {
    core.ContentOnly(_, to_content) ->
      core.Completed(None, option.unwrap(blocks, to_content(value)))
    core.Structured(output_codec, _) ->
      case codec.encode(output_codec, value) {
        Error(_) -> core.InvalidOutput
        Ok(encoded) ->
          core.Completed(
            Some(encoded),
            option.lazy_unwrap(blocks, fn() {
              [content.text(wire.text_mirror(encoded))]
            }),
          )
      }
  }
}

// --- replies and errors ------------------------------------------------------

/// A finished call. A structured tool also gets a text block that mirrors
/// the encoded value, for clients that read only content.
pub fn complete(output: output) -> Reply(output) {
  core.Complete(output, None)
}

/// A finished call with explicit content blocks instead of the text mirror.
pub fn complete_with_content(
  output: output,
  blocks: List(ContentBlock),
) -> Reply(output) {
  core.Complete(output, Some(blocks))
}

/// Pauses the call until the client answers every request; the client calls
/// again with the responses, which the handler reads with
/// `input_responses`. Requests for methods the client did not declare are
/// left out.
pub fn request_input(requests: Dict(String, InputRequest)) -> Reply(output) {
  core.NeedsInput(
    dict.to_list(requests)
    |> list.map(fn(entry) {
      let #(key, InputRequest(method, params)) = entry
      #(key, core.InputRequest(input_method_name(method), params))
    }),
  )
}

/// A tool failure with one text block.
pub fn error_message(text: String) -> ToolError {
  core.ToolError([content.text(text)], None)
}

/// A tool failure with its own content and optional structured value.
pub fn error_with(
  blocks: List(ContentBlock),
  structured: Option(Value),
) -> ToolError {
  core.ToolError(blocks, structured)
}

// --- the call ----------------------------------------------------------------

/// The client's name and version, from the request metadata.
pub type ClientInfo {
  ClientInfo(name: String, version: String)
}

/// The application context the transport built for this request.
pub fn context(call: Call(context)) -> context {
  call.context
}

/// The client's responses to the previous input round, by request key;
/// empty on the first round.
pub fn input_responses(call: Call(context)) -> Dict(String, Value) {
  dict.from_list(call.input_responses)
}

/// Sends a progress notification when the client asked for progress.
/// `progress` must increase from one report to the next; Relay drops a
/// report that does not. `total` and `message` are optional.
pub fn report_progress(
  call: Call(context),
  progress: Float,
  total: Option(Float),
  message: Option(String),
) -> Nil {
  call.progress(progress, total, message)
}

/// Fires once when the call is cancelled: the client disconnected, sent a
/// cancellation, or the invocation timed out. Select on it while the
/// handler waits, and stop work it started elsewhere: Relay waits up to the
/// runtime's cancellation grace period for the handler to return, then
/// kills it.
pub fn cancelled(call: Call(context)) -> process.Selector(Nil) {
  call.cancelled
}

/// The id Relay's telemetry uses for this invocation.
pub fn invocation_id(call: Call(context)) -> Int {
  call.invocation_id
}

/// The correlation the transport attached to this request, if any.
pub fn correlation(call: Call(context)) -> Option(Correlation) {
  call.correlation
}

/// The client's name and version, when the request declared them.
pub fn client_info(call: Call(context)) -> Option(ClientInfo) {
  option.map(call.client_info, fn(pair) { ClientInfo(pair.0, pair.1) })
}
