import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/value
import relay/client
import relay/content
import relay/reason_support
import relay/resources
import relay/server
import relay/testing

@external(erlang, "relay_ffi", "rescue_run")
fn rescue(f: fn() -> a) -> Result(a, String)

fn serve(resource: resources.Resource(Nil)) -> client.Client {
  testing.connect(server.new([]) |> server.with_resources([resource]), Nil)
}

fn not_found(peer: client.Client, uri: String) -> Nil {
  let assert Error(client.RpcError(-32_602, _, _)) =
    client.read_resource(peer, uri) |> reason_support.of
  Nil
}

pub fn embedded_variable_and_authority_free_scheme_test() {
  let entry =
    resources.template("urn:record:{id}.png", "image", fn(_ctx: Nil, uri) {
      Ok([content.text_resource(uri, "image")])
    })
    |> resources.with_title("Image")
    |> resources.with_description("Record image")
    |> resources.with_mime_type("image/png")
  let peer = serve(entry)
  let assert Ok([declaration]) = client.list_resource_templates(peer)
  declaration.uri_template |> should.equal("urn:record:{id}.png")
  declaration.name |> should.equal("image")
  declaration.title |> should.equal(Some("Image"))
  declaration.description |> should.equal(Some("Record image"))
  declaration.mime_type |> should.equal(Some("image/png"))
  // A template is not a static resource.
  client.list_resources(peer) |> should.equal(Ok([]))

  client.read_resource(peer, "urn:record:123.png")
  |> should.equal(Ok([content.text_resource("urn:record:123.png", "image")]))
  not_found(peer, "urn:record:.png")
  not_found(peer, "urn:record:123.jpg")
  not_found(peer, "urn:record:a/b.png")
  client.close(peer)
}

pub fn unsupported_template_syntax_fails_before_advertisement_test() {
  let read = fn(_ctx: Nil, uri) { Ok([content.text_resource(uri, "content")]) }
  [
    "urn:record:{id}{ext}",
    "urn:record:{+path}",
    "urn:record:{id*}",
    "urn:record:{id",
    "urn:record:id}",
  ]
  |> list.each(fn(template) {
    let assert Error(error) = resources.try_template(template, "bad", read)
    error |> should.equal(resources.UnsupportedTemplateSyntax(template))
    resources.describe_template_error(error)
    |> string.contains(template)
    |> should.be_true
  })
  ["record/{id}", "", " urn:record:{id}", "urn:", "1urn:record:{id}"]
  |> list.each(fn(template) {
    let assert Error(error) = resources.try_template(template, "bad", read)
    error |> should.equal(resources.InvalidTemplateUri(template))
  })
  resources.describe_template_error(resources.InvalidTemplateUri("record/{id}"))
  |> string.contains("record/{id}")
  |> should.be_true
  resources.try_template("urn:record:{id}", "good", read) |> should.be_ok
}

pub fn template_panics_on_unsupported_syntax_test() {
  let read = fn(_ctx: Nil, uri) { Ok([content.text_resource(uri, "content")]) }
  rescue(fn() { resources.template("urn:record:{+path}", "bad", read) })
  |> should.be_error
  rescue(fn() { resources.template("record/{id}", "bad", read) })
  |> should.be_error
  rescue(fn() { resources.template("urn:record:{id}", "good", read) })
  |> should.be_ok
}

pub fn hostile_near_match_stays_bounded_test() {
  let peer =
    serve(
      resources.template("urn:record:{id}.png", "image", fn(_ctx: Nil, uri) {
        Ok([content.text_resource(uri, "image")])
      }),
    )
  not_found(peer, "urn:record:" <> string.repeat("x", times: 20_000) <> ".jpg")
  client.close(peer)
}

pub fn explicit_matcher_supports_application_syntax_test() {
  let entry =
    resources.template_with_matcher(
      "urn:record:{+path}",
      "tree",
      fn(_ctx: Nil, uri) { Ok([content.text_resource(uri, "tree")]) },
      fn(uri) { string.starts_with(uri, "urn:record:tree/") },
    )
  let peer = serve(entry)
  let assert Ok([declaration]) = client.list_resource_templates(peer)
  declaration.uri_template |> should.equal("urn:record:{+path}")
  client.read_resource(peer, "urn:record:tree/leaf/deep")
  |> should.equal(
    Ok([content.text_resource("urn:record:tree/leaf/deep", "tree")]),
  )
  not_found(peer, "urn:record:other")
  client.close(peer)
  rescue(fn() {
    resources.template_with_matcher(
      "",
      "bad",
      fn(_ctx: Nil, _uri) { Ok([]) },
      fn(_) { True },
    )
  })
  |> should.be_error
}

pub fn template_declaration_carries_every_setter_test() {
  let annotations =
    content.Annotations(
      audience: [content.AssistantRole],
      priority: Some(0.25),
      last_modified: None,
    )
  let icon = content.icon("https://example.com/t.png")
  let meta = [#("example.com/kind", value.String("template"))]
  let peer =
    serve(
      resources.template("file:///notes/{id}.md", "note", fn(_ctx: Nil, uri) {
        Ok([content.text_resource(uri, "body")])
      })
      |> resources.with_annotations(annotations)
      |> resources.with_icons([icon])
      |> resources.with_meta(meta)
      |> resources.with_size(10),
    )
  let assert Ok([declaration]) = client.list_resource_templates(peer)
  declaration
  |> should.equal(resources.TemplateDeclaration(
    uri_template: "file:///notes/{id}.md",
    name: "note",
    title: None,
    description: None,
    mime_type: None,
    annotations: Some(annotations),
    icons: [icon],
    meta: meta,
  ))
  client.close(peer)
}
