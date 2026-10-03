//// The documentation gate: every public module renders a module doc, and
//// every public function, type and constant has a doc comment.

import gleam/list
import gleam/string

@external(erlang, "relay_docs_ffi", "public_sources")
fn public_sources() -> List(#(String, String))

/// `gleam docs` renders a module doc only from `////` lines.
pub fn every_public_module_starts_with_a_module_doc_test() {
  let sources = public_sources()
  let assert True = list.length(sources) >= 15
  let assert [] =
    sources
    |> list.filter(fn(source) { !string.starts_with(source.1, "//// ") })
    |> list.map(fn(source) { source.0 })
}

pub fn every_public_definition_has_a_doc_comment_test() {
  let assert [] =
    public_sources()
    |> list.flat_map(fn(source) {
      let #(path, text) = source
      undocumented(string.split(text, "\n"), "", [])
      |> list.map(fn(line) { path <> ": " <> line })
    })
}

fn undocumented(
  lines: List(String),
  previous: String,
  found: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(found)
    [line, ..rest] -> {
      let public =
        string.starts_with(line, "pub fn ")
        || string.starts_with(line, "pub type ")
        || string.starts_with(line, "pub opaque type ")
        || string.starts_with(line, "pub const ")
      let found = case public && !string.starts_with(previous, "///") {
        True -> [line, ..found]
        False -> found
      }
      // Attributes sit between a doc comment and its definition.
      let previous = case string.starts_with(line, "@") {
        True -> previous
        False -> line
      }
      undocumented(rest, previous, found)
    }
  }
}
