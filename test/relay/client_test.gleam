import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode as dyn_decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/codec
import json/blueprint/number
import relay/client
import relay/completion
import relay/content
import relay/prompts
import relay/resources
import relay/server
import relay/subscriptions
import relay/tool
import relay/transport/http

@external(erlang, "relay_http_ffi", "disconnect_after_first_sse_event")
fn disconnect_after_first_sse_event(
  port: Int,
  method: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Int, String)

pub fn main() -> Nil {
  gleeunit.main()
}

fn open_http_client(
  host: String,
  port: Int,
  path: String,
  secure: Bool,
  timeout_ms: Int,
  max_response_bytes: Int,
  ca_cert_file: Option(String),
) -> Result(client.Client, client.ClientError) {
  let scheme = case secure {
    True -> "https://"
    False -> "http://"
  }
  let url = scheme <> host <> ":" <> int.to_string(port) <> path
  case client.http_config(url) {
    Error(error) -> Error(error)
    Ok(config) -> {
      let config =
        config
        |> client.with_timeout(timeout_ms)
        |> client.with_max_response_bytes(max_response_bytes)
      let config = case ca_cert_file {
        None -> config
        Some(file) -> client.with_ca_cert_file(config, file)
      }
      client.connect_http(config)
    }
  }
}

