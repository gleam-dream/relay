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
import relay/completion
import relay/content
import relay/prompts
import relay/resources
import relay/server
import relay/tool
import relay/transport/http

const png_1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p2sAAAAASUVORK5CYII="

const wav_silence = "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQAAAAA="

pub fn main() -> Nil {
  let assert Ok(registry) = tool.registry(test_tools())
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(conformance_server(registry), fn() { Nil })
    |> http.with_options(options)
    |> http.with_policy(http.local_http_policy(options.host))
    |> http.start()
  }
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

fn conformance_server(registry: tool.Registry(Nil)) -> server.Server(Nil) {
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
  server.server(registry)
  |> server.with_resources([text_resource, binary_resource])
  |> server.with_resource_templates([template])
  |> server.with_prompts(prompts)
  |> server.with_completion(Some(completion))
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

fn test_tools() -> List(tool.ContextTool(Nil)) {
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
        Some(_) -> tool.Complete(Nil, [])
        None ->
          tool.NeedsInput(
            dict.from_list([
              #("user_name", elicitation_request("What is your name?", "name")),
            ]),
          )
      }
    }),
    input_required_tool("test_input_required_result_sampling", fn(responses) {
      case responses {
        Some(_) -> tool.Complete(Nil, [])
        None ->
          tool.NeedsInput(
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
        Some(_) -> tool.Complete(Nil, [])
        None ->
          tool.NeedsInput(
            dict.from_list([
              #(
                "client_roots",
                tool.InputRequest("roots/list", json.object([])),
              ),
            ]),
          )
      }
    }),
    input_required_tool(
      "test_input_required_result_request_state",
      fn(responses) {
        case responses {
          Some(_) -> tool.Complete(Nil, [])
          None ->
            tool.NeedsInput(
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
          Some(_) -> tool.Complete(Nil, [])
          None ->
            tool.NeedsInput(
              dict.from_list([
                #(
                  "user_name",
                  elicitation_request("What is your name?", "name"),
                ),
                #("greeting", sampling_request("Generate a greeting", 50)),
                #(
                  "client_roots",
                  tool.InputRequest("roots/list", json.object([])),
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
            True -> tool.Complete(Nil, [])
            False ->
              case response_has_key(received, "step1") {
                True ->
                  tool.NeedsInput(
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
                  tool.NeedsInput(
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
          tool.NeedsInput(
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
          Some(_) -> tool.Complete(Nil, [])
          None ->
            tool.NeedsInput(
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
        tool.NeedsInput(
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

fn json_schema_tool() -> tool.ContextTool(Nil) {
  let assert Ok(name) = tool.tool_name("json_schema_2020_12_tool")
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
  let assert Ok(tool) = case
    tool.definition(
      name,
      codec.object(codec.empty()),
      codec.object(codec.empty()),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Preserves the JSON Schema 2020-12 vocabulary"),
          ),
        )
      case tool.with_input_schema_override(definition, schema) {
        Ok(definition) ->
          Ok(
            tool.handle_with_error_renderer(
              definition,
              fn(_input) { Ok(Nil) },
              fn(application_error) {
                case
                  codec.encode_json(
                    codec.object(codec.empty()),
                    application_error,
                  )
                {
                  Ok(text) -> text
                  Error(_) -> "Tool execution failed."
                }
              },
            ),
          )
        Error(error) -> Error(error)
      }
    }
    Error(error) -> Error(error)
  }
  tool
}

fn custom_header_tool() -> tool.ContextTool(Nil) {
  let assert Ok(name) = tool.tool_name("test_custom_header")
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
  let assert Ok(tool) = case
    tool.definition(
      name,
      codec.field("payload", codec.string()),
      codec.object(codec.empty()),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Validates an x-mcp-header parameter"),
          ),
        )
      case tool.with_input_schema_override(definition, schema) {
        Ok(definition) ->
          Ok(
            tool.handle_with_error_renderer(
              definition,
              fn(_payload) { Ok(Nil) },
              fn(application_error) {
                case
                  codec.encode_json(
                    codec.object(codec.empty()),
                    application_error,
                  )
                {
                  Ok(text) -> text
                  Error(_) -> "Tool execution failed."
                }
              },
            ),
          )
        Error(error) -> Error(error)
      }
    }
    Error(error) -> Error(error)
  }
  tool
}

fn input_required_tool(
  name: String,
  handler: fn(Option(value.Value)) -> tool.HandlerResult(Nil),
) -> tool.ContextTool(Nil) {
  let assert Ok(tool_name) = tool.tool_name(name)
  let assert Ok(tool) = case
    tool.definition(
      tool_name,
      codec.object(codec.empty()),
      codec.object(codec.empty()),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Input continuation fixture for the pinned suite"),
          ),
        )
      Ok(
        tool.handle_advanced(definition, fn(call, _input) {
          let tool.HandlerCallContext(_application, responses, _report_progress) =
            call
          Ok(handler(responses))
        }),
      )
    }
    Error(error) -> Error(error)
  }
  tool
}

fn capability_tool() -> tool.ContextTool(Nil) {
  let assert Ok(name) = tool.tool_name("test_missing_capability")
  let assert Ok(tool) = case
    tool.definition(
      name,
      codec.object(codec.empty()),
      codec.object(codec.empty()),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.ToolMetadata(
              ..tool.empty_metadata(),
              description: Some("Requires a client sampling capability"),
            ),
            required_client_capabilities: ["sampling"],
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_input) { Ok(Nil) },
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
  tool
}

fn streaming_elicitation_tool() -> tool.ContextTool(Nil) {
  let assert Ok(name) = tool.tool_name("test_streaming_elicitation")
  let assert Ok(tool) = case
    tool.definition(
      name,
      codec.object(codec.empty()),
      codec.object(codec.empty()),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Reports progress without independent requests"),
          ),
        )
      Ok({
        let user_handler = fn(_context, _input, report_progress) {
          report_progress(10)
          process.sleep(20)
          report_progress(20)
          Ok(Nil)
        }
        let advanced_handler = fn(call, typed_input) {
          let tool.HandlerCallContext(
            application,
            _input_responses,
            report_progress,
          ) = call
          user_handler(application, typed_input, report_progress)
          |> result.map(fn(output) { tool.Complete(output, []) })
        }
        tool.handle_advanced_with_error_renderer(
          definition,
          advanced_handler,
          fn(application_error) {
            case
              codec.encode_json(codec.object(codec.empty()), application_error)
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        )
      })
    }
    Error(error) -> Error(error)
  }
  tool
}

fn elicitation_request(message: String, field: String) -> tool.InputRequest {
  let field_type = case field == "ok" {
    True -> "boolean"
    False -> "string"
  }
  tool.InputRequest(
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

fn sampling_request(message: String, max_tokens: Int) -> tool.InputRequest {
  tool.InputRequest(
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
) -> tool.ContextTool(Nil) {
  let assert Ok(tool_name) = tool.tool_name(name)
  let assert Ok(tool) = case
    tool.definition(
      tool_name,
      codec.object(codec.empty()),
      codec.object(codec.empty()),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some(
              "Fixture used by the pinned MCP conformance suite",
            ),
          ),
        )
      Ok({
        let user_handler = fn(_context, _input) { Ok(#(None, blocks)) }
        let advanced_handler = fn(call, typed_input) {
          let tool.HandlerCallContext(
            application,
            _input_responses,
            _report_progress,
          ) = call
          case user_handler(application, typed_input) {
            Ok(#(Some(output), blocks)) -> Ok(tool.Complete(output, blocks))
            Ok(#(None, blocks)) -> Ok(tool.Content(blocks))
          }
        }
        tool.handle_advanced_with_error_renderer(
          definition,
          advanced_handler,
          fn(application_error) {
            case
              codec.encode_json(codec.object(codec.empty()), application_error)
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        )
      })
    }
    Error(error) -> Error(error)
  }
  tool
}

fn error_tool(name: String) -> tool.ContextTool(Nil) {
  let assert Ok(tool_name) = tool.tool_name(name)
  let assert Ok(tool) = case
    tool.definition(
      tool_name,
      codec.object(codec.empty()),
      codec.object(codec.empty()),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some(
              "Fixture used by the pinned MCP conformance suite",
            ),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_input) { Error(Nil) },
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
  tool
}

fn progress_tool() -> tool.ContextTool(Nil) {
  let assert Ok(name) = tool.tool_name("test_tool_with_progress")
  let assert Ok(tool) = case
    tool.definition(
      name,
      codec.object(codec.empty()),
      codec.object(codec.empty()),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some(
              "Reports ordered progress for the pinned conformance suite",
            ),
          ),
        )
      Ok({
        let user_handler = fn(_context, _input, report_progress) {
          report_progress(25)
          process.sleep(25)
          report_progress(50)
          process.sleep(25)
          report_progress(75)
          process.sleep(25)
          report_progress(100)
          Ok(Nil)
        }
        let advanced_handler = fn(call, typed_input) {
          let tool.HandlerCallContext(
            application,
            _input_responses,
            report_progress,
          ) = call
          user_handler(application, typed_input, report_progress)
          |> result.map(fn(output) { tool.Complete(output, []) })
        }
        tool.handle_advanced_with_error_renderer(
          definition,
          advanced_handler,
          fn(application_error) {
            case
              codec.encode_json(codec.object(codec.empty()), application_error)
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        )
      })
    }
    Error(error) -> Error(error)
  }
  tool
}
