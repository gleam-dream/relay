//// The header value encoding of MCP 2026-07-28 for `Mcp-Name` and
//// `Mcp-Param-*`: a value travels as it is when it is a safe plain header
//// value, and as `=?base64?<Base64 of its UTF-8 bytes>?=` otherwise.

import gleam/bit_array
import gleam/string

const prefix = "=?base64?"

const suffix = "?="

/// The header value that carries `value`.
pub fn encode(value: String) -> String {
  case is_plain(value) && !is_sentinel(value) {
    True -> value
    False ->
      prefix
      <> bit_array.base64_encode(bit_array.from_string(value), True)
      <> suffix
  }
}

/// The value a header carries. A value in the Base64 form is decoded and
/// fails when its payload is not canonical Base64 of UTF-8 text; any other
/// value stands for itself.
pub fn decode(raw: String) -> Result(String, Nil) {
  case is_sentinel(raw) {
    True ->
      raw
      |> string.drop_start(string.length(prefix))
      |> string.drop_end(string.length(suffix))
      |> decode_base64_strict
    False -> Ok(raw)
  }
}

fn is_sentinel(value: String) -> Bool {
  string.starts_with(value, prefix) && string.ends_with(value, suffix)
}

// Visible ASCII, with spaces and tabs only between other characters.
fn is_plain(value: String) -> Bool {
  string.trim(value) == value && all_header_safe(<<value:utf8>>)
}

fn all_header_safe(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bits>>
      if byte >= 0x21 && byte <= 0x7E || byte == 0x20 || byte == 0x09
    -> all_header_safe(rest)
    _ -> False
  }
}

@external(erlang, "relay_ffi", "decode_base64_strict")
fn decode_base64_strict(encoded: String) -> Result(String, Nil)
