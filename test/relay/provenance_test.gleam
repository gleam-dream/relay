//// Provenance: the frozen schema checksum and the resolved Git dependency pins.

import gleam/bit_array
import gleam/string
import gleeunit/should

@external(erlang, "relay_ffi", "sha256_hex")
fn ffi_sha256_hex(bytes: BitArray) -> String

@external(erlang, "relay_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(BitArray, String)

@external(erlang, "relay_ffi", "git_head")
fn ffi_git_head(repo_path: String) -> String

pub fn mcp_frozen_schema_checksum_test() {
  let path = "test/fixtures/mcp_2026/schema.json.source"
  let assert Ok(bytes) = ffi_read_file(path)
  let digest = ffi_sha256_hex(bytes)
  digest
  |> should.equal(
    "ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203",
  )
}

fn expected_dependency_heads() -> #(String, String, String) {
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

pub fn dependency_blueprint_pin_test() {
  // Resolved dependency git head
  let head = ffi_git_head("build/packages/json_blueprint")
  let #(expected, _, _) = expected_dependency_heads()
  head |> should.equal(expected)

  // Resolved dependency package version and license
  let assert Ok(manifest_bytes) =
    ffi_read_file("build/packages/json_blueprint/gleam.toml")
  let assert Ok(manifest_str) = bit_array.to_string(manifest_bytes)
  string.contains(manifest_str, "version = \"1.7.1\"")
  |> should.be_true()
  string.contains(manifest_str, "licences = [\"MIT\"]")
  |> should.be_true()
}

pub fn dependency_sinal_pin_test() {
  // Resolved dependency git head
  let head = ffi_git_head("build/packages/sinal")
  let #(_, expected, _) = expected_dependency_heads()
  head |> should.equal(expected)

  // Resolved dependency package version
  let assert Ok(manifest_bytes) =
    ffi_read_file("build/packages/sinal/gleam.toml")
  let assert Ok(manifest_str) = bit_array.to_string(manifest_bytes)
  string.contains(manifest_str, "version = \"0.1.0\"")
  |> should.be_true()

  // Resolved dependency license
  let assert Ok(lic_bytes) = ffi_read_file("build/packages/sinal/LICENSE")
  let assert Ok(lic_str) = bit_array.to_string(lic_bytes)
  string.contains(lic_str, "Apache")
  |> should.be_true()
}

pub fn dependency_http_gun_pin_test() {
  let head = ffi_git_head("build/packages/http_gun")
  let #(_, _, expected) = expected_dependency_heads()
  head |> should.equal(expected)

  let assert Ok(manifest_bytes) =
    ffi_read_file("build/packages/http_gun/gleam.toml")
  let assert Ok(manifest_str) = bit_array.to_string(manifest_bytes)
  string.contains(manifest_str, "version = \"0.1.0\"")
  |> should.be_true()
  string.contains(manifest_str, "licences = [\"Apache-2.0\"]")
  |> should.be_true()
}
