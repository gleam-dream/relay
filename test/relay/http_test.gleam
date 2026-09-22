import gleam/bit_array
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/codec
import relay/server
import relay/tool
import relay/transport/http

pub fn main() -> Nil {
  gleeunit.main()
}

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

type ProgressNotice {
  ProgressBurstStarted(process.Pid)
  ProgressBurstFinished
}

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
  let metadata =
    json.object([
      #(
        "io.modelcontextprotocol/protocolVersion",
        json.string(protocol_version),
      ),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
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

fn empty_server() -> server.Server(Nil) {
  let assert Ok(registry) = tool.registry([])
  server.server(registry)
}

pub fn streamable_http_loopback_test() {
  let policy =
    http.HttpPolicy(
      max_body_bytes: 512,
      max_response_bytes: 4096,
      request_timeout_ms: 2000,
      allowed_hosts: ["127.0.0.1"],
      allowed_origins: ["http://127.0.0.1"],
    )
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(empty_server(), fn() { Nil })
    |> http.with_options(options)
    |> http.with_policy(policy)
    |> http.start()
  }
  let port = http.http_server_port(listener)
  let body = envelope("server/discover", True, [])
  let assert Ok(#(200, response_headers, response_body)) =
    local_request(
      port,
      "post",
      headers("server/discover", "application/json"),
      body,
    )
  let response_text = bit_array.to_string(response_body) |> result.unwrap("")
  should.be_true(string.contains(response_text, "supportedVersions"))
  should.equal(
    list.key_find(response_headers, "mcp-protocol-version"),
    Ok("2026-07-28"),
  )

  let assert Ok(#(400, _, _)) =
    local_request(port, "post", headers("tools/list", "application/json"), body)
  let assert Ok(#(400, _, mismatched_method_body)) =
    local_request(
      port,
      "post",
      headers("server/ping", "application/json"),
      body,
    )
  let mismatched_method_text =
    bit_array.to_string(mismatched_method_body) |> result.unwrap("")
  should.be_true(string.contains(mismatched_method_text, "-32020"))

  let unsupported_body =
    envelope_with_protocol("server/discover", True, [], "2099-01-01")
  let assert Ok(#(400, _, unsupported_body_text)) =
    local_request(
      port,
      "post",
      headers_with_protocol("server/discover", "application/json", "2099-01-01"),
      unsupported_body,
    )
  let unsupported_text =
    bit_array.to_string(unsupported_body_text) |> result.unwrap("")
  should.be_true(string.contains(unsupported_text, "-32022"))

  let version_mismatch_body =
    envelope_with_protocol("server/discover", True, [], "2025-11-25")
  let assert Ok(#(400, _, version_mismatch_text)) =
    local_request(
      port,
      "post",
      headers("server/discover", "application/json"),
      version_mismatch_body,
    )
  let version_mismatch =
    bit_array.to_string(version_mismatch_text) |> result.unwrap("")
  should.be_true(string.contains(version_mismatch, "-32020"))

  let unknown_method_body = envelope("testing/removed-method", True, [])
  let assert Ok(#(404, _, unknown_method_response)) =
    local_request(
      port,
      "post",
      headers("testing/removed-method", "application/json"),
      unknown_method_body,
    )
  let unknown_method_text =
    bit_array.to_string(unknown_method_response) |> result.unwrap("")
  should.be_true(string.contains(unknown_method_text, "-32601"))

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
  let assert Ok(#(200, _, _)) =
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
  let assert Ok(#(200, _, _)) =
    local_request(
      port,
      "post",
      headers_with_name("prompts/get", "missing", "application/json"),
      prompt_get,
    )
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
  let assert Ok(#(405, _, _)) =
    local_request(
      port,
      "put",
      headers("server/discover", "application/json"),
      body,
    )
  let assert Ok(#(406, _, _)) =
    local_request(
      port,
      "post",
      headers("server/discover", "application/json;q=0, text/event-stream;q=0"),
      body,
    )
  let assert Ok(#(200, sse_headers, sse_body)) =
    local_request(
      port,
      "post",
      headers("server/discover", "text/event-stream"),
      body,
    )
  should.equal(
    list.key_find(sse_headers, "content-type"),
    Ok("text/event-stream"),
  )
  let sse_text = bit_array.to_string(sse_body) |> result.unwrap("")
  should.be_true(string.contains(sse_text, "data: {"))

  let capped_policy =
    http.HttpPolicy(
      max_body_bytes: 512,
      max_response_bytes: 1,
      request_timeout_ms: 2000,
      allowed_hosts: ["127.0.0.1"],
      allowed_origins: ["http://127.0.0.1"],
    )
  let assert Ok(capped_listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(empty_server(), fn() { Nil })
    |> http.with_options(options)
    |> http.with_policy(capped_policy)
    |> http.start()
  }
  let assert Ok(#(200, capped_headers, capped_body)) =
    local_request(
      http.http_server_port(capped_listener),
      "post",
      headers("server/discover", "text/event-stream"),
      body,
    )
  should.equal(
    list.key_find(capped_headers, "content-type"),
    Ok("text/event-stream"),
  )
  should.equal(bit_array.byte_size(capped_body), 0)
  http.stop_http_server(capped_listener)

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
  http.stop_http_server(listener)
}

pub fn live_sse_progress_burst_disconnect_cancels_worker_test() {
  let policy =
    http.HttpPolicy(
      max_body_bytes: 512,
      max_response_bytes: 4096,
      request_timeout_ms: 1000,
      allowed_hosts: ["127.0.0.1"],
      allowed_origins: ["http://127.0.0.1"],
    )
  let notices = process.new_subject()
  let assert Ok(listener) = {
    let options = http.HttpOptions(port: 0, host: "127.0.0.1")
    http.listener(burst_progress_server(), fn() { notices })
    |> http.with_options(options)
    |> http.with_policy(policy)
    |> http.start()
  }
  let assert Ok(200) =
    disconnect_after_first_sse_event(
      http.http_server_port(listener),
      "POST",
      [
        #("Accept", "application/json, text/event-stream"),
        #("MCP-Protocol-Version", "2026-07-28"),
        #("Mcp-Method", "tools/call"),
        #("Mcp-Name", "disconnect_probe"),
      ],
      progress_call_envelope(),
    )
  let assert Ok(ProgressBurstStarted(worker)) = process.receive(notices, 1000)
  should.be_true(worker_exits_within(worker, 100))
  case process.receive(notices, 0) {
    Ok(ProgressBurstFinished) -> should.fail()
    Ok(ProgressBurstStarted(_)) -> should.fail()
    Error(Nil) -> Nil
  }
  http.stop_http_server(listener)
}

fn progress_call_envelope() -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(8)),
    #("method", json.string("tools/call")),
    #(
      "params",
      json.object([
        #("name", json.string("disconnect_probe")),
        #("arguments", json.object([])),
        #(
          "_meta",
          json.object([
            #(
              "io.modelcontextprotocol/protocolVersion",
              json.string("2026-07-28"),
            ),
            #("io.modelcontextprotocol/clientCapabilities", json.object([])),
            #("progressToken", json.int(1)),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

fn burst_progress_server() -> server.Server(process.Subject(ProgressNotice)) {
  let assert Ok(name) = tool.tool_name("disconnect_probe")
  let assert Ok(tool) = case
    tool.definition(
      name,
      codec.object(codec.empty()),
      codec.object(codec.empty()),
    )
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok({
        let user_handler = fn(notices, _input, report_progress) {
          process.send(notices, ProgressBurstStarted(process.self()))
          report_http_progress_burst(notices, report_progress, 1, 100_000)
          Ok(Nil)
        }
        let advanced_handler = fn(call, typed_input) {
          let tool.HandlerCallContext(
            application,
            _input_responses,
            report_progress,
          ) = call
          user_handler(application, typed_input, report_progress)
          |> result.map(fn(output) { tool.Complete(output, []) })
        }
        tool.handle_advanced_with_error_renderer(
          definition,
          advanced_handler,
          fn(application_error) {
            case
              codec.encode_json(codec.object(codec.empty()), application_error)
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        )
      })
    }
    Error(error) -> Error(error)
  }
  let assert Ok(registry) = tool.registry([tool])
  server.server(registry)
}

fn report_http_progress_burst(
  notices: process.Subject(ProgressNotice),
  report_progress: fn(Int) -> Nil,
  current: Int,
  last: Int,
) -> Nil {
  case current > last {
    True -> process.send(notices, ProgressBurstFinished)
    False -> {
      report_progress(current)
      report_http_progress_burst(notices, report_progress, current + 1, last)
    }
  }
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
