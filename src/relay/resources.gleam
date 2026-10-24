//// Resources a server lists and reads: static resources and URI templates,
//// for `resources/list`, `resources/templates/list` and `resources/read`.
////
//// `static(uri, name, read)` declares one resource. `template(uri_template,
//// name, read)` declares a family of resources; its built-in matcher accepts
//// one simple `{name}` variable per slash segment, including embedded forms
//// such as `{id}.png`, and it panics on other syntax because templates are
//// written in source code. `try_template` returns a typed error for
//// templates built at runtime, and `template_with_matcher` takes an
//// application-owned matcher for other syntax. Both kinds share the `with_*`
//// setters. A read handler's error is hidden from the client, which sees
//// the MCP resource-not-found error.
////
//// Attach resources with `relay/server.with_resources`; a client reads the
//// listings as `Declaration` and `TemplateDeclaration` values.
////
//// ```gleam
//// import relay/content
//// import relay/resources
////
//// pub fn readme() -> resources.Resource(Nil) {
////   resources.static("memo://readme", "Readme", fn(_context, uri) {
////     Ok([content.text_resource(uri, "Hello")])
////   })
////   |> resources.with_mime_type("text/plain")
//// }
//// ```

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import relay/content.{
  type Annotations, type Icon, type Meta, type ResourceContents,
}
import relay/internal/core

/// A static resource or a resource template, bound to its read handler.
pub type Resource(context) =
  core.Resource(context)

/// Why a URI template was refused.
pub type TemplateError {
  /// The template has no URI scheme, or leading or trailing whitespace.
  InvalidTemplateUri(template: String)
  /// The template uses syntax the built-in matcher does not support; use
  /// `template_with_matcher`.
  UnsupportedTemplateSyntax(template: String)
}

/// A one-line description of a template error.
pub fn describe_template_error(error: TemplateError) -> String {
  case error {
    InvalidTemplateUri(template) ->
      "resource template \"" <> template <> "\" has no valid URI scheme"
    UnsupportedTemplateSyntax(template) ->
      "resource template \""
      <> template
      <> "\" needs one simple {name} variable per segment; use template_with_matcher for other syntax"
  }
}

/// A resource at one URI. `read` receives the context and the requested URI.
pub fn static(
  uri: String,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), error),
) -> Resource(context) {
  entry(core.Static(uri), name, read)
}

/// A family of resources matched by a URI template such as
/// `"file:///notes/{id}.md"`. Panics on a template the built-in matcher does
/// not support; use `try_template` for templates built at runtime.
pub fn template(
  uri_template: String,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), error),
) -> Resource(context) {
  case try_template(uri_template, name, read) {
    Ok(resource) -> resource
    Error(error) ->
      panic as { "relay/resources.template: " <> describe_template_error(error) }
  }
}

/// `template` for templates built from runtime data.
pub fn try_template(
  uri_template: String,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), error),
) -> Result(Resource(context), TemplateError) {
  use _ <- result.try(admit_scheme(uri_template))
  use segments <- result.try(
    parse_segments(string.split(uri_template, on: "/"))
    |> result.replace_error(UnsupportedTemplateSyntax(uri_template)),
  )
  let matches = fn(uri) { segments_match(segments, string.split(uri, on: "/")) }
  Ok(entry(core.Template(uri_template, matches), name, read))
}

/// A resource template whose URIs an application-owned `matches` function
/// recognizes, for template syntax beyond the built-in matcher. The
/// template is published as given. Panics when it has no URI scheme.
pub fn template_with_matcher(
  uri_template: String,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), error),
  matches: fn(String) -> Bool,
) -> Resource(context) {
  case admit_scheme(uri_template) {
    Ok(Nil) -> entry(core.Template(uri_template, matches), name, read)
    Error(error) ->
      panic as {
        "relay/resources.template_with_matcher: "
        <> describe_template_error(error)
      }
  }
}

fn entry(
  kind: core.ResourceKind,
  name: String,
  read: fn(context, String) -> Result(List(ResourceContents), error),
) -> Resource(context) {
  core.Resource(
    kind: kind,
    name: name,
    title: None,
    description: None,
    mime_type: None,
    size: None,
    annotations: None,
    icons: [],
    meta: [],
    read: fn(context, uri) { read(context, uri) |> result.replace_error(Nil) },
  )
}

/// Sets the human-readable title.
pub fn with_title(
  resource: Resource(context),
  title: String,
) -> Resource(context) {
  core.Resource(..resource, title: Some(title))
}

/// Sets the description.
pub fn with_description(
  resource: Resource(context),
  description: String,
) -> Resource(context) {
  core.Resource(..resource, description: Some(description))
}

/// Sets the MIME type of the contents.
pub fn with_mime_type(
  resource: Resource(context),
  mime_type: String,
) -> Resource(context) {
  core.Resource(..resource, mime_type: Some(mime_type))
}

/// Sets the size in bytes of a static resource. Templates publish no size.
pub fn with_size(resource: Resource(context), size: Int) -> Resource(context) {
  core.Resource(..resource, size: Some(size))
}

/// Sets the annotations.
pub fn with_annotations(
  resource: Resource(context),
  annotations: Annotations,
) -> Resource(context) {
  core.Resource(..resource, annotations: Some(annotations))
}

/// Replaces the icons.
pub fn with_icons(
  resource: Resource(context),
  icons: List(Icon),
) -> Resource(context) {
  core.Resource(..resource, icons: icons)
}

/// Replaces the `_meta` members.
pub fn with_meta(resource: Resource(context), meta: Meta) -> Resource(context) {
  core.Resource(..resource, meta: meta)
}

// --- listings ----------------------------------------------------------------

/// A static resource as `resources/list` publishes it. Read fields by label.
pub type Declaration {
  Declaration(
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

/// A resource template as `resources/templates/list` publishes it. Read
/// fields by label.
pub type TemplateDeclaration {
  TemplateDeclaration(
    uri_template: String,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    annotations: Option(Annotations),
    icons: List(Icon),
    meta: Meta,
  )
}

// --- template matching -------------------------------------------------------

type Segment {
  StaticSegment(String)
  VariableSegment(prefix: String, suffix: String)
}

fn admit_scheme(raw: String) -> Result(Nil, TemplateError) {
  case raw == string.trim(raw), string.split(raw, on: ":") {
    True, [scheme, ..rest] ->
      case rest != [] && string.join(rest, ":") != "" && valid_scheme(scheme) {
        True -> Ok(Nil)
        False -> Error(InvalidTemplateUri(raw))
      }
    _, _ -> Error(InvalidTemplateUri(raw))
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

fn parse_segments(segments: List(String)) -> Result(List(Segment), Nil) {
  list.try_map(segments, parse_segment)
}

// One variable per slash segment keeps matching deterministic. Embedded
// variables such as `{id}.png` are supported; operators and composites are not.
fn parse_segment(segment: String) -> Result(Segment, Nil) {
  case string.split(segment, on: "{") {
    [literal] ->
      case string.contains(literal, "}") {
        True -> Error(Nil)
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
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
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

fn segments_match(template: List(Segment), uri: List(String)) -> Bool {
  case template, uri {
    [], [] -> True
    [StaticSegment(expected), ..template], [actual, ..uri] ->
      expected == actual && segments_match(template, uri)
    [VariableSegment(prefix, suffix), ..template], [actual, ..uri] ->
      string.starts_with(actual, prefix)
      && string.ends_with(actual, suffix)
      && string.length(actual) > string.length(prefix) + string.length(suffix)
      && segments_match(template, uri)
    _, _ -> False
  }
}
