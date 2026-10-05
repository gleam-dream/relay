//// Extract the typed answer from a completed MCP tool call.
//// A non-interactive caller can use `require` instead of handling all
//// three result variants. Tool refusals and input requests retain their
//// evidence; a transport error keeps the original `client.Error`.
//// No retry decision is implied: combine `evidence` with the tool's
//// read-only hint and the application's policy.

import gleam/list
import gleam/option.{type Option, None}
import json/blueprint/value.{type Value}
import relay/client
import relay/content
import relay/tool

/// One error boundary for callers requiring a tool's output.
pub type Error {
  CallFailed(client.Error)
  ToolFailed(content: List(content.ContentBlock), structured: Option(Value))
  InputRequired
}

/// Stable classification; match a detailed variant only when needed.
pub type Kind {
  TransportFailure
  ToolRefusal
  NeedsInput
}

pub fn error_kind(error: Error) -> Kind {
  case error {
    CallFailed(_) -> TransportFailure
    ToolFailed(..) -> ToolRefusal
    InputRequired -> NeedsInput
  }
}

pub fn require(
  result: Result(client.ToolResult(a), client.Error),
) -> Result(a, Error) {
  case result {
    Ok(client.Succeeded(output, _)) -> Ok(output)
    Ok(client.ToolFailed(blocks, structured)) ->
      Error(ToolFailed(blocks, structured))
    Ok(client.InputRequired(..)) -> Error(InputRequired)
    Error(error) -> Error(CallFailed(error))
  }
}

/// A server refusal or input request is a completed exchange. Only a
/// transport failure can leave submission unknown.
pub fn evidence(error: Error) -> client.Evidence {
  case error {
    CallFailed(error) -> client.evidence(error)
    _ -> client.Completed
  }
}

pub fn describe_error(error: Error) -> String {
  case error {
    CallFailed(error) ->
      "the MCP call failed: "
      <> client.describe_error(error)
      <> " ("
      <> client.name(error)
      <> ")"
    ToolFailed(blocks, _) ->
      case content.text_of(blocks) {
        "" -> "the tool failed"
        text -> text
      }
    InputRequired -> "the tool asked for client input"
  }
}

/// Read one application metadata member from the first text block that
/// contains it. Input-required results have no output metadata yet.
pub fn meta(result: client.ToolResult(a), key: String) -> Option(Value) {
  let blocks = case result {
    client.Succeeded(content:, ..) | client.ToolFailed(content:, ..) -> content
    client.InputRequired(..) -> []
  }
  list.find_map(blocks, fn(block) {
    case block {
      content.TextContent(meta:, ..) -> list.key_find(meta, key)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Extract a discovered tool's structured value, or project a content-only
/// answer to a JSON string of its text blocks. Only use this projection
/// when text is sufficient; `call_discovered` retains all media blocks.
pub fn require_discovered(
  result: Result(client.ToolResult(Value), client.Error),
  declaration: tool.Declaration,
) -> Result(Value, Error) {
  case result, declaration.output_schema {
    Ok(client.Succeeded(value.Null, blocks)), None ->
      Ok(value.String(content.text_of(blocks)))
    other, _ -> require(other)
  }
}
