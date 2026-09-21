import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import json/blueprint/number
import json/blueprint/parser
import json/blueprint/value.{type Value}
import relay/protocol/jsonrpc.{
  type ProgressToken, type RequestId, type RpcError, ProgressInteger,
  ProgressString, RequestInteger, RequestString,
}
import relay/schema
import relay/tool.{type ToolDeclaration, type ToolName}

pub type RequestMetadata {
  RequestMetadata(
    protocol_version: String,
    client_capabilities: Dynamic,
    progress_token: Option(ProgressToken),
  )
}

pub type Request {
  Discover(id: RequestId, metadata: RequestMetadata)
  ToolsList(id: RequestId, metadata: RequestMetadata, cursor: Option(String))
  ToolsCall(
    id: RequestId,
    metadata: RequestMetadata,
    name: ToolName,
    arguments: Value,
  )
}

pub type Notification {
  Cancelled(request_id: RequestId)
  OtherNotification(method: String)
}

pub type UnhandledKind {
  UnsupportedNotificationReason
  UnexpectedResponseReason
}

pub type Admission {
  AdmittedRequest(Request)
  AdmittedNotification(Notification)
  AdmittedIgnored(UnhandledKind)
  AdmittedRejected(id: Option(RequestId), error: RpcError)
}

@external(erlang, "relay_ffi", "dynamic_to_json_string")
fn ffi_dynamic_to_json_string(d: Dynamic) -> String

/// Admits and parses an incoming UTF-8 JSON-RPC string message.
pub fn admit_message(raw_json: String) -> Admission {
  case json.parse(from: raw_json, using: decode.dynamic) {
    Error(_) -> AdmittedRejected(None, jsonrpc.parse_error())
    Ok(raw_dynamic) -> admit_dynamic(raw_dynamic)
  }
}

/// Admits and parses an incoming BitArray message.
pub fn admit_bytes(bytes: BitArray) -> Admission {
  case bit_array.to_string(bytes) {
    Error(_) -> AdmittedRejected(None, jsonrpc.parse_error())
    Ok(str) -> admit_message(str)
  }
}

fn admit_dynamic(data: Dynamic) -> Admission {
  let root_decoder = decode.dict(decode.string, decode.dynamic)

  case decode.run(data, root_decoder) {
    Error(_) -> AdmittedRejected(None, jsonrpc.invalid_request())
    Ok(obj) -> {
      case dict.get(obj, "jsonrpc") {
        Ok(jsonrpc_val) ->
          case decode.run(jsonrpc_val, decode.string) {
            Ok("2.0") -> classify_envelope(obj)
            _ -> AdmittedRejected(None, jsonrpc.invalid_request())
          }
        _ -> AdmittedRejected(None, jsonrpc.invalid_request())
      }
    }
  }
}

fn classify_envelope(obj: Dict(String, Dynamic)) -> Admission {
  // Check if this is an unexpected response message
  case dict.get(obj, "result"), dict.get(obj, "error") {
    Ok(_), _ -> AdmittedIgnored(UnexpectedResponseReason)
    _, Ok(_) -> AdmittedIgnored(UnexpectedResponseReason)
    Error(_), Error(_) -> {
      // Check method
      case dict.get(obj, "method") {
        Error(_) -> AdmittedRejected(None, jsonrpc.invalid_request())
        Ok(method_dyn) ->
          case decode.run(method_dyn, decode.string) {
            Error(_) -> AdmittedRejected(None, jsonrpc.invalid_request())
            Ok(method) -> {
              let id_res = parse_id_field(dict.get(obj, "id"))
              case id_res {
                // Invalid ID format
                Error(Nil) -> AdmittedRejected(None, jsonrpc.invalid_request())
                // Notification (no ID)
                Ok(None) -> route_notification(method, dict.get(obj, "params"))
                // Request (with ID)
                Ok(Some(id)) ->
                  route_request(id, method, dict.get(obj, "params"))
              }
            }
          }
      }
    }
  }
}

