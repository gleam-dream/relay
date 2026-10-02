//// MCP content values and their wire JSON encoders: text, image, audio,
//// resource-link and embedded-resource blocks, resource contents, roles and
//// annotations.
////
//// Tools (`relay/tool`), prompts (`relay/prompts`) and resources
//// (`relay/resources`) return these values, and `relay/client` decodes results
//// into them. `text_content`, `image_content` and `audio_content` build blocks
//// without annotations.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Role {
  UserRole
  AssistantRole
}

pub fn role_to_string(role: Role) -> String {
  case role {
    UserRole -> "user"
    AssistantRole -> "assistant"
  }
}

pub fn role_from_string(str: String) -> Result(Role, Nil) {
  case str {
    "user" -> Ok(UserRole)
    "assistant" -> Ok(AssistantRole)
    _ -> Error(Nil)
  }
}

pub type Annotations {
  Annotations(
    audience: Option(List(Role)),
    priority: Option(Float),
    title: Option(String),
    description: Option(String),
  )
}

pub fn empty_annotations() -> Annotations {
  Annotations(audience: None, priority: None, title: None, description: None)
}

pub fn annotations_to_json(annotations: Annotations) -> json.Json {
  let fields = []
  let fields = case annotations.audience {
    None -> fields
    Some(roles) -> [
      #("audience", json.array(roles, fn(r) { json.string(role_to_string(r)) })),
      ..fields
    ]
  }
  let fields = case annotations.priority {
    None -> fields
    Some(p) -> [#("priority", json.float(p)), ..fields]
  }
  let fields = case annotations.title {
    None -> fields
    Some(t) -> [#("title", json.string(t)), ..fields]
  }
  let fields = case annotations.description {
    None -> fields
    Some(d) -> [#("description", json.string(d)), ..fields]
  }
  json.object(fields)
}

pub type ResourceContents {
  TextResourceContents(uri: String, text: String, mime_type: Option(String))
  BlobResourceContents(uri: String, blob: String, mime_type: Option(String))
}

pub fn resource_contents_to_json(contents: ResourceContents) -> json.Json {
  case contents {
    TextResourceContents(uri, text, mime_type) -> {
      let fields = [#("uri", json.string(uri)), #("text", json.string(text))]
      let fields = case mime_type {
        None -> fields
        Some(m) -> list.append(fields, [#("mimeType", json.string(m))])
      }
      json.object(fields)
    }
    BlobResourceContents(uri, blob, mime_type) -> {
      let fields = [#("uri", json.string(uri)), #("blob", json.string(blob))]
      let fields = case mime_type {
        None -> fields
        Some(m) -> list.append(fields, [#("mimeType", json.string(m))])
      }
      json.object(fields)
    }
  }
}

pub type ResourceLink {
  ResourceLink(
    uri: String,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    size: Option(Int),
    annotations: Option(Annotations),
  )
}

pub fn resource_link_to_json(link: ResourceLink) -> json.Json {
  let fields = [
    #("type", json.string("resource_link")),
    #("uri", json.string(link.uri)),
    #("name", json.string(link.name)),
  ]
  let fields = case link.title {
    None -> fields
    Some(t) -> list.append(fields, [#("title", json.string(t))])
  }
  let fields = case link.description {
    None -> fields
    Some(d) -> list.append(fields, [#("description", json.string(d))])
  }
  let fields = case link.mime_type {
    None -> fields
    Some(m) -> list.append(fields, [#("mimeType", json.string(m))])
  }
  let fields = case link.size {
    None -> fields
    Some(s) -> list.append(fields, [#("size", json.int(s))])
  }
  let fields = case link.annotations {
    None -> fields
    Some(a) -> list.append(fields, [#("annotations", annotations_to_json(a))])
  }
  json.object(fields)
}

pub type EmbeddedResource {
  EmbeddedResource(resource: ResourceContents, annotations: Option(Annotations))
}

pub fn embedded_resource_to_json(embedded: EmbeddedResource) -> json.Json {
  let fields = [
    #("type", json.string("resource")),
    #("resource", resource_contents_to_json(embedded.resource)),
  ]
  let fields = case embedded.annotations {
    None -> fields
    Some(a) -> list.append(fields, [#("annotations", annotations_to_json(a))])
  }
  json.object(fields)
}

pub type ContentBlock {
  TextContent(text: String, annotations: Option(Annotations))
  ImageContent(
    data: String,
    mime_type: String,
    annotations: Option(Annotations),
  )
  AudioContent(
    data: String,
    mime_type: String,
    annotations: Option(Annotations),
  )
  ResourceLinkBlock(link: ResourceLink)
  EmbeddedResourceBlock(embedded: EmbeddedResource)
}

pub fn text_content(text: String) -> ContentBlock {
  TextContent(text: text, annotations: None)
}

pub fn image_content(data: String, mime_type: String) -> ContentBlock {
  ImageContent(data: data, mime_type: mime_type, annotations: None)
}

pub fn audio_content(data: String, mime_type: String) -> ContentBlock {
  AudioContent(data: data, mime_type: mime_type, annotations: None)
}

pub fn content_block_to_json(block: ContentBlock) -> json.Json {
  case block {
    TextContent(text, annotations) -> {
      let fields = [
        #("type", json.string("text")),
        #("text", json.string(text)),
      ]
      let fields = case annotations {
        None -> fields
        Some(a) ->
          list.append(fields, [#("annotations", annotations_to_json(a))])
      }
      json.object(fields)
    }
    ImageContent(data, mime_type, annotations) -> {
      let fields = [
        #("type", json.string("image")),
        #("data", json.string(data)),
        #("mimeType", json.string(mime_type)),
      ]
      let fields = case annotations {
        None -> fields
        Some(a) ->
          list.append(fields, [#("annotations", annotations_to_json(a))])
      }
      json.object(fields)
    }
    AudioContent(data, mime_type, annotations) -> {
      let fields = [
        #("type", json.string("audio")),
        #("data", json.string(data)),
        #("mimeType", json.string(mime_type)),
      ]
      let fields = case annotations {
        None -> fields
        Some(a) ->
          list.append(fields, [#("annotations", annotations_to_json(a))])
      }
      json.object(fields)
    }
    ResourceLinkBlock(link) -> resource_link_to_json(link)
    EmbeddedResourceBlock(embedded) -> embedded_resource_to_json(embedded)
  }
}
