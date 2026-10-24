//// The representations behind Relay's opaque server types. The public
//// modules (`relay/tool`, `relay/resources`, `relay/prompts`,
//// `relay/completion`, `relay/server`) alias these types and build them;
//// the reducer and the client read them.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option}
import json/blueprint/codec.{type Codec, type DecodeError}
import json/blueprint/value.{type Value}
import relay/content.{
  type Annotations, type ContentBlock, type Icon, type Meta,
  type ResourceContents,
}
import relay/internal/jsonrpc
import sinal/correlation.{type Correlation}

// --- tools -------------------------------------------------------------------

/// The four behavior hints of a tool's annotations.
pub type Hints {
  Hints(
    read_only: Option(Bool),
    destructive: Option(Bool),
    idempotent: Option(Bool),
    open_world: Option(Bool),
  )
}

/// What a tool publishes in `tools/list`.
pub type ToolInfo {
  ToolInfo(
    name: String,
    title: Option(String),
    description: Option(String),
    input_schema: Value,
    output_schema: Option(Value),
    hints: Hints,
    icons: List(Icon),
    meta: Meta,
    required_capabilities: List(String),
  )
}

/// How a definition's output reaches the wire.
pub type Output(output) {
  Structured(codec: Codec(output), schema: Value)
  ContentOnly(
    from_content: fn(List(ContentBlock)) -> output,
    to_content: fn(output) -> List(ContentBlock),
  )
}

pub type Definition(input, output) {
  Definition(info: ToolInfo, input: Codec(input), output: Output(output))
}

/// A server-initiated input request: its method name and params object.
pub type InputRequest {
  InputRequest(method: String, params: Value)
}

/// What a handler returns: a result, or a request for another input round.
pub type Reply(output) {
  Complete(output: output, content: Option(List(ContentBlock)), meta: Meta)
  NeedsInput(requests: List(#(String, InputRequest)))
}

/// A tool failure the client sees as an `isError` result.
pub type ToolError {
  ToolError(content: List(ContentBlock), structured: Option(Value))
}

/// One server-side invocation, as a handler sees it.
pub type Call(context) {
  Call(
    context: context,
    input_responses: List(#(String, Value)),
    invocation_id: Int,
    request_id: jsonrpc.RequestId,
    idempotency_key: Option(String),
    correlation: Correlation,
    client_info: Option(#(String, String)),
    progress: fn(Float, Option(Float), Option(String)) -> Nil,
    cancelled: process.Selector(Nil),
  )
}

/// A tool's result with its native types erased.
pub type Outcome {
  Completed(structured: Option(Value), content: List(ContentBlock))
  Failed(content: List(ContentBlock), structured: Option(Value))
  AwaitingInput(requests: List(#(String, InputRequest)))
  InvalidArguments(DecodeError)
  InvalidOutput
}

pub type Tool(context) {
  Tool(info: ToolInfo, invoke: fn(Call(context), Value) -> Outcome)
}

// --- resources ---------------------------------------------------------------

pub type ResourceKind {
  Static(uri: String)
  Template(uri_template: String, matches: fn(String) -> Bool)
}

pub type Resource(context) {
  Resource(
    kind: ResourceKind,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    size: Option(Int),
    annotations: Option(Annotations),
    icons: List(Icon),
    meta: Meta,
    read: fn(context, String) -> Result(List(ResourceContents), Nil),
  )
}

// --- prompts -----------------------------------------------------------------

pub type PromptArgument {
  PromptArgument(
    name: String,
    title: Option(String),
    description: Option(String),
    required: Bool,
  )
}

/// Result members encoded by the module that owns their types, and the
/// result's own `_meta` members.
pub type Encoded {
  Encoded(fields: List(#(String, json.Json)), meta: Meta)
}

pub type Prompt(context) {
  Prompt(
    name: String,
    title: Option(String),
    description: Option(String),
    arguments: List(PromptArgument),
    icons: List(Icon),
    meta: Meta,
    // The encoded `GetPromptResult` members, or another input round.
    get: fn(Call(context), Dict(String, String)) -> Result(Reply(Encoded), Nil),
  )
}

// --- completion --------------------------------------------------------------

pub type CompletionTarget {
  PromptTarget(name: String)
  ResourceTarget(uri_template: String)
}

pub type CompletionQuery {
  CompletionQuery(
    target: CompletionTarget,
    argument_name: String,
    argument_value: String,
    context: Dict(String, String),
  )
}

pub type Completion(context) {
  Completion(
    // The encoded `completion` object of a `CompleteResult`.
    complete: fn(context, CompletionQuery) -> Result(json.Json, Nil),
  )
}

// --- server ------------------------------------------------------------------

pub type Server(context) {
  Server(
    tools: List(Tool(context)),
    resources: List(Resource(context)),
    prompts: List(Prompt(context)),
    completion: Option(Completion(context)),
    visible: fn(context, Tool(context)) -> Bool,
    callable: fn(context, Tool(context)) -> Bool,
    name: String,
    version: String,
    instructions: Option(String),
    // Signs pagination cursors and input-round state, so a token from one
    // connection stays valid on another that serves the same description.
    cursor_key: BitArray,
  )
}

pub fn find_tool(
  tools: List(Tool(context)),
  name: String,
) -> Result(Tool(context), Nil) {
  case tools {
    [] -> Error(Nil)
    [tool, ..rest] ->
      case tool.info.name == name {
        True -> Ok(tool)
        False -> find_tool(rest, name)
      }
  }
}
