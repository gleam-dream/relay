import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import relay/content.{
  type Annotations, type ResourceContents, annotations_to_json,
}

pub opaque type ResourceUri {
  ResourceUri(String)
}

pub fn resource_uri(raw: String) -> Result(ResourceUri, String) {
  case string.trim(raw) {
    "" -> Error("Resource URI cannot be empty")
    trimmed ->
      case string.contains(trimmed, "://") {
        True -> Ok(ResourceUri(trimmed))
        False ->
          Error(
            "Resource URI must contain a scheme (e.g. file:// or custom://)",
          )
      }
  }
}

pub fn resource_uri_to_string(uri: ResourceUri) -> String {
  let ResourceUri(raw) = uri
  raw
}

pub type Resource {
  Resource(
    uri: String,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    size: Option(Int),
    annotations: Option(Annotations),
  )
}

pub type ResourceTemplate {
  ResourceTemplate(
    uri_template: String,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    annotations: Option(Annotations),
  )
}

pub type ResourceError {
  ResourceNotFound(uri: String)
  ResourceInvalidUri(reason: String)
  ResourceFailed(reason: String)
}

pub type ContextResource(context) {
  ContextResource(
    resource: Resource,
    read: fn(context, String) -> Result(List(ResourceContents), ResourceError),
  )
}

pub type ContextResourceTemplate(context) {
  ContextResourceTemplate(
    template: ResourceTemplate,
    read: fn(context, String) -> Result(List(ResourceContents), ResourceError),
  )
}

pub fn resource(
  uri: String,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), ResourceError),
) -> ContextResource(context) {
  ContextResource(
    resource: Resource(
      uri: uri,
      name: name,
      title: None,
      description: None,
      mime_type: None,
      size: None,
      annotations: None,
    ),
    read: read,
  )
}

pub fn resource_template(
  uri_template: String,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), ResourceError),
) -> ContextResourceTemplate(context) {
  ContextResourceTemplate(
    template: ResourceTemplate(
      uri_template: uri_template,
      name: name,
      title: None,
      description: None,
      mime_type: None,
      annotations: None,
    ),
    read: read,
  )
}

pub fn resource_to_json(res: Resource) -> json.Json {
  let fields = [
    #("uri", json.string(res.uri)),
    #("name", json.string(res.name)),
  ]
  let fields = case res.title {
    None -> fields
    Some(t) -> list.append(fields, [#("title", json.string(t))])
  }
  let fields = case res.description {
    None -> fields
    Some(d) -> list.append(fields, [#("description", json.string(d))])
  }
  let fields = case res.mime_type {
    None -> fields
    Some(m) -> list.append(fields, [#("mimeType", json.string(m))])
  }
  let fields = case res.size {
    None -> fields
    Some(s) -> list.append(fields, [#("size", json.int(s))])
  }
  let fields = case res.annotations {
    None -> fields
    Some(a) -> list.append(fields, [#("annotations", annotations_to_json(a))])
  }
  json.object(fields)
}

pub fn resource_template_to_json(tmpl: ResourceTemplate) -> json.Json {
  let fields = [
    #("uriTemplate", json.string(tmpl.uri_template)),
    #("name", json.string(tmpl.name)),
  ]
  let fields = case tmpl.title {
    None -> fields
    Some(t) -> list.append(fields, [#("title", json.string(t))])
  }
  let fields = case tmpl.description {
    None -> fields
    Some(d) -> list.append(fields, [#("description", json.string(d))])
  }
  let fields = case tmpl.mime_type {
    None -> fields
    Some(m) -> list.append(fields, [#("mimeType", json.string(m))])
  }
  let fields = case tmpl.annotations {
    None -> fields
    Some(a) -> list.append(fields, [#("annotations", annotations_to_json(a))])
  }
  json.object(fields)
}
