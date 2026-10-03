//// Prints one JSON line per wire message Relay delivers, for
//// `scripts/relay_schema_check.py`, which validates each against the frozen
//// MCP 2026-07-28 schema. Every server message passes through the reducer
//// (admission, routing, invocation and response encoding), so the gate
//// checks the delivered wire shapes. Each line is
//// `{"label", "definition", ["resultDefinition",] "instance"}`.

import gleam/bit_array
import gleam/io
import gleam/json
import gleam/option.{None}
import gleam/string
import json/blueprint/codec
import relay/completion
import relay/content
import relay/internal/protocol/v2026_07_28 as v2026
import relay/internal/subscriptions_state as subs
import relay/prompts
import relay/reducer
import relay/resources
import relay/server
import relay/subscriptions
import relay/test_codec
import relay/tool

pub fn main() -> Nil {
  // Tools: one that succeeds and one that fails with an application error.
  let greet =
    tool.define(
      "greet",
      test_codec.property("name", codec.string()),
      codec.string(),
    )
    |> tool.with_description("Greets the user")
    |> tool.handle(fn(name: String) { Ok("Hello " <> name) })
  let fail =
    tool.define(
      "fail_tool",
      test_codec.property("msg", codec.string()),
      codec.string(),
    )
    |> tool.with_description("Fails with application error")
    |> tool.handle_with_error_renderer(
      fn(msg: String) { Error("application error: " <> msg) },
      tool.error_message,
    )
  let tools = reducer.init(server.new([greet, fail]))

  let #(tools, delivered) = deliver(tools, "server/discover", [])
  emit("discover", "DiscoverResultResponse", delivered)

  let #(tools, delivered) = deliver(tools, "tools/list", [])
  emit("tools_list", "ListToolsResultResponse", delivered)

  let #(tools, delivered) =
    deliver(tools, "tools/call", [
      #("name", json.string("greet")),
      #("arguments", json.object([#("name", json.string("World"))])),
    ])
  emit("tool_call_success", "CallToolResultResponse", delivered)

  let #(tools, delivered) =
    deliver(tools, "tools/call", [
      #("name", json.string("fail_tool")),
      #("arguments", json.object([#("msg", json.string("deliberate failure"))])),
    ])
  emit("tool_call_error", "CallToolResultResponse", delivered)

  // An unsupported protocol version is refused at admission.
  let #(_tools, delivered) =
    deliver_frame(
      tools,
      frame(
        "server/discover",
        json.object([
          #(
            "io.modelcontextprotocol/protocolVersion",
            json.string("2024-01-01"),
          ),
          #("io.modelcontextprotocol/clientCapabilities", json.object([])),
        ]),
        [],
      ),
    )
  emit("unsupported_version", "UnsupportedProtocolVersionError", delivered)

  // Services: resources, a template, a prompt and a completion handler.
  let resource =
    resources.static(
      "memory://corpus/one",
      "corpus resource",
      fn(_context: Nil, uri) {
        Ok([
          content.TextResourceContents(
            uri,
            "resource body",
            option.Some("text/plain"),
            [],
          ),
        ])
      },
    )
  let template =
    resources.template(
      "memory://corpus/{id}",
      "corpus template",
      fn(_context: Nil, uri) {
        Ok([
          content.TextResourceContents(
            uri,
            "template body",
            option.Some("text/plain"),
            [],
          ),
        ])
      },
    )
  let prompt =
    prompts.prompt("welcome", [], fn(_context: Nil, _arguments) {
      Ok(prompts.PromptResult(None, [prompts.user_message("hello")], []))
    })
  let complete =
    completion.completion(fn(_context: Nil, request: completion.Request) {
      Ok(completion.Values([request.value], option.Some(1), option.Some(False)))
    })
  let services =
    server.new([greet])
    |> server.with_resources([resource, template])
    |> server.with_prompts([prompt])
    |> server.with_completion(complete)
    |> reducer.init

  let #(services, delivered) = deliver(services, "resources/list", [])
  emit_service(
    "resources_list",
    "ListResourcesResultResponse",
    "ListResourcesResult",
    delivered,
  )
  let #(services, delivered) = deliver(services, "resources/templates/list", [])
  emit_service(
    "resource_templates_list",
    "ListResourceTemplatesResultResponse",
    "ListResourceTemplatesResult",
    delivered,
  )
  let #(services, delivered) =
    deliver(services, "resources/read", [
      #("uri", json.string("memory://corpus/one")),
    ])
  emit_service(
    "resource_read",
    "ReadResourceResultResponse",
    "ReadResourceResult",
    delivered,
  )
  let #(services, delivered) = deliver(services, "prompts/list", [])
  emit_service(
    "prompts_list",
    "ListPromptsResultResponse",
    "ListPromptsResult",
    delivered,
  )
  let #(services, delivered) =
    deliver(services, "prompts/get", [
      #("name", json.string("welcome")),
      #("arguments", json.object([])),
    ])
  emit_service(
    "prompt_get",
    "GetPromptResultResponse",
    "GetPromptResult",
    delivered,
  )
  let #(services, delivered) =
    deliver(services, "completion/complete", [
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
      #(
        "context",
        json.object([
          #("arguments", json.object([#("lang", json.string("gleam"))])),
        ]),
      ),
    ])
  emit_service(
    "completion",
    "CompleteResultResponse",
    "CompleteResult",
    delivered,
  )

  // A listen stream: the request as the client encodes it, then the
  // acknowledgement and every notification kind the server writes on it.
  let filter =
    subs.filter_of([
      subscriptions.ToolsListChanged,
      subscriptions.ResourcesListChanged,
      subscriptions.PromptsListChanged,
      subscriptions.ResourceUpdated("memory://corpus/one"),
    ])
  let listen =
    frame("subscriptions/listen", default_meta(), [
      #("notifications", v2026.filter_to_json(filter)),
    ])
  emit("subscriptions_listen", "SubscriptionsListenRequest", body(listen))

  let exchange = reducer.new_exchange_id()
  let #(services, effects) =
    reducer.step(services, reducer.Received(exchange, Nil, listen, None))
  let assert [reducer.Admitted(_, _), reducer.Write(_, ack)] = effects
  emit(
    "subscriptions_acknowledged",
    "SubscriptionsAcknowledgedNotification",
    body(ack),
  )

  let services =
    notify(
      services,
      subscriptions.ResourceUpdated("memory://corpus/one"),
      "resource_updated",
      "ResourceUpdatedNotification",
    )
  let services =
    notify(
      services,
      subscriptions.ToolsListChanged,
      "tools_list_changed",
      "ToolListChangedNotification",
    )
  let services =
    notify(
      services,
      subscriptions.ResourcesListChanged,
      "resources_list_changed",
      "ResourceListChangedNotification",
    )
  let _services =
    notify(
      services,
      subscriptions.PromptsListChanged,
      "prompts_list_changed",
      "PromptListChangedNotification",
    )
  Nil
}

