//// Provenance: the frozen schema checksum.

import gleeunit/should

@external(erlang, "relay_ffi", "sha256_hex")
fn ffi_sha256_hex(bytes: BitArray) -> String

@external(erlang, "relay_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(BitArray, String)

pub fn mcp_frozen_schema_checksum_test() {
  let path = "test/fixtures/mcp_2026/schema.json.source"
  let assert Ok(bytes) = ffi_read_file(path)
  let digest = ffi_sha256_hex(bytes)
  digest
  |> should.equal(
    "ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203",
  )
}
