import gleam/io
import gleam/json
import gleam/option.{Some}
import json/blueprint/codec
import relay
import relay/protocol/jsonrpc.{RequestString}
import relay/protocol/v2026_07_28 as v2026

pub fn main() -> Nil {
  // 1. Tool setup
  let assert Ok(greet_name) = relay.tool_name("greet")
  let assert Ok(greet_tool) =
    relay.context_tool(
      greet_name,
      relay.tool_metadata("Greets the user"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: String, name: String) { Ok("Hello " <> name) },
    )

  let assert Ok(fail_name) = relay.tool_name("fail_tool")
  let assert Ok(fail_tool) =
    relay.context_tool(
      fail_name,
      relay.tool_metadata("Fails with application error"),
      codec.field("msg", codec.string()),
      codec.string(),
      codec.field("reason", codec.string()),
      fn(_ctx: String, msg: String) { Error("application error: " <> msg) },
    )

  let assert Ok(reg) = relay.registry([greet_tool, fail_tool])

  // 1. Discover response
  let disc_wire =
    v2026.encode_discovery_response(RequestString("disc-1"))
    |> json.to_string()
  emit("discover", "DiscoverResultResponse", disc_wire)

  // 2. Tools list response
  let decls = relay.declarations(reg, "corpus")
  let list_wire =
    v2026.encode_tools_list_response(RequestString("list-1"), decls)
    |> json.to_string()
  emit("tools_list", "ListToolsResultResponse", list_wire)

  // 3. Call success response
  let assert Ok(args_val) =
    codec.encode(codec.field("name", codec.string()), "World")
  let assert Ok(call_success_val) =
    relay.dispatch(reg, "corpus", greet_name, args_val)
  let call_success_wire =
    v2026.encode_call_success_response(
      RequestString("call-1"),
      call_success_val,
    )
    |> json.to_string()
  emit("tool_call_success", "CallToolResultResponse", call_success_wire)

  // 4. Call application error response
  let call_err_wire =
    v2026.encode_call_error_response(
      RequestString("call-2"),
      "application error: deliberate failure",
    )
    |> json.to_string()
  emit("tool_call_error", "CallToolResultResponse", call_err_wire)

  // 5. Unsupported protocol version error
  let unsupp_err =
    jsonrpc.unsupported_protocol_version("2024-01-01", ["2026-07-28"])
  let unsupp_wire =
    jsonrpc.error_to_json(Some(RequestString("unsupp-1")), unsupp_err)
    |> json.to_string()
  emit("unsupported_version", "UnsupportedProtocolVersionError", unsupp_wire)
}

fn emit(label: String, definition: String, wire_json: String) -> Nil {
  let line =
    "{\"label\":"
    <> json.to_string(json.string(label))
    <> ",\"definition\":"
    <> json.to_string(json.string(definition))
    <> ",\"instance\":"
    <> wire_json
    <> "}"
  io.println(line)
}
