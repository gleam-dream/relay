import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/value
import relay
import relay/completion
import relay/content
import relay/prompts
import relay/resources
import relay/server
import relay/transport/http

const png_1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p2sAAAAASUVORK5CYII="

const wav_silence = "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQAAAAA="

pub fn main() -> Nil {
  let assert Ok(registry) = relay.registry(test_tools())
  let assert Ok(listener) =
    http.start_http_server(
      conformance_server(registry),
      http.HttpOptions(port: 0, host: "127.0.0.1"),
    )
  io.println(
    "RELAY_CONFORMANCE_URL=http://127.0.0.1:"
    <> int.to_string(http.http_server_port(listener))
    <> "/mcp",
  )
  keep_alive()
}

fn keep_alive() -> Nil {
  process.sleep(60_000)
  keep_alive()
}

fn conformance_server(registry: relay.Registry(Nil)) -> server.Server(Nil) {
  let text_resource =
    resources.ContextResource(
      resource: resources.Resource(
        uri: "test://static-text",
        name: "Static Text",
        title: None,
        description: Some("Static text resource for the official MCP harness"),
        mime_type: Some("text/plain"),
        size: None,
        annotations: None,
      ),
      read: fn(_context, uri) {
        Ok([
          content.TextResourceContents(
            uri,
            "This is the content of the static text resource.",
            Some("text/plain"),
          ),
        ])
      },
    )
  let binary_resource =
    resources.ContextResource(
      resource: resources.Resource(
        uri: "test://static-binary",
        name: "Static Binary",
        title: None,
        description: Some("Static image resource for the official MCP harness"),
        mime_type: Some("image/png"),
        size: None,
        annotations: None,
      ),
      read: fn(_context, uri) {
        Ok([content.BlobResourceContents(uri, png_1x1, Some("image/png"))])
      },
    )
  let template =
    resources.ContextResourceTemplate(
      template: resources.ResourceTemplate(
        uri_template: "test://template/{id}/data",
        name: "Template Data",
        title: None,
        description: Some("Substituted JSON resource for conformance tests"),
        mime_type: Some("application/json"),
        annotations: None,
      ),
      read: fn(_context, uri) {
        let id = uri |> string.drop_start(string.length("test://template/"))
        let id = case string.split(id, on: "/data") {
          [value, ..] -> value
          _ -> "unknown"
        }
        let text =
          json.object([
            #("id", json.string(id)),
            #("templateTest", json.bool(True)),
            #("data", json.string("Data for ID: " <> id)),
          ])
          |> json.to_string()
        Ok([content.TextResourceContents(uri, text, Some("application/json"))])
      },
    )
  let prompts = [
    conformance_prompt("test_simple_prompt", [], fn(_args) {
      [
        prompts.PromptMessage(
          content.UserRole,
          content.text_content("This is a simple prompt for testing."),
        ),
      ]
    }),
    conformance_prompt(
      "test_prompt_with_arguments",
      [
        prompts.prompt_argument("arg1", True),
        prompts.prompt_argument("arg2", True),
      ],
      fn(args) {
        let first = dict.get(args, "arg1") |> result.unwrap("")
        let second = dict.get(args, "arg2") |> result.unwrap("")
        [
          prompts.PromptMessage(
            content.UserRole,
            content.text_content(
              "Prompt with arguments: arg1='"
              <> first
              <> "', arg2='"
              <> second
              <> "'",
            ),
          ),
        ]
      },
    ),
    conformance_prompt(
      "test_prompt_with_embedded_resource",
      [prompts.prompt_argument("resourceUri", True)],
      fn(args) {
        let uri = dict.get(args, "resourceUri") |> result.unwrap("")
        [
          prompts.PromptMessage(
            content.UserRole,
            content.EmbeddedResourceBlock(content.EmbeddedResource(
              content.TextResourceContents(
                uri,
                "Embedded resource content for testing.",
                Some("text/plain"),
              ),
              None,
            )),
          ),
          prompts.PromptMessage(
            content.UserRole,
            content.text_content("Please process the embedded resource above."),
          ),
        ]
      },
    ),
    conformance_prompt("test_prompt_with_image", [], fn(_args) {
      [
        prompts.PromptMessage(
          content.UserRole,
          content.image_content(png_1x1, "image/png"),
        ),
        prompts.PromptMessage(
          content.UserRole,
          content.text_content("Please analyze the image above."),
        ),
      ]
    }),
    prompts.prompt_with_inputs(
      prompts.Prompt(
        name: "test_input_required_result_prompt",
        title: None,
        description: Some("Prompt that requests additional client context"),
        arguments: [],
      ),
      fn(_context, _arguments, responses) {
        case responses {
          Some(_) ->
            Ok(
              prompts.CompletePrompt(
                prompts.PromptResult(None, [
                  prompts.PromptMessage(
                    content.UserRole,
                    content.text_content("Prompt resumed with client context."),
                  ),
                ]),
              ),
            )
          None ->
            Ok(
              prompts.RequestPromptInput(
                dict.from_list([
                  #(
                    "user_context",
                    elicitation_request(
                      "What context should the prompt use?",
                      "context",
                    ),
                  ),
                ]),
              ),
            )
        }
      },
    ),
  ]
  let completion =
    completion.completion(fn(_context, _reference, argument) {
      Ok(completion.CompletionValues(
        [argument.value <> "-next"],
        Some(1),
        Some(False),
      ))
    })
  server.server_with_services(
    registry,
    [text_resource, binary_resource],
    [template],
    prompts,
    Some(completion),
  )
}

