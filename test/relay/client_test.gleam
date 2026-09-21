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
import relay/transport/http

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
      codec.string(),
      fn(_context, _value) { Error("private handler detail") },
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
    [],
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
  should.equal(list.length(tools), 107)
  should.be_true(list.any(tools, fn(tool) { string.contains(tool, "list-1") }))

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
  should.equal(
    client.call_tool(
      peer,
      fail_name,
      "MCP",
      codec.field("name", codec.string()),
      codec.string(),
    ),
    client.ToolFailure([
      content.TextContent("The tool reported an error.", None),
    ]),
  )

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