fn parse_id_field(
  field_opt: Result(Dynamic, Nil),
) -> Result(Option(RequestId), Nil) {
  case field_opt {
    Error(_) -> Ok(None)
    Ok(dyn) ->
      case decode.run(dyn, decode.string) {
        Ok(s) -> Ok(Some(RequestString(s)))
        Error(_) ->
          case decode.run(dyn, decode.int) {
            Ok(i) -> Ok(Some(RequestInteger(i)))
            Error(_) -> Error(Nil)
          }
      }
  }
}

fn route_notification(
  method: String,
  params_opt: Result(Dynamic, Nil),
) -> Admission {
  case method {
    "notifications/cancelled" ->
      case params_opt {
        Ok(params_dyn) -> {
          let req_id_decoder =
            decode.at(
              ["requestId"],
              decode.one_of(decode.map(decode.string, RequestString), or: [
                decode.map(decode.int, RequestInteger),
              ]),
            )
          case decode.run(params_dyn, req_id_decoder) {
            Ok(req_id) -> AdmittedNotification(Cancelled(req_id))
            Error(_) -> AdmittedIgnored(UnsupportedNotificationReason)
          }
        }
        Error(_) -> AdmittedIgnored(UnsupportedNotificationReason)
      }
    _ -> AdmittedIgnored(UnsupportedNotificationReason)
  }
}

fn route_request(
  id: RequestId,
  method: String,
  params_opt: Result(Dynamic, Nil),
) -> Admission {
  case params_opt {
    Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
    Ok(params_dyn) ->
      case parse_metadata(params_dyn) {
        Error(err) -> AdmittedRejected(Some(id), err)
        Ok(meta) ->
          case method {
            "server/discover" -> AdmittedRequest(Discover(id, meta))
            "tools/list" -> parse_tools_list_params(id, meta, params_dyn)
            "tools/call" -> parse_tools_call_params(id, meta, params_dyn)
            _ -> AdmittedRejected(Some(id), jsonrpc.method_not_found())
          }
      }
  }
}

fn parse_metadata(params_dyn: Dynamic) -> Result(RequestMetadata, RpcError) {
  let meta_field_decoder =
    decode.at(["_meta"], decode.dict(decode.string, decode.dynamic))

  case decode.run(params_dyn, meta_field_decoder) {
    Error(_) -> Error(jsonrpc.invalid_params())
    Ok(meta_dict) -> {
      case dict.get(meta_dict, "io.modelcontextprotocol/protocolVersion") {
        Error(_) -> Error(jsonrpc.invalid_params())
        Ok(ver_dyn) ->
          case decode.run(ver_dyn, decode.string) {
            Error(_) -> Error(jsonrpc.invalid_params())
            Ok(ver) ->
              case ver == "2026-07-28" {
                False ->
                  Error(
                    jsonrpc.unsupported_protocol_version(ver, [
                      "2026-07-28",
                    ]),
                  )
                True ->
                  case
                    dict.get(
                      meta_dict,
                      "io.modelcontextprotocol/clientCapabilities",
                    )
                  {
                    Error(_) -> Error(jsonrpc.invalid_params())
                    Ok(caps_dyn) ->
                      case
                        decode.run(
                          caps_dyn,
                          decode.dict(decode.string, decode.dynamic),
                        )
                      {
                        Error(_) -> Error(jsonrpc.invalid_params())
                        Ok(_) -> {
                          let progress_token =
                            parse_progress_token_from_meta(meta_dict)
                          Ok(RequestMetadata(
                            protocol_version: ver,
                            client_capabilities: caps_dyn,
                            progress_token: progress_token,
                          ))
                        }
                      }
                  }
              }
          }
      }
    }
  }
}

