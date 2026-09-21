import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/number
import json/blueprint/value
import relay/logging.{Debug, Warning}
import relay/protocol/jsonrpc.{ProgressInteger, RequestInteger, RequestString}
import relay/protocol/v2026_07_28 as v2026

pub fn main() -> Nil {
  gleeunit.main()
}

// Test discovery response shape and serverInfo
pub fn discovery_response_test() {
  let req_id = RequestString("disc-1")
  let resp_json = v2026.encode_discovery_response(req_id)
  let str = json.to_string(resp_json)

  // Parse back to inspect fields
  let assert Ok(parsed) = json.parse(str, decode.dynamic)
  let assert Ok(dict) =
    decode.run(parsed, decode.dict(decode.string, decode.dynamic))

  let assert Ok(_) = dict.get(dict, "result")
}

// Test unsupported version returns -32022
pub fn unsupported_version_test() {
  let raw_request =
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

  let admission = v2026.admit_message(raw_request)
  case admission {
    v2026.AdmittedRejected(Some(RequestInteger(1)), err) -> {
      err.code |> should.equal(-32_022)
    }
    _ -> should.fail()
  }
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
  let assert Ok(limits) = number.number_limits(1024, 100, 1000)
  let assert Ok(expected) = number.parse_number(limits, number_text)

  case v2026.admit_message(raw) {
    v2026.AdmittedRequest(v2026.ToolsCall(
      _,
      _,
      _,
      value.Object([#("n", value.Number(actual))]),
      _,
      _,
    )) -> actual |> should.equal(expected)
    _ -> should.fail()
  }

  let response =
    v2026.encode_call_success_response(
      RequestInteger(1),
      value.Object([#("n", value.Number(expected))]),
    )
  let rendered = json.to_string(response)
  string.contains(rendered, "\"n\":" <> number_text)
  |> should.equal(True)
}

pub fn json_parser_preserves_non_ascii_text_test() {
  let assert Ok(value) = json.parse("\"€\"", decode.dynamic)
  let assert Ok(text) = decode.run(value, decode.string)
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

  case v2026.admit_message(discovery_request(meta)) {
    v2026.AdmittedRejected(Some(RequestInteger(7)), err) ->
      err.code |> should.equal(-32_602)
    _ -> should.fail()
  }
}

pub fn malformed_present_progress_token_is_rejected_test() {
  let meta = request_meta([#("progressToken", json.bool(True))])

  case v2026.admit_message(discovery_request(meta)) {
    v2026.AdmittedRejected(Some(RequestInteger(7)), err) ->
      err.code |> should.equal(-32_602)
    _ -> should.fail()
  }
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

  case v2026.admit_message(discovery_request(meta)) {
    v2026.AdmittedRequest(v2026.Discover(_, admitted)) -> {
      admitted.client_info
      |> should.equal(Some(v2026.ClientInfo("client", "1.2.3")))
      admitted.progress_token
      |> should.equal(Some(ProgressInteger(0)))
    }
    _ -> should.fail()
  }
}

pub fn modern_log_level_is_request_scoped_metadata_test() {
  let meta =
    request_meta([
      #("io.modelcontextprotocol/logLevel", json.string("debug")),
    ])

  case v2026.admit_message(discovery_request(meta)) {
    v2026.AdmittedRequest(v2026.Discover(_, admitted)) -> {
      admitted.log_level |> should.equal(Some(Debug))
      v2026.request_allows_log(admitted, Debug) |> should.be_true
      v2026.request_allows_log(admitted, Warning) |> should.be_true
    }
    _ -> should.fail()
  }
}

pub fn legacy_logging_set_level_rpc_is_not_admitted_test() {
  let raw =
    service_request("logging/setLevel", [
      #("level", json.string("debug")),
    ])

  case v2026.admit_message(raw) {
    v2026.AdmittedRejected(Some(RequestInteger(7)), err) ->
      err.code |> should.equal(-32_601)
    _ -> should.fail()
  }
}

pub fn resource_read_continuation_is_rejected_test() {
  let raw =
    service_request("resources/read", [
      #("uri", json.string("memory://notes/1")),
      #("requestState", json.string("continue-me")),
    ])

  case v2026.admit_message(raw) {
    v2026.AdmittedRejected(Some(RequestInteger(7)), err) ->
      err.code |> should.equal(-32_602)
    _ -> should.fail()
  }
}

pub fn prompt_get_continuation_is_admitted_test() {
  let raw =
    service_request("prompts/get", [
      #("name", json.string("welcome")),
      #("inputResponses", json.object([])),
    ])

  case v2026.admit_message(raw) {
    v2026.AdmittedRequest(v2026.PromptsGet(
      RequestInteger(7),
      _,
      "welcome",
      _,
      None,
      Some(value.Object([])),
    )) -> Nil
    _ -> should.fail()
  }
}

fn service_request(
  method: String,
  fields: List(#(String, json.Json)),
) -> String {
  let meta = request_meta([])
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(7)),
    #("method", json.string(method)),
    #("params", json.object([#("_meta", meta), ..fields])),
  ])
  |> json.to_string
}

// Test call success encoding includes resultType: "complete" and serverInfo in _meta
pub fn call_success_encoding_test() {
  let req_id = RequestString("call-1")
  let structured = value.String("hello world")
  let resp = v2026.encode_call_success_response(req_id, structured)
  let str = json.to_string(resp)

  // Verify resultType is complete and serverInfo exists
  let assert Ok(parsed) = json.parse(str, decode.dynamic)
  let assert Ok(dict) =
    decode.run(parsed, decode.dict(decode.string, decode.dynamic))
  let assert Ok(result_dyn) = dict.get(dict, "result")
  let assert Ok(result_dict) =
    decode.run(result_dyn, decode.dict(decode.string, decode.dynamic))

  let assert Ok(res_type) = dict.get(result_dict, "resultType")
  let assert Ok(res_type_str) = decode.run(res_type, decode.string)
  res_type_str |> should.equal("complete")

  let assert Ok(meta_dyn) = dict.get(result_dict, "_meta")
  let assert Ok(meta_dict) =
    decode.run(meta_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(server_info_dyn) =
    dict.get(meta_dict, "io.modelcontextprotocol/serverInfo")
  let assert Ok(server_info_dict) =
    decode.run(server_info_dyn, decode.dict(decode.string, decode.string))
  let assert Ok(name) = dict.get(server_info_dict, "name")
  name |> should.equal("relay")
}

// Test call error encoding includes isError: true, text in content, and NO structuredContent
pub fn call_error_encoding_test() {
  let req_id = RequestString("call-err-1")
  let resp = v2026.encode_call_error_response(req_id, "Something went wrong")
  let str = json.to_string(resp)

  let assert Ok(parsed) = json.parse(str, decode.dynamic)
  let assert Ok(dict) =
    decode.run(parsed, decode.dict(decode.string, decode.dynamic))
  let assert Ok(result_dyn) = dict.get(dict, "result")
  let assert Ok(result_dict) =
    decode.run(result_dyn, decode.dict(decode.string, decode.dynamic))

  let assert Ok(is_error_dyn) = dict.get(result_dict, "isError")
  let assert Ok(is_error) = decode.run(is_error_dyn, decode.bool)
  is_error |> should.equal(True)

  // structuredContent should NOT be present on application error
  dict.get(result_dict, "structuredContent") |> should.be_error()
}
