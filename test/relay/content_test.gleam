import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value
import relay/client
import relay/content
import relay/internal/wire
import relay/reducer
import relay/server
import relay/testing
import relay/tool

fn annotations() -> content.Annotations {
  content.Annotations(
    audience: [content.UserRole, content.AssistantRole],
    priority: Some(0.5),
    last_modified: Some("2026-07-28T12:00:00Z"),
  )
}

fn round_trip(block: content.ContentBlock) -> content.ContentBlock {
  let encoded = json.to_string(wire.content_block_to_json(block))
  let assert Ok(decoded) = json.parse(encoded, wire.content_block_decoder())
  decoded
}

fn all_blocks() -> List(content.ContentBlock) {
  [
    content.text("hello"),
    content.image(<<137, 80, 78, 71, 0, 255>>, "image/png"),
    content.audio(<<82, 73, 70, 70, 1, 2>>, "audio/wav"),
    content.resource_link("memory://items/1", "item"),
    content.embedded(content.text_resource("memory://items/1", "{\"ok\":true}")),
  ]
}

pub fn modern_content_families_encode_with_annotations_test() {
  let link =
    content.ResourceLink(
      uri: "memory://items/1",
      name: "item",
      title: Some("Item"),
      description: None,
      mime_type: Some("application/json"),
      size: Some(5),
      annotations: Some(annotations()),
      icons: [],
      meta: [],
    )
  let blocks = [
    content.text("hello") |> content.with_annotations(annotations()),
    content.image(<<"hello":utf8>>, "image/png")
      |> content.with_annotations(annotations()),
    content.audio(<<"audio":utf8>>, "audio/wav"),
    content.ResourceLinkBlock(link),
    content.EmbeddedResourceBlock(
      resource: content.TextResourceContents(
        "memory://items/1",
        "{\"ok\":true}",
        Some("application/json"),
        [],
      ),
      annotations: Some(annotations()),
      meta: [],
    ),
  ]
  let encoded = json.array(blocks, wire.content_block_to_json) |> json.to_string
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
  should.be_true(string.contains(
    encoded,
    "\"lastModified\":\"2026-07-28T12:00:00Z\"",
  ))
  should.be_true(string.contains(encoded, "\"data\":\"aGVsbG8=\""))
  should.be_true(string.contains(encoded, "\"data\":\"YXVkaW8=\""))
}

pub fn annotations_use_the_spec_shape_test() {
  let encoded = json.to_string(wire.annotations_to_json(annotations()))
  let assert Ok(members) =
    json.parse(encoded, decode.dict(decode.string, decode.dynamic))
  list.sort(dict.keys(members), string.compare)
  |> should.equal(["audience", "lastModified", "priority"])
  string.contains(encoded, "title") |> should.be_false
  string.contains(encoded, "description") |> should.be_false
  json.parse(encoded, wire.annotations_decoder())
  |> should.equal(Ok(annotations()))

  // Empty annotations encode as an empty object and decode back.
  let empty =
    json.to_string(wire.annotations_to_json(content.empty_annotations()))
  empty |> should.equal("{}")
  json.parse(empty, wire.annotations_decoder())
  |> should.equal(Ok(content.empty_annotations()))
}

pub fn binary_bytes_are_base64_on_the_wire_and_decode_back_test() {
  let bytes = <<0, 1, 2, 250, 251, 252, 253, 254, 255>>
  let base64 = bit_array.base64_encode(bytes, True)

  let image = content.image(bytes, "image/png")
  let image_json = json.to_string(wire.content_block_to_json(image))
  string.contains(image_json, "\"data\":\"" <> base64 <> "\"")
  |> should.be_true
  round_trip(image) |> should.equal(image)

  let audio = content.audio(bytes, "audio/wav")
  string.contains(
    json.to_string(wire.content_block_to_json(audio)),
    "\"data\":\"" <> base64 <> "\"",
  )
  |> should.be_true
  round_trip(audio) |> should.equal(audio)

  let blob = content.blob_resource("memory://blob", bytes)
  let blob_json = json.to_string(wire.resource_contents_to_json(blob))
  string.contains(blob_json, "\"blob\":\"" <> base64 <> "\"") |> should.be_true
  json.parse(blob_json, wire.resource_contents_decoder())
  |> should.equal(Ok(blob))
  let embedded_blob = content.embedded(blob)
  round_trip(embedded_blob) |> should.equal(embedded_blob)

  // Bad base64 is refused.
  json.parse(
    "{\"type\":\"image\",\"data\":\"not base64!\",\"mimeType\":\"image/png\"}",
    wire.content_block_decoder(),
  )
  |> should.be_error
}

pub fn meta_encodes_and_decodes_test() {
  let meta = [
    #("example.com/trace", value.String("abc")),
    #("example.com/flags", value.Array([value.Bool(True)])),
  ]
  let text = content.text("hello") |> content.with_meta(meta)
  let encoded = json.to_string(wire.content_block_to_json(text))
  string.contains(
    encoded,
    "\"_meta\":{\"example.com/trace\":\"abc\",\"example.com/flags\":[true]}",
  )
  |> should.be_true
  // JSON objects are unordered: decoding keeps every member, not their order.
  let assert content.TextContent("hello", None, decoded_meta) = round_trip(text)
  sort_meta(decoded_meta) |> should.equal(sort_meta(meta))

  let resource =
    content.TextResourceContents("memory://a", "body", Some("text/plain"), meta)
  let resource_json = json.to_string(wire.resource_contents_to_json(resource))
  string.contains(resource_json, "\"_meta\"") |> should.be_true
  let assert Ok(content.TextResourceContents(
    "memory://a",
    "body",
    Some("text/plain"),
    decoded_meta,
  )) = json.parse(resource_json, wire.resource_contents_decoder())
  sort_meta(decoded_meta) |> should.equal(sort_meta(meta))

  // Empty meta is omitted.
  string.contains(
    json.to_string(wire.content_block_to_json(content.text("plain"))),
    "_meta",
  )
  |> should.be_false
  // A non-object `_meta` is refused.
  json.parse(
    "{\"type\":\"text\",\"text\":\"x\",\"_meta\":[1]}",
    wire.content_block_decoder(),
  )
  |> should.be_error
}