fn default_meta() -> json.Json {
  json.object([
    #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
    #("io.modelcontextprotocol/clientCapabilities", json.object([])),
  ])
}

fn frame(
  method: String,
  meta: json.Json,
  fields: List(#(String, json.Json)),
) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(1)),
    #("method", json.string(method)),
    #("params", json.object([#("_meta", meta), ..fields])),
  ])
  |> json.to_string
  |> bit_array.from_string
}

fn deliver(
  state: reducer.State(Nil),
  method: String,
  fields: List(#(String, json.Json)),
) -> #(reducer.State(Nil), String) {
  deliver_frame(state, frame(method, default_meta(), fields))
}

// Steps one request frame through the reducer, runs its invocation when it
// starts one, and returns the response the client receives.
fn deliver_frame(
  state: reducer.State(Nil),
  bytes: BitArray,
) -> #(reducer.State(Nil), String) {
  let #(state, effects) =
    reducer.step(
      state,
      reducer.Received(reducer.new_exchange_id(), Nil, bytes, None),
    )
  case effects {
    [reducer.Admitted(_, _), reducer.Write(_, bytes), reducer.Close(_)]
    | [reducer.Write(_, bytes), reducer.Close(_)] -> #(state, body(bytes))
    [reducer.Admitted(_, _), reducer.Start(invocation)] -> {
      let finished = reducer.perform(invocation, fn(_, _, _) { Nil })
      let #(state, effects) = reducer.step(state, finished)
      let assert [reducer.Write(_, bytes), reducer.Close(_)] = effects
      #(state, body(bytes))
    }
    _ -> panic as "corpus request was not delivered"
  }
}

fn notify(
  state: reducer.State(Nil),
  notification: subscriptions.Notification,
  label: String,
  definition: String,
) -> reducer.State(Nil) {
  let #(state, effects) = reducer.step(state, reducer.Notify(notification))
  let assert [reducer.Write(_, bytes)] = effects
  emit(label, definition, body(bytes))
  state
}

// The JSON text of a frame, without the newline the reducer appends.
fn body(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes)
  case string.ends_with(text, "\n") {
    True -> string.drop_end(text, 1)
    False -> text
  }
}

fn emit(label: String, definition: String, wire_json: String) -> Nil {
  io.println(
    "{\"label\":"
    <> json.to_string(json.string(label))
    <> ",\"definition\":"
    <> json.to_string(json.string(definition))
    <> ",\"instance\":"
    <> wire_json
    <> "}",
  )
}

fn emit_service(
  label: String,
  definition: String,
  result_definition: String,
  wire_json: String,
) -> Nil {
  io.println(
    "{\"label\":"
    <> json.to_string(json.string(label))
    <> ",\"definition\":"
    <> json.to_string(json.string(definition))
    <> ",\"resultDefinition\":"
    <> json.to_string(json.string(result_definition))
    <> ",\"instance\":"
    <> wire_json
    <> "}",
  )
}
