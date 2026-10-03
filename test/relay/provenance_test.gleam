//// Provenance: the frozen schema checksum and the sibling pins.

import gleam/bit_array
import gleam/io
import gleam/string
import gleeunit/should

@external(erlang, "relay_ffi", "sha256_hex")
fn ffi_sha256_hex(bytes: BitArray) -> String

@external(erlang, "relay_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(BitArray, String)

@external(erlang, "relay_ffi", "git_head")
fn ffi_git_head(repo_path: String) -> String

@external(erlang, "relay_provenance_ffi", "ci_environment")
fn ffi_ci_environment() -> Bool

pub fn mcp_frozen_schema_checksum_test() {
  let path = "test/fixtures/mcp_2026/schema.json.source"
  let assert Ok(bytes) = ffi_read_file(path)
  let digest = ffi_sha256_hex(bytes)
  digest
  |> should.equal(
    "ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203",
  )
}

fn expected_sibling_heads() -> #(String, String, String) {
  let assert Ok(bytes) = ffi_read_file("sibling-revisions.txt")
  let assert Ok(source) = bit_array.to_string(bytes)
  let assert [blueprint_line, sinal_line, http_gun_line, ""] =
    string.split(source, on: "\n")
  let assert ["json_blueprint", blueprint_head] =
    string.split(blueprint_line, on: "=")
  let assert ["sinal", sinal_head] = string.split(sinal_line, on: "=")
  let assert ["http_gun", http_gun_head] = string.split(http_gun_line, on: "=")
  #(blueprint_head, sinal_head, http_gun_head)
}

/// CI checks each sibling out at its pin, so a mismatch there means the
/// workflow ignored sibling-revisions.txt. A local sibling checkout may move
/// past its pin during development, so a local mismatch only warns.
fn check_sibling_head(name: String, head: String, expected: String) -> Nil {
  case head == expected, ffi_ci_environment() {
    True, _ -> Nil
    False, True -> head |> should.equal(expected)
    False, False ->
      io.println_error(
        "warning: "
        <> name
        <> " head "
        <> head
        <> " differs from pin "
        <> expected
        <> " (local checkout; enforced in CI)",
      )
  }
}

pub fn sibling_blueprint_pin_test() {
  // Sibling git head
  let head = ffi_git_head("../json_blueprint")
  let #(expected, _, _) = expected_sibling_heads()
  check_sibling_head("json_blueprint", head, expected)

  // Sibling package version and license
  let assert Ok(manifest_bytes) = ffi_read_file("../json_blueprint/gleam.toml")
  let assert Ok(manifest_str) = bit_array.to_string(manifest_bytes)
  string.contains(manifest_str, "version = \"1.7.1\"")
  |> should.be_true()
  string.contains(manifest_str, "licences = [\"MIT\"]")
  |> should.be_true()
}

pub fn sibling_sinal_pin_test() {
  // Sibling git head
  let head = ffi_git_head("../sinal")
  let #(_, expected, _) = expected_sibling_heads()
  check_sibling_head("sinal", head, expected)

  // Sibling package version
  let assert Ok(manifest_bytes) = ffi_read_file("../sinal/gleam.toml")
  let assert Ok(manifest_str) = bit_array.to_string(manifest_bytes)
  string.contains(manifest_str, "version = \"0.1.0\"")
  |> should.be_true()

  // Sibling license
  let assert Ok(lic_bytes) = ffi_read_file("../sinal/LICENSE")
  let assert Ok(lic_str) = bit_array.to_string(lic_bytes)
  string.contains(lic_str, "Apache")
  |> should.be_true()
}

pub fn sibling_http_gun_pin_test() {
  let head = ffi_git_head("../http_gun")
  let #(_, _, expected) = expected_sibling_heads()
  check_sibling_head("http_gun", head, expected)

  let assert Ok(manifest_bytes) = ffi_read_file("../http_gun/gleam.toml")
  let assert Ok(manifest_str) = bit_array.to_string(manifest_bytes)
  string.contains(manifest_str, "version = \"0.1.0\"")
  |> should.be_true()
  string.contains(manifest_str, "licences = [\"Apache-2.0\"]")
  |> should.be_true()
}
