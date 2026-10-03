//// Fixture server for the official MCP conformance harness. It lives in
//// `dev/`, so it is not published with the package.
////
//// `main` starts a Streamable HTTP listener on `127.0.0.1` with the
//// harness's test tools, resources and prompts, prints
//// `RELAY_CONFORMANCE_URL=...`, and runs until stopped.
//// `scripts/conformance/run-server-suite.sh` runs it with
//// `gleam run -m relay_conformance_server`.

import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/value.{type Value}
import relay/completion
import relay/content
import relay/http
import relay/prompts
import relay/resources
import relay/server
import relay/tool

const png_1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p2sAAAAASUVORK5CYII="

const wav_silence = "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQAAAAA="

fn bytes(base64: String) -> BitArray {
  let assert Ok(decoded) = bit_array.base64_decode(base64)
  decoded
}

pub fn main() -> Nil {
  let assert Ok(listener) = http.start(http.new(conformance_server()))
  io.println(
    "RELAY_CONFORMANCE_URL=http://127.0.0.1:"
    <> int.to_string(http.port(listener))
    <> "/mcp",
  )
  keep_alive()
}

fn keep_alive() -> Nil {
  process.sleep(60_000)
  keep_alive()
}

fn conformance_server() -> server.Server(Nil) {
  let text_resource =
    resources.static("test://static-text", "Static Text", fn(_context, uri) {
      Ok([
        content.TextResourceContents(
          uri,
          "This is the content of the static text resource.",
          Some("text/plain"),
          [],
        ),
      ])
    })
    |> resources.with_description(
      "Static text resource for the official MCP harness",
    )
    |> resources.with_mime_type("text/plain")
  let binary_resource =
    resources.static("test://static-binary", "Static Binary", fn(_context, uri) {
      Ok([
        content.BlobResourceContents(uri, bytes(png_1x1), Some("image/png"), []),
      ])
    })
    |> resources.with_description(
      "Static image resource for the official MCP harness",
    )
    |> resources.with_mime_type("image/png")
  let template =
    resources.template(
      "test://template/{id}/data",
      "Template Data",
      fn(_context, uri) {
        let id = uri |> string.drop_start(string.length("test://template/"))
        let id = case string.split(id, on: "/data") {
          [found, ..] -> found
          _ -> "unknown"
        }
        let text =
          json.object([
            #("id", json.string(id)),
            #("templateTest", json.bool(True)),
            #("data", json.string("Data for ID: " <> id)),
          ])
          |> json.to_string()
        Ok([
          content.TextResourceContents(uri, text, Some("application/json"), []),
        ])
      },
    )
    |> resources.with_description(
      "Substituted JSON resource for conformance tests",
    )
    |> resources.with_mime_type("application/json")
  let fixtures = [
    fixture_prompt("test_simple_prompt", [], fn(_args) {
      [prompts.user_message("This is a simple prompt for testing.")]
    }),
    fixture_prompt(
      "test_prompt_with_arguments",
      [prompts.required_argument("arg1"), prompts.required_argument("arg2")],
      fn(args) {
        let first = dict.get(args, "arg1") |> result.unwrap("")
        let second = dict.get(args, "arg2") |> result.unwrap("")
        [
          prompts.user_message(
            "Prompt with arguments: arg1='"
            <> first
            <> "', arg2='"
            <> second
            <> "'",
          ),
        ]
      },
    ),
    fixture_prompt(
      "test_prompt_with_embedded_resource",
      [prompts.required_argument("resourceUri")],
      fn(args) {
        let uri = dict.get(args, "resourceUri") |> result.unwrap("")
        [
          prompts.PromptMessage(
            content.UserRole,
            content.embedded(
              content.TextResourceContents(
                uri,
                "Embedded resource content for testing.",
                Some("text/plain"),
                [],
              ),
            ),
          ),
          prompts.user_message("Please process the embedded resource above."),
        ]
      },
    ),
    fixture_prompt("test_prompt_with_image", [], fn(_args) {
      [
        prompts.PromptMessage(
          content.UserRole,
          content.image(bytes(png_1x1), "image/png"),
        ),
        prompts.user_message("Please analyze the image above."),
      ]
    }),
    prompts.prompt_call("test_input_required_result_prompt", [], fn(call, _) {
      case dict.is_empty(tool.input_responses(call)) {
        False ->
          Ok(
            tool.complete(
              prompts.PromptResult(
                None,
                [prompts.user_message("Prompt resumed with client context.")],
                [],
              ),
            ),
          )
        True ->
          Ok(
            tool.request_input(
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
    })
      |> prompts.with_description(
        "Prompt that requests additional client context",
      ),
  ]
  let completer =
    completion.completion(fn(_context, request: completion.Request) {
      Ok(completion.Values([request.value <> "-next"], Some(1), Some(False)))
    })
  server.new(test_tools())
  |> server.with_resources([text_resource, binary_resource, template])
  |> server.with_prompts(fixtures)
  |> server.with_completion(completer)
}

fn fixture_prompt(
  name: String,
  arguments: List(prompts.PromptArgument),
  messages: fn(dict.Dict(String, String)) -> List(prompts.PromptMessage),
) -> prompts.Prompt(Nil) {
  prompts.prompt(name, arguments, fn(_context, args) {
    Ok(prompts.PromptResult(None, messages(args), []))
  })
  |> prompts.with_description(
    "Prompt fixture for the official MCP conformance harness",
  )
}

fn no_input() -> codec.Codec(Nil) {
  codec.success(Nil)
}

fn test_tools() -> List(tool.Tool(Nil)) {
  [
    content_tool("test_simple_text", [
      content.text("This is a simple text response for testing."),
    ]),
    content_tool("test_image_content", [
      content.image(bytes(png_1x1), "image/png"),
    ]),
    content_tool("test_audio_content", [
      content.audio(bytes(wav_silence), "audio/wav"),
    ]),
    content_tool("test_embedded_resource", [
      content.embedded(
        content.TextResourceContents(
          "test://embedded-resource",
          "This is an embedded resource content.",
          Some("text/plain"),
          [],
        ),
      ),
    ]),
    content_tool("test_multiple_content_types", [
      content.text("Multiple content types test:"),
      content.image(bytes(png_1x1), "image/png"),
      content.embedded(
        content.TextResourceContents(
          "test://mixed-content-resource",
          "{\"test\":\"data\",\"value\":123}",
          Some("application/json"),
          [],
        ),
      ),
    ]),
    progress_tool("test_tool_with_progress", [25.0, 50.0, 75.0, 100.0]),
    content_tool("test_tool_with_logging", [
      content.text("Logging fixture completed."),
    ]),
    content_tool("test_logging_tool", [
      content.text("No message is emitted without a logLevel."),
    ]),
    json_schema_tool(),
    custom_header_tool(),
    tool.define("test_missing_capability", no_input(), no_input())
      |> tool.with_description("Requires a client sampling capability")
      |> tool.with_required_client_capabilities(["sampling"])
      |> tool.handle(fn(_) { Ok(Nil) }),
    progress_tool("test_streaming_elicitation", [10.0, 20.0]),
    input_required_tool("test_input_required_result_elicitation", fn(responses) {
      case dict.is_empty(responses) {
        False -> Ok(tool.complete(Nil))
        True ->
          Ok(
            tool.request_input(
              dict.from_list([
                #(
                  "user_name",
                  elicitation_request("What is your name?", "name"),
                ),
              ]),
            ),
          )
      }
    }),
    input_required_tool("test_input_required_result_sampling", fn(responses) {
      case dict.is_empty(responses) {
        False -> Ok(tool.complete(Nil))
        True ->
          Ok(
            tool.request_input(
              dict.from_list([
                #(
                  "capital_question",
                  sampling_request("What is the capital of France?", 100),
                ),
              ]),
            ),
          )
      }
    }),
    input_required_tool("test_input_required_result_list_roots", fn(responses) {
      case dict.is_empty(responses) {
        False -> Ok(tool.complete(Nil))
        True ->
          Ok(
            tool.request_input(
              dict.from_list([
                #(
                  "client_roots",
                  tool.InputRequest(tool.Roots, value.Object([])),
                ),
              ]),
            ),
          )
      }
    }),
    confirm_tool("test_input_required_result_request_state"),
    input_required_tool(
      "test_input_required_result_multiple_inputs",
      fn(responses) {
        case dict.is_empty(responses) {
          False -> Ok(tool.complete(Nil))
          True ->
            Ok(
              tool.request_input(
                dict.from_list([
                  #(
                    "user_name",
                    elicitation_request("What is your name?", "name"),
                  ),
                  #("greeting", sampling_request("Generate a greeting", 50)),
                  #(
                    "client_roots",
                    tool.InputRequest(tool.Roots, value.Object([])),
                  ),
                ]),
              ),
            )
        }
      },
    ),
    input_required_tool("test_input_required_result_multi_round", fn(responses) {
      case dict.has_key(responses, "step2"), dict.has_key(responses, "step1") {
        True, _ -> Ok(tool.complete(Nil))
        False, True ->
          Ok(
            tool.request_input(
              dict.from_list([
                #(
                  "step2",
                  elicitation_request(
                    "Step 2: What is your favorite color?",
                    "color",
                  ),
                ),
              ]),
            ),
          )
        False, False ->
          Ok(
            tool.request_input(
              dict.from_list([
                #(
                  "step1",
                  elicitation_request("Step 1: What is your name?", "name"),
                ),
              ]),
            ),
          )
      }
    }),
    confirm_tool("test_input_required_result_tampered_state"),
    input_required_tool("test_input_required_result_capabilities", fn(_) {
      Ok(
        tool.request_input(
          dict.from_list([
            #("name", elicitation_request("What is your name?", "name")),
            #("sample", sampling_request("What should happen next?", 50)),
          ]),
        ),
      )
    }),
    tool.define("test_error_handling", no_input(), no_input())
      |> tool.with_description(
        "Fixture used by the pinned MCP conformance suite",
      )
      |> tool.handle(fn(_) { Error(Nil) }),
  ]
}

