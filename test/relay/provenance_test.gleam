import gleam/bit_array
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

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

pub fn sibling_blueprint_pin_test() {
  // Sibling git head
  let head = ffi_git_head("../json_blueprint")
  head |> should.equal("d3f0708b61eddb4a4789c0476ab5384267814a51")

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
  head |> should.equal("dd09933e5466628f7d46fa896c389f31ba7d4cb6")

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
