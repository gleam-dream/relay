//// Codec shapes the tests share.

import json/blueprint/codec.{type Codec}

/// An object with one required property `name` holding `inner`.
pub fn property(name: String, inner: Codec(a)) -> Codec(a) {
  use value <- codec.field(name, inner, get: fn(value) { value })
  codec.success(value)
}