fn conformance_prompt(
  name: String,
  arguments: List(prompts.PromptArgument),
  messages: fn(dict.Dict(String, String)) -> List(prompts.PromptMessage),
) -> prompts.ContextPrompt(Nil) {
  prompts.ContextPrompt(
    prompt: prompts.Prompt(
      name: name,
      title: None,
      description: Some(
        "Prompt fixture for the official MCP conformance harness",
      ),
      arguments: arguments,
    ),
    get: fn(_context, args) { Ok(prompts.PromptResult(None, messages(args))) },
  )
}

fn test_tools() -> List(relay.ContextTool(Nil)) {
  [
    content_tool("test_simple_text", [
      content.text_content("This is a simple text response for testing."),
    ]),
    content_tool("test_image_content", [
      content.image_content(png_1x1, "image/png"),
    ]),
    content_tool("test_audio_content", [
      content.audio_content(wav_silence, "audio/wav"),
    ]),
    content_tool("test_embedded_resource", [
      content.EmbeddedResourceBlock(content.EmbeddedResource(
        content.TextResourceContents(
          "test://embedded-resource",
          "This is an embedded resource content.",
          Some("text/plain"),
        ),
        None,
      )),
    ]),
    content_tool("test_multiple_content_types", [
      content.text_content("Multiple content types test:"),
      content.image_content(png_1x1, "image/png"),
      content.EmbeddedResourceBlock(content.EmbeddedResource(
        content.TextResourceContents(
          "test://mixed-content-resource",
          "{\"test\":\"data\",\"value\":123}",
          Some("application/json"),
        ),
        None,
      )),
    ]),
    progress_tool(),
    content_tool("test_tool_with_logging", [
      content.text_content("Logging fixture completed."),
    ]),
    content_tool("test_logging_tool", [
      content.text_content("No message is emitted without a logLevel."),
    ]),
    json_schema_tool(),
    custom_header_tool(),
    capability_tool(),
    streaming_elicitation_tool(),
    input_required_tool("test_input_required_result_elicitation", fn(responses) {
      case responses {
        Some(_) -> relay.complete_output(Nil)
        None ->
          relay.request_input(
            dict.from_list([
              #("user_name", elicitation_request("What is your name?", "name")),
            ]),
          )
      }
    }),
    input_required_tool("test_input_required_result_sampling", fn(responses) {
      case responses {
        Some(_) -> relay.complete_output(Nil)
        None ->
          relay.request_input(
            dict.from_list([
              #(
                "capital_question",
                sampling_request("What is the capital of France?", 100),
              ),
            ]),
          )
      }
    }),
    input_required_tool("test_input_required_result_list_roots", fn(responses) {
      case responses {
        Some(_) -> relay.complete_output(Nil)
        None ->
          relay.request_input(
            dict.from_list([
              #(
                "client_roots",
                relay.input_request("roots/list", json.object([])),
              ),
            ]),
          )
      }
    }),
    input_required_tool(
      "test_input_required_result_request_state",
      fn(responses) {
        case responses {
          Some(_) -> relay.complete_output(Nil)
          None ->
            relay.request_input(
              dict.from_list([
                #("confirm", elicitation_request("Please confirm", "ok")),
              ]),
            )
        }
      },
    ),
    input_required_tool(
      "test_input_required_result_multiple_inputs",
      fn(responses) {
        case responses {
          Some(_) -> relay.complete_output(Nil)
          None ->
            relay.request_input(
              dict.from_list([
                #(
                  "user_name",
                  elicitation_request("What is your name?", "name"),
                ),
                #("greeting", sampling_request("Generate a greeting", 50)),
                #(
                  "client_roots",
                  relay.input_request("roots/list", json.object([])),
                ),
              ]),
            )
        }
      },
    ),
    input_required_tool("test_input_required_result_multi_round", fn(responses) {
      case responses {
        Some(received) ->
          case response_has_key(received, "step2") {
            True -> relay.complete_output(Nil)
            False ->
              case response_has_key(received, "step1") {
                True ->
                  relay.request_input(
                    dict.from_list([
                      #(
                        "step2",
                        elicitation_request(
                          "Step 2: What is your favorite color?",
                          "color",
                        ),
                      ),
                    ]),
                  )
                False ->
                  relay.request_input(
                    dict.from_list([
                      #(
                        "step1",
                        elicitation_request(
                          "Step 1: What is your name?",
                          "name",
                        ),
                      ),
                    ]),
                  )
              }
          }
        _ ->
          relay.request_input(
            dict.from_list([
              #(
                "step1",
                elicitation_request("Step 1: What is your name?", "name"),
              ),
            ]),
          )
      }
    }),
    input_required_tool(
      "test_input_required_result_tampered_state",
      fn(responses) {
        case responses {
          Some(_) -> relay.complete_output(Nil)
          None ->
            relay.request_input(
              dict.from_list([
                #("confirm", elicitation_request("Please confirm", "ok")),
              ]),
            )
        }
      },
    ),
    input_required_tool(
      "test_input_required_result_capabilities",
      fn(_responses) {
        relay.request_input(
          dict.from_list([
            #("name", elicitation_request("What is your name?", "name")),
            #("sample", sampling_request("What should happen next?", 50)),
          ]),
        )
      },
    ),
    error_tool("test_error_handling"),
  ]
}

