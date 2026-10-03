//// Wire encoders and decoders for the protocol records in `relay/content`,
//// shared by the server codecs and the client.

import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import json/blueprint/value.{type Value}
import relay/content.{
  type Annotations, type ContentBlock, type Icon, type Meta,
  type ResourceContents, type ResourceLink, type Role, Annotations,
  AssistantRole, AudioContent, BlobResourceContents, DarkTheme,
  EmbeddedResourceBlock, Icon, ImageContent, LightTheme, ResourceLink,
  ResourceLinkBlock, TextContent, TextResourceContents, UserRole,
}

@external(erlang, "relay_ffi", "raw_json")
fn ffi_raw_json(json_str: String) -> json.Json

/// An exact `json.Json` for a Blueprint value; numbers keep their digits.
pub fn value_to_json(val: Value) -> json.Json {
  ffi_raw_json(value.to_string(val))
}

/// The text a structured result mirrors into its content, for clients that
/// read only content.
pub fn text_mirror(val: Value) -> String {
  case val {
    value.String(text) -> text
    _ -> value.to_string(val)
  }
}

/// A `_meta` member, or nothing for empty metadata.
pub fn meta_field(meta: Meta) -> List(#(String, json.Json)) {
  case meta {
    [] -> []
    _ -> [#("_meta", value_to_json(value.Object(meta)))]
  }
}

/// An optional string member.
pub fn optional_string(
  key: String,
  field: Option(String),
) -> List(#(String, json.Json)) {
  case field {
    None -> []
    Some(text) -> [#(key, json.string(text))]
  }
}

/// An optional integer member.
pub fn optional_int(
  key: String,
  field: Option(Int),
) -> List(#(String, json.Json)) {
  case field {
    None -> []
    Some(number) -> [#(key, json.int(number))]
  }
}

pub fn role_name(role: Role) -> String {
  case role {
    UserRole -> "user"
    AssistantRole -> "assistant"
  }
}

pub fn annotations_to_json(annotations: Annotations) -> json.Json {
  let audience = case annotations.audience {
    [] -> []
    roles -> [
      #(
        "audience",
        json.array(roles, fn(role) { json.string(role_name(role)) }),
      ),
    ]
  }
  let priority = case annotations.priority {
    None -> []
    Some(priority) -> [#("priority", json.float(priority))]
  }
  json.object(
    list.flatten([
      audience,
      optional_string("lastModified", annotations.last_modified),
      priority,
    ]),
  )
}

fn optional_annotations(
  annotations: Option(Annotations),
) -> List(#(String, json.Json)) {
  case annotations {
    None -> []
    Some(annotations) -> [#("annotations", annotations_to_json(annotations))]
  }
}

pub fn icon_to_json(icon: Icon) -> json.Json {
  let sizes = case icon.sizes {
    [] -> []
    sizes -> [#("sizes", json.array(sizes, json.string))]
  }
  let theme = case icon.theme {
    None -> []
    Some(LightTheme) -> [#("theme", json.string("light"))]
    Some(DarkTheme) -> [#("theme", json.string("dark"))]
  }
  json.object(
    list.flatten([
      [#("src", json.string(icon.src))],
      optional_string("mimeType", icon.mime_type),
      sizes,
      theme,
    ]),
  )
}

/// An `icons` member, or nothing for no icons.
pub fn icons_field(icons: List(Icon)) -> List(#(String, json.Json)) {
  case icons {
    [] -> []
    icons -> [#("icons", json.array(icons, icon_to_json))]
  }
}

pub fn resource_contents_to_json(contents: ResourceContents) -> json.Json {
  case contents {
    TextResourceContents(uri, text, mime_type, meta) ->
      json.object(
        list.flatten([
          [#("uri", json.string(uri)), #("text", json.string(text))],
          optional_string("mimeType", mime_type),
          meta_field(meta),
        ]),
      )
    BlobResourceContents(uri, blob, mime_type, meta) ->
      json.object(
        list.flatten([
          [
            #("uri", json.string(uri)),
            #("blob", json.string(bit_array.base64_encode(blob, True))),
          ],
          optional_string("mimeType", mime_type),
          meta_field(meta),
        ]),
      )
  }
}

pub fn resource_link_to_json(link: ResourceLink) -> json.Json {
  json.object(
    list.flatten([
      [
        #("type", json.string("resource_link")),
        #("uri", json.string(link.uri)),
        #("name", json.string(link.name)),
      ],
      optional_string("title", link.title),
      optional_string("description", link.description),
      optional_string("mimeType", link.mime_type),
      optional_int("size", link.size),
      optional_annotations(link.annotations),
      icons_field(link.icons),
      meta_field(link.meta),
    ]),
  )
}

pub fn content_block_to_json(block: ContentBlock) -> json.Json {
  case block {
    TextContent(text, annotations, meta) ->
      json.object(
        list.flatten([
          [#("type", json.string("text")), #("text", json.string(text))],
          optional_annotations(annotations),
          meta_field(meta),
        ]),
      )
    ImageContent(data, mime_type, annotations, meta) ->
      binary_block("image", data, mime_type, annotations, meta)
    AudioContent(data, mime_type, annotations, meta) ->
      binary_block("audio", data, mime_type, annotations, meta)
    ResourceLinkBlock(link) -> resource_link_to_json(link)
    EmbeddedResourceBlock(resource, annotations, meta) ->
      json.object(
        list.flatten([
          [
            #("type", json.string("resource")),
            #("resource", resource_contents_to_json(resource)),
          ],
          optional_annotations(annotations),
          meta_field(meta),
        ]),
      )
  }
}

fn binary_block(
  kind: String,
  data: BitArray,
  mime_type: String,
  annotations: Option(Annotations),
  meta: Meta,
) -> json.Json {
  json.object(
    list.flatten([
      [
        #("type", json.string(kind)),
        #("data", json.string(bit_array.base64_encode(data, True))),
        #("mimeType", json.string(mime_type)),
      ],
      optional_annotations(annotations),
      meta_field(meta),
    ]),
  )
}

// --- decoders ----------------------------------------------------------------

/// A JSON object as `_meta` members. A non-object fails.
pub fn meta_decoder() -> Decoder(Meta) {
  use found <- decode.then(value.decoder())
  case found {
    value.Object(members) -> decode.success(members)
    _ -> decode.failure([], "_meta object")
  }
}

/// The optional `_meta` member of an object.
pub fn optional_meta(next: fn(Meta) -> Decoder(a)) -> Decoder(a) {
  decode.optional_field("_meta", [], meta_decoder(), next)
}

/// An optional string member.
pub fn optional_string_field(
  key: String,
  next: fn(Option(String)) -> Decoder(a),
) -> Decoder(a) {
  decode.optional_field(key, None, decode.optional(decode.string), next)
}

/// A JSON number as a float, integers included.
pub fn number_decoder() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn role_decoder() -> Decoder(Role) {
  use name <- decode.then(decode.string)
  case name {
    "user" -> decode.success(UserRole)
    "assistant" -> decode.success(AssistantRole)
    _ -> decode.failure(UserRole, "role")
  }
}

pub fn annotations_decoder() -> Decoder(Annotations) {
  use audience <- decode.optional_field(
    "audience",
    [],
    decode.list(role_decoder()),
  )
  use priority <- decode.optional_field(
    "priority",
    None,
    decode.optional(number_decoder()),
  )
  use last_modified <- optional_string_field("lastModified")
  decode.success(Annotations(audience:, priority:, last_modified:))
}

fn optional_annotations_field(
  next: fn(Option(Annotations)) -> Decoder(a),
) -> Decoder(a) {
  decode.optional_field(
    "annotations",
    None,
    decode.optional(annotations_decoder()),
    next,
  )
}

pub fn icon_decoder() -> Decoder(Icon) {
  use src <- decode.field("src", decode.string)
  use mime_type <- optional_string_field("mimeType")
  use sizes <- decode.optional_field("sizes", [], decode.list(decode.string))
  use theme <- decode.optional_field(
    "theme",
    None,
    decode.optional({
      use name <- decode.then(decode.string)
      case name {
        "light" -> decode.success(LightTheme)
        "dark" -> decode.success(DarkTheme)
        _ -> decode.failure(LightTheme, "icon theme")
      }
    }),
  )
  decode.success(Icon(src:, mime_type:, sizes:, theme:))
}

/// The optional `icons` member of an object.
pub fn optional_icons(next: fn(List(Icon)) -> Decoder(a)) -> Decoder(a) {
  decode.optional_field("icons", [], decode.list(icon_decoder()), next)
}

fn base64_decoder() -> Decoder(BitArray) {
  use encoded <- decode.then(decode.string)
  case bit_array.base64_decode(encoded) {
    Ok(bytes) -> decode.success(bytes)
    Error(Nil) -> decode.failure(<<>>, "base64")
  }
}

pub fn resource_contents_decoder() -> Decoder(ResourceContents) {
  use uri <- decode.field("uri", decode.string)
  use mime_type <- optional_string_field("mimeType")
  use meta <- optional_meta
  use text <- decode.optional_field(
    "text",
    None,
    decode.optional(decode.string),
  )
  use blob <- decode.optional_field(
    "blob",
    None,
    decode.optional(base64_decoder()),
  )
  case text, blob {
    Some(text), None ->
      decode.success(TextResourceContents(uri:, text:, mime_type:, meta:))
    None, Some(blob) ->
      decode.success(BlobResourceContents(uri:, blob:, mime_type:, meta:))
    _, _ ->
      decode.failure(
        TextResourceContents(uri:, text: "", mime_type:, meta:),
        "exactly one of text or blob",
      )
  }
}

pub fn resource_link_decoder() -> Decoder(ResourceLink) {
  use uri <- decode.field("uri", decode.string)
  use name <- decode.field("name", decode.string)
  use title <- optional_string_field("title")
  use description <- optional_string_field("description")
  use mime_type <- optional_string_field("mimeType")
  use size <- decode.optional_field("size", None, decode.optional(decode.int))
  use annotations <- optional_annotations_field
  use icons <- optional_icons
  use meta <- optional_meta
  decode.success(ResourceLink(
    uri:,
    name:,
    title:,
    description:,
    mime_type:,
    size:,
    annotations:,
    icons:,
    meta:,
  ))
}

pub fn content_block_decoder() -> Decoder(ContentBlock) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "text" -> {
      use text <- decode.field("text", decode.string)
      use annotations <- optional_annotations_field
      use meta <- optional_meta
      decode.success(TextContent(text:, annotations:, meta:))
    }
    "image" -> {
      use data <- decode.field("data", base64_decoder())
      use mime_type <- decode.field("mimeType", decode.string)
      use annotations <- optional_annotations_field
      use meta <- optional_meta
      decode.success(ImageContent(data:, mime_type:, annotations:, meta:))
    }
    "audio" -> {
      use data <- decode.field("data", base64_decoder())
      use mime_type <- decode.field("mimeType", decode.string)
      use annotations <- optional_annotations_field
      use meta <- optional_meta
      decode.success(AudioContent(data:, mime_type:, annotations:, meta:))
    }
    "resource_link" -> resource_link_decoder() |> decode.map(ResourceLinkBlock)
    "resource" -> {
      use resource <- decode.field("resource", resource_contents_decoder())
      use annotations <- optional_annotations_field
      use meta <- optional_meta
      decode.success(EmbeddedResourceBlock(resource:, annotations:, meta:))
    }
    _ -> decode.failure(content.text(""), "content block type")
  }
}
