import gleam/erlang/atom.{type Atom}
import relay/http
import relay/server

fn listener() -> fn() -> Nil {
  let assert Ok(endpoint) = http.start(http.new(server.new([])))
  fn() { http.stop(endpoint) }
}

@external(erlang, "relay_http_lifecycle_ffi", "intentional_stop")
fn intentional_stop(start: fn() -> fn() -> Nil) -> Nil

@external(erlang, "relay_http_lifecycle_ffi", "unexpected_listener_exit")
fn unexpected_listener_exit(start: fn() -> fn() -> Nil) -> Nil

@external(erlang, "relay_http_lifecycle_ffi", "stop_with_slow_listener")
fn stop_with_slow_listener(port: Int, stop: fn() -> Nil) -> Atom

pub fn stop_returns_only_after_the_listener_refuses_connections_test() {
  let assert Ok(endpoint) = http.start(http.new(server.new([])))
  let port = http.port(endpoint)
  let outcome = stop_with_slow_listener(port, fn() { http.stop(endpoint) })
  assert atom.to_string(outcome) == "refused"
}

pub fn intentional_listener_stop_keeps_its_caller_alive_test() {
  intentional_stop(listener)
}

pub fn unexpected_listener_exit_still_reaches_its_caller_test() {
  unexpected_listener_exit(listener)
}