fn content_tool(
  name: String,
  blocks: List(content.ContentBlock),
) -> tool.Tool(Nil) {
  tool.define_content(name, no_input())
  |> tool.with_description("Fixture used by the pinned MCP conformance suite")
  |> tool.handle(fn(_) { Ok(blocks) })
}

fn progress_tool(name: String, steps: List(Float)) -> tool.Tool(Nil) {
  tool.define(name, no_input(), no_input())
  |> tool.with_description(
    "Reports ordered progress for the pinned conformance suite",
  )
  |> tool.handle_call(fn(call, _) {
    list.each(steps, fn(step) {
      tool.report_progress(call, step, Some(100.0), None)
      process.sleep(20)
    })
    Ok(tool.complete(Nil))
  })
}

fn input_required_tool(
  name: String,
  handler: fn(dict.Dict(String, Value)) ->
    Result(tool.Reply(Nil), tool.ToolError),
) -> tool.Tool(Nil) {
  tool.define(name, no_input(), no_input())
  |> tool.with_description("Input continuation fixture for the pinned suite")
  |> tool.handle_call(fn(call, _) { handler(tool.input_responses(call)) })
}

fn confirm_tool(name: String) -> tool.Tool(Nil) {
  input_required_tool(name, fn(responses) {
    case dict.is_empty(responses) {
      False -> Ok(tool.complete(Nil))
      True ->
        Ok(
          tool.request_input(
            dict.from_list([
              #("confirm", elicitation_request("Please confirm", "ok")),
            ]),
          ),
        )
    }
  })
}

