import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/number
import json/blueprint/value
import relay/content
import relay/internal/core
import relay/internal/jsonrpc.{ProgressInteger, RequestInteger, RequestString}
import relay/internal/logging.{Debug, Warning}
import relay/internal/protocol/v2026_07_28 as v2026

const identity = v2026.Identity("relay", "0.1.0")

fn no_capabilities() -> v2026.Capabilities {
  v2026.Capabilities(
    tools: False,
    resources: False,
    prompts: False,
    completions: False,
  )
}

fn decoded(
  rendered: json.Json,
  path: List(String),
  decoder: decode.Decoder(a),
) -> a {
  let assert Ok(found) =
    json.parse(json.to_string(rendered), decode.at(path, decoder))
  found
}

fn present(rendered: json.Json, path: List(String)) -> Bool {
  case json.parse(json.to_string(rendered), decode.at(path, decode.dynamic)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

// The discovery response carries the result, versions and serverInfo.
pub fn discovery_response_test() {
  let rendered =
    v2026.encode_discovery_response(
      RequestString("disc-1"),
      no_capabilities(),
      identity,
      None,
    )
  decoded(rendered, ["result", "supportedVersions"], decode.list(decode.string))
  |> should.equal(["2026-07-28"])
  decoded(rendered, ["result", "resultType"], decode.string)
  |> should.equal("complete")
  decoded(
    rendered,
    ["result", "_meta", "io.modelcontextprotocol/serverInfo", "name"],
    decode.string,
  )
  |> should.equal("relay")
  present(rendered, ["result", "instructions"]) |> should.be_false
}

pub fn discovery_response_advertises_offered_capabilities_test() {
  let rendered =
    v2026.encode_discovery_response(
      RequestInteger(1),
      v2026.Capabilities(
        tools: True,
        resources: True,
        prompts: False,
        completions: True,
      ),
      v2026.Identity("notes", "1.0.0"),
      Some("Read the notes."),
    )
  decoded(
    rendered,
    ["result", "capabilities", "tools", "listChanged"],
    decode.bool,
  )
  |> should.be_true
  decoded(
    rendered,
    ["result", "capabilities", "resources", "subscribe"],
    decode.bool,
  )
  |> should.be_true
  present(rendered, ["result", "capabilities", "completions"]) |> should.be_true
  present(rendered, ["result", "capabilities", "prompts"]) |> should.be_false
  decoded(rendered, ["result", "instructions"], decode.string)
  |> should.equal("Read the notes.")
}

// An unsupported protocol version answers -32022.
pub fn unsupported_version_test() {
  let raw =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(1)),
      #("method", json.string("server/discover")),
      #(
        "params",
        json.object([
          #(
            "_meta",
            json.object([
              #(
                "io.modelcontextprotocol/protocolVersion",
                json.string("2024-11-05"),
              ),
              #("io.modelcontextprotocol/clientCapabilities", json.object([])),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string()

  let assert v2026.AdmittedRejected(Some(RequestInteger(1)), err) =
    v2026.admit_message(raw)
  err.code |> should.equal(-32_022)
}

pub fn exact_blueprint_number_round_trips_through_wire_test() {
  let number_text = "12345678901234567890123456789012345678901234567890"
  let raw =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{"
    <> "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\","
    <> "\"io.modelcontextprotocol/clientCapabilities\":{}},"
    <> "\"name\":\"exact\",\"arguments\":{\"n\":"
    <> number_text
    <> "}}}"
  let assert Ok(expected) =
    number.parse(number_text, number.limits(1024, 100, 1000))

  let assert v2026.AdmittedRequest(v2026.ToolsCall(
    _,
    _,
    "exact",
    value.Object([#("n", value.Number(actual))]),
    None,
    None,
  )) = v2026.admit_message(raw)
  actual |> should.equal(expected)

  let response =
    v2026.encode_call_response(
      RequestInteger(1),
      Some(value.Object([#("n", value.Number(expected))])),
      [],
      False,
      identity,
    )
  string.contains(json.to_string(response), "\"n\":" <> number_text)
  |> should.be_true
}

pub fn json_parser_preserves_non_ascii_text_test() {
  let assert Ok(parsed) = json.parse("\"€\"", decode.dynamic)
  let assert Ok(text) = decode.run(parsed, decode.string)
  text |> should.equal("€")
}

fn request_meta(extra_fields: List(#(String, json.Json))) -> json.Json {
  json.object([
    #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
    #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ..extra_fields
  ])
}

fn discovery_request(meta: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(7)),
    #("method", json.string("server/discover")),
    #("params", json.object([#("_meta", meta)])),
  ])
  |> json.to_string
}

pub fn malformed_present_client_info_is_rejected_test() {
  let meta =
    request_meta([
      #(
        "io.modelcontextprotocol/clientInfo",
        json.object([#("name", json.string("client-without-version"))]),
      ),
    ])

  let assert v2026.AdmittedRejected(Some(RequestInteger(7)), err) =
    v2026.admit_message(discovery_request(meta))
  err.code |> should.equal(-32_602)
}

pub fn malformed_present_progress_token_is_rejected_test() {
  let meta = request_meta([#("progressToken", json.bool(True))])

  let assert v2026.AdmittedRejected(Some(RequestInteger(7)), err) =
    v2026.admit_message(discovery_request(meta))
  err.code |> should.equal(-32_602)
}

pub fn valid_client_info_and_zero_progress_token_are_retained_test() {
  let meta =
    request_meta([
      #(
        "io.modelcontextprotocol/clientInfo",
        json.object([
          #("name", json.string("client")),
          #("version", json.string("1.2.3")),
        ]),
      ),
      #("progressToken", json.int(0)),
    ])

  let assert v2026.AdmittedRequest(v2026.Discover(_, admitted)) =
    v2026.admit_message(discovery_request(meta))
  admitted.client_info
  |> should.equal(Some(v2026.ClientInfo("client", "1.2.3")))
  admitted.progress_token
  |> should.equal(Some(ProgressInteger(0)))
}

pub fn modern_log_level_is_request_scoped_metadata_test() {
  let meta =
    request_meta([
      #("io.modelcontextprotocol/logLevel", json.string("debug")),
    ])

  let assert v2026.AdmittedRequest(v2026.Discover(_, admitted)) =
    v2026.admit_message(discovery_request(meta))
  admitted.log_level |> should.equal(Some(Debug))
  v2026.request_allows_log(admitted, Debug) |> should.be_true
  v2026.request_allows_log(admitted, Warning) |> should.be_true
}

pub fn legacy_logging_set_level_rpc_is_not_admitted_test() {
  let raw =
    service_request("logging/setLevel", [
      #("level", json.string("debug")),
    ])

  let assert v2026.AdmittedRejected(Some(RequestInteger(7)), err) =
    v2026.admit_message(raw)
  err.code |> should.equal(-32_601)
}

pub fn resource_read_continuation_is_rejected_test() {
  let raw =
    service_request("resources/read", [
      #("uri", json.string("memory://notes/1")),
      #("requestState", json.string("continue-me")),
    ])

  let assert v2026.AdmittedRejected(Some(RequestInteger(7)), err) =
    v2026.admit_message(raw)
  err.code |> should.equal(-32_602)
}

pub fn prompt_get_continuation_is_admitted_test() {
  let raw =
    service_request("prompts/get", [
      #("name", json.string("welcome")),
      #("inputResponses", json.object([])),
    ])

  let assert v2026.AdmittedRequest(v2026.PromptsGet(
    RequestInteger(7),
    _,
    "welcome",
    _,
    None,
    Some(value.Object([])),
  )) = v2026.admit_message(raw)
}

fn completion_request(extra: List(#(String, json.Json))) -> String {
  service_request("completion/complete", [
    #(
      "ref",
      json.object([
        #("type", json.string("ref/prompt")),
        #("name", json.string("welcome")),
      ]),
    ),
    #(
      "argument",
      json.object([
        #("name", json.string("name")),
        #("value", json.string("a")),
      ]),
    ),
    ..extra
  ])
}

// The 2026-07-28 schema nests the known argument values under
// `context.arguments`.
pub fn completion_parses_spec_shaped_context_test() {
  let raw =
    completion_request([
      #(
        "context",
        json.object([
          #(
            "arguments",
            json.object([
              #("lang", json.string("gleam")),
              #("tone", json.string("dry")),
            ]),
          ),
        ]),
      ),
    ])

  let assert v2026.AdmittedRequest(v2026.CompletionComplete(
    RequestInteger(7),
    _,
    core.CompletionQuery(core.PromptTarget("welcome"), "name", "a", known),
  )) = v2026.admit_message(raw)
  known
  |> should.equal(dict.from_list([#("lang", "gleam"), #("tone", "dry")]))
}

pub fn completion_without_context_has_no_known_arguments_test() {
  let assert v2026.AdmittedRequest(v2026.CompletionComplete(
    _,
    _,
    core.CompletionQuery(_, _, _, known),
  )) = v2026.admit_message(completion_request([]))
  known |> should.equal(dict.new())
}

pub fn completion_resource_reference_is_parsed_test() {
  let raw =
    service_request("completion/complete", [
      #(
        "ref",
        json.object([
          #("type", json.string("ref/resource")),
          #("uri", json.string("memo://{id}")),
        ]),
      ),
      #(
        "argument",
        json.object([
          #("name", json.string("id")),
          #("value", json.string("4")),
        ]),
      ),
    ])
  let assert v2026.AdmittedRequest(v2026.CompletionComplete(
    _,
    _,
    core.CompletionQuery(core.ResourceTarget("memo://{id}"), "id", "4", _),
  )) = v2026.admit_message(raw)
}

pub fn completion_context_with_non_string_argument_is_rejected_test() {
  let raw =
    completion_request([
      #(
        "context",
        json.object([
          #("arguments", json.object([#("count", json.int(3))])),
        ]),
      ),
    ])
  let assert v2026.AdmittedRejected(Some(RequestInteger(7)), err) =
    v2026.admit_message(raw)
  err.code |> should.equal(-32_602)
}

fn service_request(
  method: String,
  fields: List(#(String, json.Json)),
) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(7)),
    #("method", json.string(method)),
    #("params", json.object([#("_meta", request_meta([])), ..fields])),
  ])
  |> json.to_string
}

// A call success has resultType "complete" and serverInfo in _meta.
pub fn call_success_encoding_test() {
  let rendered =
    v2026.encode_call_response(
      RequestString("call-1"),
      Some(value.String("hello world")),
      [content.text("hello world")],
      False,
      identity,
    )

  decoded(rendered, ["result", "resultType"], decode.string)
  |> should.equal("complete")
  decoded(rendered, ["result", "structuredContent"], decode.string)
  |> should.equal("hello world")
  present(rendered, ["result", "isError"]) |> should.be_false
  decoded(
    rendered,
    ["result", "_meta", "io.modelcontextprotocol/serverInfo"],
    decode.dict(decode.string, decode.string),
  )
  |> should.equal(dict.from_list([#("name", "relay"), #("version", "0.1.0")]))
}

// A tool error has isError: true, its text in content and no
// structuredContent.
pub fn call_error_encoding_test() {
  let rendered =
    v2026.encode_call_response(
      RequestString("call-err-1"),
      None,
      [content.text("Something went wrong")],
      True,
      identity,
    )

  decoded(rendered, ["result", "isError"], decode.bool) |> should.be_true
  decoded(
    rendered,
    ["result", "content"],
    decode.list(decode.at(["text"], decode.string)),
  )
  |> should.equal(["Something went wrong"])
  present(rendered, ["result", "structuredContent"]) |> should.be_false
}

// Whole progress values encode as integers, fractions as floats; total and
// message are optional.
pub fn progress_notification_encoding_test() {
  v2026.encode_progress_notification(
    jsonrpc.ProgressString("tok"),
    0.5,
    Some(2.0),
    Some("half"),
  )
  |> json.to_string
  |> should.equal(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":"
    <> "{\"progressToken\":\"tok\",\"progress\":0.5,\"total\":2,\"message\":\"half\"}}",
  )
  v2026.encode_progress_notification(ProgressInteger(3), 1.0, None, None)
  |> json.to_string
  |> should.equal(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":"
    <> "{\"progressToken\":3,\"progress\":1}}",
  )
}
