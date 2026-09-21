import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

/// JSON-RPC 2.0 request identifier (string or integer).
pub type RequestId {
  RequestString(String)
  RequestInteger(Int)
}

/// JSON-RPC progress token (string or integer).
pub type ProgressToken {
  ProgressString(String)
  ProgressInteger(Int)
}

/// JSON-RPC 2.0 error object.
pub type RpcError {
  RpcError(code: Int, message: String, data: Option(json.Json))
}

pub const parse_error_code = -32_700

pub const invalid_request_code = -32_600

pub const method_not_found_code = -32_601

pub const invalid_params_code = -32_602

pub const internal_error_code = -32_603

pub const resource_not_found_code = -32_002

pub const unsupported_protocol_version_code = -32_022

pub const missing_required_client_capability_code = -32_021

pub fn parse_error() -> RpcError {
  RpcError(parse_error_code, "Parse error.", None)
}

pub fn invalid_request() -> RpcError {
  RpcError(invalid_request_code, "Invalid request.", None)
}

pub fn method_not_found() -> RpcError {
  RpcError(method_not_found_code, "Method not found.", None)
}

pub fn invalid_params() -> RpcError {
  RpcError(invalid_params_code, "Invalid params.", None)
}

pub fn internal_error() -> RpcError {
  RpcError(internal_error_code, "Internal error.", None)
}

pub fn resource_not_found() -> RpcError {
  RpcError(resource_not_found_code, "Resource not found.", None)
}

pub fn unsupported_protocol_version(
  requested: String,
  supported: List(String),
) -> RpcError {
  let data =
    json.object([
      #("requested", json.string(requested)),
      #("supported", json.array(supported, json.string)),
    ])
  RpcError(
    unsupported_protocol_version_code,
    "Unsupported protocol version.",
    Some(data),
  )
}

pub fn missing_required_client_capability(
  capabilities: List(String),
) -> RpcError {
  let required =
    json.object(list.map(capabilities, fn(name) { #(name, json.object([])) }))
  RpcError(
    missing_required_client_capability_code,
    "Missing required client capability.",
    Some(json.object([#("requiredCapabilities", required)])),
  )
}

pub fn request_id_to_json(id: RequestId) -> json.Json {
  case id {
    RequestString(s) -> json.string(s)
    RequestInteger(n) -> json.int(n)
  }
}

pub fn progress_token_to_json(token: ProgressToken) -> json.Json {
  case token {
    ProgressString(s) -> json.string(s)
    ProgressInteger(n) -> json.int(n)
  }
}

pub fn error_to_json(id: Option(RequestId), err: RpcError) -> json.Json {
  let id_field = case id {
    None -> []
    Some(req_id) -> [#("id", request_id_to_json(req_id))]
  }
  let err_fields = [
    #("code", json.int(err.code)),
    #("message", json.string(err.message)),
    ..case err.data {
      None -> []
      Some(d) -> [#("data", d)]
    }
  ]
  json.object([
    #("jsonrpc", json.string("2.0")),
    ..list_append(id_field, [#("error", json.object(err_fields))])
  ])
}

fn list_append(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [item, ..rest] -> [item, ..list_append(rest, second)]
  }
}