fn custom_header_tool() -> tool.Tool(Nil) {
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
  let input = {
    use payload <- codec.field("payload", codec.string(), get: fn(payload) {
      payload
    })
    codec.success(payload)
  }
  tool.define("test_custom_header", input, no_input())
  |> tool.with_description("Validates an x-mcp-header parameter")
  |> tool.with_input_schema(schema)
  |> tool.handle(fn(_) { Ok(Nil) })
}

fn object(members: List(#(String, Value))) -> Value {
  value.Object(members)
}

fn elicitation_request(message: String, field: String) -> tool.InputRequest {
  let field_type = case field == "ok" {
    True -> "boolean"
    False -> "string"
  }
  tool.InputRequest(
    tool.Elicitation,
    object([
      #("message", value.String(message)),
      #(
        "requestedSchema",
        object([
          #("type", value.String("object")),
          #(
            "properties",
            object([#(field, object([#("type", value.String(field_type))]))]),
          ),
          #("required", value.Array([value.String(field)])),
        ]),
      ),
    ]),
  )
}

fn sampling_request(message: String, max_tokens: Int) -> tool.InputRequest {
  let assert Ok(max_tokens) =
    value.parse(int.to_string(max_tokens), value.default_limits())
  tool.InputRequest(
    tool.Sampling,
    object([
      #(
        "messages",
        value.Array([
          object([
            #("role", value.String("user")),
            #(
              "content",
              object([
                #("type", value.String("text")),
                #("text", value.String(message)),
              ]),
            ),
          ]),
        ]),
      ),
      #("maxTokens", max_tokens),
    ]),
  )
}

fn json_schema_tool() -> tool.Tool(Nil) {
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
  tool.define("json_schema_2020_12_tool", no_input(), no_input())
  |> tool.with_description("Preserves the JSON Schema 2020-12 vocabulary")
  |> tool.with_input_schema(schema)
  |> tool.handle(fn(_) { Ok(Nil) })
}
