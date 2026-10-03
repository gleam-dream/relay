//// MCP content values: text, image, audio, resource-link and
//// embedded-resource blocks, resource contents, annotations and icons.
////
//// These records mirror the frozen `2026-07-28` schema and include every
//// optional field it defines, `_meta` included, so they change only with a
//// protocol revision. Tools (`relay/tool`), prompts (`relay/prompts`) and
//// resources (`relay/resources`) return them, and `relay/client` decodes
//// results into them. Build blocks with `text`, `image`, `audio`,
//// `resource_link` and `embedded`; read them by label or with `case`.
////
//// Binary data stays bytes: `image`, `audio` and `blob_resource` take a
//// `BitArray`, and Relay encodes base64 only on the wire.
////
//// ```gleam
//// import gleam/option.{Some}
//// import relay/content
////
//// pub fn reply() -> List(content.ContentBlock) {
////   let note =
////     content.text("Report ready")
////     |> content.with_annotations(content.Annotations(
////       ..content.empty_annotations(),
////       priority: Some(0.8),
////     ))
////   [note, content.image(<<137, 80, 78, 71>>, "image/png")]
//// }
//// ```

import gleam/option.{type Option, None, Some}
import json/blueprint/value.{type Value}

/// The `_meta` object of a protocol value: its members. An empty
/// list omits `_meta` on the wire; a decoded value may list members in another
/// order.
pub type Meta =
  List(#(String, Value))

/// Who a piece of content is meant for.
pub type Role {
  UserRole
  AssistantRole
}

/// Hints about how a client should use a piece of content. An empty
/// `audience` and `None` fields are omitted on the wire. `priority` ranges
/// from 0.0 (least important) to 1.0 (most important); `last_modified` is
/// an ISO 8601 timestamp.
pub type Annotations {
  Annotations(
    audience: List(Role),
    priority: Option(Float),
    last_modified: Option(String),
  )
}

/// Annotations with no hints set.
pub fn empty_annotations() -> Annotations {
  Annotations(audience: [], priority: None, last_modified: None)
}

/// The theme an icon is designed for.
pub type IconTheme {
  LightTheme
  DarkTheme
}

/// An icon a client may show for a tool, resource or prompt. An empty
/// `sizes` list is omitted on the wire.
pub type Icon {
  Icon(
    src: String,
    mime_type: Option(String),
    sizes: List(String),
    theme: Option(IconTheme),
  )
}

/// An icon with only its source URI.
pub fn icon(src: String) -> Icon {
  Icon(src: src, mime_type: None, sizes: [], theme: None)
}

/// The contents of one resource: text, or binary data as bytes.
pub type ResourceContents {
  TextResourceContents(
    uri: String,
    text: String,
    mime_type: Option(String),
    meta: Meta,
  )
  BlobResourceContents(
    uri: String,
    blob: BitArray,
    mime_type: Option(String),
    meta: Meta,
  )
}

/// Text resource contents without a MIME type.
pub fn text_resource(uri: String, text: String) -> ResourceContents {
  TextResourceContents(uri: uri, text: text, mime_type: None, meta: [])
}

/// Binary resource contents without a MIME type. Relay encodes the bytes as
/// base64 on the wire.
pub fn blob_resource(uri: String, blob: BitArray) -> ResourceContents {
  BlobResourceContents(uri: uri, blob: blob, mime_type: None, meta: [])
}

/// A link to a resource that a client may read, carried in a
/// `ResourceLinkBlock`.
pub type ResourceLink {
  ResourceLink(
    uri: String,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    size: Option(Int),
    annotations: Option(Annotations),
    icons: List(Icon),
    meta: Meta,
  )
}

/// One block of content in a tool result or a prompt message.
pub type ContentBlock {
  TextContent(text: String, annotations: Option(Annotations), meta: Meta)
  ImageContent(
    data: BitArray,
    mime_type: String,
    annotations: Option(Annotations),
    meta: Meta,
  )
  AudioContent(
    data: BitArray,
    mime_type: String,
    annotations: Option(Annotations),
    meta: Meta,
  )
  ResourceLinkBlock(link: ResourceLink)
  EmbeddedResourceBlock(
    resource: ResourceContents,
    annotations: Option(Annotations),
    meta: Meta,
  )
}

/// A text block.
pub fn text(text: String) -> ContentBlock {
  TextContent(text: text, annotations: None, meta: [])
}

/// An image block from raw image bytes, such as a PNG file's contents.
pub fn image(data: BitArray, mime_type: String) -> ContentBlock {
  ImageContent(data: data, mime_type: mime_type, annotations: None, meta: [])
}

/// An audio block from raw audio bytes.
pub fn audio(data: BitArray, mime_type: String) -> ContentBlock {
  AudioContent(data: data, mime_type: mime_type, annotations: None, meta: [])
}

/// A resource-link block with only its URI and name.
pub fn resource_link(uri: String, name: String) -> ContentBlock {
  ResourceLinkBlock(
    ResourceLink(
      uri: uri,
      name: name,
      title: None,
      description: None,
      mime_type: None,
      size: None,
      annotations: None,
      icons: [],
      meta: [],
    ),
  )
}

/// A block that embeds the contents of a resource.
pub fn embedded(resource: ResourceContents) -> ContentBlock {
  EmbeddedResourceBlock(resource: resource, annotations: None, meta: [])
}

/// Replaces a block's annotations.
pub fn with_annotations(
  block: ContentBlock,
  annotations: Annotations,
) -> ContentBlock {
  case block {
    TextContent(..) -> TextContent(..block, annotations: Some(annotations))
    ImageContent(..) -> ImageContent(..block, annotations: Some(annotations))
    AudioContent(..) -> AudioContent(..block, annotations: Some(annotations))
    ResourceLinkBlock(link) ->
      ResourceLinkBlock(ResourceLink(..link, annotations: Some(annotations)))
    EmbeddedResourceBlock(..) ->
      EmbeddedResourceBlock(..block, annotations: Some(annotations))
  }
}

/// Replaces a block's `_meta` members.
pub fn with_meta(block: ContentBlock, meta: Meta) -> ContentBlock {
  case block {
    TextContent(..) -> TextContent(..block, meta: meta)
    ImageContent(..) -> ImageContent(..block, meta: meta)
    AudioContent(..) -> AudioContent(..block, meta: meta)
    ResourceLinkBlock(link) ->
      ResourceLinkBlock(ResourceLink(..link, meta: meta))
    EmbeddedResourceBlock(..) -> EmbeddedResourceBlock(..block, meta: meta)
  }
}
