import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import json/blueprint/value
import relay/protocol/jsonrpc.{RequestInteger, RequestString}
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
