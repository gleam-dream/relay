//// `Origin` allow-list matching for the HTTP endpoint. An origin is the
//// triple of scheme, host and effective port (RFC 6454): a missing port
//// stands for the scheme's default, so `http://localhost` admits
//// `http://localhost:80` but not `http://localhost:3000`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The origins admitted when the application configures none.
pub fn defaults() -> List(String) {
  ["http://localhost", "http://127.0.0.1", "http://[::1]"]
}

@external(erlang, "relay_url_ffi", "valid_ipv6")
fn valid_ipv6(address: String) -> Bool

@external(erlang, "relay_url_ffi", "loopback_bind_host")
fn loopback_bind_host(host: String) -> Bool

/// The listener's own origins on the bound `port`. A loopback bind admits
/// the bind host and the loopback names; a wildcard bind admits the
/// loopback names; any other bind admits only the bind host.
pub fn listener_origins(host: String, tls: Bool, port: Int) -> List(String) {
  let scheme = case tls {
    True -> "https://"
    False -> "http://"
  }
  let host = string.lowercase(host)
  let loopback = ["localhost", "127.0.0.1", "::1"]
  let hosts = case host {
    "0.0.0.0" | "::" | "0:0:0:0:0:0:0:0" -> loopback
    _ ->
      case loopback_bind_host(host) {
        True -> [host, ..loopback]
        False -> [host]
      }
  }
  hosts
  |> list.unique
  |> list.map(fn(host) {
    let host = case
      string.contains(host, ":") && !string.starts_with(host, "[")
    {
      True -> "[" <> host <> "]"
      False -> host
    }
    scheme <> host <> ":" <> int.to_string(port)
  })
}

/// Whether `origin` names the same scheme, host and effective port as an
/// entry of `allowed`. Matching is case-insensitive.
pub fn allowed(origin: String, allowed: List(String)) -> Bool {
  case parts(string.lowercase(origin)) {
    None -> False
    Some(origin) ->
      list.any(allowed, fn(candidate) {
        parts(string.lowercase(candidate)) == Some(origin)
      })
  }
}

fn parts(origin: String) -> Option(#(String, String, Option(Int))) {
  case string.split(origin, on: "://") {
    [scheme, authority] if scheme != "" && authority != "" ->
      case string.split(authority, on: "/") {
        [authority] ->
          case authority_port(authority), authority_host(authority) {
            Ok(port), Ok(host) ->
              Some(#(scheme, host, option.or(port, default_port(scheme))))
            _, _ -> None
          }
        _ -> None
      }
    _ -> None
  }
}

fn default_port(scheme: String) -> Option(Int) {
  case scheme {
    "http" -> Some(80)
    "https" -> Some(443)
    _ -> None
  }
}

// The explicit port of an authority, `None` when it names none, or an error
// when the text after the host is not a port.
fn authority_port(authority: String) -> Result(Option(Int), Nil) {
  let rest = case string.starts_with(authority, "[") {
    True ->
      case string.split_once(authority, on: "]") {
        Ok(#(_, rest)) -> Ok(rest)
        Error(Nil) -> Error(Nil)
      }
    False ->
      case string.split_once(authority, on: ":") {
        Ok(#(_, port)) -> Ok(":" <> port)
        Error(Nil) -> Ok("")
      }
  }
  use rest <- result.try(rest)
  case rest {
    "" -> Ok(None)
    ":" <> port ->
      case ascii_digits(port), int.parse(port) {
        True, Ok(port) if port <= 65_535 -> Ok(Some(port))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn ascii_digits(text: String) -> Bool {
  text != ""
  && string.length(text) <= 5
  && list.all(string.to_graphemes(text), fn(char) {
    string.contains("0123456789", char)
  })
}

// The host of an authority. A bracketed host must be an IPv6 address.
fn authority_host(authority: String) -> Result(String, Nil) {
  case string.starts_with(authority, "[") {
    True ->
      case string.split_once(string.drop_start(authority, 1), on: "]") {
        Ok(#(host, _)) ->
          case valid_ipv6(host) {
            True -> Ok(host)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    False ->
      case string.split_once(authority, on: ":") {
        Ok(#(host, _)) -> Ok(host)
        Error(Nil) -> Ok(authority)
      }
  }
}