fn sort_meta(meta: content.Meta) -> content.Meta {
  list.sort(meta, fn(a, b) { string.compare(a.0, b.0) })
}

pub fn resource_link_with_icons_round_trips_test() {
  let icons = [
    content.icon("https://example.com/a.png"),
    content.Icon(
      src: "https://example.com/b.svg",
      mime_type: Some("image/svg+xml"),
      sizes: ["any", "48x48"],
      theme: Some(content.LightTheme),
    ),
  ]
  let link =
    content.ResourceLinkBlock(
      content.ResourceLink(
        uri: "memory://items/1",
        name: "item",
        title: Some("Item"),
        description: Some("An item"),
        mime_type: Some("application/json"),
        size: Some(42),
        annotations: Some(annotations()),
        icons: icons,
        meta: [#("k", value.String("v"))],
      ),
    )
  let encoded = json.to_string(wire.content_block_to_json(link))
  string.contains(encoded, "\"icons\":[{\"src\":\"https://example.com/a.png\"}")
  |> should.be_true
  string.contains(encoded, "\"sizes\":[\"any\",\"48x48\"]") |> should.be_true
  string.contains(encoded, "\"theme\":\"light\"") |> should.be_true
  string.contains(encoded, "\"size\":42") |> should.be_true
  round_trip(link) |> should.equal(link)
}

pub fn with_annotations_and_with_meta_apply_to_every_block_kind_test() {
  let meta = [#("example.com/k", value.String("v"))]
  all_blocks()
  |> list.each(fn(block) {
    let changed =
      block
      |> content.with_annotations(annotations())
      |> content.with_meta(meta)
    let #(found_annotations, found_meta) = case changed {
      content.TextContent(_, a, m) -> #(a, m)
      content.ImageContent(_, _, a, m) -> #(a, m)
      content.AudioContent(_, _, a, m) -> #(a, m)
      content.ResourceLinkBlock(link) -> #(link.annotations, link.meta)
      content.EmbeddedResourceBlock(_, a, m) -> #(a, m)
    }
    found_annotations |> should.equal(Some(annotations()))
    found_meta |> should.equal(meta)
    let encoded = json.to_string(wire.content_block_to_json(changed))
    string.contains(encoded, "\"annotations\":{") |> should.be_true
    string.contains(encoded, "\"_meta\":{\"example.com/k\":\"v\"}")
    |> should.be_true
    round_trip(changed) |> should.equal(changed)
  })
}

pub fn constructors_leave_optional_fields_empty_test() {
  content.text("a") |> should.equal(content.TextContent("a", None, []))
  content.image(<<1>>, "image/png")
  |> should.equal(content.ImageContent(<<1>>, "image/png", None, []))
  content.audio(<<1>>, "audio/wav")
  |> should.equal(content.AudioContent(<<1>>, "audio/wav", None, []))
  content.text_resource("u:x", "t")
  |> should.equal(content.TextResourceContents("u:x", "t", None, []))
  content.blob_resource("u:x", <<1>>)
  |> should.equal(content.BlobResourceContents("u:x", <<1>>, None, []))
  content.icon("https://x/i.png")
  |> should.equal(content.Icon("https://x/i.png", None, [], None))
  let assert content.ResourceLinkBlock(link) =
    content.resource_link("u:x", "name")
  link.title |> should.equal(None)
  link.icons |> should.equal([])
}

pub fn rich_content_families_survive_server_wire_encoding_test() {
  let blocks = all_blocks()
  let definition = tool.define("rich", codec.success(Nil), codec.string())
  let bound =
    tool.handle_call(definition, fn(_call, _input) {
      Ok(tool.complete_with_content("structured", blocks))
    })
  let srv = server.new([bound])

  // Through the reducer: the encoded response carries every family.
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
  let #(next, effects) =
    reducer.step(
      reducer.init(srv),
      reducer.Received(reducer.new_exchange_id(), Nil, body, None),
    )
  let assert [reducer.Admitted(_, "tools/call"), reducer.Start(invocation)] =
    effects
  let #(_, effects) =
    reducer.step(next, reducer.perform(invocation, fn(_, _, _) { Nil }))
  let assert [reducer.Write(_, response), reducer.Close(_)] = effects
  let assert Ok(response) = bit_array.to_string(response)
  should.be_true(string.contains(response, "\"structuredContent\""))
  should.be_true(string.contains(response, "\"type\":\"text\""))
  should.be_true(string.contains(response, "\"type\":\"image\""))
  should.be_true(string.contains(response, "\"type\":\"audio\""))
  should.be_true(string.contains(response, "\"type\":\"resource_link\""))
  should.be_true(string.contains(response, "\"type\":\"resource\""))

  // Through a client: the blocks decode back to the same values.
  let peer = testing.connect(srv, Nil)
  client.call(peer, definition, Nil)
  |> should.equal(Ok(client.Succeeded("structured", blocks)))
  client.close(peer)
}
