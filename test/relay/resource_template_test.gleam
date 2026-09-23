import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import relay/content
import relay/resources

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn embedded_variable_and_authority_free_scheme_test() {
  let assert Ok(entry) =
    resources.resource_template(
      "urn:record:{id}.png",
      "image",
      fn(_ctx: Nil, uri) {
        Ok([content.TextResourceContents(uri, "image", None)])
      },
    )
  let entry =
    entry
    |> resources.with_template_title(Some("Image"))
    |> resources.with_template_description(Some("Record image"))
    |> resources.with_template_mime_type(Some("image/png"))
  let description = resources.template_description(entry)
  description.title |> should.equal(Some("Image"))
  description.description |> should.equal(Some("Record image"))
  description.mime_type |> should.equal(Some("image/png"))

  let assert Some(read) =
    resources.matching_template_reader(entry, "urn:record:123.png")
  read(Nil, "urn:record:123.png")
  |> should.equal(
    Ok([content.TextResourceContents("urn:record:123.png", "image", None)]),
  )
  case resources.matching_template_reader(entry, "urn:record:.png") {
    None -> True
    Some(_) -> False
  }
  |> should.be_true
  case resources.matching_template_reader(entry, "urn:record:123.jpg") {
    None -> True
    Some(_) -> False
  }
  |> should.be_true
}

pub fn unsupported_template_syntax_fails_before_advertisement_test() {
  let read = fn(_ctx: Nil, uri) {
    Ok([content.TextResourceContents(uri, "content", None)])
  }
  let unsupported = [
    "urn:record:{id}{ext}",
    "urn:record:{+path}",
    "urn:record:{id*}",
    "urn:record:{id",
    "urn:record:id}",
  ]
  unsupported
  |> list.each(fn(template) {
    resources.resource_template(template, "bad", read)
    |> should.equal(Error(resources.UnsupportedTemplateSyntax))
  })
  resources.resource_template("record/{id}", "bad", read)
  |> should.equal(Error(resources.InvalidTemplateUri))
}

pub fn hostile_near_match_stays_bounded_test() {
  let assert Ok(entry) =
    resources.resource_template(
      "urn:record:{id}.png",
      "image",
      fn(_ctx: Nil, uri) {
        Ok([content.TextResourceContents(uri, "image", None)])
      },
    )
  let long_miss = "urn:record:" <> string.repeat("x", times: 20_000) <> ".jpg"
  case resources.matching_template_reader(entry, long_miss) {
    None -> True
    Some(_) -> False
  }
  |> should.be_true
}

pub fn explicit_matcher_supports_application_syntax_test() {
  let assert Ok(entry) =
    resources.resource_template_with_matcher(
      "urn:record:{+path}",
      "tree",
      fn(_ctx: Nil, uri) {
        Ok([content.TextResourceContents(uri, "tree", None)])
      },
      fn(uri) { string.starts_with(uri, "urn:record:tree/") },
    )
  let assert Some(_) =
    resources.matching_template_reader(entry, "urn:record:tree/leaf")
  case resources.matching_template_reader(entry, "urn:record:other") {
    None -> True
    Some(_) -> False
  }
  |> should.be_true
  resources.resource_template_with_matcher(
    "",
    "bad",
    fn(_ctx: Nil, _uri) { Ok([]) },
    fn(_) { True },
  )
  |> should.equal(Error(resources.InvalidTemplateUri))
}
