import gleam/bit_array
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import json/blueprint/codec
import relay/completion
import relay/content
import relay/internal/protocol/v2026_07_28 as v2026
import relay/prompts
import relay/protocol/jsonrpc.{RequestString}
import relay/resources
import relay/server
import relay/subscriptions
import relay/tool

pub fn main() -> Nil {
  // 1. Tool setup
  let assert Ok(greet_name) = tool.tool_name("greet")
  let assert Ok(greet_tool) = case
    tool.definition(
      greet_name,
      codec.field("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Greets the user"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(name: String) { Ok("Hello " <> name) },
          fn(application_error) {
            case
              codec.encode_json(codec.object(codec.empty()), application_error)
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }

  let assert Ok(fail_name) = tool.tool_name("fail_tool")
  let assert Ok(fail_tool) = case
    tool.definition(
      fail_name,
      codec.field("msg", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Fails with application error"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(msg: String) { Error("application error: " <> msg) },
          fn(application_error) {
            case
              codec.encode_json(
                codec.field("reason", codec.string()),
                application_error,
              )
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }

  let assert Ok(reg) = tool.registry([greet_tool, fail_tool])

  // 1. Discover response
  let disc_wire =
    v2026.encode_discovery_response(RequestString("disc-1"))
    |> json.to_string()
  emit("discover", "DiscoverResultResponse", disc_wire)

  // 2. Tools list response
  let decls = tool.declarations(reg, "corpus")
  let list_wire =
    v2026.encode_tools_list_response(RequestString("list-1"), decls)
    |> json.to_string()
  emit("tools_list", "ListToolsResultResponse", list_wire)

  // 3. Call success response
  let assert Ok(args_val) =
    codec.encode(codec.field("name", codec.string()), "World")
  let assert Ok(call_success_val) =
    tool.dispatch(reg, "corpus", greet_name, args_val)
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

  let subscription_id = RequestString("sub-1")
  let filter =
    subscriptions.SubscriptionFilter(
      tools_list_changed: True,
      resources_list_changed: True,
      prompts_list_changed: True,
      resource_subscriptions: ["memory://corpus/one"],
    )
  let listen_wire =
    v2026.encode_subscriptions_listen_request(subscription_id, filter)
    |> json.to_string
  emit("subscriptions_listen", "SubscriptionsListenRequest", listen_wire)
  let acknowledgement_wire =
    v2026.encode_subscriptions_acknowledged_notification(
      subscription_id,
      filter,
    )
    |> json.to_string
  emit(
    "subscriptions_acknowledged",
    "SubscriptionsAcknowledgedNotification",
    acknowledgement_wire,
  )
  let resource_updated_wire =
    v2026.encode_resource_updated_notification(
      subscription_id,
      "memory://corpus/one",
    )
    |> json.to_string
  emit("resource_updated", "ResourceUpdatedNotification", resource_updated_wire)
  let tools_changed_wire =
    v2026.encode_tools_list_changed_notification(subscription_id)
    |> json.to_string
  emit("tools_list_changed", "ToolListChangedNotification", tools_changed_wire)
  let resources_changed_wire =
    v2026.encode_resources_list_changed_notification(subscription_id)
    |> json.to_string
  emit(
    "resources_list_changed",
    "ResourceListChangedNotification",
    resources_changed_wire,
  )
  let prompts_changed_wire =
    v2026.encode_prompts_list_changed_notification(subscription_id)
    |> json.to_string
  emit(
    "prompts_list_changed",
    "PromptListChangedNotification",
    prompts_changed_wire,
  )

  // 5. Unsupported protocol version error
  let unsupp_err =
    jsonrpc.unsupported_protocol_version("2024-01-01", ["2026-07-28"])
  let unsupp_wire =
    jsonrpc.error_to_json(Some(RequestString("unsupp-1")), unsupp_err)
    |> json.to_string()
  emit("unsupported_version", "UnsupportedProtocolVersionError", unsupp_wire)

  // Service results below pass through server admission, dispatch and response
  // encoding, so the gate checks the actual delivered wire shapes.
  let assert Ok(empty_registry) = tool.registry([])
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
    server.server(empty_registry)
    |> server.with_resources([resource])
    |> server.with_resource_templates([template])
    |> server.with_prompts([prompt])
    |> server.with_completion(Some(completion))

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
