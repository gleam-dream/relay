import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode as dyn_decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/codec
import json/blueprint/number
import relay
import relay/client
import relay/completion
import relay/content
import relay/prompts
import relay/resources
import relay/server
import relay/subscriptions
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

fn local_server() -> server.Server(Nil) {
  let assert Ok(name) = relay.tool_name("echo")
  let assert Ok(echo_tool) =
    relay.context_tool(
      name,
      relay.empty_metadata(),
      codec.field("name", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_context, value) { Ok("hello " <> value) },
    )
  let assert Ok(fail_name) = relay.tool_name("fail")
  let assert Ok(fail_tool) =
    relay.context_tool(
      fail_name,
      relay.empty_metadata(),
      codec.field("name", codec.string()),
      codec.string(),
      fail_error_codec(),
      fn(_context, _value) {
        Error(#("not_found", "The requested record is unavailable."))
      },
    )
  let assert Ok(error_encoding_name) = relay.tool_name("error_encoding")
  let assert Ok(error_codec) = codec.integer_between(0, 10)
  let assert Ok(error_encoding_tool) =
    relay.context_tool(
      error_encoding_name,
      relay.empty_metadata(),
      codec.field("name", codec.string()),
      codec.string(),
      error_codec,
      fn(_context, _value) { Error(11) },
    )
  let assert Ok(say_name) = relay.tool_name("say")
  let assert Ok(say_tool) =
    relay.context_tool_with_content(
      say_name,
      relay.empty_metadata(),
      codec.field("name", codec.string()),
      codec.string(),
      codec.string(),
      fn(_context, _value) {
        Ok(#(None, [content.text_content("content-only reply")]))
      },
    )
  let assert Ok(rich_name) = relay.tool_name("rich")
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
  let assert Ok(rich_tool) =
    relay.context_tool_with_content(
      rich_name,
      relay.empty_metadata(),
      codec.field("name", codec.string()),
      codec.string(),
      codec.string(),
      fn(_context, _value) { Ok(#(None, rich_blocks)) },
    )
  let assert Ok(exact_name) = relay.tool_name("exact")
  let assert Ok(exact_tool) =
    relay.context_tool(
      exact_name,
      relay.empty_metadata(),
      codec.field("value", codec.number()),
      codec.number(),
      codec.string(),
      fn(_context, value) { Ok(value) },
    )
  let assert Ok(slow_name) = relay.tool_name("slow")
  let assert Ok(slow_tool) =
    relay.context_tool(
      slow_name,
      relay.empty_metadata(),
      codec.field("name", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_context, _value) {
        process.sleep(1500)
        Ok("finished")
      },
    )
  let assert Ok(registry) =
    relay.registry([
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
  server.server_with_services(
    registry,
    [readable],
    [template],
    [prompt],
    Some(completion),
  )
}

fn rich_annotations() -> content.Annotations {
  content.Annotations(
    audience: Some([content.UserRole, content.AssistantRole]),
    priority: Some(0.75),
    title: Some("preview"),
    description: Some("image preview"),
  )
}

fn many_named_tools(count: Int) -> List(relay.ContextTool(Nil)) {
  case count <= 0 {
    True -> []
    False -> {
      let assert Ok(name) = relay.tool_name("list-" <> int.to_string(count))
      let assert Ok(listed_tool) =
        relay.context_tool(
          name,
          relay.empty_metadata(),
          codec.field("name", codec.string()),
          codec.string(),
          codec.object(codec.empty()),
          fn(_context, value) { Ok(value) },
        )
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
  let assert Ok(listener) =
    http.start_https_server(
      local_server(),
      http.HttpOptions(port: 0, host: "127.0.0.1"),
      "test/fixtures/tls/localhost.crt",
      "test/fixtures/tls/localhost.key",
    )
  let config =
    client.ClientConfig(
      host: "localhost",
      port: http.http_server_port(listener),
      path: "/",
      secure: True,
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    )
  let untrusted_connection = client.connect(config)
  case untrusted_connection {
    Ok(peer) -> client.close(peer)
    Error(_) -> Nil
  }
  let trusted_result =
    client.connect_with_ca(config, "test/fixtures/tls/root-ca.crt")
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
  let assert Ok(greet_name) = relay.tool_name("greet")
  let call =
    client.call_tool(
      peer,
      greet_name,
      "stdio",
      codec.field("name", codec.string()),
      codec.string(),
    )
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
  let assert Ok([tool]) = client.list_tool_declarations(peer)
  let assert Ok([resource]) = client.list_resource_declarations(peer)
  let assert Ok([template]) = client.list_resource_template_declarations(peer)
  let assert Ok([prompt]) = client.list_prompt_declarations(peer)
  client.close(peer)

  should.equal(tool.name, "annotated")
  case tool.annotations, tool.icons {
    Some(client.ToolAnnotations(
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
  let assert Ok(listener) =
    http.start_http_server_with_policy(
      local_server(),
      http.HttpOptions(port: 0, host: "127.0.0.1"),
      policy,
    )
  let assert Ok(peer) =
    client.connect(client.ClientConfig(
      host: "127.0.0.1",
      port: http.http_server_port(listener),
      path: "/",
      secure: False,
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))

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

  let assert Ok(name) = relay.tool_name("echo")
  let outcome =
    client.call_tool(
      peer,
      name,
      "MCP",
      codec.field("name", codec.string()),
      codec.string(),
    )
  should.equal(
    outcome,
    client.StructuredSuccess("hello MCP", [
      content.TextContent("hello MCP", None),
    ]),
  )

  let assert Ok(fail_name) = relay.tool_name("fail")
  let failure =
    client.call_tool(
      peer,
      fail_name,
      "MCP",
      codec.field("name", codec.string()),
      codec.string(),
    )
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
    dyn_decode.at(["error", "code"], dyn_decode.int),
  )
  |> should.equal(Ok(-32_603))
  dyn_decode.run(
    error_response,
    dyn_decode.at(["error", "message"], dyn_decode.string),
  )
  |> should.equal(Ok("Internal error."))
  dyn_decode.run(error_response, dyn_decode.at(["result"], dyn_decode.dynamic))
  |> should.be_error()

  let assert Ok(say_name) = relay.tool_name("say")
  should.equal(
    client.call_tool(
      peer,
      say_name,
      "MCP",
      codec.field("name", codec.string()),
      codec.string(),
    ),
    client.ContentOnlySuccess([
      content.TextContent("content-only reply", None),
    ]),
  )

  let assert Ok(rich_name) = relay.tool_name("rich")
  case
    client.call_tool(
      peer,
      rich_name,
      "MCP",
      codec.field("name", codec.string()),
      codec.string(),
    )
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
  let assert Ok(exact_name) = relay.tool_name("exact")
  let exact_outcome =
    client.call_tool(
      peer,
      exact_name,
      exact,
      codec.field("value", codec.number()),
      codec.number(),
    )
  case exact_outcome {
    client.StructuredSuccess(value, _) -> should.equal(value, exact)
    _ -> should.fail()
  }

  let assert Ok(timeout_peer) =
    client.connect(client.ClientConfig(
      host: "127.0.0.1",
      port: http.http_server_port(listener),
      path: "/",
      secure: False,
      timeout_ms: 1000,
      max_response_bytes: 65_536,
    ))
  let assert Ok(slow_name) = relay.tool_name("slow")
  should.equal(
    client.call_tool(
      timeout_peer,
      slow_name,
      "MCP",
      codec.field("name", codec.string()),
      codec.string(),
    ),
    client.TransportFailure("request timed out"),
  )
  process.sleep(600)
  client.close(timeout_peer)

  let assert Ok(bounded_peer) =
    client.connect(client.ClientConfig(
      host: "127.0.0.1",
      port: http.http_server_port(listener),
      path: "/",
      secure: False,
      timeout_ms: 3000,
      max_response_bytes: 8,
    ))
  let assert Error(limit_reason) = client.discover(bounded_peer)
  should.equal(limit_reason, "response exceeded configured byte limit")
  client.close(bounded_peer)

  client.close(peer)
  http.stop_http_server(listener)
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
  let assert Ok(listener) =
    http.start_http_server_with_policy(
      local_server(),
      http.HttpOptions(port: 0, host: "127.0.0.1"),
      policy,
    )
  let assert Ok(peer) =
    client.connect(client.ClientConfig(
      host: "127.0.0.1",
      port: http.http_server_port(listener),
      path: "/",
      secure: False,
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))

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
      let assert Ok(dynamic_name) = relay.tool_name("late-bound")
      let assert Ok(dynamic_tool) =
        relay.context_tool(
          dynamic_name,
          relay.tool_metadata("Registered after HTTP listener startup"),
          codec.field("name", codec.string()),
          codec.string(),
          codec.string(),
          fn(_context, _name) { Ok("arrived") },
        )
      let registration = http.register_tool(listener, dynamic_tool)
      let received = client.next_notification(subscription, 1000)
      let assert Ok(registry_peer) =
        client.connect(client.ClientConfig(
          host: "127.0.0.1",
          port: http.http_server_port(listener),
          path: "/",
          secure: False,
          timeout_ms: 3000,
          max_response_bytes: 65_536,
        ))
      let listed = client.list_tools_json(registry_peer)
      let called =
        client.call_tool(
          registry_peer,
          dynamic_name,
          "caller",
          codec.field("name", codec.string()),
          codec.string(),
        )
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
  let assert Ok(registry) = relay.registry([])
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
  let assert Ok(name) = relay.tool_name(late_tool_name)
  let assert Ok(late_tool) =
    relay.context_tool(
      name,
      relay.tool_metadata("Registered during subscription establishment"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.string(),
      fn(_context, _name) { Ok("arrived") },
    )
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
  let assert Ok(listener) =
    http.start_http_server_with_context(
      initial_server,
      http.HttpOptions(port: 0, host: "127.0.0.1"),
      context,
      policy,
    )
  process.send(command, #(listener, late_tool))
  let assert Ok(peer) =
    client.connect(client.ClientConfig(
      host: "127.0.0.1",
      port: http.http_server_port(listener),
      path: "/",
      secure: False,
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
  let subscription_result = client.listen(peer, requested)
  let registration = process.receive(registration_result, within: 3000)

  let outcome = case subscription_result {
    Error(_) -> Error("subscription did not receive its acknowledgement")
    Ok(subscription) -> {
      let acknowledged = client.acknowledged_notifications(subscription)
      let notification = client.next_notification(subscription, 1000)
      let assert Ok(registry_peer) =
        client.connect(client.ClientConfig(
          host: "127.0.0.1",
          port: http.http_server_port(listener),
          path: "/",
          secure: False,
          timeout_ms: 3000,
          max_response_bytes: 65_536,
        ))
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
  let assert Ok(name) = relay.tool_name("replace-me")
  let assert Ok(old_tool) =
    relay.context_tool(
      name,
      relay.tool_metadata("old metadata"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.string(),
      fn(_context, _value) { Ok("old handler") },
    )
  let assert Ok(replacement_tool) =
    relay.context_tool(
      name,
      relay.tool_metadata("replacement metadata"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.string(),
      fn(_context, _value) { Ok("replacement handler") },
    )
  let assert Ok(registry) = relay.registry([old_tool])
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
  let assert Ok(listener) =
    http.start_http_server_with_context(
      server.server(registry),
      http.HttpOptions(port: 0, host: "127.0.0.1"),
      context,
      http.HttpPolicy(
        max_body_bytes: 4096,
        max_response_bytes: 65_536,
        request_timeout_ms: 3000,
        allowed_hosts: ["127.0.0.1"],
        allowed_origins: [],
      ),
    )
  process.send(command, #(listener, name, replacement_tool))
  let assert Ok(peer) =
    client.connect(client.ClientConfig(
      host: "127.0.0.1",
      port: http.http_server_port(listener),
      path: "/",
      secure: False,
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
  let subscription_result = client.listen(peer, requested)
  let assert Ok(#(removed, registered)) =
    process.receive(replacement_result, within: 3000)
  let outcome = case subscription_result {
    Error(_) -> Error("subscription did not receive its acknowledgement")
    Ok(subscription) -> {
      let acknowledged = client.acknowledged_notifications(subscription)
      let notification = client.next_notification(subscription, 1000)
      let assert Ok(registry_peer) =
        client.connect(client.ClientConfig(
          host: "127.0.0.1",
          port: http.http_server_port(listener),
          path: "/",
          secure: False,
          timeout_ms: 3000,
          max_response_bytes: 65_536,
        ))
      let listing = client.list_tools_json(registry_peer)
      let called =
        client.call_tool(
          registry_peer,
          name,
          "replacement caller",
          codec.field("name", codec.string()),
          codec.string(),
        )
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
  let assert Ok(registry) = relay.registry([])
  let assert Ok(listener) =
    http.start_http_server_with_policy(
      server.server(registry),
      http.HttpOptions(port: 0, host: "127.0.0.1"),
      http.HttpPolicy(
        max_body_bytes: 4096,
        max_response_bytes: 65_536,
        request_timeout_ms: 3000,
        allowed_hosts: ["127.0.0.1"],
        allowed_origins: [],
      ),
    )
  churn_registry(listener, 128)
  let assert Ok(peer) =
    client.connect(client.ClientConfig(
      host: "127.0.0.1",
      port: http.http_server_port(listener),
      path: "/",
      secure: False,
      timeout_ms: 3000,
      max_response_bytes: 65_536,
    ))
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
      let assert Ok(name) = relay.tool_name(raw_name)
      let assert Ok(new_tool) =
        relay.context_tool(
          name,
          relay.empty_metadata(),
          codec.field("name", codec.string()),
          codec.string(),
          codec.string(),
          fn(_context, value) { Ok(value) },
        )
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
  let assert Ok(registry) = relay.registry([])
  let assert Ok(listener) =
    http.start_http_server_with_context(
      server.server(registry),
      http.HttpOptions(port: 0, host: "127.0.0.1"),
      context,
      http.HttpPolicy(
        max_body_bytes: 4096,
        max_response_bytes: 65_536,
        request_timeout_ms: 1000,
        allowed_hosts: ["127.0.0.1"],
        allowed_origins: [],
      ),
    )
  let assert Ok(peer) =
    client.connect(client.ClientConfig(
      host: "127.0.0.1",
      port: http.http_server_port(listener),
      path: "/",
      secure: False,
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
