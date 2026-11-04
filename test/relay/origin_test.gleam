import gleeunit/should
import relay/internal/origin

pub fn bracketed_non_ipv6_host_is_refused_test() {
  origin.allowed("http://[::1]", origin.defaults()) |> should.be_true
  origin.allowed("http://[localhost]", origin.defaults()) |> should.be_false
  origin.allowed("http://[127.0.0.1]", origin.defaults()) |> should.be_false
  origin.allowed("http://localhost", ["http://[localhost]"])
  |> should.be_false
}

pub fn port_must_be_ascii_digits_test() {
  origin.allowed("http://localhost:80", origin.defaults()) |> should.be_true
  origin.allowed("http://localhost:+80", origin.defaults()) |> should.be_false
  origin.allowed("http://localhost:-0", origin.defaults()) |> should.be_false
  origin.allowed("http://[::1]:+80", origin.defaults()) |> should.be_false
  origin.allowed("http://localhost:", origin.defaults()) |> should.be_false
}

pub fn loopback_listener_admits_loopback_names_test() {
  origin.listener_origins("127.0.0.1", False, 8080)
  |> should.equal([
    "http://127.0.0.1:8080",
    "http://localhost:8080",
    "http://[::1]:8080",
  ])
  origin.listener_origins("::1", True, 8443)
  |> should.equal([
    "https://[::1]:8443",
    "https://localhost:8443",
    "https://127.0.0.1:8443",
  ])
}

pub fn wildcard_listener_admits_loopback_names_test() {
  origin.listener_origins("0.0.0.0", False, 8080)
  |> should.equal([
    "http://localhost:8080",
    "http://127.0.0.1:8080",
    "http://[::1]:8080",
  ])
  origin.listener_origins("::", False, 8080)
  |> should.equal([
    "http://localhost:8080",
    "http://127.0.0.1:8080",
    "http://[::1]:8080",
  ])
}

pub fn specific_listener_admits_only_its_bind_host_test() {
  origin.listener_origins("192.168.1.5", False, 8080)
  |> should.equal(["http://192.168.1.5:8080"])
  origin.listener_origins("fd00::5", False, 8080)
  |> should.equal(["http://[fd00::5]:8080"])
}
