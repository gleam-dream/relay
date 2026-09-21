import gleam/bit_array
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import json/blueprint/codec
import relay
import relay/completion
import relay/content
import relay/prompts
import relay/protocol/jsonrpc.{RequestString}
import relay/protocol/v2026_07_28 as v2026
import relay/resources
import relay/server

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

  // Service results below pass through server admission, dispatch and response
  // encoding, so the gate checks the actual delivered wire shapes.
  let assert Ok(empty_registry) = relay.registry([])
  let resource =
    resources.resource(
      "memory://corpus/one",
      "corpus resource",
      fn(_context: Nil, uri) {
        Ok([
          content.TextResourceContents(uri, "resource body", Some("text/plain")),
        ])
      },
    )
  let template =
    resources.resource_template(
      "memory://corpus/{id}",
      "corpus template",
      fn(_context: Nil, uri) {
        Ok([
          content.TextResourceContents(uri, "template body", Some("text/plain")),
        ])
      },
    )
  let prompt =
    prompts.prompt("welcome", [], fn(_context: Nil, _arguments) {
      Ok(
        prompts.PromptResult(None, [
          prompts.PromptMessage(content.UserRole, content.text_content("hello")),
        ]),
      )
    })
  let completion =
    completion.completion(fn(_context: Nil, _reference, argument) {
      Ok(completion.CompletionValues([argument.value], Some(1), Some(False)))
    })
  let service_server =
    server.server_with_services(
      empty_registry,
      [resource],
      [template],
      [prompt],
      Some(completion),
    )

  let #(service_server, delivered) =
    deliver(service_server, "resources/list", [])
  emit_service(
    "resources_list",
    "ListResourcesResultResponse",
    "ListResourcesResult",
    delivered,
  )
  let #(service_server, delivered) =
    deliver(service_server, "resources/templates/list", [])
  emit_service(
    "resource_templates_list",
    "ListResourceTemplatesResultResponse",
    "ListResourceTemplatesResult",
    delivered,
  )
  let #(service_server, delivered) =
    deliver(service_server, "resources/read", [
      #("uri", json.string("memory://corpus/one")),
    ])
  emit_service(
    "resource_read",
    "ReadResourceResultResponse",
    "ReadResourceResult",
    delivered,
  )
  let #(service_server, delivered) = deliver(service_server, "prompts/list", [])
  emit_service(
    "prompts_list",
    "ListPromptsResultResponse",
    "ListPromptsResult",
    delivered,
  )
  let #(service_server, delivered) =
    deliver(service_server, "prompts/get", [
      #("name", json.string("welcome")),
      #("arguments", json.object([])),
    ])
  emit_service(
    "prompt_get",
    "GetPromptResultResponse",
    "GetPromptResult",
    delivered,
  )
  let #(_service_server, delivered) =
    deliver(service_server, "completion/complete", [
      #(
        "ref",
        json.object([
          #("type", json.string("ref/prompt")),
          #("name", json.string("welcome")),
        ]),
      ),
      #(
        "argument",
        json.object([
          #("name", json.string("name")),
          #("value", json.string("a")),
        ]),
      ),
    ])
  emit_service(
    "completion",
    "CompleteResultResponse",
    "CompleteResult",
    delivered,
  )
}

fn deliver(
  server: server.Server(Nil),
  method: String,
  fields: List(#(String, json.Json)),
) -> #(server.Server(Nil), String) {
  let meta =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ])
  let request =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(1)),
      #("method", json.string(method)),
      #("params", json.object([#("_meta", meta), ..fields])),
    ])
  let #(server, effects) =
    server.step(
      server,
      server.MessageReceived(
        server.fresh_exchange(),
        Nil,
        request |> json.to_string |> bit_array.from_string,
      ),
    )
  case effects {
    [
      server.EmitRequestAdmitted(_, _),
      server.Write(_, bytes),
      server.CloseExchange(_),
    ] -> #(server, response_body(bytes))
    [server.EmitRequestAdmitted(_, _), server.StartInvocation(invocation)] -> {
      let #(server, effects) = server.step(server, server.perform(invocation))
      let assert [server.Write(_, bytes), server.CloseExchange(_)] = effects
      #(server, response_body(bytes))
    }
    _ -> panic as "service corpus request was not delivered"
  }
}

fn response_body(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes)
  string.drop_end(text, 1)
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

fn emit_service(
  label: String,
  definition: String,
  result_definition: String,
  wire_json: String,
) -> Nil {
  let line =
    "{\"label\":"
    <> json.to_string(json.string(label))
    <> ",\"definition\":"
    <> json.to_string(json.string(definition))
    <> ",\"resultDefinition\":"
    <> json.to_string(json.string(result_definition))
    <> ",\"instance\":"
    <> wire_json
    <> "}"
  io.println(line)
}