fn parse_progress_token_from_meta(
  meta_dict: Dict(String, Dynamic),
) -> Option(ProgressToken) {
  case dict.get(meta_dict, "progressToken") {
    Error(_) -> None
    Ok(dyn) ->
      case decode.run(dyn, decode.string) {
        Ok(s) -> Some(ProgressString(s))
        Error(_) ->
          case decode.run(dyn, decode.int) {
            Ok(i) -> Some(ProgressInteger(i))
            Error(_) -> None
          }
      }
  }
}

fn parse_tools_list_params(
  id: RequestId,
  meta: RequestMetadata,
  params_dyn: Dynamic,
) -> Admission {
  case decode.run(params_dyn, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
    Ok(params_dict) ->
      case dict.get(params_dict, "cursor") {
        Error(_) -> AdmittedRequest(ToolsList(id, meta, None))
        Ok(cursor_dyn) ->
          case decode.run(cursor_dyn, decode.string) {
            Ok(cursor) -> AdmittedRequest(ToolsList(id, meta, Some(cursor)))
            Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
          }
      }
  }
}

fn parse_tools_call_params(
  id: RequestId,
  meta: RequestMetadata,
  params_dyn: Dynamic,
) -> Admission {
  // Reject unsupported continuation parameters in wave 1
  let continuation_check = decode.dict(decode.string, decode.dynamic)
  case decode.run(params_dyn, continuation_check) {
    Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
    Ok(params_map) -> {
      case
        dict.get(params_map, "requestState"),
        dict.get(params_map, "inputResponses")
      {
        Ok(_), _ -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
        _, Ok(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
        Error(_), Error(_) -> {
          case dict.get(params_map, "name") {
            Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
            Ok(name_dyn) ->
              case decode.run(name_dyn, decode.string) {
                Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
                Ok(raw_name) ->
                  case tool.tool_name(raw_name) {
                    Error(_) ->
                      AdmittedRejected(Some(id), jsonrpc.invalid_params())
                    Ok(tool_name) -> {
                      case dict.get(params_map, "arguments") {
                        Error(_) ->
                          AdmittedRequest(ToolsCall(
                            id,
                            meta,
                            tool_name,
                            value.Object([]),
                          ))
                        Ok(args_dyn) ->
                          case decode_arguments_to_value(args_dyn) {
                            Error(_) ->
                              AdmittedRejected(
                                Some(id),
                                jsonrpc.invalid_params(),
                              )
                            Ok(args_value) ->
                              AdmittedRequest(ToolsCall(
                                id,
                                meta,
                                tool_name,
                                args_value,
                              ))
                          }
                      }
                    }
                  }
              }
          }
        }
      }
    }
  }
}

fn decode_arguments_to_value(args_dyn: Dynamic) -> Result(Value, Nil) {
  // Arguments MUST be a JSON object
  let is_map = decode.run(args_dyn, decode.dict(decode.string, decode.dynamic))
  case is_map {
    Error(_) -> Error(Nil)
    Ok(_) -> {
      let raw_json_str = ffi_dynamic_to_json_string(args_dyn)
      case
        parser.parse_value_from_string(parser.default_limits(), raw_json_str)
      {
        Ok(v) -> Ok(v)
        Error(_) -> Error(Nil)
      }
    }
  }
}

/// Server info identifying Relay 0.1.0.
pub fn server_info() -> json.Json {
  json.object([
    #("name", json.string("relay")),
    #("version", json.string("0.1.0")),
  ])
}

/// Result _meta containing io.modelcontextprotocol/serverInfo.
pub fn result_meta() -> json.Json {
  json.object([
    #("io.modelcontextprotocol/serverInfo", server_info()),
  ])
}

/// Encodes discovery response.
pub fn encode_discovery_response(id: RequestId) -> json.Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", jsonrpc.request_id_to_json(id)),
    #(
      "result",
      json.object([
        #("cacheScope", json.string("private")),
        #("capabilities", json.object([#("tools", json.object([]))])),
        #("resultType", json.string("complete")),
        #("supportedVersions", json.array(["2026-07-28"], json.string)),
        #("ttlMs", json.int(0)),
        #("_meta", result_meta()),
      ]),
    ),
  ])
}