fn local_server() -> server.Server(Nil) {
  let assert Ok(name) = tool.tool_name("echo")
  let assert Ok(echo_tool) = case
    tool.definition(name, codec.field("name", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(value) { Ok("hello " <> value) },
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
  let assert Ok(fail_name) = tool.tool_name("fail")
  let assert Ok(fail_tool) = case
    tool.definition(
      fail_name,
      codec.field("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_value) {
            Error(#("not_found", "The requested record is unavailable."))
          },
          fn(application_error) {
            case codec.encode_json(fail_error_codec(), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }
  let assert Ok(error_encoding_name) = tool.tool_name("error_encoding")
  let assert Ok(error_codec) = codec.integer_between(0, 10)
  let assert Ok(error_encoding_tool) = case
    tool.definition(
      error_encoding_name,
      codec.field("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_value) { Error(11) },
          fn(application_error) {
            case codec.encode_json(error_codec, application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }
  let assert Ok(say_name) = tool.tool_name("say")
  let assert Ok(say_definition) =
    tool.content_definition(say_name, codec.field("name", codec.string()))
  let say_tool =
    tool.handle_content(say_definition, fn(_value) {
      Ok([content.text_content("content-only reply")])
    })
  let assert Ok(rich_name) = tool.tool_name("rich")
  let rich_blocks = [
    content.ImageContent("aGVsbG8=", "image/png", Some(rich_annotations())),
    content.AudioContent("AQID", "audio/wav", None),
    content.ResourceLinkBlock(content.ResourceLink(
      uri: "https://example.test/resource",
      name: "linked",
      title: None,
      description: None,
      mime_type: None,
      size: None,
      annotations: None,
    )),
    content.EmbeddedResourceBlock(content.EmbeddedResource(
      content.TextResourceContents(
        uri: "file:///embedded",
        text: "embedded text",
        mime_type: Some("text/plain"),
      ),
      None,
    )),
  ]
  let assert Ok(rich_tool) = case
    tool.definition(
      rich_name,
      codec.field("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok({
        let user_handler = fn(_context, _value) { Ok(#(None, rich_blocks)) }
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
            case codec.encode_json(codec.string(), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        )
      })
    }
    Error(error) -> Error(error)
  }
  let assert Ok(exact_name) = tool.tool_name("exact")
  let assert Ok(exact_tool) = case
    tool.definition(
      exact_name,
      codec.field("value", codec.number()),
      codec.number(),
    )
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(value) { Ok(value) },
          fn(application_error) {
            case codec.encode_json(codec.string(), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }
  let assert Ok(slow_name) = tool.tool_name("slow")
  let assert Ok(slow_tool) = case
    tool.definition(
      slow_name,
      codec.field("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_value) {
            process.sleep(1500)
            Ok("finished")
          },
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
  let assert Ok(registry) =
    tool.registry([
      echo_tool,
      fail_tool,
      error_encoding_tool,
      say_tool,
      rich_tool,
      exact_tool,
      slow_tool,
      ..many_named_tools(101)
    ])
  let readable =
    resources.resource("memory://client-note", "client note", fn(_context, uri) {
      Ok([
        content.TextResourceContents(uri, "client resource", Some("text/plain")),
      ])
    })
  let template =
    resources.resource_template(
      "memory://client/{name}",
      "client resource template",
      fn(_context, uri) {
        Ok([
          content.TextResourceContents(
            uri,
            "template resource",
            Some("text/plain"),
          ),
        ])
      },
    )
  let prompt =
    prompts.prompt("client-prompt", [], fn(_context, _arguments) {
      Ok(
        prompts.PromptResult(Some("client prompt"), [
          prompts.PromptMessage(
            content.UserRole,
            content.text_content("greeting"),
          ),
        ]),
      )
    })
  let completion =
    completion.completion(fn(_context, _reference, argument) {
      Ok(completion.CompletionValues(
        [argument.value <> "-next"],
        Some(1),
        Some(False),
      ))
    })
  server.server(registry)
  |> server.with_resources([readable])
  |> server.with_resource_templates([template])
  |> server.with_prompts([prompt])
  |> server.with_completion(Some(completion))
}

fn rich_annotations() -> content.Annotations {
  content.Annotations(
    audience: Some([content.UserRole, content.AssistantRole]),
    priority: Some(0.75),
    title: Some("preview"),
    description: Some("image preview"),
  )
}

fn many_named_tools(count: Int) -> List(tool.ContextTool(Nil)) {
  case count <= 0 {
    True -> []
    False -> {
      let assert Ok(name) = tool.tool_name("list-" <> int.to_string(count))
      let assert Ok(listed_tool) = case
        tool.definition(
          name,
          codec.field("name", codec.string()),
          codec.string(),
        )
      {
        Ok(definition) -> {
          let definition = tool.with_metadata(definition, tool.empty_metadata())
          Ok(
            tool.handle_with_error_renderer(
              definition,
              fn(value) { Ok(value) },
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
        }
        Error(error) -> Error(error)
      }
      [listed_tool, ..many_named_tools(count - 1)]
    }
  }
}

fn fail_error_codec() -> codec.Codec(#(String, String)) {
  let assert Ok(fields) =
    codec.combine(
      codec.required("code", codec.string()),
      codec.required("message", codec.string()),
    )
  codec.object(fields)
}

pub fn http_client_uses_explicit_ca_for_tls_test() {
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(local_server(), fn() { Nil })
    |> http.with_options(options)
    |> http.with_policy(http.local_http_policy(options.host))
    |> http.with_tls(
      "test/fixtures/tls/localhost.crt",
      "test/fixtures/tls/localhost.key",
    )
    |> http.start()
  }
  let untrusted_connection =
    open_http_client(
      "localhost",
      http.http_server_port(listener),
      "/",
      True,
      3000,
      65_536,
      None,
    )
  case untrusted_connection {
    Ok(peer) -> client.close(peer)
    Error(_) -> Nil
  }
  let trusted_result =
    open_http_client(
      "localhost",
      http.http_server_port(listener),
      "/",
      True,
      3000,
      65_536,
      Some("test/fixtures/tls/root-ca.crt"),
    )
  let discovery = case trusted_result {
    Error(client.InvalidClientConfiguration) ->
      Error("explicit CA connection had invalid configuration")
    Error(client.ConnectionFailed(reason)) ->
      Error("explicit CA connection failed: " <> reason)
    Ok(peer) -> {
      let discovery = client.discover(peer)
      client.close(peer)
      discovery
    }
  }
  http.stop_http_server(listener)
  case untrusted_connection {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
  case discovery {
    Error(reason) -> should.equal(reason, "expected success")
    Ok(result) ->
      should.be_true(list.contains(result.supported_versions, "2026-07-28"))
  }
}

pub fn stdio_client_uses_typed_request_surface_test() {
  let assert Ok(peer) =
    client.connect_stdio(client.StdioConfig(
      executable: "./test/fixtures/stdio/relay-stdio",
      args: [],
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))
  let discovery = client.discover(peer)
  let assert Ok(greet_name) = tool.tool_name("greet")
  let call = case
    tool.definition(
      greet_name,
      codec.field("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> client.call_definition(peer, definition, "stdio")
    Error(_) -> client.ProtocolFailure("invalid local tool definition")
  }
  client.close(peer)
  case discovery {
    Error(_) -> should.fail()
    Ok(result) ->
      should.be_true(list.contains(result.supported_versions, "2026-07-28"))
  }
  should.equal(
    call,
    client.StructuredSuccess("child-server: hello stdio", [
      content.text_content("child-server: hello stdio"),
    ]),
  )
}

pub fn stdio_client_skips_notifications_and_rejects_unrelated_responses_test() {
  let assert Ok(peer) =
    client.connect_stdio(client.StdioConfig(
      executable: "/bin/sh",
      args: [
        "-c",
        "IFS= read -r request; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///ignored\"}}'; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":\"wrong-id\",\"result\":{}}'",
      ],
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))
  let discovery = client.discover(peer)
  client.close(peer)
  should.equal(discovery, Error("stdio response ID did not match request"))
}

pub fn stdio_client_subscriptions_retain_ack_and_notifications_test() {
  let assert Ok(peer) =
    client.connect_stdio(client.StdioConfig(
      executable: "./test/fixtures/stdio/subscription-peer",
      args: [],
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))
  let requested =
    subscriptions.SubscriptionFilter(
      tools_list_changed: True,
      resources_list_changed: False,
      prompts_list_changed: False,
      resource_subscriptions: [],
    )
  let outcome = case client.listen(peer, requested) {
    Error(reason) -> Error(reason)
    Ok(subscription) -> {
      let acknowledged = client.acknowledged_notifications(subscription)
      let notification = client.next_notification(subscription, 1000)
      client.close_subscription(subscription)
      Ok(#(acknowledged, notification))
    }
  }
  client.close(peer)
  case outcome {
    Error(_reason) -> should.fail()
    Ok(#(acknowledged, notification)) -> {
      should.be_true(acknowledged.tools_list_changed)
      should.equal(notification, Ok(client.ToolsListChanged))
    }
  }
}

pub fn stdio_client_preserves_frozen_declaration_fields_test() {
  let assert Ok(peer) =
    client.connect_stdio(client.StdioConfig(
      executable: "./test/fixtures/stdio/declaration-peer",
      args: [],
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))
  let assert Ok([tool]) = client.list_tools(peer)
  let assert Ok([resource]) = client.list_resources(peer)
  let assert Ok([template]) = client.list_resource_templates(peer)
  let assert Ok([prompt]) = client.list_prompts(peer)
  client.close(peer)

  should.equal(tool.name, "annotated")
  case tool.annotations, tool.icons {
    Some(tool.ToolAnnotations(
      title,
      read_only,
      destructive,
      idempotent,
      open_world,
    )),
      Some([
        client.Icon(src, Some(mime_type), Some([size]), Some(client.IconDark)),
      ])
    -> {
      should.equal(title, Some("Safe lookup"))
      should.equal(read_only, Some(True))
      should.equal(destructive, Some(False))
      should.equal(idempotent, Some(True))
      should.equal(open_world, Some(False))
      should.equal(src, "https://example.test/tool.svg")
      should.equal(mime_type, "image/svg+xml")
      should.equal(size, "any")
    }
    _, _ -> should.fail()
  }
  case resource.annotations, resource.icons {
    Some(client.Annotations(audience, priority, last_modified)),
      Some([client.Icon(_, _, Some(["48x48"]), Some(client.IconLight))])
    -> {
      should.equal(audience, Some([content.UserRole]))
      should.equal(priority, Some(0.5))
      should.equal(last_modified, Some("2026-09-22T00:00:00Z"))
    }
    _, _ -> should.fail()
  }
  should.equal(template.uri_template, "memory://annotated/{name}")
  should.be_true(template.icons != None)
  should.equal(prompt.arguments, [])
  should.be_true(prompt.icons != None)
}

pub fn stdio_subscription_is_ordered_cancellable_and_timeout_safe_test() {
  let assert Ok(peer) =
    client.connect_stdio(client.StdioConfig(
      executable: "./test/fixtures/stdio/subscription-lifecycle-peer",
      args: [],
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))
  let requested =
    subscriptions.SubscriptionFilter(
      tools_list_changed: True,
      resources_list_changed: False,
      prompts_list_changed: True,
      resource_subscriptions: [],
    )
  let assert Ok(first) = client.listen(peer, requested)
  let assert Ok(second) = client.listen(peer, requested)

  should.equal(
    client.next_notification(first, 300),
    Error("subscription notification timed out"),
  )
  should.equal(
    client.next_notification(second, 1000),
    Ok(client.ToolsListChanged),
  )
  should.equal(
    client.next_notification(second, 1000),
    Ok(client.PromptsListChanged),
  )

  client.close_subscription(second)
  let discovery = client.discover(peer)
  should.equal(
    client.next_notification(second, 100),
    Error("stdio subscription is closed"),
  )
  client.close_subscription(first)
  client.close(peer)
  case discovery {
    Error(_) -> should.fail()
    Ok(result) ->
      should.equal(
        result.server_info,
        Some(client.ServerInfo("lifecycle-peer", "1")),
      )
  }
}

pub fn stdio_frame_overflow_closes_the_owned_child_test() {
  let assert Ok(peer) =
    client.connect_stdio(client.StdioConfig(
      executable: "./test/fixtures/stdio/overflow-peer",
      args: [],
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))
  let first = client.discover(peer)
  case first {
    Error(reason) -> should.be_true(string.contains(reason, "buffer exceeded"))
    Ok(_) -> should.fail()
  }
  should.equal(client.discover(peer), Error("stdio client is closed"))
  client.close(peer)
}

pub fn gun_http_client_discovery_and_typed_call_test() {
  let policy =
    http.HttpPolicy(
      max_body_bytes: 4096,
      max_response_bytes: 65_536,
      request_timeout_ms: 3000,
      allowed_hosts: ["127.0.0.1"],
      allowed_origins: [],
    )
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(local_server(), fn() { Nil })
    |> http.with_options(options)
    |> http.with_policy(policy)
    |> http.start()
  }
  let assert Ok(peer) =
    open_http_client(
      "127.0.0.1",
      http.http_server_port(listener),
      "/",
      False,
      3000,
      65_536,
      None,
    )

  let assert Ok(discovery) = client.discover(peer)
  should.be_true(list.contains(discovery.supported_versions, "2026-07-28"))

  let assert Ok(read_result) =
    client.read_resource(peer, "memory://client-note")
  should.equal(read_result, [
    content.TextResourceContents(
      "memory://client-note",
      "client resource",
      Some("text/plain"),
    ),
  ])
  let assert Ok(prompt_result) =
    client.get_prompt(peer, "client-prompt", dict.new())
  should.equal(
    prompt_result,
    prompts.PromptResult(Some("client prompt"), [
      prompts.PromptMessage(content.UserRole, content.text_content("greeting")),
    ]),
  )
  let assert Ok(completion_result) =
    client.complete(
      peer,
      completion.PromptRef("client-prompt"),
      completion.CompletionArgument("topic", "gleam"),
      None,
    )
  should.equal(
    completion_result,
    completion.CompletionValues(["gleam-next"], Some(1), Some(False)),
  )

  let assert Ok(raw_discovery) =
    client.raw_json_call(peer, "server/discover", None, [])
  let assert Ok(raw_discovery) = bit_array.to_string(raw_discovery)
  should.be_true(string.contains(raw_discovery, "supportedVersions"))

  let assert Ok(raw_tool_page) =
    client.raw_json_call(peer, "tools/list", None, [])
  let assert Ok(raw_tool_page) = bit_array.to_string(raw_tool_page)
  let assert Ok(tool_page) = json.parse(raw_tool_page, dyn_decode.dynamic)
  let assert Ok(cursor) =
    dyn_decode.run(
      tool_page,
      dyn_decode.at(["result", "nextCursor"], dyn_decode.string),
    )
  let assert Ok(cross_family) =
    client.raw_json_call(peer, "prompts/list", None, [
      #("cursor", json.string(cursor)),
    ])
  let assert Ok(cross_family) = bit_array.to_string(cross_family)
  should.be_true(string.contains(cross_family, "\"error\""))
  let assert Ok(invalid_cursor) =
    client.raw_json_call(peer, "tools/list", None, [
      #("cursor", json.string("invalid-cursor")),
    ])
  let assert Ok(invalid_cursor) = bit_array.to_string(invalid_cursor)
  should.be_true(string.contains(invalid_cursor, "\"error\""))

  let assert Ok(tools) = client.list_tools(peer)
  should.equal(list.length(tools), 108)
  should.be_true(
    list.any(tools, fn(declaration) { declaration.name == "list-1" }),
  )
  let assert Ok(resource_list) = client.list_resources(peer)
  should.be_true(
    list.any(resource_list, fn(resource) {
      resource.uri == "memory://client-note"
    }),
  )
  let assert Ok(template_list) = client.list_resource_templates(peer)
  should.be_true(
    list.any(template_list, fn(template) {
      template.uri_template == "memory://client/{name}"
    }),
  )
  let assert Ok(prompt_list) = client.list_prompts(peer)
  should.be_true(
    list.any(prompt_list, fn(prompt) { prompt.name == "client-prompt" }),
  )

  let assert Ok(name) = tool.tool_name("echo")
  let outcome = case
    tool.definition(name, codec.field("name", codec.string()), codec.string())
  {
    Ok(definition) -> client.call_definition(peer, definition, "MCP")
    Error(_) -> client.ProtocolFailure("invalid local tool definition")
  }
  should.equal(
    outcome,
    client.StructuredSuccess("hello MCP", [
      content.TextContent("hello MCP", None),
    ]),
  )

  let assert Ok(fail_name) = tool.tool_name("fail")
  let failure = case
    tool.definition(
      fail_name,
      codec.field("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> client.call_definition(peer, definition, "MCP")
    Error(_) -> client.ProtocolFailure("invalid local tool definition")
  }
  case failure {
    client.ToolFailure([content.TextContent(error_json, None)]) ->
      codec.decode_json(fail_error_codec(), error_json)
      |> should.equal(
        Ok(#("not_found", "The requested record is unavailable.")),
      )
    _ -> should.fail()
  }

  let assert Ok(error_response) =
    client.raw_json_call(peer, "tools/call", Some("error_encoding"), [
      #("name", json.string("error_encoding")),
      #("arguments", json.object([#("name", json.string("MCP"))])),
    ])
  let assert Ok(error_response_text) = bit_array.to_string(error_response)
  let assert Ok(error_response) =
    json.parse(error_response_text, dyn_decode.dynamic)
  dyn_decode.run(
    error_response,
    dyn_decode.at(["result", "isError"], dyn_decode.bool),
  )
  |> should.equal(Ok(True))
  string.contains(error_response_text, "Tool execution failed.")
  |> should.be_true()

  let assert Ok(say_name) = tool.tool_name("say")
  let assert Ok(say_definition) =
    tool.content_definition(say_name, codec.field("name", codec.string()))
  should.equal(
    client.call_content_definition(peer, say_definition, "MCP"),
    Ok([
      content.TextContent("content-only reply", None),
    ]),
  )

  let assert Ok(rich_name) = tool.tool_name("rich")
  case
    case
      tool.definition(
        rich_name,
        codec.field("name", codec.string()),
        codec.string(),
      )
    {
      Ok(definition) -> client.call_definition(peer, definition, "MCP")
      Error(_) -> client.ProtocolFailure("invalid local tool definition")
    }
  {
    client.ContentOnlySuccess(blocks) ->
      should.equal(blocks, [
        content.ImageContent("aGVsbG8=", "image/png", Some(rich_annotations())),
        content.AudioContent("AQID", "audio/wav", None),
        content.ResourceLinkBlock(content.ResourceLink(
          uri: "https://example.test/resource",
          name: "linked",
          title: None,
          description: None,
          mime_type: None,
          size: None,
          annotations: None,
        )),
        content.EmbeddedResourceBlock(content.EmbeddedResource(
          content.TextResourceContents(
            uri: "file:///embedded",
            text: "embedded text",
            mime_type: Some("text/plain"),
          ),
          None,
        )),
      ])
    _ -> should.fail()
  }

  let exact_token =
    "1234567890123456789012345678901234567890.1234567890123456789"
  let assert Ok(number_limits) = number.number_limits(1024, 100, 1000)
  let assert Ok(exact) = number.parse_number(number_limits, exact_token)
  let assert Ok(exact_name) = tool.tool_name("exact")
  let exact_outcome = case
    tool.definition(
      exact_name,
      codec.field("value", codec.number()),
      codec.number(),
    )
  {
    Ok(definition) -> client.call_definition(peer, definition, exact)
    Error(_) -> client.ProtocolFailure("invalid local tool definition")
  }
  case exact_outcome {
    client.StructuredSuccess(value, _) -> should.equal(value, exact)
    _ -> should.fail()
  }

  let assert Ok(timeout_peer) =
    open_http_client(
      "127.0.0.1",
      http.http_server_port(listener),
      "/",
      False,
      1000,
      65_536,
      None,
    )
  let assert Ok(slow_name) = tool.tool_name("slow")
  should.equal(
    case
      tool.definition(
        slow_name,
        codec.field("name", codec.string()),
        codec.string(),
      )
    {
      Ok(definition) -> client.call_definition(timeout_peer, definition, "MCP")
      Error(_) -> client.ProtocolFailure("invalid local tool definition")
    },
    client.TransportFailure("request timed out"),
  )
  process.sleep(600)
  client.close(timeout_peer)

  let assert Ok(bounded_peer) =
    open_http_client(
      "127.0.0.1",
      http.http_server_port(listener),
      "/",
      False,
      3000,
      8,
      None,
    )
  let assert Error(limit_reason) = client.discover(bounded_peer)
  should.equal(limit_reason, "response exceeded configured byte limit")
  client.close(bounded_peer)

  client.close(peer)
  http.stop_http_server(listener)
}

pub fn admitted_definition_uses_plain_mcp_errors_and_typed_client_call_test() {
  let assert Ok(success_name) = tool.tool_name("definition_success")
  let assert Ok(default_name) = tool.tool_name("definition_default_error")
  let assert Ok(rendered_name) = tool.tool_name("definition_rendered_error")
  let input = codec.field("name", codec.string())
  let assert Ok(success_definition) =
    tool.definition(success_name, input, codec.string())
  let assert Ok(default_definition) =
    tool.definition(default_name, input, codec.string())
  let assert Ok(rendered_definition) =
    tool.definition(rendered_name, input, codec.string())
  let assert Ok(registry) =
    tool.registry([
      tool.handle(success_definition, fn(name) { Ok("hello " <> name) }),
      tool.handle(default_definition, fn(_name) { Error("private secret") }),
      tool.handle_with_error_renderer(
        rendered_definition,
        fn(_name) { Error("record missing") },
        fn(error) { "Public: " <> error },
      ),
    ])
  let policy =
    http.HttpPolicy(
      max_body_bytes: 4096,
      max_response_bytes: 65_536,
      request_timeout_ms: 3000,
      allowed_hosts: ["127.0.0.1"],
      allowed_origins: [],
    )
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(server.server(registry), fn() { Nil })
    |> http.with_options(options)
    |> http.with_policy(policy)
    |> http.start()
  }
  let assert Ok(peer) =
    open_http_client(
      "127.0.0.1",
      http.http_server_port(listener),
      "/",
      False,
      3000,
      65_536,
      None,
    )
  let success = client.call_definition(peer, success_definition, "world")
  let default_failure =
    client.call_definition(peer, default_definition, "world")
  let rendered_failure =
    client.call_definition(peer, rendered_definition, "world")
  client.close(peer)
  http.stop_http_server(listener)
  should.equal(
    success,
    client.StructuredSuccess("hello world", [
      content.text_content("hello world"),
    ]),
  )
  should.equal(
    default_failure,
    client.ToolFailure([content.text_content("Tool execution failed.")]),
  )
  should.equal(
    rendered_failure,
    client.ToolFailure([content.text_content("Public: record missing")]),
  )
}

pub fn http_subscription_receives_requested_list_change_test() {
  let policy =
    http.HttpPolicy(
      max_body_bytes: 4096,
      max_response_bytes: 65_536,
      request_timeout_ms: 3000,
      allowed_hosts: ["127.0.0.1"],
      allowed_origins: [],
    )
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(local_server(), fn() { Nil })
    |> http.with_options(options)
    |> http.with_policy(policy)
    |> http.start()
  }
  let assert Ok(peer) =
    open_http_client(
      "127.0.0.1",
      http.http_server_port(listener),
      "/",
      False,
      3000,
      65_536,
      None,
    )

  let raw_body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("raw-subscription-probe")),
      #("method", json.string("subscriptions/listen")),
      #(
        "params",
        json.object([
          #(
            "_meta",
            json.object([
              #(
                "io.modelcontextprotocol/protocolVersion",
                json.string("2026-07-28"),
              ),
              #("io.modelcontextprotocol/clientCapabilities", json.object([])),
            ]),
          ),
          #(
            "notifications",
            json.object([#("toolsListChanged", json.bool(True))]),
          ),
        ]),
      ),
    ])
    |> json.to_string
    |> bit_array.from_string
  should.equal(
    disconnect_after_first_sse_event(
      http.http_server_port(listener),
      "POST",
      [
        #("Accept", "text/event-stream"),
        #("MCP-Protocol-Version", "2026-07-28"),
        #("Mcp-Method", "subscriptions/listen"),
      ],
      raw_body,
    ),
    Ok(200),
  )

  let subscription_result =
    client.listen(
      peer,
      subscriptions.SubscriptionFilter(
        tools_list_changed: True,
        resources_list_changed: False,
        prompts_list_changed: False,
        resource_subscriptions: [],
      ),
    )
  let notification_result = case subscription_result {
    Error(reason) -> Error(reason)
    Ok(subscription) -> {
      let assert Ok(dynamic_name) = tool.tool_name("late-bound")
      let assert Ok(dynamic_tool) = case
        tool.definition(
          dynamic_name,
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
                description: Some("Registered after HTTP listener startup"),
              ),
            )
          Ok(
            tool.handle_with_error_renderer(
              definition,
              fn(_name) { Ok("arrived") },
              fn(application_error) {
                case codec.encode_json(codec.string(), application_error) {
                  Ok(text) -> text
                  Error(_) -> "Tool execution failed."
                }
              },
            ),
          )
        }
        Error(error) -> Error(error)
      }
      let registration = http.register_tool(listener, dynamic_tool)
      let received = client.next_notification(subscription, 1000)
      let assert Ok(registry_peer) =
        open_http_client(
          "127.0.0.1",
          http.http_server_port(listener),
          "/",
          False,
          3000,
          65_536,
          None,
        )
      let listed = client.list_tools_json(registry_peer)
      let called = case
        tool.definition(
          dynamic_name,
          codec.field("name", codec.string()),
          codec.string(),
        )
      {
        Ok(definition) ->
          client.call_definition(registry_peer, definition, "caller")
        Error(_) -> client.ProtocolFailure("invalid local tool definition")
      }
      let removed = http.unregister_tool(listener, dynamic_name)
      let removal_notification = client.next_notification(subscription, 1000)
      let listed_after_removal = client.list_tools_json(registry_peer)
      client.close(registry_peer)
      client.close_subscription(subscription)
      Ok(#(
        registration,
        received,
        listed,
        called,
        removed,
        removal_notification,
        listed_after_removal,
      ))
    }
  }

  client.close(peer)
  http.stop_http_server(listener)
  case notification_result {
    Error(reason) -> should.equal(reason, "should have returned result")
    Ok(#(
      registration,
      received,
      listed,
      called,
      removed,
      removal_notification,
      listed_after_removal,
    )) -> {
      should.equal(registration, Ok(Nil))
      should.equal(received, Ok(client.ToolsListChanged))
      case listed {
        Error(_) -> should.fail()
        Ok(declarations) ->
          should.be_true(
            list.any(declarations, fn(declaration) {
              string.contains(declaration, "late-bound")
            }),
          )
      }
      should.equal(
        called,
        client.StructuredSuccess("arrived", [content.text_content("arrived")]),
      )
      should.equal(removed, True)
      should.equal(removal_notification, Ok(client.ToolsListChanged))
      case listed_after_removal {
        Error(_) -> should.fail()
        Ok(declarations) ->
          should.be_false(
            list.any(declarations, fn(declaration) {
              string.contains(declaration, "late-bound")
            }),
          )
      }
    }
  }
}

pub fn http_subscription_from_empty_registry_honors_first_tool_change_test() {
  let assert Ok(registry) = tool.registry([])
  assert_subscription_reconciles_tool_change(
    server.server(registry),
    "first-tool",
  )
}

pub fn http_subscription_reconciles_change_during_establishment_test() {
  assert_subscription_reconciles_tool_change(local_server(), "racing-tool")
}

fn assert_subscription_reconciles_tool_change(
  initial_server: server.Server(Nil),
  late_tool_name: String,
) -> Nil {
  let assert Ok(name) = tool.tool_name(late_tool_name)
  let assert Ok(late_tool) = case
    tool.definition(name, codec.field("name", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Registered during subscription establishment"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_name) { Ok("arrived") },
          fn(application_error) {
            case codec.encode_json(codec.string(), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }
  let worker_ready = process.new_subject()
  let registration_result = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let command = process.new_subject()
      let start = process.new_subject()
      process.send(worker_ready, #(command, start))
      let assert Ok(#(listener, tool)) = process.receive(command, within: 3000)
      let assert Ok(release) = process.receive(start, within: 3000)
      process.send(registration_result, http.register_tool(listener, tool))
      process.send(release, Nil)
      context_gate(start)
    })
  let assert Ok(#(command, start)) = process.receive(worker_ready, within: 3000)
  let context = fn() {
    let released = process.new_subject()
    process.send(start, released)
    let _ = process.receive(released, within: 3000)
    Nil
  }
  let policy =
    http.HttpPolicy(
      max_body_bytes: 4096,
      max_response_bytes: 65_536,
      request_timeout_ms: 3000,
      allowed_hosts: ["127.0.0.1"],
      allowed_origins: [],
    )
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(initial_server, context)
    |> http.with_options(options)
    |> http.with_policy(policy)
    |> http.start()
  }
  process.send(command, #(listener, late_tool))
  let assert Ok(peer) =
    open_http_client(
      "127.0.0.1",
      http.http_server_port(listener),
      "/",
      False,
      3000,
      65_536,
      None,
    )
  let requested =
    subscriptions.SubscriptionFilter(
      tools_list_changed: True,
      resources_list_changed: False,
      prompts_list_changed: False,
      resource_subscriptions: [],
    )
  let subscription_result = client.listen(peer, requested)
  let registration = process.receive(registration_result, within: 3000)

  let outcome = case subscription_result {
    Error(_) -> Error("subscription did not receive its acknowledgement")
    Ok(subscription) -> {
      let acknowledged = client.acknowledged_notifications(subscription)
      let notification = client.next_notification(subscription, 1000)
      let assert Ok(registry_peer) =
        open_http_client(
          "127.0.0.1",
          http.http_server_port(listener),
          "/",
          False,
          3000,
          65_536,
          None,
        )
      let listing_result = process.new_subject()
      let _ =
        process.spawn_unlinked(fn() {
          process.send(listing_result, client.list_tools_json(registry_peer))
        })
      let listing = process.receive(listing_result, within: 3000)
      client.close(registry_peer)
      client.close_subscription(subscription)
      case listing {
        Error(_) -> Error("tool listing did not complete")
        Ok(listed) -> Ok(#(acknowledged, notification, listed))
      }
    }
  }

  client.close(peer)
  http.stop_http_server(listener)
  case registration, outcome {
    Ok(Ok(Nil)), Ok(#(acknowledged, notification, listing)) -> {
      should.be_true(acknowledged.tools_list_changed)
      should.equal(notification, Ok(client.ToolsListChanged))
      case listing {
        Error(_) -> should.fail()
        Ok(declarations) ->
          should.be_true(
            list.any(declarations, fn(declaration) {
              string.contains(declaration, late_tool_name)
            }),
          )
      }
    }
    _, _ -> should.fail()
  }
}

pub fn http_subscription_reconciles_same_name_replacement_during_establishment_test() {
  let assert Ok(name) = tool.tool_name("replace-me")
  let assert Ok(old_tool) = case
    tool.definition(name, codec.field("name", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("old metadata"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_value) { Ok("old handler") },
          fn(application_error) {
            case codec.encode_json(codec.string(), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }
  let assert Ok(replacement_tool) = case
    tool.definition(name, codec.field("name", codec.string()), codec.string())
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("replacement metadata"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_value) { Ok("replacement handler") },
          fn(application_error) {
            case codec.encode_json(codec.string(), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }
  let assert Ok(registry) = tool.registry([old_tool])
  let worker_ready = process.new_subject()
  let replacement_result = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let command = process.new_subject()
      let start = process.new_subject()
      process.send(worker_ready, #(command, start))
      let assert Ok(#(listener, old_name, new_tool)) =
        process.receive(command, within: 3000)
      let assert Ok(release) = process.receive(start, within: 3000)
      let removed = http.unregister_tool(listener, old_name)
      let registered = http.register_tool(listener, new_tool)
      process.send(replacement_result, #(removed, registered))
      process.send(release, Nil)
      context_gate(start)
    })
  let assert Ok(#(command, start)) = process.receive(worker_ready, within: 3000)
  let context = fn() {
    let released = process.new_subject()
    process.send(start, released)
    let _ = process.receive(released, within: 3000)
    Nil
  }
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(server.server(registry), context)
    |> http.with_options(options)
    |> http.with_policy(
      http.HttpPolicy(
        max_body_bytes: 4096,
        max_response_bytes: 65_536,
        request_timeout_ms: 3000,
        allowed_hosts: ["127.0.0.1"],
        allowed_origins: [],
      ),
    )
    |> http.start()
  }
  process.send(command, #(listener, name, replacement_tool))
  let assert Ok(peer) =
    open_http_client(
      "127.0.0.1",
      http.http_server_port(listener),
      "/",
      False,
      3000,
      65_536,
      None,
    )
  let requested =
    subscriptions.SubscriptionFilter(
      tools_list_changed: True,
      resources_list_changed: False,
      prompts_list_changed: False,
      resource_subscriptions: [],
    )
  let subscription_result = client.listen(peer, requested)
  let assert Ok(#(removed, registered)) =
    process.receive(replacement_result, within: 3000)
  let outcome = case subscription_result {
    Error(_) -> Error("subscription did not receive its acknowledgement")
    Ok(subscription) -> {
      let acknowledged = client.acknowledged_notifications(subscription)
      let notification = client.next_notification(subscription, 1000)
      let assert Ok(registry_peer) =
        open_http_client(
          "127.0.0.1",
          http.http_server_port(listener),
          "/",
          False,
          3000,
          65_536,
          None,
        )
      let listing = client.list_tools_json(registry_peer)
      let called = case
        tool.definition(
          name,
          codec.field("name", codec.string()),
          codec.string(),
        )
      {
        Ok(definition) ->
          client.call_definition(
            registry_peer,
            definition,
            "replacement caller",
          )
        Error(_) -> client.ProtocolFailure("invalid local tool definition")
      }
      client.close(registry_peer)
      client.close_subscription(subscription)
      Ok(#(acknowledged, notification, listing, called))
    }
  }
  client.close(peer)
  http.stop_http_server(listener)
  case removed, registered, outcome {
    True, Ok(Nil), Ok(#(acknowledged, notification, listing, called)) -> {
      should.be_true(acknowledged.tools_list_changed)
      should.equal(notification, Ok(client.ToolsListChanged))
      case listing {
        Error(_) -> should.fail()
        Ok(declarations) -> {
          should.be_true(
            list.any(declarations, fn(declaration) {
              string.contains(declaration, "replacement metadata")
            }),
          )
          should.be_false(
            list.any(declarations, fn(declaration) {
              string.contains(declaration, "old metadata")
            }),
          )
        }
      }
      should.equal(
        called,
        client.StructuredSuccess("replacement handler", [
          content.text_content("replacement handler"),
        ]),
      )
    }
    _, _, _ -> should.fail()
  }
}

pub fn http_subscription_after_registry_churn_reconciles_current_state_test() {
  let assert Ok(registry) = tool.registry([])
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(server.server(registry), fn() { Nil })
    |> http.with_options(options)
    |> http.with_policy(
      http.HttpPolicy(
        max_body_bytes: 4096,
        max_response_bytes: 65_536,
        request_timeout_ms: 3000,
        allowed_hosts: ["127.0.0.1"],
        allowed_origins: [],
      ),
    )
    |> http.start()
  }
  churn_registry(listener, 128)
  let assert Ok(peer) =
    open_http_client(
      "127.0.0.1",
      http.http_server_port(listener),
      "/",
      False,
      3000,
      65_536,
      None,
    )
  let result =
    client.listen(
      peer,
      subscriptions.SubscriptionFilter(
        tools_list_changed: True,
        resources_list_changed: False,
        prompts_list_changed: False,
        resource_subscriptions: [],
      ),
    )
  case result {
    Error(_) -> should.fail()
    Ok(subscription) -> {
      should.be_true(
        client.acknowledged_notifications(subscription).tools_list_changed,
      )
      client.close_subscription(subscription)
    }
  }
  client.close(peer)
  http.stop_http_server(listener)
}

fn churn_registry(listener: http.HttpServer(Nil), remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let raw_name = "churn-" <> int.to_string(remaining)
      let assert Ok(name) = tool.tool_name(raw_name)
      let assert Ok(new_tool) = case
        tool.definition(
          name,
          codec.field("name", codec.string()),
          codec.string(),
        )
      {
        Ok(definition) -> {
          let definition = tool.with_metadata(definition, tool.empty_metadata())
          Ok(
            tool.handle_with_error_renderer(
              definition,
              fn(value) { Ok(value) },
              fn(application_error) {
                case codec.encode_json(codec.string(), application_error) {
                  Ok(text) -> text
                  Error(_) -> "Tool execution failed."
                }
              },
            ),
          )
        }
        Error(error) -> Error(error)
      }
      should.equal(http.register_tool(listener, new_tool), Ok(Nil))
      should.be_true(http.unregister_tool(listener, name))
      churn_registry(listener, remaining - 1)
    }
  }
}

pub fn http_subscription_registration_fails_when_hub_dies_test() {
  let entered = process.new_subject()
  let context = fn() {
    let release = process.new_subject()
    process.send(entered, release)
    let _ = process.receive(release, within: 3000)
    Nil
  }
  let assert Ok(registry) = tool.registry([])
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(server.server(registry), context)
    |> http.with_options(options)
    |> http.with_policy(
      http.HttpPolicy(
        max_body_bytes: 4096,
        max_response_bytes: 65_536,
        request_timeout_ms: 1000,
        allowed_hosts: ["127.0.0.1"],
        allowed_origins: [],
      ),
    )
    |> http.start()
  }
  let assert Ok(peer) =
    open_http_client(
      "127.0.0.1",
      http.http_server_port(listener),
      "/",
      False,
      3000,
      65_536,
      None,
    )
  let requested =
    subscriptions.SubscriptionFilter(
      tools_list_changed: True,
      resources_list_changed: False,
      prompts_list_changed: False,
      resource_subscriptions: [],
    )
  let result = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(result, client.listen(peer, requested))
    })
  let assert Ok(release) = process.receive(entered, within: 3000)
  http.stop_http_server(listener)
  process.send(release, Nil)
  let listen_result = process.receive(result, within: 5000)
  client.close(peer)
  case listen_result {
    Ok(Error(_)) -> Nil
    Ok(Ok(_)) | Error(_) -> should.fail()
  }
}

fn context_gate(start: process.Subject(process.Subject(Nil))) -> Nil {
  case process.receive(start, within: 3000) {
    Ok(release) -> {
      process.send(release, Nil)
      context_gate(start)
    }
    Error(_) -> Nil
  }
}

pub fn stdio_client_handles_child_exit_and_repeated_close_test() {
  let assert Ok(peer) =
    client.connect_stdio(client.StdioConfig(
      executable: "/bin/sh",
      args: ["-c", "exit 3"],
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))
  let discovery = client.discover(peer)
  client.close(peer)
  client.close(peer)
  case discovery {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn stdio_client_concurrent_close_is_safe_test() {
  let assert Ok(peer) =
    client.connect_stdio(client.StdioConfig(
      executable: "./test/fixtures/stdio/relay-stdio",
      args: [],
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))
  let finished = process.new_subject()
  let _ =
    process.spawn(fn() {
      client.close(peer)
      process.send(finished, Nil)
    })
  let _ =
    process.spawn(fn() {
      client.close(peer)
      process.send(finished, Nil)
    })
  let assert Ok(Nil) = process.receive(finished, within: 3000)
  let assert Ok(Nil) = process.receive(finished, within: 3000)
}
