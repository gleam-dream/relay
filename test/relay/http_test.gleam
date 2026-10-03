import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http as gleam_http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import mist
import relay/client
import relay/content
import relay/http
import relay/resources
import relay/server
import relay/subscriptions
import relay/telemetry
import relay/testing
import relay/tool
import sinal
import sinal/correlation

// --- the raw HTTP client ------------------------------------------------------

@external(erlang, "relay_http_ffi", "request")
fn local_request(
  port: Int,
  method: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(#(Int, List(#(String, String)), BitArray), String)

@external(erlang, "relay_http_ffi", "disconnect_after_first_sse_event")
fn disconnect_after_first_sse_event(
  port: Int,
  method: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Int, String)

@external(erlang, "relay_http_ffi", "send_and_hold")
fn send_and_hold(
  port: Int,
  method: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(HeldConnection, String)

@external(erlang, "relay_http_ffi", "read_until")
fn read_until(
  connection: HeldConnection,
  needle: BitArray,
  timeout_ms: Int,
) -> Result(BitArray, String)

@external(erlang, "relay_http_ffi", "abort_connection")
fn abort_connection(connection: HeldConnection) -> BitArray

@external(erlang, "relay_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

type HeldConnection

type SlowNotice {
  SlowStarted(process.Pid)
  SlowFinished
}

type ProgressNotice {
  ProgressBurstStarted(process.Pid)
  ProgressBurstFinished
}

// --- shared helpers -----------------------------------------------------------

fn envelope(
  method: String,
  with_id: Bool,
  params: List(#(String, json.Json)),
) -> BitArray {
  envelope_with_protocol(method, with_id, params, "2026-07-28")
}

fn envelope_with_protocol(
  method: String,
  with_id: Bool,
  params: List(#(String, json.Json)),
  protocol_version: String,
) -> BitArray {
  envelope_with_meta(method, with_id, params, protocol_version, [])
}

fn envelope_with_meta(
  method: String,
  with_id: Bool,
  params: List(#(String, json.Json)),
  protocol_version: String,
  extra_meta: List(#(String, json.Json)),
) -> BitArray {
  let metadata =
    json.object([
      #(
        "io.modelcontextprotocol/protocolVersion",
        json.string(protocol_version),
      ),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
      ..extra_meta
    ])
  let request_fields = [
    #("jsonrpc", json.string("2.0")),
    #("method", json.string(method)),
    #("params", json.object([#("_meta", metadata), ..params])),
  ]
  let request_fields = case with_id {
    True -> list.append(request_fields, [#("id", json.int(7))])
    False -> request_fields
  }
  json.object(request_fields)
  |> json.to_string()
  |> bit_array.from_string()
}

fn headers_with_protocol(
  method: String,
  accept: String,
  protocol_version: String,
) -> List(#(String, String)) {
  [
    #("Accept", accept),
    #("MCP-Protocol-Version", protocol_version),
    #("Mcp-Method", method),
  ]
}

fn headers(method: String, accept: String) -> List(#(String, String)) {
  [
    #("Accept", accept),
    #("mCp-pRoToCoL-vErSiOn", "2026-07-28"),
    #("McP-MeThOd", method),
  ]
}

fn headers_with_name(
  method: String,
  name: String,
  accept: String,
) -> List(#(String, String)) {
  [#("Mcp-Name", name), ..headers(method, accept)]
}

fn text(bytes: BitArray) -> String {
  bit_array.to_string(bytes) |> result.unwrap("")
}

fn no_input() -> codec.Codec(Nil) {
  codec.success(Nil)
}

fn text_input() -> codec.Codec(String) {
  use text <- codec.field("text", codec.string(), get: fn(text) { text })
  codec.success(text)
}

fn echo_definition() -> tool.Definition(String, String) {
  tool.define("echo", text_input(), codec.string())
}

fn echo_tool() -> tool.Tool(context) {
  tool.handle(echo_definition(), fn(text) { Ok(text) })
}

fn empty_server() -> server.Server(Nil) {
  server.new([])
}

fn echo_server() -> server.Server(Nil) {
  server.new([echo_tool()])
}

fn mounted(config: http.Config(context)) -> http.Handler(context) {
  let assert Ok(handler) = http.handler(config)
  handler
}

fn started(config: http.Config(context)) -> http.Handler(context) {
  let assert Ok(listener) = http.start(config)
  listener
}

fn connect(listener: http.Handler(context)) -> client.Client {
  connect_port(http.port(listener))
}

fn connect_port(port: Int) -> client.Client {
  let assert Ok(config) =
    client.http("http://127.0.0.1:" <> int.to_string(port) <> "/")
  let assert Ok(peer) = client.connect(config)
  peer
}

fn echo_call(text: String) -> request.Request(BitArray) {
  testing.request("tools/call", [
    #("name", json.string("echo")),
    #("arguments", json.object([#("text", json.string(text))])),
  ])
}

fn listen_params() -> List(#(String, json.Json)) {
  [#("notifications", json.object([#("toolsListChanged", json.bool(True))]))]
}

fn worker_exits_within(worker: process.Pid, attempts: Int) -> Bool {
  case process.is_alive(worker) {
    False -> True
    True ->
      case attempts <= 0 {
        True -> False
        False -> {
          process.sleep(10)
          worker_exits_within(worker, attempts - 1)
        }
      }
  }
}

fn index_of(haystack: String, needle: String) -> Int {
  case string.split_once(haystack, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
}

fn observe_rejections() -> #(
  process.Subject(telemetry.HttpRejectedMeta),
  sinal.Attachment,
) {
  let rejected = process.new_subject()
  let attachment =
    sinal.observe(telemetry.http_rejected_event(), fn(_, meta) {
      process.send(rejected, meta)
    })
  #(rejected, attachment)
}

fn receive_rejection(
  rejected: process.Subject(telemetry.HttpRejectedMeta),
  reason: telemetry.RejectReason,
) -> telemetry.HttpRejectedMeta {
  let assert Ok(meta) = process.receive(rejected, 1000)
  case meta.reason == reason {
    True -> meta
    False -> receive_rejection(rejected, reason)
  }
}

// --- the listener on the wire -------------------------------------------------

pub fn invalid_keepalive_rejected_before_listener_start_test() {
  http.new(empty_server())
  |> http.with_sse_keepalive(duration.milliseconds(0))
  |> http.start()
  |> should.equal(Error(http.InvalidConfig(http.SseKeepalive)))
}

pub fn streamable_http_loopback_test() {
  let listener =
    http.new(empty_server())
    |> http.with_max_body_bytes(512)
    |> http.with_max_response_bytes(4096)
    |> http.with_request_timeout(duration.seconds(2))
    |> http.with_allowed_hosts(["127.0.0.1"])
    |> http.with_allowed_origins(["http://127.0.0.1"])
    |> started
  let port = http.port(listener)
  let body = envelope("server/discover", True, [])
  let assert Ok(#(200, response_headers, response_body)) =
    local_request(
      port,
      "post",
      headers("server/discover", "application/json"),
      body,
    )
  should.be_true(string.contains(text(response_body), "supportedVersions"))
  should.equal(
    list.key_find(response_headers, "mcp-protocol-version"),
    Ok("2026-07-28"),
  )
  should.equal(
    list.key_find(response_headers, "content-type"),
    Ok("application/json"),
  )

  // The routing headers must match the body.
  let assert Ok(#(400, _, _)) =
    local_request(port, "post", headers("tools/list", "application/json"), body)
  let assert Ok(#(400, _, mismatched_method_body)) =
    local_request(
      port,
      "post",
      headers("server/ping", "application/json"),
      body,
    )
  should.be_true(string.contains(text(mismatched_method_body), "-32020"))

  let unsupported_body =
    envelope_with_protocol("server/discover", True, [], "2099-01-01")
  let assert Ok(#(400, _, unsupported_response)) =
    local_request(
      port,
      "post",
      headers_with_protocol("server/discover", "application/json", "2099-01-01"),
      unsupported_body,
    )
  should.be_true(string.contains(text(unsupported_response), "-32022"))

  let version_mismatch_body =
    envelope_with_protocol("server/discover", True, [], "2025-11-25")
  let assert Ok(#(400, _, version_mismatch_response)) =
    local_request(
      port,
      "post",
      headers("server/discover", "application/json"),
      version_mismatch_body,
    )
  should.be_true(string.contains(text(version_mismatch_response), "-32020"))

  let unknown_method_body = envelope("testing/removed-method", True, [])
  let assert Ok(#(404, _, unknown_method_response)) =
    local_request(
      port,
      "post",
      headers("testing/removed-method", "application/json"),
      unknown_method_body,
    )
  should.be_true(string.contains(text(unknown_method_response), "-32601"))

  // resources/read and prompts/get need a matching Mcp-Name header.
  let resource_read =
    envelope("resources/read", True, [
      #("uri", json.string("memory://missing/1")),
    ])
  let assert Ok(#(400, _, _)) =
    local_request(
      port,
      "post",
      headers("resources/read", "application/json"),
      resource_read,
    )
  let assert Ok(#(400, _, _)) =
    local_request(
      port,
      "post",
      headers_with_name(
        "resources/read",
        "memory://different/1",
        "application/json",
      ),
      resource_read,
    )
  let assert Ok(#(200, _, missing_resource)) =
    local_request(
      port,
      "post",
      headers_with_name(
        "resources/read",
        "memory://missing/1",
        "application/json",
      ),
      resource_read,
    )
  should.be_true(string.contains(text(missing_resource), "-32002"))
  let prompt_get =
    envelope("prompts/get", True, [
      #("name", json.string("missing")),
      #("arguments", json.object([])),
    ])
  let assert Ok(#(400, _, _)) =
    local_request(
      port,
      "post",
      headers("prompts/get", "application/json"),
      prompt_get,
    )
  let assert Ok(#(200, _, missing_prompt)) =
    local_request(
      port,
      "post",
      headers_with_name("prompts/get", "missing", "application/json"),
      prompt_get,
    )
  should.be_true(string.contains(text(missing_prompt), "\"error\""))

  // Origin and Host allow-lists.
  let assert Ok(#(403, _, _)) =
    local_request(
      port,
      "post",
      [
        #("Origin", "http://attacker.invalid"),
        ..headers("server/discover", "application/json")
      ],
      body,
    )
  let assert Ok(#(403, _, _)) =
    local_request(
      port,
      "post",
      [
        #("Host", "rebound.invalid"),
        ..headers("server/discover", "application/json")
      ],
      body,
    )
  let assert Ok(#(405, put_headers, _)) =
    local_request(
      port,
      "put",
      headers("server/discover", "application/json"),
      body,
    )
  should.equal(list.key_find(put_headers, "allow"), Ok("POST"))
  let assert Ok(#(406, _, _)) =
    local_request(
      port,
      "post",
      headers("server/discover", "application/json;q=0, text/event-stream;q=0"),
      body,
    )

  // An immediate answer is JSON even when the client accepts SSE.
  let assert Ok(#(200, sse_headers, sse_body)) =
    local_request(
      port,
      "post",
      headers("server/discover", "text/event-stream"),
      body,
    )
  should.equal(
    list.key_find(sse_headers, "content-type"),
    Ok("application/json"),
  )
  should.be_true(string.contains(text(sse_body), "supportedVersions"))

  let oversized =
    json.string(string.repeat("x", 600))
    |> json.to_string
    |> bit_array.from_string
  let assert Ok(#(413, _, _)) =
    local_request(
      port,
      "post",
      headers("server/discover", "application/json"),
      oversized,
    )
  let notification =
    envelope("notifications/cancelled", False, [#("requestId", json.int(8))])
  let assert Ok(#(202, _, empty_body)) =
    local_request(
      port,
      "post",
      headers("notifications/cancelled", "application/json"),
      notification,
    )
  should.equal(bit_array.byte_size(empty_body), 0)
  http.stop(listener)
}

pub fn response_over_the_limit_is_not_sent_test() {
  let listener =
    http.new(empty_server())
    |> http.with_max_response_bytes(1)
    |> started
  let assert Ok(#(status, _, capped_body)) =
    local_request(
      http.port(listener),
      "post",
      headers("server/discover", "application/json, text/event-stream"),
      envelope("server/discover", True, []),
    )
  should.not_equal(status, 200)
  string.contains(text(capped_body), "supportedVersions") |> should.be_false
  http.stop(listener)
}

pub fn live_sse_progress_burst_disconnect_cancels_worker_test() {
  let notices = process.new_subject()
  let listener =
    http.new_with_context(burst_progress_server(), fn(_) { Ok(notices) })
    // Long enough that only the disconnect, never the invocation timeout,
    // can end the worker within the wait below. The handler ignores the
    // cancellation, so it is killed when the short grace ends.
    |> http.with_request_timeout(duration.seconds(10))
    |> http.with_cancellation_grace(duration.milliseconds(100))
    |> started
  let assert Ok(200) =
    disconnect_after_first_sse_event(
      http.port(listener),
      "POST",
      [
        #("Accept", "application/json, text/event-stream"),
        #("MCP-Protocol-Version", "2026-07-28"),
        #("Mcp-Method", "tools/call"),
        #("Mcp-Name", "disconnect_probe"),
      ],
      progress_call_envelope("disconnect_probe"),
    )
  let assert Ok(ProgressBurstStarted(worker)) = process.receive(notices, 1000)
  should.be_true(worker_exits_within(worker, 100))
  case process.receive(notices, 0) {
    Ok(ProgressBurstFinished) -> should.fail()
    Ok(ProgressBurstStarted(_)) -> should.fail()
    Error(Nil) -> Nil
  }
  http.stop(listener)
}

/// Streamable HTTP cancels a request when its client disconnects. A buffered
/// JSON call writes nothing until it finishes, so the listener must notice the
/// closed socket itself, cancel the invocation, and write no result.
pub fn buffered_call_disconnect_cancels_worker_test() {
  let notices = process.new_subject()
  let cancelled = process.new_subject()
  let attachment =
    sinal.observe(telemetry.invocation_cancelled_event(), fn(_, meta) {
      process.send(cancelled, meta)
    })
  let listener =
    http.new_with_context(slow_server(), fn(_) { Ok(notices) })
    |> http.with_request_timeout(duration.seconds(5))
    // The handler ignores the cancellation: it is killed when the grace
    // ends, well before it would finish.
    |> http.with_cancellation_grace(duration.milliseconds(100))
    |> started
  let body =
    envelope("tools/call", True, [
      #("name", json.string("slow_probe")),
      #("arguments", json.object([])),
    ])
  let assert Ok(connection) =
    send_and_hold(
      http.port(listener),
      "POST",
      headers_with_name("tools/call", "slow_probe", "application/json"),
      body,
    )
  let assert Ok(SlowStarted(worker)) = process.receive(notices, 1000)
  // No response has been written while the call runs.
  let written = abort_connection(connection)
  let stopped = worker_exits_within(worker, 100)
  // Without cancellation the worker would outlive this test and emit
  // telemetry into later ones, so stop it before asserting.
  case stopped {
    True -> Nil
    False -> process.kill(worker)
  }
  let cancellation = process.receive(cancelled, 1000)
  let assert Ok(Nil) = sinal.detach(attachment)
  http.stop(listener)
  should.equal(written, <<>>)
  should.be_true(stopped)
  let assert Ok(meta) = cancellation
  meta.method |> should.equal("tools/call")
  meta.tool |> should.equal(Some("slow_probe"))
  // The handler never finished, so no result was produced for the call.
  should.equal(process.receive(notices, 300), Error(Nil))
}

type DownstreamNotice {
  DownstreamStarted(process.Pid)
  DownstreamCancelConfirmed
}

/// TH-3: a handler that started work elsewhere cancels it when its
/// `tool.cancelled` selector fires. After an HTTP disconnect it keeps the
/// cancellation grace, so the cancellation is confirmed before Relay could
/// kill the handler.
pub fn disconnect_gives_the_cancelled_handler_its_grace_test() {
  let notices = process.new_subject()
  let listener =
    http.new_with_context(downstream_server(), fn(_) { Ok(notices) })
    |> http.with_request_timeout(duration.seconds(10))
    |> started
  let body =
    envelope("tools/call", True, [
      #("name", json.string("downstream_probe")),
      #("arguments", json.object([])),
    ])
  let assert Ok(connection) =
    send_and_hold(
      http.port(listener),
      "POST",
      headers_with_name("tools/call", "downstream_probe", "application/json"),
      body,
    )
  let assert Ok(DownstreamStarted(worker)) = process.receive(notices, 1000)
  let monitor = process.monitor(worker)
  let written = abort_connection(connection)
  let confirmed = process.receive(notices, 2000)
  let exit =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down.reason })
    |> process.selector_receive(2000)
  http.stop(listener)
  should.equal(written, <<>>)
  confirmed |> should.equal(Ok(DownstreamCancelConfirmed))
  // The handler returned on its own; Relay did not kill it.
  exit |> should.equal(Ok(process.Normal))
}

fn downstream_server() -> server.Server(process.Subject(DownstreamNotice)) {
  let probe =
    tool.define("downstream_probe", no_input(), no_input())
    |> tool.handle_call(fn(call, _input) {
      let notices = tool.context(call)
      // The work started elsewhere: a process that takes 200 ms to stop
      // once asked, then confirms.
      let handshake = process.new_subject()
      let _ =
        process.spawn_unlinked(fn() {
          let inbox = process.new_subject()
          process.send(handshake, inbox)
          case process.receive(inbox, 10_000) {
            Ok(confirm) -> {
              process.sleep(200)
              process.send(confirm, Nil)
            }
            Error(Nil) -> Nil
          }
        })
      let assert Ok(downstream) = process.receive(handshake, 1000)
      process.send(notices, DownstreamStarted(process.self()))
      case process.selector_receive(tool.cancelled(call), 10_000) {
        Ok(Nil) -> {
          let confirm = process.new_subject()
          process.send(downstream, confirm)
          case process.receive(confirm, 2000) {
            Ok(Nil) -> process.send(notices, DownstreamCancelConfirmed)
            Error(Nil) -> Nil
          }
        }
        Error(Nil) -> Nil
      }
      Ok(tool.complete(Nil))
    })
  server.new([probe])
}

fn slow_server() -> server.Server(process.Subject(SlowNotice)) {
  let slow_tool =
    tool.define("slow_probe", no_input(), no_input())
    |> tool.handle_call(fn(call, _input) {
      let notices = tool.context(call)
      process.send(notices, SlowStarted(process.self()))
      process.sleep(2000)
      process.send(notices, SlowFinished)
      Ok(tool.complete(Nil))
    })
  server.new([slow_tool])
}

fn progress_call_envelope(name: String) -> BitArray {
  envelope_with_meta(
    "tools/call",
    True,
    [#("name", json.string(name)), #("arguments", json.object([]))],
    "2026-07-28",
    [#("progressToken", json.int(1))],
  )
}

fn burst_progress_server() -> server.Server(process.Subject(ProgressNotice)) {
  let burst =
    tool.define("disconnect_probe", no_input(), no_input())
    |> tool.handle_call(fn(call, _input) {
      let notices = tool.context(call)
      process.send(notices, ProgressBurstStarted(process.self()))
      report_progress_burst(call, notices, 1, 100_000)
      Ok(tool.complete(Nil))
    })
  server.new([burst])
}

fn report_progress_burst(
  call: tool.Call(context),
  notices: process.Subject(ProgressNotice),
  current: Int,
  last: Int,
) -> Nil {
  case current > last {
    True -> process.send(notices, ProgressBurstFinished)
    False -> {
      tool.report_progress(call, int.to_float(current), None, None)
      report_progress_burst(call, notices, current + 1, last)
    }
  }
}

// --- server-sent events -------------------------------------------------------

pub fn progress_streams_events_before_the_result_test() {
  let progress =
    tool.define("progress", no_input(), no_input())
    |> tool.handle_call(fn(call, _input) {
      tool.report_progress(call, 1.0, Some(2.0), Some("half way"))
      tool.report_progress(call, 2.0, Some(2.0), None)
      process.sleep(50)
      Ok(tool.complete(Nil))
    })
  let listener = started(http.new(server.new([progress])))
  let assert Ok(#(200, response_headers, body)) =
    local_request(
      http.port(listener),
      "post",
      headers_with_name(
        "tools/call",
        "progress",
        "application/json, text/event-stream",
      ),
      progress_call_envelope("progress"),
    )
  http.stop(listener)
  list.key_find(response_headers, "content-type")
  |> should.equal(Ok("text/event-stream"))
  list.key_find(response_headers, "transfer-encoding")
  |> should.equal(Ok("chunked"))
  list.key_find(response_headers, "connection") |> should.equal(Ok("close"))
  let body = text(body)
  let events =
    string.split(body, "\n\n")
    |> list.filter(fn(event) { event != "" })
  list.length(events) |> should.equal(3)
  list.all(events, string.starts_with(_, "data: ")) |> should.be_true
  let assert [first, second, last] = events
  string.contains(first, "notifications/progress") |> should.be_true
  string.contains(first, "half way") |> should.be_true
  string.contains(second, "notifications/progress") |> should.be_true
  string.contains(last, "\"result\"") |> should.be_true
  { index_of(body, "notifications/progress") < index_of(body, "\"result\"") }
  |> should.be_true
}

pub fn idle_listen_stream_writes_keepalive_comments_test() {
  let listener =
    http.new(echo_server())
    |> http.with_sse_keepalive(duration.milliseconds(30))
    |> started
  let assert Ok(connection) =
    send_and_hold(
      http.port(listener),
      "POST",
      headers("subscriptions/listen", "text/event-stream"),
      envelope("subscriptions/listen", True, listen_params()),
    )
  let assert Ok(head) =
    read_until(connection, <<"notifications/subscriptions/acknowledged">>, 2000)
  string.contains(text(head), "text/event-stream") |> should.be_true
  let assert Ok(_) = read_until(connection, <<": keepalive\n\n">>, 1000)
  let assert Ok(_) = read_until(connection, <<": keepalive\n\n">>, 1000)
  let _ = abort_connection(connection)
  http.stop(listener)
}

// --- the mountable handler ----------------------------------------------------

pub fn mounted_handler_answers_mcp_requests_test() {
  let handler = mounted(http.new(echo_server()))

  let call = http.handle(handler, echo_call("hello"))
  call.status |> should.equal(200)
  response.get_header(call, "content-type")
  |> should.equal(Ok("application/json"))
  response.get_header(call, "mcp-protocol-version")
  |> should.equal(Ok("2026-07-28"))
  let body = testing.body_text(call)
  string.contains(body, "\"result\"") |> should.be_true
  string.contains(body, "hello") |> should.be_true

  let listing = http.handle(handler, testing.request("tools/list", []))
  listing.status |> should.equal(200)
  string.contains(testing.body_text(listing), "\"echo\"") |> should.be_true

  let notification =
    http.handle(
      handler,
      testing.request("notifications/cancelled", [
        #("requestId", json.string("unknown")),
      ]),
    )
  notification.status |> should.equal(202)
  testing.body_text(notification) |> should.equal("")
}

pub fn mounted_handler_refuses_bad_requests_test() {
  let handler =
    mounted(http.new(echo_server()) |> http.with_max_body_bytes(256))

  let get =
    http.handle(handler, echo_call("x") |> request.set_method(gleam_http.Get))
  get.status |> should.equal(405)
  response.get_header(get, "allow") |> should.equal(Ok("POST"))

  let wrong_type =
    http.handle(
      handler,
      echo_call("x") |> request.set_header("content-type", "text/plain"),
    )
  wrong_type.status |> should.equal(415)

  let wrong_accept =
    http.handle(
      handler,
      echo_call("x") |> request.set_header("accept", "text/html"),
    )
  wrong_accept.status |> should.equal(406)

  let wrong_host =
    http.handle(handler, echo_call("x") |> request.set_host("evil.example"))
  wrong_host.status |> should.equal(403)

  let too_large = http.handle(handler, echo_call(string.repeat("x", 300)))
  too_large.status |> should.equal(413)

  let mismatch =
    http.handle(
      handler,
      echo_call("x") |> request.set_header("mcp-name", "another"),
    )
  mismatch.status |> should.equal(400)
  string.contains(testing.body_text(mismatch), "-32020") |> should.be_true

  // handle cannot stream, so it refuses subscriptions/listen.
  let listen =
    http.handle(
      handler,
      testing.request("subscriptions/listen", listen_params()),
    )
  listen.status |> should.equal(406)
}

fn nested(depth: Int) -> json.Json {
  case depth {
    0 -> json.int(1)
    _ -> json.preprocessed_array([nested(depth - 1)])
  }
}

pub fn mounted_handler_refuses_deep_json_test() {
  let handler = mounted(http.new(echo_server()))
  let deep =
    testing.request("tools/call", [
      #("name", json.string("echo")),
      #("arguments", json.object([#("text", nested(70))])),
    ])
  let response = http.handle(handler, deep)
  response.status |> should.equal(400)
  string.contains(testing.body_text(response), "-32600") |> should.be_true

  // Within the depth limit, the same shape reaches the server.
  let shallow =
    testing.request("tools/call", [
      #("name", json.string("echo")),
      #("arguments", json.object([#("text", nested(10))])),
    ])
  let response = http.handle(handler, shallow)
  response.status |> should.equal(200)
  string.contains(testing.body_text(response), "-32602") |> should.be_true
}

pub fn context_builder_sees_the_request_test() {
  let invoked = process.new_subject()
  let whoami =
    tool.define("whoami", no_input(), codec.string())
    |> tool.handle_call(fn(call, _input) {
      process.send(invoked, Nil)
      Ok(tool.complete("tenant " <> tool.context(call)))
    })
  let handler =
    http.new_with_context(server.new([whoami]), fn(request) {
      case request.get_header(request, "x-tenant") {
        Ok(tenant) -> Ok(tenant)
        Error(Nil) ->
          Error(
            response.new(418)
            |> response.set_header("x-refused", "no-tenant")
            |> response.set_body(bytes_tree.from_string("no tenant")),
          )
      }
    })
    |> mounted
  let call =
    testing.request("tools/call", [
      #("name", json.string("whoami")),
      #("arguments", json.object([])),
    ])

  let answered =
    http.handle(handler, request.set_header(call, "x-tenant", "acme"))
  answered.status |> should.equal(200)
  string.contains(testing.body_text(answered), "tenant acme") |> should.be_true
  process.receive(invoked, 1000) |> should.equal(Ok(Nil))

  // The builder's response is returned as is and the server never runs.
  let refused = http.handle(handler, call)
  refused.status |> should.equal(418)
  response.get_header(refused, "x-refused") |> should.equal(Ok("no-tenant"))
  testing.body_text(refused) |> should.equal("no tenant")
  process.receive(invoked, 100) |> should.equal(Error(Nil))
}

// --- request and stream caps --------------------------------------------------

fn gated_tool(
  entered: process.Subject(process.Subject(Nil)),
) -> tool.Tool(context) {
  tool.define("gated", no_input(), no_input())
  |> tool.handle_call(fn(call, _input) {
    let release = process.new_subject()
    process.send(entered, release)
    let _ =
      process.new_selector()
      |> process.select(release)
      |> process.merge_selector(tool.cancelled(call))
      |> process.selector_receive(5000)
    Ok(tool.complete(Nil))
  })
}

pub fn requests_beyond_the_concurrency_cap_get_503_test() {
  let entered = process.new_subject()
  let handler =
    http.new(server.new([gated_tool(entered)]))
    |> http.with_max_concurrent_requests(1)
    |> mounted
  let #(rejected, attachment) = observe_rejections()
  let results = process.new_subject()
  let gated =
    testing.request("tools/call", [
      #("name", json.string("gated")),
      #("arguments", json.object([])),
    ])
  process.spawn(fn() { process.send(results, http.handle(handler, gated)) })
  let assert Ok(release) = process.receive(entered, 1000)

  let busy = http.handle(handler, testing.request("tools/list", []))
  busy.status |> should.equal(503)
  response.get_header(busy, "retry-after") |> should.equal(Ok("1"))
  let meta = receive_rejection(rejected, telemetry.TooManyRequests)
  meta.status |> should.equal(503)
  let assert Ok(Nil) = sinal.detach(attachment)

  // The slot is released when the first request ends.
  process.send(release, Nil)
  let assert Ok(first) = process.receive(results, 2000)
  first.status |> should.equal(200)
  let later = http.handle(handler, testing.request("tools/list", []))
  later.status |> should.equal(200)
}

fn listen_eventually(
  peer: client.Client,
  attempts: Int,
) -> Result(client.Subscription, client.Error) {
  case client.listen(peer, [subscriptions.ToolsListChanged]) {
    Ok(subscription) -> Ok(subscription)
    Error(error) ->
      case attempts <= 0 {
        True -> Error(error)
        False -> {
          process.sleep(20)
          listen_eventually(peer, attempts - 1)
        }
      }
  }
}

pub fn listen_streams_beyond_the_cap_get_503_test() {
  let listener =
    http.new(echo_server())
    |> http.with_max_listen_streams(1)
    |> http.with_sse_keepalive(duration.milliseconds(20))
    |> started
  let peer = connect(listener)
  let #(rejected, attachment) = observe_rejections()
  let assert Ok(first) = client.listen(peer, [subscriptions.ToolsListChanged])

  let assert Error(client.HttpStatus(503, _)) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  let meta = receive_rejection(rejected, telemetry.TooManyStreams)
  meta.status |> should.equal(503)
  let assert Ok(Nil) = sinal.detach(attachment)

  // Ordinary requests still run while the stream is open.
  let assert Ok(client.Succeeded("still served", _)) =
    client.call(peer, echo_definition(), "still served")

  // Closing the stream frees its slot once the next keepalive fails.
  client.close_subscription(first)
  let assert Ok(second) = listen_eventually(peer, 50)
  client.close_subscription(second)
  client.close(peer)
  http.stop(listener)
}

// --- mounting in an application's mist server ---------------------------------

pub fn mist_handler_serves_mcp_with_streaming_test() {
  let readme =
    resources.static("memo://readme", "Readme", fn(_context, uri) {
      Ok([content.text_resource(uri, "Hello")])
    })
  let handler =
    http.new(echo_server() |> server.with_resources([readme])) |> mounted
  let ports = process.new_subject()
  let assert Ok(application) =
    mist.new(http.mist_handler(handler))
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _interface) {
      process.send(ports, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(ports, 2000)
  let peer = connect_port(port)

  let assert Ok(discovery) = client.discover(peer)
  discovery.supported_versions |> list.contains("2026-07-28") |> should.be_true
  let assert Ok(client.Succeeded("mounted", _)) =
    client.call(peer, echo_definition(), "mounted")

  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ResourceUpdated("memo://readme")])
  http.notify(handler, subscriptions.ResourceUpdated("memo://readme"))
  client.next_notification(subscription, duration.seconds(2))
  |> should.equal(Ok(Some(subscriptions.ResourceUpdated("memo://readme"))))
  client.close_subscription(subscription)
  client.close(peer)
  process.unlink(application.pid)
  stop_supervisor(application.pid)
  http.stop(handler)
}

// --- dynamic registration -----------------------------------------------------

fn tool_names(peer: client.Client) -> List(String) {
  let assert Ok(declarations) = client.list_tools(peer)
  list.map(declarations, fn(declaration) { declaration.name })
}

pub fn registration_changes_listings_and_notifies_streams_test() {
  let readme =
    resources.static("memo://readme", "Readme", fn(_context, uri) {
      Ok([content.text_resource(uri, "Hello")])
    })
  let listener =
    http.new(echo_server() |> server.with_resources([readme])) |> started
  let peer = connect(listener)
  let assert Ok(subscription) =
    client.listen(peer, [
      subscriptions.ToolsListChanged,
      subscriptions.ResourceUpdated("memo://readme"),
    ])
  let extra =
    tool.define("extra", no_input(), no_input())
    |> tool.handle(fn(_) { Ok(Nil) })

  http.register_tool(listener, extra) |> should.equal(Ok(Nil))
  http.register_tool(listener, extra)
  |> should.equal(Error(server.DuplicateTool("extra")))
  client.next_notification(subscription, duration.seconds(2))
  |> should.equal(Ok(Some(subscriptions.ToolsListChanged)))
  tool_names(peer) |> should.equal(["echo", "extra"])

  http.unregister_tool(listener, "extra") |> should.be_true
  http.unregister_tool(listener, "extra") |> should.be_false
  client.next_notification(subscription, duration.seconds(2))
  |> should.equal(Ok(Some(subscriptions.ToolsListChanged)))
  tool_names(peer) |> should.equal(["echo"])

  http.notify(listener, subscriptions.ResourceUpdated("memo://readme"))
  client.next_notification(subscription, duration.seconds(2))
  |> should.equal(Ok(Some(subscriptions.ResourceUpdated("memo://readme"))))
  client.next_notification(subscription, duration.milliseconds(50))
  |> should.equal(Ok(None))

  client.close_subscription(subscription)
  client.close(peer)
  http.stop(listener)
}

pub fn mounted_handler_sees_registered_tools_test() {
  let handler = mounted(http.new(empty_server()))
  let assert Ok(Nil) = http.register_tool(handler, echo_tool())
  let call = http.handle(handler, echo_call("registered"))
  string.contains(testing.body_text(call), "registered") |> should.be_true
  http.unregister_tool(handler, "echo") |> should.be_true
  let gone = http.handle(handler, echo_call("registered"))
  string.contains(testing.body_text(gone), "-32602") |> should.be_true
}

// --- wave 5: correlation and request ids across the wire -----------------------

type Seen {
  Seen(correlation: correlation.Correlation, request_id: tool.RequestId)
}

fn seen_tool(seen: process.Subject(Seen)) -> tool.Tool(context) {
  tool.define("whoami", no_input(), codec.string())
  |> tool.handle_call(fn(call, _input) {
    process.send(seen, Seen(tool.correlation(call), tool.request_id(call)))
    Ok(tool.complete(correlation.to_string(tool.correlation(call))))
  })
}

fn whoami() -> tool.Definition(Nil, String) {
  tool.define("whoami", no_input(), codec.string())
}

fn whoami_request() -> request.Request(BitArray) {
  testing.request("tools/call", [
    #("name", json.string("whoami")),
    #("arguments", json.object([])),
  ])
}

/// TH-7: a Relay client's correlation reaches the server over HTTP, and
/// every server event of the call carries it.
pub fn client_correlation_names_the_server_side_of_the_call_test() {
  let label = "carried-http"
  let events = process.new_subject()
  let forward = fn(name, listener, correlation) {
    case listener {
      Some(found) if found == label -> process.send(events, #(name, correlation))
      _ -> Nil
    }
  }
  let attachments = [
    sinal.observe(telemetry.request_admitted_event(), fn(_, m) {
      forward("admitted", m.listener, m.correlation)
    }),
    sinal.observe(telemetry.invocation_started_event(), fn(_, m) {
      forward("started", m.listener, m.correlation)
    }),
    sinal.observe(telemetry.invocation_completed_event(), fn(_, m) {
      forward("completed", m.listener, m.correlation)
    }),
    sinal.observe(telemetry.exchange_closed_event(), fn(_, m) {
      forward("closed", m.listener, m.correlation)
    }),
  ]
  let seen = process.new_subject()
  let listener =
    http.new(server.new([seen_tool(seen)]))
    |> http.with_label(label)
    |> started
  let peer = connect(listener)
  let assert Ok(tag) = correlation.from_string("question-41")

  let assert Ok(client.Succeeded("question-41", _)) =
    client.call(client.with_correlation(peer, tag), whoami(), Nil)
  let assert Ok(Seen(correlation: found, request_id: tool.StringId(id))) =
    process.receive(seen, 1000)
  found |> should.equal(tag)
  string.starts_with(id, "relay-") |> should.be_true
  let names =
    list.map(["admitted", "started", "completed", "closed"], fn(_) {
      let assert Ok(#(name, correlation)) = process.receive(events, 1000)
      correlation |> should.equal(Some(tag))
      name
    })
  list.sort(names, string.compare)
  |> should.equal(["admitted", "closed", "completed", "started"])

  // A correlation that is not visible ASCII is not sent; the server mints.
  let local = correlation.from_key("two words")
  let assert Ok(client.Succeeded(minted, _)) =
    client.call(client.with_correlation(peer, local), whoami(), Nil)
  let assert True = minted != "two words"
  string.length(minted) |> should.equal(32)

  client.close(peer)
  http.stop(listener)
  list.each(attachments, fn(attachment) {
    let assert Ok(Nil) = sinal.detach(attachment)
  })
}

/// A client view's request id reaches the handler as sent, so a retry
/// through the same view is recognisable.
pub fn request_id_view_reaches_the_handler_test() {
  let seen = process.new_subject()
  let listener = http.new(server.new([seen_tool(seen)])) |> started
  let peer = connect(listener)
  let retrying = client.with_request_id(peer, "order-1001")

  let assert Ok(client.Succeeded(_, _)) = client.call(retrying, whoami(), Nil)
  let assert Ok(client.Succeeded(_, _)) = client.call(retrying, whoami(), Nil)
  let assert Ok(Seen(request_id: first, ..)) = process.receive(seen, 1000)
  let assert Ok(Seen(request_id: second, ..)) = process.receive(seen, 1000)
  first |> should.equal(tool.StringId("order-1001"))
  second |> should.equal(first)

  // Without the view each request gets a fresh id.
  let assert Ok(client.Succeeded(_, _)) = client.call(peer, whoami(), Nil)
  let assert Ok(client.Succeeded(_, _)) = client.call(peer, whoami(), Nil)
  let assert Ok(Seen(request_id: a, ..)) = process.receive(seen, 1000)
  let assert Ok(Seen(request_id: b, ..)) = process.receive(seen, 1000)
  let assert True = a != b
  client.close(peer)
  http.stop(listener)
}

pub fn integer_request_ids_reach_the_handler_as_integers_test() {
  let seen = process.new_subject()
  let handler = http.new(server.new([seen_tool(seen)])) |> mounted
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(5)),
      #("method", json.string("tools/call")),
      #(
        "params",
        json.object([
          #(
            "_meta",
            json.object([
              #(
                "io.modelcontextprotocol/protocolVersion",
                json.string("2026-07-28"),
              ),
              #("io.modelcontextprotocol/clientCapabilities", json.object([])),
            ]),
          ),
          #("name", json.string("whoami")),
          #("arguments", json.object([])),
        ]),
      ),
    ])
    |> json.to_string
    |> bit_array.from_string
  let response = http.handle(handler, request.set_body(whoami_request(), body))
  response.status |> should.equal(200)
  let assert Ok(Seen(request_id: id, ..)) = process.receive(seen, 1000)
  id |> should.equal(tool.IntegerId(5))
}

/// The endpoint's builder wins over the client's header, which wins over a
/// fresh value; a header Relay cannot accept is ignored.
pub fn endpoint_correlation_precedence_test() {
  let seen = process.new_subject()
  let handler =
    http.new(server.new([seen_tool(seen)]))
    |> http.with_correlation(fn(request) {
      request.get_header(request, "x-request-id")
      |> result.try(fn(raw) {
        correlation.from_string(raw) |> result.replace_error(Nil)
      })
      |> option.from_result
    })
    |> mounted
  let answer = fn(request) {
    let response = http.handle(handler, request)
    response.status |> should.equal(200)
    let assert Ok(Seen(correlation: found, ..)) = process.receive(seen, 1000)
    correlation.to_string(found)
  }

  whoami_request()
  |> request.set_header("x-request-id", "from-app")
  |> request.set_header("x-correlation-id", "from-client")
  |> answer
  |> should.equal("from-app")
  whoami_request()
  |> request.set_header("x-correlation-id", "from-client")
  |> answer
  |> should.equal("from-client")
  let assert 32 =
    whoami_request()
    |> request.set_header("x-correlation-id", string.repeat("x", 129))
    |> answer
    |> string.length
  let assert 32 = whoami_request() |> answer |> string.length
}