/// Encodes tools list response.
pub fn encode_tools_list_response(
  id: RequestId,
  tools: List(ToolDeclaration),
) -> json.Json {
  let tool_items =
    list.map(tools, fn(decl) {
      let fields = [
        #("name", json.string(tool.tool_name_to_string(decl.name))),
        #(
          "inputSchema",
          value_to_json(schema.materialize_schema(decl.input_schema)),
        ),
      ]
      let with_desc = case decl.metadata.description {
        None -> fields
        Some(d) -> list.append(fields, [#("description", json.string(d))])
      }
      let with_out_schema = case decl.output_schema {
        None -> with_desc
        Some(s) ->
          list.append(with_desc, [
            #("outputSchema", value_to_json(schema.materialize_schema(s))),
          ])
      }
      json.object(with_out_schema)
    })

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", jsonrpc.request_id_to_json(id)),
    #(
      "result",
      json.object([
        #("cacheScope", json.string("private")),
        #("resultType", json.string("complete")),
        #("tools", json.array(tool_items, fn(x) { x })),
        #("ttlMs", json.int(0)),
        #("_meta", result_meta()),
      ]),
    ),
  ])
}

/// Encodes call success response with structuredContent and text mirror in content.
pub fn encode_call_success_response(
  id: RequestId,
  structured: Value,
) -> json.Json {
  let text_mirror = text_mirror_of_value(structured)
  let content_block =
    json.object([
      #("type", json.string("text")),
      #("text", json.string(text_mirror)),
    ])

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", jsonrpc.request_id_to_json(id)),
    #(
      "result",
      json.object([
        #("content", json.array([content_block], fn(x) { x })),
        #("resultType", json.string("complete")),
        #("structuredContent", value_to_json(structured)),
        #("_meta", result_meta()),
      ]),
    ),
  ])
}

/// Encodes call tool error response with isError: true, text in content, and NO structuredContent.
pub fn encode_call_error_response(
  id: RequestId,
  error_message: String,
) -> json.Json {
  let content_block =
    json.object([
      #("type", json.string("text")),
      #("text", json.string(error_message)),
    ])

  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", jsonrpc.request_id_to_json(id)),
    #(
      "result",
      json.object([
        #("content", json.array([content_block], fn(x) { x })),
        #("isError", json.bool(True)),
        #("resultType", json.string("complete")),
        #("_meta", result_meta()),
      ]),
    ),
  ])
}

/// Encodes progress notification.
pub fn encode_progress_notification(
  token: ProgressToken,
  progress: Int,
) -> json.Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("notifications/progress")),
    #(
      "params",
      json.object([
        #("progressToken", jsonrpc.progress_token_to_json(token)),
        #("progress", json.int(progress)),
      ]),
    ),
  ])
}

fn text_mirror_of_value(val: Value) -> String {
  case val {
    value.String(s) -> s
    value.Number(n) -> number.number_text(n)
    value.Bool(True) -> "true"
    value.Bool(False) -> "false"
    value.Null -> "null"
    _ -> json.to_string(value_to_json(val))
  }
}

/// Converts a Blueprint Value into a json.Json representation.
pub fn value_to_json(val: Value) -> json.Json {
  case val {
    value.Null -> json.null()
    value.Bool(b) -> json.bool(b)
    value.String(s) -> json.string(s)
    value.Number(n) -> {
      let assert Ok(limit) = number.integer_projection_limit(1000)
      case number.to_int_exact(n, limit) {
        Ok(i) -> json.int(i)
        Error(_) ->
          case number.to_float_exact(n) {
            Ok(f) -> json.float(f)
            Error(_) -> json.string(number.number_text(n))
          }
      }
    }
    value.Array(items) -> json.array(items, value_to_json)
    value.Object(entries) ->
      json.object(list.map(entries, fn(e) { #(e.0, value_to_json(e.1)) }))
  }
}