fn json_schema_tool() -> relay.ContextTool(Nil) {
  let assert Ok(name) = relay.tool_name("json_schema_2020_12_tool")
  let schema =
    value.Object([
      #("$schema", value.String("https://json-schema.org/draft/2020-12/schema")),
      #("type", value.String("object")),
      #(
        "$defs",
        value.Object([
          #(
            "address",
            value.Object([
              #("$anchor", value.String("addressDef")),
              #("type", value.String("object")),
              #(
                "properties",
                value.Object([
                  #("street", value.Object([#("type", value.String("string"))])),
                  #("city", value.Object([#("type", value.String("string"))])),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      #(
        "properties",
        value.Object([
          #("name", value.Object([#("type", value.String("string"))])),
          #(
            "address",
            value.Object([#("$ref", value.String("#/$defs/address"))]),
          ),
          #(
            "contactMethod",
            value.Object([
              #("type", value.String("string")),
              #(
                "enum",
                value.Array([value.String("phone"), value.String("email")]),
              ),
            ]),
          ),
          #("phone", value.Object([#("type", value.String("string"))])),
          #("email", value.Object([#("type", value.String("string"))])),
        ]),
      ),
      #(
        "allOf",
        value.Array([
          value.Object([
            #(
              "anyOf",
              value.Array([
                value.Object([
                  #("required", value.Array([value.String("phone")])),
                ]),
                value.Object([
                  #("required", value.Array([value.String("email")])),
                ]),
              ]),
            ),
          ]),
        ]),
      ),
      #(
        "if",
        value.Object([
          #(
            "properties",
            value.Object([
              #(
                "contactMethod",
                value.Object([#("const", value.String("phone"))]),
              ),
            ]),
          ),
          #("required", value.Array([value.String("contactMethod")])),
        ]),
      ),
      #(
        "then",
        value.Object([#("required", value.Array([value.String("phone")]))]),
      ),
      #(
        "else",
        value.Object([#("required", value.Array([value.String("email")]))]),
      ),
      #("additionalProperties", value.Bool(False)),
    ])
  let assert Ok(tool) =
    relay.context_tool_with_input_schema(
      name,
      relay.tool_metadata("Preserves the JSON Schema 2020-12 vocabulary"),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      schema,
      fn(_context, _input) { Ok(Nil) },
    )
  tool
}

fn custom_header_tool() -> relay.ContextTool(Nil) {
  let assert Ok(name) = relay.tool_name("test_custom_header")
  let schema =
    value.Object([
      #("type", value.String("object")),
      #(
        "properties",
        value.Object([
          #(
            "payload",
            value.Object([
              #("type", value.String("string")),
              #("x-mcp-header", value.String("payload")),
            ]),
          ),
        ]),
      ),
      #("required", value.Array([value.String("payload")])),
      #("additionalProperties", value.Bool(False)),
    ])
  let assert Ok(tool) =
    relay.context_tool_with_input_schema(
      name,
      relay.tool_metadata("Validates an x-mcp-header parameter"),
      codec.field("payload", codec.string()),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      schema,
      fn(_context, _payload) { Ok(Nil) },
    )
  tool
}

fn input_required_tool(
  name: String,
  handler: fn(Option(value.Value)) -> relay.InputHandlerResult(Nil),
) -> relay.ContextTool(Nil) {
  let assert Ok(tool_name) = relay.tool_name(name)
  let assert Ok(tool) =
    relay.context_tool_with_inputs(
      tool_name,
      relay.tool_metadata("Input continuation fixture for the pinned suite"),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      fn(_context, _input, responses) { Ok(handler(responses)) },
    )
  tool
}

fn capability_tool() -> relay.ContextTool(Nil) {
  let assert Ok(name) = relay.tool_name("test_missing_capability")
  let assert Ok(tool) =
    relay.context_tool(
      name,
      relay.tool_metadata_requiring_client_capabilities(
        "Requires a client sampling capability",
        ["sampling"],
      ),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      fn(_context, _input) { Ok(Nil) },
    )
  tool
}

fn streaming_elicitation_tool() -> relay.ContextTool(Nil) {
  let assert Ok(name) = relay.tool_name("test_streaming_elicitation")
  let assert Ok(tool) =
    relay.context_tool_with_progress(
      name,
      relay.tool_metadata("Reports progress without independent requests"),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      fn(_context, _input, report_progress) {
        report_progress(10)
        process.sleep(20)
        report_progress(20)
        Ok(Nil)
      },
    )
  tool
}

fn elicitation_request(message: String, field: String) -> relay.InputRequest {
  let field_type = case field == "ok" {
    True -> "boolean"
    False -> "string"
  }
  relay.input_request(
    "elicitation/create",
    json.object([
      #("message", json.string(message)),
      #(
        "requestedSchema",
        json.object([
          #("type", json.string("object")),
          #(
            "properties",
            json.object([
              #(field, json.object([#("type", json.string(field_type))])),
            ]),
          ),
          #("required", json.array([json.string(field)], fn(item) { item })),
        ]),
      ),
    ]),
  )
}

