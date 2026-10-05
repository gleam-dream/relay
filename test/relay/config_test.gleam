import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import relay/authorization
import relay/client
import relay/completion
import relay/content
import relay/http
import relay/prompts
import relay/reason_support
import relay/resources
import relay/server
import relay/testing
import relay/tool

@external(erlang, "relay_ffi", "rescue_run")
fn rescue(f: fn() -> a) -> Result(a, String)

@external(erlang, "relay_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

fn empty_server() -> server.Server(Nil) {
  server.new([])
}

fn message_input() -> codec.Codec(String) {
  use message <- codec.field("message", codec.string(), get: fn(message) {
    message
  })
  codec.success(message)
}

fn url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

fn connect_port(port: Int) -> client.Client {
  let assert Ok(config) = client.http(url(port))
  let assert Ok(peer) = client.connect(config)
  peer
}

// --- server description -------------------------------------------------------

pub fn service_modifiers_replace_lists_test() {
  let custom = tool.define("custom", message_input(), codec.string())
  let first =
    resources.static("memory://first", "first", fn(_context, uri) {
      Ok([content.text_resource(uri, "first")])
    })
  let second =
    resources.static("memory://second", "second", fn(_context, uri) {
      Ok([content.text_resource(uri, "second")])
    })
  let template =
    resources.template(
      "memory://second/{id}",
      "second template",
      fn(_context, uri) { Ok([content.text_resource(uri, "template")]) },
    )
  let prompt =
    prompts.prompt("p", [], fn(_context, _arguments) {
      Ok(prompts.PromptResult(None, [], []))
    })
  let configured =
    server.new([
      tool.handle_with_error_renderer(
        custom,
        fn(message) { Ok(message) },
        fn(_error: Nil) { tool.error_message("custom failure") },
      ),
    ])
    |> server.with_resources([first])
    |> server.with_prompts([prompt])
    |> server.with_resources([second, template])
  // The tools survive the modifiers in either order.
  server.tools(configured)
  |> list.map(fn(declaration) { declaration.name })
  |> should.equal(["custom"])

  let peer = testing.connect(configured, Nil)
  let assert Ok(listed) = client.list_resources(peer)
  list.map(listed, fn(resource) { resource.uri })
  |> should.equal(["memory://second"])
  let assert Ok(templates) = client.list_resource_templates(peer)
  list.map(templates, fn(template) { template.uri_template })
  |> should.equal(["memory://second/{id}"])
  let assert Ok(listed_prompts) = client.list_prompts(peer)
  list.map(listed_prompts, fn(prompt) { prompt.name }) |> should.equal(["p"])
  let assert Ok(discovery) = client.discover(peer)
  client.has_capability(discovery, "completions") |> should.be_false
  let assert Ok(client.Succeeded("hello", _)) =
    client.call(peer, custom, "hello")
  client.close(peer)

  // Unregistering a tool removes it from later calls.
  let without_tool = server.unregister_tool(configured, "custom")
  server.has_tool(without_tool, "custom") |> should.be_false
  let peer = testing.connect(without_tool, Nil)
  let assert Error(client.RpcError(code: -32_602, ..)) =
    client.call(peer, custom, "hello") |> reason_support.of
  client.close(peer)

  // A completion handler adds the completions capability.
  let with_completion =
    configured
    |> server.with_completion(
      completion.completion(fn(_context, request: completion.Request) {
        Ok(completion.values([request.value]))
      }),
    )
  let peer = testing.connect(with_completion, Nil)
  let assert Ok(discovery) = client.discover(peer)
  client.has_capability(discovery, "completions") |> should.be_true
  client.close(peer)
}

// --- client configuration -----------------------------------------------------

pub fn url_config_admits_only_supported_components_test() {
  [
    "http://",
    "ftp://localhost/",
    "http://user@localhost/",
    "http://localhost/?q=1",
    "http://localhost/#fragment",
    "http://localhost:0/",
    "http://localhost:65536/",
    "http://localhost:bad/",
    "http://localhost:/",
    "http://local host/",
    "http://[::1/",
    "http://[:::]/",
    "http://[::1]evil/",
    "http://localhost/has space",
    "http://localhost/%GG",
    "http://localhost/%A",
  ]
  |> list.each(fn(url) {
    client.http(url)
    |> refused
    |> should.equal(Ok(client.Url))
  })
  let assert Ok(_) = client.http("http://localhost")
  let assert Ok(_) = client.http("HTTP://localhost/")
  let assert Ok(_) = client.http("http://localhost:080/%61")
  let assert Ok(_) = client.http("https://[::1]:443/%61")
}

pub fn configured_http_lifecycle_test() {
  let assert Ok(running) = http.start(http.new(empty_server()))
  let assert Ok(config) = client.http(url(http.port(running)))
  let config =
    config
    |> client.with_timeout(duration.seconds(1))
    |> client.with_timeout(duration.seconds(3))
    |> client.with_max_response_bytes(65_536)
  let assert Ok(peer) = client.connect(config)
  let assert Ok(discovery) = client.discover(peer)
  discovery.supported_versions
  |> list.contains("2026-07-28")
  |> should.be_true
  client.close(peer)

  // connect validates every setting before it starts anything.
  client.connect(client.with_ca_cert_file(config, "ca.pem"))
  |> refused
  |> should.equal(Ok(client.CaCertFile))
  client.connect(client.with_timeout(config, duration.milliseconds(0)))
  |> refused
  |> should.equal(Ok(client.RequestTimeout))
  client.connect(client.with_connect_timeout(config, duration.milliseconds(0)))
  |> refused
  |> should.equal(Ok(client.ConnectTimeout))
  client.connect(client.with_max_response_bytes(config, 0))
  |> refused
  |> should.equal(Ok(client.MaxResponseBytes))
  client.connect(client.with_listing_limits(config, 0, 10))
  |> refused
  |> should.equal(Ok(client.ListingLimits))
  client.connect(client.with_listing_limits(config, 10, 0))
  |> refused
  |> should.equal(Ok(client.ListingLimits))
  client.connect(client.with_max_pending_calls(config, 0))
  |> refused
  |> should.equal(Ok(client.MaxPendingCalls))
  http.stop(running)
}

@external(erlang, "relay_http_ffi", "with_unlistened_port")
fn with_unlistened_port(callback: fn(Int) -> a) -> a

pub fn http_connect_is_lazy_test() {
  // Keep the port bound without listening through the whole call. This
  // avoids racing a stopped listener's socket closure or port reuse.
  use port <- with_unlistened_port
  let assert Ok(config) = client.http(url(port))
  let assert Ok(peer) =
    client.connect(client.with_connect_timeout(config, duration.seconds(1)))
  let assert Error(error) = client.discover(peer)
  client.reason(error) |> should.equal(client.ConnectFailed)
  client.evidence(error) |> should.equal(client.NotSent)
  client.close(peer)
}

pub fn stdio_config_validates_and_hides_its_command_test() {
  let config = client.stdio("/bin/echo", ["relay-secret-argument"])
  string.contains(string.inspect(config), "relay-secret-argument")
  |> should.be_false
  client.connect(client.with_max_pending_calls(config, 0))
  |> refused
  |> should.equal(Ok(client.MaxPendingCalls))
  client.connect(client.with_ca_cert_file(config, "ca.pem"))
  |> refused
  |> should.equal(Ok(client.CaCertFile))
  client.connect(client.with_timeout(config, duration.milliseconds(0)))
  |> refused
  |> should.equal(Ok(client.RequestTimeout))
}

// --- listener lifecycle -------------------------------------------------------

pub fn configured_https_lifecycle_and_invalid_listener_test() {
  let base = http.new(empty_server())
  http.start(http.with_bind(base, "", -1))
  |> should.equal(Error(http.InvalidConfig(http.BindHost)))
  http.start(http.with_bind(base, "127.0.0.1", -1))
  |> should.equal(Error(http.InvalidConfig(http.BindPort)))
  http.start(http.with_bind(base, "127.0.0.1", 65_536))
  |> should.equal(Error(http.InvalidConfig(http.BindPort)))
  http.start(http.with_tls(base, "", "key"))
  |> should.equal(Error(http.InvalidConfig(http.TlsFiles)))
  http.start(http.with_tls(base, "missing.crt", "missing.key"))
  |> should.equal(Error(http.InvalidConfig(http.TlsFiles)))
  http.start(http.with_bind(base, "bad host", 0))
  |> should.equal(Error(http.InvalidConfig(http.BindHost)))
  let assert Ok(running) =
    base
    |> http.with_tls(
      "test/fixtures/tls/localhost.crt",
      "test/fixtures/tls/localhost.key",
    )
    |> http.start()
  let assert Ok(config) =
    client.http(
      "https://localhost:" <> int.to_string(http.port(running)) <> "/",
    )
  let config = client.with_ca_cert_file(config, "test/fixtures/tls/root-ca.crt")
  let assert Ok(peer) = client.connect(config)
  let assert Ok(_) = client.discover(peer)
  client.close(peer)
  http.stop(running)
}

pub fn validate_reports_each_invalid_limit_test() {
  let base = http.new(empty_server())
  http.validate(base) |> should.equal(Ok(Nil))
  [
    #(http.with_max_body_bytes(base, 0), http.MaxBodyBytes),
    #(http.with_max_response_bytes(base, 0), http.MaxResponseBytes),
    #(
      http.with_request_timeout(base, duration.milliseconds(0)),
      http.RequestTimeout,
    ),
    #(
      http.with_cancellation_grace(base, duration.milliseconds(-1)),
      http.CancellationGrace,
    ),
    #(
      http.with_sse_keepalive(base, duration.milliseconds(-1)),
      http.SseKeepalive,
    ),
    #(http.with_allowed_hosts(base, []), http.AllowedHosts),
    #(http.with_max_concurrent_requests(base, 0), http.MaxConcurrentRequests),
    #(http.with_max_listen_streams(base, 0), http.MaxListenStreams),
    #(http.with_max_json_depth(base, 0), http.MaxJsonDepth),
  ]
  |> list.each(fn(entry) {
    let #(config, field) = entry
    http.validate(config) |> should.equal(Error(http.InvalidConfig(field)))
    // handler validates the same limits, binding nothing.
    let assert Error(http.InvalidConfig(refused)) = http.handler(config)
    refused |> should.equal(field)
    string.contains(
      http.describe_start_error(http.InvalidConfig(field)),
      "out of range",
    )
    |> should.be_true
  })
}

