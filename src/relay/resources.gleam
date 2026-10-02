//// Static resources and resource templates for `resources/list`,
//// `resources/templates/list` and `resources/read`.
////
//// `resource(uri, name, read)` declares a static resource. `resource_template`
//// admits a URI template with one simple `{name}` variable per slash segment,
//// including embedded forms such as `{id}.png`; `resource_template_with_matcher`
//// accepts other syntax with an application-owned matcher. The simple
//// constructors replace handler errors with a generic `ResourceFailed`. Read
//// results are `relay/content.ResourceContents`. Attach resources with
//// `relay/server.with_resources` and `relay/server.with_resource_templates`.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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

pub opaque type ContextResourceTemplate(context) {
  ContextResourceTemplate(
    template: ResourceTemplate,
    read: fn(context, String) -> Result(List(ResourceContents), ResourceError),
    matches: fn(String) -> Bool,
  )
}

pub type TemplateError {
  InvalidTemplateUri
  UnsupportedTemplateSyntax
}

type TemplateSegment {
  StaticSegment(String)
  VariableSegment(prefix: String, suffix: String)
}

pub fn resource(
  uri: String,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), application_error),
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
    read: fn(context, uri) {
      read(context, uri)
      |> result.map_error(fn(_) { ResourceFailed("Resource handler failed") })
    },
  )
}

pub fn resource_template(
  uri_template: String,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), application_error),
) -> Result(ContextResourceTemplate(context), TemplateError) {
  use segments <- result.try(admit_template(uri_template))
  resource_template_with_matcher(uri_template, name, read, fn(uri) {
    template_matches_segments(segments, string.split(uri, on: "/"))
  })
}

/// Uses an application-owned matcher for template syntax beyond the built-in
/// simple `{name}` form. The advertised URI template remains caller-owned.
pub fn resource_template_with_matcher(
  uri_template: String,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), application_error),
  matches: fn(String) -> Bool,
) -> Result(ContextResourceTemplate(context), TemplateError) {
  use _ <- result.try(admit_template_scheme(uri_template))
  Ok(ContextResourceTemplate(
    template: ResourceTemplate(
      uri_template: uri_template,
      name: name,
      title: None,
      description: None,
      mime_type: None,
      annotations: None,
    ),
    read: fn(context, uri) {
      read(context, uri)
      |> result.map_error(fn(_) { ResourceFailed("Resource handler failed") })
    },
    matches: matches,
  ))
}

pub fn with_template_title(
  entry: ContextResourceTemplate(context),
  title: Option(String),
) -> ContextResourceTemplate(context) {
  ContextResourceTemplate(
    ..entry,
    template: ResourceTemplate(..entry.template, title: title),
  )
}

pub fn with_template_description(
  entry: ContextResourceTemplate(context),
  description: Option(String),
) -> ContextResourceTemplate(context) {
  ContextResourceTemplate(
    ..entry,
    template: ResourceTemplate(..entry.template, description: description),
  )
}

pub fn with_template_mime_type(
  entry: ContextResourceTemplate(context),
  mime_type: Option(String),
) -> ContextResourceTemplate(context) {
  ContextResourceTemplate(
    ..entry,
    template: ResourceTemplate(..entry.template, mime_type: mime_type),
  )
}

pub fn with_template_annotations(
  entry: ContextResourceTemplate(context),
  annotations: Option(Annotations),
) -> ContextResourceTemplate(context) {
  ContextResourceTemplate(
    ..entry,
    template: ResourceTemplate(..entry.template, annotations: annotations),
  )
}

pub fn template_description(
  entry: ContextResourceTemplate(context),
) -> ResourceTemplate {
  entry.template
}

pub fn matching_template_reader(
  entry: ContextResourceTemplate(context),
  uri: String,
) -> Option(
  fn(context, String) -> Result(List(ResourceContents), ResourceError),
) {
  case entry.matches(uri) {
    True -> Some(entry.read)
    False -> None
  }
}

fn admit_template(raw: String) -> Result(List(TemplateSegment), TemplateError) {
  use _ <- result.try(admit_template_scheme(raw))
  parse_segments(string.split(raw, on: "/"))
}

fn admit_template_scheme(raw: String) -> Result(Nil, TemplateError) {
  case raw == string.trim(raw), string.split(raw, on: ":") {
    False, _ -> Error(InvalidTemplateUri)
    True, [scheme, ..rest] ->
      case rest != [] && string.join(rest, ":") != "" && valid_scheme(scheme) {
        False -> Error(InvalidTemplateUri)
        True -> Ok(Nil)
      }
    True, _ -> Error(InvalidTemplateUri)
  }
}

fn valid_scheme(scheme: String) -> Bool {
  case string.to_graphemes(scheme) {
    [] -> False
    [first, ..rest] ->
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
        first,
      )
      && list.all(rest, fn(char) {
        string.contains(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-",
          char,
        )
      })
  }
}

fn parse_segments(
  segments: List(String),
) -> Result(List(TemplateSegment), TemplateError) {
  case segments {
    [] -> Ok([])
    [segment, ..rest] -> {
      use parsed <- result.try(parse_segment(segment))
      use remainder <- result.try(parse_segments(rest))
      Ok([parsed, ..remainder])
    }
  }
}

// One variable per slash segment keeps matching deterministic. Embedded
// variables such as `{id}.png` are supported; operators and composites are not.
fn parse_segment(segment: String) -> Result(TemplateSegment, TemplateError) {
  case string.split(segment, on: "{") {
    [literal] ->
      case string.contains(literal, "}") {
        True -> Error(UnsupportedTemplateSyntax)
        False -> Ok(StaticSegment(literal))
      }
    [prefix, after_open] ->
      case string.split(after_open, on: "}") {
        [name, suffix] ->
          case
            valid_variable_name(name)
            && !string.contains(prefix, "}")
            && !string.contains(suffix, "{")
          {
            True -> Ok(VariableSegment(prefix, suffix))
            False -> Error(UnsupportedTemplateSyntax)
          }
        _ -> Error(UnsupportedTemplateSyntax)
      }
    _ -> Error(UnsupportedTemplateSyntax)
  }
}

fn valid_variable_name(name: String) -> Bool {
  case string.to_graphemes(name) {
    [] -> False
    [first, ..rest] ->
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_",
        first,
      )
      && list.all(rest, fn(char) {
        string.contains(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789",
          char,
        )
      })
  }
}

fn template_matches_segments(
  template: List(TemplateSegment),
  uri: List(String),
) -> Bool {
  case template, uri {
    [], [] -> True
    [StaticSegment(expected), ..remaining_template], [actual, ..remaining_uri]
    ->
      expected == actual
      && template_matches_segments(remaining_template, remaining_uri)
    [VariableSegment(prefix, suffix), ..remaining_template],
      [actual, ..remaining_uri]
    ->
      string.starts_with(actual, prefix)
      && string.ends_with(actual, suffix)
      && string.length(actual) > string.length(prefix) + string.length(suffix)
      && template_matches_segments(remaining_template, remaining_uri)
    _, _ -> False
  }
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