fn sampling_request(message: String, max_tokens: Int) -> relay.InputRequest {
  relay.input_request(
    "sampling/createMessage",
    json.object([
      #(
        "messages",
        json.array(
          [
            json.object([
              #("role", json.string("user")),
              #(
                "content",
                json.object([
                  #("type", json.string("text")),
                  #("text", json.string(message)),
                ]),
              ),
            ]),
          ],
          fn(item) { item },
        ),
      ),
      #("maxTokens", json.int(max_tokens)),
    ]),
  )
}

fn response_has_key(responses: value.Value, key: String) -> Bool {
  case responses {
    value.Object(fields) ->
      list.any(fields, fn(field) {
        case field {
          #(name, _) -> name == key
        }
      })
    _ -> False
  }
}

fn content_tool(
  name: String,
  blocks: List(content.ContentBlock),
) -> relay.ContextTool(Nil) {
  let assert Ok(tool_name) = relay.tool_name(name)
  let assert Ok(tool) =
    relay.context_tool_with_content(
      tool_name,
      relay.tool_metadata("Fixture used by the pinned MCP conformance suite"),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      fn(_context, _input) { Ok(#(None, blocks)) },
    )
  tool
}

fn error_tool(name: String) -> relay.ContextTool(Nil) {
  let assert Ok(tool_name) = relay.tool_name(name)
  let assert Ok(tool) =
    relay.context_tool(
      tool_name,
      relay.tool_metadata("Fixture used by the pinned MCP conformance suite"),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      fn(_context, _input) { Error(Nil) },
    )
  tool
}

fn progress_tool() -> relay.ContextTool(Nil) {
  let assert Ok(name) = relay.tool_name("test_tool_with_progress")
  let assert Ok(tool) =
    relay.context_tool_with_progress(
      name,
      relay.tool_metadata(
        "Reports ordered progress for the pinned conformance suite",
      ),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      codec.object(codec.empty()),
      fn(_context, _input, report_progress) {
        report_progress(25)
        process.sleep(25)
        report_progress(50)
        process.sleep(25)
        report_progress(75)
        process.sleep(25)
        report_progress(100)
        Ok(Nil)
      },
    )
  tool
}
