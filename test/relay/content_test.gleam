import gleam/bit_array
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/codec
import relay/content
import relay/server
import relay/tool

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn modern_content_families_encode_with_annotations_test() {
  let annotations =
    content.Annotations(
      audience: Some([content.UserRole, content.AssistantRole]),
      priority: Some(0.5),
      title: Some("Annotated"),
      description: Some("Visible in the response"),
    )
  let blocks = [
    content.TextContent("hello", Some(annotations)),
    content.ImageContent("aGVsbG8=", "image/png", Some(annotations)),
    content.AudioContent("YXVkaW8=", "audio/wav", None),
    content.ResourceLinkBlock(content.ResourceLink(
      uri: "memory://items/1",
      name: "item",
      title: Some("Item"),
      description: None,
      mime_type: Some("application/json"),
      size: Some(5),
      annotations: Some(annotations),
    )),
    content.EmbeddedResourceBlock(content.EmbeddedResource(
      resource: content.TextResourceContents(
        "memory://items/1",
        "{\"ok\":true}",
        Some("application/json"),
      ),
      annotations: Some(annotations),
    )),
  ]
  let encoded =
    json.array(blocks, content.content_block_to_json) |> json.to_string
  should.be_true(string.contains(encoded, "\"type\":\"text\""))
  should.be_true(string.contains(encoded, "\"type\":\"image\""))
  should.be_true(string.contains(encoded, "\"type\":\"audio\""))
  should.be_true(string.contains(encoded, "\"type\":\"resource_link\""))
  should.be_true(string.contains(encoded, "\"type\":\"resource\""))
  should.be_true(string.contains(
    encoded,
    "\"audience\":[\"user\",\"assistant\"]",
  ))
  should.be_true(string.contains(encoded, "\"priority\":0.5"))
}

pub fn rich_content_families_survive_server_wire_encoding_test() {
  let blocks = [
    content.TextContent("hello", None),
    content.ImageContent("aGVsbG8=", "image/png", None),
    content.AudioContent("YXVkaW8=", "audio/wav", None),
    content.ResourceLinkBlock(content.ResourceLink(
      uri: "memory://items/1",
      name: "item",
      title: None,
      description: None,
      mime_type: None,
      size: None,
      annotations: None,
    )),
    content.EmbeddedResourceBlock(content.EmbeddedResource(
      resource: content.TextResourceContents(
        "memory://items/1",
        "embedded",
        None,
      ),
      annotations: None,
    )),
  ]
  let assert Ok(name) = tool.tool_name("rich")
  let assert Ok(tool) = case
    tool.definition(name, codec.object(codec.empty()), codec.string())
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok({
        let user_handler = fn(_context, _input) {
          Ok(#(Some("structured"), blocks))
        }
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
  let assert Ok(registry) = tool.registry([tool])
  let metadata =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ])
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("rich-result")),
      #("method", json.string("tools/call")),
      #(
        "params",
        json.object([
          #("_meta", metadata),
          #("name", json.string("rich")),
          #("arguments", json.object([])),
        ]),
      ),
    ])
    |> json.to_string
    |> bit_array.from_string
  let exchange = server.fresh_exchange()
  let #(next, effects) =
    server.step(
      server.server(registry),
      server.MessageReceived(exchange, Nil, body),
    )
  let assert [
    server.EmitRequestAdmitted(_, "tools/call"),
    server.StartInvocation(inv),
  ] = effects
  let #(_, effects) = server.step(next, server.perform(inv))
  let assert [server.Write(_, response), server.CloseExchange(_)] = effects
  let assert Ok(response) = bit_array.to_string(response)
  should.be_true(string.contains(response, "\"structuredContent\""))
  should.be_true(string.contains(response, "\"type\":\"text\""))
  should.be_true(string.contains(response, "\"type\":\"image\""))
  should.be_true(string.contains(response, "\"type\":\"audio\""))
  should.be_true(string.contains(response, "\"type\":\"resource_link\""))
  should.be_true(string.contains(response, "\"type\":\"resource\""))
}