pub fn start_binds_loopback_with_an_ephemeral_port_test() {
  let assert Ok(first) = http.start(http.new(empty_server()))
  let assert Ok(second) = http.start(http.new(empty_server()))
  let first_port = http.port(first)
  let second_port = http.port(second)
  { first_port > 0 && second_port > 0 } |> should.be_true
  should.not_equal(first_port, second_port)
  let peer = connect_port(first_port)
  let assert Ok(_) = client.discover(peer)
  client.close(peer)
  http.stop(first)
  http.stop(second)

  // A stopped listener answers nothing.
  let peer = connect_port(first_port)
  let assert Error(_) = client.discover(peer)
  client.close(peer)
}

pub fn loopback_listener_starts_without_protection_test() {
  let base = http.new(empty_server())
  ["127.0.0.1", "127.0.0.2", "localhost", "::1"]
  |> list.each(fn(host) {
    http.with_bind(base, host, 0)
    |> http.validate
    |> should.equal(Ok(Nil))
  })
  let assert Ok(running) = http.start(http.with_bind(base, "127.0.0.1", 0))
  http.stop(running)
}

pub fn non_loopback_listener_without_protection_is_refused_test() {
  let base = http.new(empty_server())
  ["0.0.0.0", "::", "192.168.1.10", "10.0.0.1"]
  |> list.each(fn(host) {
    http.with_bind(base, host, 0)
    |> http.validate
    |> should.equal(Error(http.UnauthenticatedNonLoopbackBind(host: host)))
  })
  let assert Error(error) = http.start(http.with_bind(base, "0.0.0.0", 0))
  error |> should.equal(http.UnauthenticatedNonLoopbackBind(host: "0.0.0.0"))
  let message = http.describe_start_error(error)
  string.contains(message, "0.0.0.0") |> should.be_true
  string.contains(message, "http.allow_unauthenticated") |> should.be_true
  // A mounted handler binds nothing, so the bind host does not matter.
  let assert Ok(handler) = http.handler(http.with_bind(base, "0.0.0.0", 0))
  http.stop(handler)
}

