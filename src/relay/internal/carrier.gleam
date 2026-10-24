//// How a correlation and an idempotency key cross the wire between a Relay
//// client and server.
////
//// MCP `2026-07-28` defines no correlation or trace field, so Relay uses
//// two carriers of its own:
////
//// - the `_meta` key `io.github.gleam-dream/correlation` on every request,
////   which every transport carries; and
//// - the HTTP header `x-correlation-id`, which an HTTP endpoint reads
////   before it reads the body, so the authorization decision and the
////   verifier see the same value as the invocation.
////
//// A carried value is untrusted input: it is accepted only when it has 1
//// to 128 bytes, all visible ASCII (`!` to `~`), so it cannot inject
//// control characters, spaces or line breaks into logs. A correlation that
//// fails is ignored and the receiver uses a fresh one; an idempotency key
//// that fails refuses the request, because dropping it would silently turn
//// a retry into new work. The idempotency key travels in `_meta` under
//// `io.github.gleam-dream/idempotency-key`.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import sinal/correlation.{type Correlation}

/// The HTTP header that carries a correlation.
pub const header = "x-correlation-id"

/// The request `_meta` key that carries a correlation.
pub const meta_key = "io.github.gleam-dream/correlation"

/// The request `_meta` key that carries an idempotency key.
pub const idempotency_meta_key = "io.github.gleam-dream/idempotency-key"

/// The longest carried value, in bytes.
pub const max_bytes = 128

/// Whether a value may be carried: 1 to 128 visible ASCII bytes.
pub fn valid(raw: String) -> Bool {
  let bytes = bit_array.from_string(raw)
  let size = bit_array.byte_size(bytes)
  size >= 1 && size <= max_bytes && visible_ascii(bytes)
}

/// Accepts a carried correlation, or ignores it.
pub fn parse(raw: String) -> Option(Correlation) {
  case valid(raw) {
    False -> None
    True -> correlation.from_string(raw) |> option.from_result
  }
}

/// The correlation's text when a receiver would accept it.
pub fn sendable(value: Correlation) -> Option(String) {
  let text = correlation.to_string(value)
  case parse(text) {
    Some(_) -> Some(text)
    None -> None
  }
}

/// The correlation a JSON-RPC frame carries in `params._meta`, if any.
pub fn from_frame(bytes: BitArray) -> Option(Correlation) {
  bit_array.to_string(bytes)
  |> result.try(fn(text) {
    json.parse(text, decode.at(["params", "_meta", meta_key], decode.string))
    |> result.replace_error(Nil)
  })
  |> option.from_result
  |> option.then(parse)
}

/// The transport's correlation, else the frame's, else a fresh one.
pub fn resolve(transport: Option(Correlation), bytes: BitArray) -> Correlation {
  case transport {
    Some(value) -> value
    None -> option.lazy_unwrap(from_frame(bytes), correlation.unique)
  }
}

fn visible_ascii(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> if byte >= 0x21 && byte <= 0x7E -> visible_ascii(rest)
    _ -> False
  }
}