pub fn non_loopback_listener_starts_with_explicit_opt_in_test() {
  let listener =
    http.new(empty_server())
    |> http.with_bind("0.0.0.0", 0)
    |> http.allow_unauthenticated
  http.validate(listener) |> should.equal(Ok(Nil))
  let assert Ok(running) = http.start(listener)
  let peer = connect_port(http.port(running))
  let assert Ok(_discovery) = client.discover(peer)
  client.close(peer)
  http.stop(running)
}

pub fn non_loopback_protected_listener_needs_no_opt_in_test() {
  let assert Ok(resource) =
    authorization.protected_resource("https://relay.example/mcp")
  authorization.protection(resource, [])
  |> http.new_protected(
    empty_server(),
    testing.verifier([]),
    _,
    fn(_request, _grant) { Ok(Nil) },
  )
  |> http.with_bind("0.0.0.0", 0)
  |> http.validate
  |> should.equal(Ok(Nil))
}

pub fn supervised_listener_is_reachable_by_name_test() {
  let name = process.new_name("relay_http_config_test")
  let assert Ok(started) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(http.supervised(http.new(empty_server()), name))
    |> supervisor.start
  let listener = http.named(name)
  let port = http.port(listener)
  { port > 0 } |> should.be_true
  let peer = connect_port(port)
  let assert Ok(_) = client.discover(peer)
  client.close(peer)
  process.unlink(started.pid)
  stop_supervisor(started.pid)
}

pub fn port_panics_for_a_mounted_handler_test() {
  let assert Ok(handler) = http.handler(http.new(empty_server()))
  let assert Error(_) = rescue(fn() { http.port(handler) })
  http.stop(handler)
}

// The setting a refused `http` or `connect` named; any other outcome is
// reported by name.
fn refused(
  outcome: Result(a, client.Error),
) -> Result(client.ConfigField, String) {
  case result.map_error(outcome, client.reason) {
    Error(client.InvalidConfig(field)) -> Ok(field)
    Error(_) -> Error("other failure")
    Ok(_) -> Error("accepted")
  }
}
