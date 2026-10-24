//// The wire codec of the MCP `2026-07-28` revision: request admission and
//// parsing, HTTP routing fields, and the encoders of every result and
//// notification the server writes.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import json/blueprint/value.{type Value}
import relay/content.{type ContentBlock, type ResourceContents}
import relay/internal/carrier
import relay/internal/core
import relay/internal/jsonrpc.{
  type ProgressToken, type RequestId, type RpcError, ProgressInteger,
  ProgressString, RequestInteger, RequestString,
}
import relay/internal/logging.{type LogLevel, parse_level, permits}
import relay/internal/subscriptions_state.{type Filter, Filter}
import relay/internal/wire.{value_to_json}
import relay/subscriptions
import relay/tool.{type Declaration}

pub type ClientInfo {
  ClientInfo(name: String, version: String)
}

pub type RequestMetadata {
  RequestMetadata(
    protocol_version: String,
    client_capabilities: Dynamic,
    client_info: Option(ClientInfo),
    progress_token: Option(ProgressToken),
    log_level: Option(LogLevel),
    idempotency_key: Option(String),
  )
}

pub type Request {
  Discover(id: RequestId, metadata: RequestMetadata)
  ToolsList(id: RequestId, metadata: RequestMetadata, cursor: Option(String))
  ResourcesList(
    id: RequestId,
    metadata: RequestMetadata,
    cursor: Option(String),
  )
  ResourceTemplatesList(
    id: RequestId,
    metadata: RequestMetadata,
    cursor: Option(String),
  )
  ResourcesRead(id: RequestId, metadata: RequestMetadata, uri: String)
  SubscriptionsListen(id: RequestId, metadata: RequestMetadata, filter: Filter)
  PromptsList(id: RequestId, metadata: RequestMetadata, cursor: Option(String))
  PromptsGet(
    id: RequestId,
    metadata: RequestMetadata,
    name: String,
    arguments: Dict(String, String),
    request_state: Option(String),
    input_responses: Option(Value),
  )
  CompletionComplete(
    id: RequestId,
    metadata: RequestMetadata,
    query: core.CompletionQuery,
  )
  ToolsCall(
    id: RequestId,
    metadata: RequestMetadata,
    name: String,
    arguments: Value,
    request_state: Option(String),
    input_responses: Option(Value),
  )
}

pub type Notification {
  Cancelled(request_id: RequestId)
  OtherNotification(method: String)
}

pub type HttpRoute {
  HttpRoute(
    method: String,
    name: Option(String),
    arguments: Option(Value),
    protocol_version: Option(String),
    has_id: Bool,
  )
}

pub type HttpFailure {
  HttpFailure(status_code: Int, body: BitArray)
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

@external(erlang, "relay_ffi", "extract_arguments_as_blueprint_value")
fn ffi_extract_arguments_as_blueprint_value(
  raw_bytes: BitArray,
) -> Result(Value, Dynamic)

@external(erlang, "relay_ffi", "extract_input_responses_as_blueprint_value")
fn ffi_extract_input_responses_as_blueprint_value(
  raw_bytes: BitArray,
) -> Result(Value, Dynamic)

@external(erlang, "relay_ffi", "json_depth_within")
fn ffi_json_depth_within(bytes: BitArray, max_depth: Int) -> Bool

/// Whether a frame nests objects and arrays at most `max_depth` levels deep.
/// The check scans bytes and runs before any parsing.
pub fn depth_within(bytes: BitArray, max_depth: Int) -> Bool {
  ffi_json_depth_within(bytes, max_depth)
}

/// Admits and parses an incoming UTF-8 JSON-RPC string message.
pub fn admit_message(raw_json: String) -> Admission {
  admit_bytes(bit_array.from_string(raw_json))
}

/// Reads the HTTP routing fields without executing or admitting the request.
pub fn http_route(bytes: BitArray) -> Result(HttpRoute, Nil) {
  use raw <- result.try(
    bit_array.to_string(bytes) |> result.map_error(fn(_) { Nil }),
  )
  use dynamic <- result.try(
    json.parse(raw, decode.dynamic) |> result.map_error(fn(_) { Nil }),
  )
  use fields <- result.try(
    decode.run(dynamic, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { Nil }),
  )
  use method_dynamic <- result.try(
    dict.get(fields, "method") |> result.map_error(fn(_) { Nil }),
  )
  use method <- result.try(
    decode.run(method_dynamic, decode.string) |> result.map_error(fn(_) { Nil }),
  )
  let routing_field = case method {
    "tools/call" | "prompts/get" -> Some("name")
    "resources/read" -> Some("uri")
    "tasks/get" | "tasks/update" | "tasks/cancel" -> Some("taskId")
    _ -> None
  }
  let name = case routing_field {
    None -> None
    Some(field) ->
      case dict.get(fields, "params") {
        Error(_) -> None
        Ok(params) ->
          case decode.run(params, decode.dict(decode.string, decode.dynamic)) {
            Error(_) -> None
            Ok(params) ->
              case dict.get(params, field) {
                Error(_) -> None
                Ok(name) ->
                  decode.run(name, decode.string)
                  |> result.map(Some)
                  |> result.unwrap(None)
              }
          }
      }
  }
  let has_id = case dict.get(fields, "id") {
    Ok(_) -> True
    Error(_) -> False
  }
  let protocol_version = case dict.get(fields, "params") {
    Error(_) -> None
    Ok(params) ->
      case decode.run(params, decode.dict(decode.string, decode.dynamic)) {
        Error(_) -> None
        Ok(params) ->
          case dict.get(params, "_meta") {
            Error(_) -> None
            Ok(meta) ->
              case
                decode.run(meta, decode.dict(decode.string, decode.dynamic))
              {
                Error(_) -> None
                Ok(meta) ->
                  case
                    dict.get(meta, "io.modelcontextprotocol/protocolVersion")
                  {
                    Error(_) -> None
                    Ok(version) ->
                      decode.run(version, decode.string)
                      |> result.map(Some)
                      |> result.unwrap(None)
                  }
              }
          }
      }
  }
  let arguments = case method {
    "tools/call" ->
      ffi_extract_arguments_as_blueprint_value(bytes)
      |> result.map(Some)
      |> result.unwrap(None)
    _ -> None
  }
  Ok(HttpRoute(method, name, arguments, protocol_version, has_id))
}

/// Returns an HTTP status and JSON-RPC error for messages rejected at admission.
pub fn http_admission_failure(bytes: BitArray) -> Option(HttpFailure) {
  case admit_bytes(bytes) {
    AdmittedRejected(id, error) -> {
      let status_code = case error.code == jsonrpc.method_not_found_code {
        True -> 404
        False -> 400
      }
      let body =
        json.to_string(jsonrpc.error_to_json(id, error))
        |> string_to_bytes
      Some(HttpFailure(status_code, body))
    }
    _ -> None
  }
}

/// Encodes the modern Streamable HTTP routing-header mismatch error.
pub fn encode_http_routing_error(bytes: BitArray) -> BitArray {
  let id = case admit_bytes(bytes) {
    AdmittedRequest(request) -> Some(request_id(request))
    AdmittedRejected(id, _) -> id
    _ -> None
  }
  json.to_string(jsonrpc.error_to_json(
    id,
    jsonrpc.RpcError(
      code: -32_020,
      message: "HTTP routing headers do not match the request body.",
      data: None,
    ),
  ))
  |> string_to_bytes
}

fn string_to_bytes(raw: String) -> BitArray {
  bit_array.from_string(raw <> "
")
}

fn request_id(request: Request) -> RequestId {
  case request {
    Discover(id, _) -> id
    ToolsList(id, _, _) -> id
    ResourcesList(id, _, _) -> id
    ResourceTemplatesList(id, _, _) -> id
    ResourcesRead(id, _, _) -> id
    SubscriptionsListen(id, _, _) -> id
    PromptsList(id, _, _) -> id
    PromptsGet(id, _, _, _, _, _) -> id
    CompletionComplete(id, _, _) -> id
    ToolsCall(id, _, _, _, _, _) -> id
  }
}

/// True for a JSON-RPC response or error object, false for a notification.
pub fn is_response_frame(bytes: BitArray) -> Bool {
  case bit_array.to_string(bytes) {
    Error(_) -> False
    Ok(raw) ->
      case json.parse(raw, decode.dynamic) {
        Error(_) -> False
        Ok(dynamic) ->
          case decode.run(dynamic, decode.dict(decode.string, decode.dynamic)) {
            Error(_) -> False
            Ok(fields) -> {
              let has_id_or_error =
                dict.has_key(fields, "id") || dict.has_key(fields, "error")
              !dict.has_key(fields, "method") && has_id_or_error
            }
          }
      }
  }
}

/// Returns the Streamable HTTP status required for protocol-level errors.
pub fn http_response_status(bytes: BitArray) -> Option(Int) {
  case bit_array.to_string(bytes) {
    Error(_) -> None
    Ok(raw) ->
      case json.parse(raw, decode.dynamic) {
        Error(_) -> None
        Ok(dynamic) ->
          case decode.run(dynamic, decode.dict(decode.string, decode.dynamic)) {
            Error(_) -> None
            Ok(fields) ->
              case dict.get(fields, "error") {
                Error(_) -> None
                Ok(error) ->
                  case
                    decode.run(
                      error,
                      decode.dict(decode.string, decode.dynamic),
                    )
                  {
                    Error(_) -> None
                    Ok(error) ->
                      case dict.get(error, "code") {
                        Error(_) -> None
                        Ok(code) ->
                          case decode.run(code, decode.int) {
                            Error(_) -> None
                            Ok(-32_601) -> Some(404)
                            Ok(-32_021) | Ok(-32_022) -> Some(400)
                            Ok(_) -> None
                          }
                      }
                  }
              }
          }
      }
  }
}

/// Admits and parses an incoming BitArray message.
pub fn admit_bytes(bytes: BitArray) -> Admission {
  case bit_array.to_string(bytes) {
    Error(_) -> AdmittedRejected(None, jsonrpc.parse_error())
    Ok(str) ->
      case json.parse(from: str, using: decode.dynamic) {
        Error(_) -> AdmittedRejected(None, jsonrpc.parse_error())
        Ok(raw_dynamic) -> admit_dynamic(raw_dynamic, bytes)
      }
  }
}

fn admit_dynamic(data: Dynamic, bytes: BitArray) -> Admission {
  let root_decoder = decode.dict(decode.string, decode.dynamic)

  case decode.run(data, root_decoder) {
    Error(_) -> AdmittedRejected(None, jsonrpc.invalid_request())
    Ok(obj) -> {
      case dict.get(obj, "jsonrpc") {
        Ok(jsonrpc_val) ->
          case decode.run(jsonrpc_val, decode.string) {
            Ok("2.0") -> classify_envelope(obj, bytes)
            _ -> AdmittedRejected(None, jsonrpc.invalid_request())
          }
        _ -> AdmittedRejected(None, jsonrpc.invalid_request())
      }
    }
  }
}

fn classify_envelope(obj: Dict(String, Dynamic), bytes: BitArray) -> Admission {
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
                  route_request(id, method, dict.get(obj, "params"), bytes)
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
  bytes: BitArray,
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
            "resources/list" ->
              parse_resources_list_params(id, meta, params_dyn)
            "resources/templates/list" ->
              parse_resource_templates_list_params(id, meta, params_dyn)
            "resources/read" ->
              parse_resources_read_params(id, meta, params_dyn)
            "subscriptions/listen" ->
              parse_subscriptions_listen_params(id, meta, params_dyn)
            "prompts/list" -> parse_prompts_list_params(id, meta, params_dyn)
            "prompts/get" ->
              parse_prompts_get_params(id, meta, params_dyn, bytes)
            "completion/complete" ->
              parse_completion_params(id, meta, params_dyn)
            "tools/call" -> parse_tools_call_params(id, meta, params_dyn, bytes)
            _ -> AdmittedRejected(Some(id), jsonrpc.method_not_found())
          }
      }
  }
}

fn parse_subscriptions_listen_params(
  id: RequestId,
  meta: RequestMetadata,
  params_dyn: Dynamic,
) -> Admission {
  case decode.run(params_dyn, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
    Ok(params) ->
      case dict.get(params, "notifications") {
        Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
        Ok(notif_dyn) ->
          case parse_subscription_filter(notif_dyn) {
            Ok(filter) -> AdmittedRequest(SubscriptionsListen(id, meta, filter))
            Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
          }
      }
  }
}

fn parse_subscription_filter(dyn: Dynamic) -> Result(Filter, Nil) {
  case decode.run(dyn, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> Error(Nil)
    Ok(filter_dict) -> {
      use tools_list_changed <- result.try(
        case dict.get(filter_dict, "toolsListChanged") {
          Error(_) -> Ok(False)
          Ok(v) -> decode.run(v, decode.bool) |> result.map_error(fn(_) { Nil })
        },
      )
      use resources_list_changed <- result.try(
        case dict.get(filter_dict, "resourcesListChanged") {
          Error(_) -> Ok(False)
          Ok(v) -> decode.run(v, decode.bool) |> result.map_error(fn(_) { Nil })
        },
      )
      use prompts_list_changed <- result.try(
        case dict.get(filter_dict, "promptsListChanged") {
          Error(_) -> Ok(False)
          Ok(v) -> decode.run(v, decode.bool) |> result.map_error(fn(_) { Nil })
        },
      )
      use resource_subscriptions <- result.try(
        case dict.get(filter_dict, "resourceSubscriptions") {
          Error(_) -> Ok([])
          Ok(v) ->
            decode.run(v, decode.list(decode.string))
            |> result.map_error(fn(_) { Nil })
        },
      )
      Ok(Filter(
        tools_list_changed: tools_list_changed,
        resources_list_changed: resources_list_changed,
        prompts_list_changed: prompts_list_changed,
        resource_subscriptions: resource_subscriptions,
      ))
    }
  }
}

fn parse_resources_list_params(
  id: RequestId,
  meta: RequestMetadata,
  params_dyn: Dynamic,
) -> Admission {
  parse_cursor(params_dyn)
  |> result.map(fn(cursor) { AdmittedRequest(ResourcesList(id, meta, cursor)) })
  |> result.unwrap(AdmittedRejected(Some(id), jsonrpc.invalid_params()))
}

fn parse_resource_templates_list_params(
  id: RequestId,
  meta: RequestMetadata,
  params_dyn: Dynamic,
) -> Admission {
  parse_cursor(params_dyn)
  |> result.map(fn(cursor) {
    AdmittedRequest(ResourceTemplatesList(id, meta, cursor))
  })
  |> result.unwrap(AdmittedRejected(Some(id), jsonrpc.invalid_params()))
}

fn parse_prompts_list_params(
  id: RequestId,
  meta: RequestMetadata,
  params_dyn: Dynamic,
) -> Admission {
  parse_cursor(params_dyn)
  |> result.map(fn(cursor) { AdmittedRequest(PromptsList(id, meta, cursor)) })
  |> result.unwrap(AdmittedRejected(Some(id), jsonrpc.invalid_params()))
}

fn parse_cursor(params_dyn: Dynamic) -> Result(Option(String), Nil) {
  case decode.run(params_dyn, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> Error(Nil)
    Ok(params) ->
      case dict.get(params, "cursor") {
        Error(_) -> Ok(None)
        Ok(raw) ->
          decode.run(raw, decode.string)
          |> result.map(Some)
          |> result.map_error(fn(_) { Nil })
      }
  }
}

fn parse_resources_read_params(
  id: RequestId,
  meta: RequestMetadata,
  params_dyn: Dynamic,
) -> Admission {
  case decode.run(params_dyn, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
    Ok(params) ->
      case has_continuation_inputs(params) {
        True -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
        False ->
          case dict.get(params, "uri") {
            Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
            Ok(uri_dyn) ->
              case decode.run(uri_dyn, decode.string) {
                Ok(uri) -> AdmittedRequest(ResourcesRead(id, meta, uri))
                Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
              }
          }
      }
  }
}

fn parse_prompts_get_params(
  id: RequestId,
  meta: RequestMetadata,
  params_dyn: Dynamic,
  bytes: BitArray,
) -> Admission {
  case decode.run(params_dyn, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
    Ok(params) ->
      case dict.get(params, "name") {
        Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
        Ok(name_dyn) ->
          case decode.run(name_dyn, decode.string) {
            Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
            Ok(name) ->
              case
                parse_string_arguments(dict.get(params, "arguments")),
                parse_optional_string(params, "requestState"),
                parse_optional_input_responses(params, bytes)
              {
                Ok(arguments), Ok(request_state), Ok(input_responses) ->
                  AdmittedRequest(PromptsGet(
                    id,
                    meta,
                    name,
                    arguments,
                    request_state,
                    input_responses,
                  ))
                _, _, _ -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
              }
          }
      }
  }
}

fn has_continuation_inputs(params: Dict(String, Dynamic)) -> Bool {
  case dict.get(params, "requestState"), dict.get(params, "inputResponses") {
    Error(_), Error(_) -> False
    _, _ -> True
  }
}

fn parse_string_arguments(
  args: Result(Dynamic, Nil),
) -> Result(Dict(String, String), Nil) {
  case args {
    Error(_) -> Ok(dict.new())
    Ok(raw) ->
      decode.run(raw, decode.dict(decode.string, decode.string))
      |> result.map_error(fn(_) { Nil })
  }
}

fn parse_completion_params(
  id: RequestId,
  meta: RequestMetadata,
  params_dyn: Dynamic,
) -> Admission {
  case decode.run(params_dyn, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
    Ok(params) ->
      case dict.get(params, "ref"), dict.get(params, "argument") {
        Ok(ref_dyn), Ok(argument_dyn) ->
          case
            parse_completion_reference(ref_dyn),
            parse_completion_argument(argument_dyn)
          {
            Ok(reference), Ok(#(argument_name, argument_value)) -> {
              let context = case dict.get(params, "context") {
                Error(_) -> Ok(dict.new())
                Ok(context_dyn) ->
                  decode.run(context_dyn, {
                    use arguments <- decode.optional_field(
                      "arguments",
                      dict.new(),
                      decode.dict(decode.string, decode.string),
                    )
                    decode.success(arguments)
                  })
              }
              case context {
                Ok(context_values) ->
                  AdmittedRequest(CompletionComplete(
                    id,
                    meta,
                    core.CompletionQuery(
                      reference,
                      argument_name,
                      argument_value,
                      context_values,
                    ),
                  ))
                Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
              }
            }
            _, _ -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
          }
        _, _ -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
      }
  }
}

fn parse_completion_reference(
  raw: Dynamic,
) -> Result(core.CompletionTarget, Nil) {
  case decode.run(raw, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> Error(Nil)
    Ok(fields) ->
      case dict.get(fields, "type") {
        Error(_) -> Error(Nil)
        Ok(type_dyn) ->
          case decode.run(type_dyn, decode.string) {
            Ok("ref/prompt") ->
              dict.get(fields, "name")
              |> result.map_error(fn(_) { Nil })
              |> result.try(fn(name_dyn) {
                decode.run(name_dyn, decode.string)
                |> result.map(core.PromptTarget)
                |> result.map_error(fn(_) { Nil })
              })
            Ok("ref/resource") ->
              dict.get(fields, "uri")
              |> result.map_error(fn(_) { Nil })
              |> result.try(fn(uri_dyn) {
                decode.run(uri_dyn, decode.string)
                |> result.map(core.ResourceTarget)
                |> result.map_error(fn(_) { Nil })
              })
            _ -> Error(Nil)
          }
      }
  }
}

fn parse_completion_argument(raw: Dynamic) -> Result(#(String, String), Nil) {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use value <- decode.field("value", decode.string)
    decode.success(#(name, value))
  }
  decode.run(raw, decoder) |> result.map_error(fn(_) { Nil })
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
                          use client_info <- result.try(
                            parse_client_info_from_meta(meta_dict),
                          )
                          use progress_token <- result.try(
                            parse_progress_token_from_meta(meta_dict),
                          )
                          use log_level <- result.try(parse_log_level_from_meta(
                            meta_dict,
                          ))
                          use idempotency_key <- result.try(
                            parse_idempotency_key_from_meta(meta_dict),
                          )
                          Ok(RequestMetadata(
                            protocol_version: ver,
                            client_capabilities: caps_dyn,
                            client_info: client_info,
                            progress_token: progress_token,
                            log_level: log_level,
                            idempotency_key: idempotency_key,
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

// An idempotency key that Relay cannot accept refuses the request: ignoring
// it would turn the client's retry into new work.
fn parse_idempotency_key_from_meta(
  meta_dict: Dict(String, Dynamic),
) -> Result(Option(String), RpcError) {
  case dict.get(meta_dict, carrier.idempotency_meta_key) {
    Error(_) -> Ok(None)
    Ok(key_dyn) ->
      case decode.run(key_dyn, decode.string) {
        Ok(key) ->
          case carrier.valid(key) {
            True -> Ok(Some(key))
            False -> Error(jsonrpc.invalid_params())
          }
        Error(_) -> Error(jsonrpc.invalid_params())
      }
  }
}

fn parse_log_level_from_meta(
  meta_dict: Dict(String, Dynamic),
) -> Result(Option(LogLevel), RpcError) {
  case dict.get(meta_dict, "io.modelcontextprotocol/logLevel") {
    Error(_) -> Ok(None)
    Ok(level_dyn) ->
      case decode.run(level_dyn, decode.string) {
        Error(_) -> Error(jsonrpc.invalid_params())
        Ok(raw) ->
          case parse_level(raw) {
            Ok(level) -> Ok(Some(level))
            Error(_) -> Error(jsonrpc.invalid_params())
          }
      }
  }
}

/// Returns whether a request opted into a message at the given severity.
pub fn request_allows_log(
  metadata: RequestMetadata,
  message_level: LogLevel,
) -> Bool {
  case metadata.log_level {
    Some(threshold) -> permits(threshold, message_level)
    None -> False
  }
}

/// Reports whether a request declared the capability needed for an input method.
pub fn client_supports_input_request(
  metadata: RequestMetadata,
  method: String,
) -> Bool {
  let required_capability = case method {
    "elicitation/create" -> Some("elicitation")
    "sampling/createMessage" -> Some("sampling")
    "roots/list" -> Some("roots")
    _ -> None
  }
  case required_capability {
    None -> False
    Some(capability) -> client_declares_capability(metadata, capability)
  }
}

/// Reports whether the client declared a named capability as an object.
pub fn client_declares_capability(
  metadata: RequestMetadata,
  capability: String,
) -> Bool {
  case
    decode.run(
      metadata.client_capabilities,
      decode.dict(decode.string, decode.dynamic),
    )
  {
    Error(_) -> False
    Ok(capabilities) ->
      case dict.get(capabilities, capability) {
        Error(_) -> False
        Ok(candidate) ->
          case
            decode.run(candidate, decode.dict(decode.string, decode.dynamic))
          {
            Ok(_) -> True
            Error(_) -> False
          }
      }
  }
}

fn parse_client_info_from_meta(
  meta_dict: Dict(String, Dynamic),
) -> Result(Option(ClientInfo), RpcError) {
  case dict.get(meta_dict, "io.modelcontextprotocol/clientInfo") {
    Error(_) -> Ok(None)
    Ok(info_dyn) -> {
      let info_decoder = {
        use name <- decode.field("name", decode.string)
        use version <- decode.field("version", decode.string)
        decode.success(ClientInfo(name, version))
      }
      case decode.run(info_dyn, info_decoder) {
        Ok(info) -> Ok(Some(info))
        Error(_) -> Error(jsonrpc.invalid_params())
      }
    }
  }
}

fn parse_progress_token_from_meta(
  meta_dict: Dict(String, Dynamic),
) -> Result(Option(ProgressToken), RpcError) {
  case dict.get(meta_dict, "progressToken") {
    Error(_) -> Ok(None)
    Ok(dyn) ->
      case decode.run(dyn, decode.string) {
        Ok(s) -> Ok(Some(ProgressString(s)))
        Error(_) ->
          case decode.run(dyn, decode.int) {
            Ok(i) -> Ok(Some(ProgressInteger(i)))
            Error(_) -> Error(jsonrpc.invalid_params())
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
  bytes: BitArray,
) -> Admission {
  let continuation_check = decode.dict(decode.string, decode.dynamic)
  case decode.run(params_dyn, continuation_check) {
    Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
    Ok(params_map) -> {
      case dict.get(params_map, "name") {
        Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
        Ok(name_dyn) ->
          case decode.run(name_dyn, decode.string) {
            Error(_) -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
            Ok(raw_name) ->
              case raw_name {
                "" -> AdmittedRejected(Some(id), jsonrpc.invalid_params())
                tool_name -> {
                  let args = case dict.get(params_map, "arguments") {
                    Error(_) -> Ok(value.Object([]))
                    Ok(_) -> ffi_extract_arguments_as_blueprint_value(bytes)
                  }
                  let request_state =
                    parse_optional_string(params_map, "requestState")
                  let input_responses =
                    parse_optional_input_responses(params_map, bytes)
                  case args, request_state, input_responses {
                    Ok(args), Ok(request_state), Ok(input_responses) ->
                      AdmittedRequest(ToolsCall(
                        id,
                        meta,
                        tool_name,
                        args,
                        request_state,
                        input_responses,
                      ))
                    _, _, _ ->
                      AdmittedRejected(Some(id), jsonrpc.invalid_params())
                  }
                }
              }
          }
      }
    }
  }
}

fn parse_optional_string(
  params: Dict(String, Dynamic),
  key: String,
) -> Result(Option(String), Nil) {
  case dict.get(params, key) {
    Error(_) -> Ok(None)
    Ok(raw) ->
      decode.run(raw, decode.string)
      |> result.map(Some)
      |> result.map_error(fn(_) { Nil })
  }
}

fn parse_optional_input_responses(
  params: Dict(String, Dynamic),
  bytes: BitArray,
) -> Result(Option(Value), Nil) {
  case dict.get(params, "inputResponses") {
    Error(_) -> Ok(None)
    Ok(_) ->
      case ffi_extract_input_responses_as_blueprint_value(bytes) {
        Ok(parsed) ->
          case parsed {
            value.Object(_) -> Ok(Some(parsed))
            _ -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
  }
}

// --- encoders ----------------------------------------------------------------

/// The server name and version reported in result metadata.
pub type Identity {
  Identity(name: String, version: String)
}

fn server_info(identity: Identity) -> json.Json {
  json.object([
    #("name", json.string(identity.name)),
    #("version", json.string(identity.version)),
  ])
}

fn result_meta(identity: Identity) -> #(String, json.Json) {
  #(
    "_meta",
    json.object([#("io.modelcontextprotocol/serverInfo", server_info(identity))]),
  )
}

fn encode_result(id: RequestId, result_json: json.Json) -> json.Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", jsonrpc.request_id_to_json(id)),
    #("result", result_json),
  ])
}

fn with_next_cursor(cursor: Option(String)) -> List(#(String, json.Json)) {
  case cursor {
    Some(value) -> [#("nextCursor", json.string(value))]
    None -> []
  }
}

fn cache_fields() -> List(#(String, json.Json)) {
  [
    #("cacheScope", json.string("private")),
    #("resultType", json.string("complete")),
    #("ttlMs", json.int(0)),
  ]
}

pub type Capabilities {
  Capabilities(tools: Bool, resources: Bool, prompts: Bool, completions: Bool)
}

/// Encodes the `server/discover` response.
pub fn encode_discovery_response(
  id: RequestId,
  capabilities: Capabilities,
  identity: Identity,
  instructions: Option(String),
) -> json.Json {
  let advertised =
    list.flatten([
      case capabilities.tools {
        True -> [#("tools", json.object([#("listChanged", json.bool(True))]))]
        False -> []
      },
      case capabilities.resources {
        True -> [
          #(
            "resources",
            json.object([
              #("listChanged", json.bool(True)),
              #("subscribe", json.bool(True)),
            ]),
          ),
        ]
        False -> []
      },
      case capabilities.prompts {
        True -> [
          #("prompts", json.object([#("listChanged", json.bool(True))])),
        ]
        False -> []
      },
      case capabilities.completions {
        True -> [#("completions", json.object([]))]
        False -> []
      },
    ])
  encode_result(
    id,
    json.object(
      list.flatten([
        [
          #("cacheScope", json.string("private")),
          #("capabilities", json.object(list.reverse(advertised))),
        ],
        wire.optional_string("instructions", instructions),
        [
          #("resultType", json.string("complete")),
          #("supportedVersions", json.array(["2026-07-28"], json.string)),
          #("ttlMs", json.int(0)),
          result_meta(identity),
        ],
      ]),
    ),
  )
}

fn tool_annotations_json(
  declaration: Declaration,
) -> List(#(String, json.Json)) {
  let annotations = declaration.annotations
  let hint = fn(key, value) {
    case value {
      None -> []
      Some(flag) -> [#(key, json.bool(flag))]
    }
  }
  let fields =
    list.flatten([
      wire.optional_string("title", annotations.title),
      hint("readOnlyHint", annotations.read_only_hint),
      hint("destructiveHint", annotations.destructive_hint),
      hint("idempotentHint", annotations.idempotent_hint),
      hint("openWorldHint", annotations.open_world_hint),
    ])
  case fields {
    [] -> []
    _ -> [#("annotations", json.object(fields))]
  }
}

pub fn tool_declaration_to_json(declaration: Declaration) -> json.Json {
  json.object(
    list.flatten([
      [
        #("name", json.string(declaration.name)),
        #("inputSchema", value_to_json(declaration.input_schema)),
      ],
      wire.optional_string("title", declaration.title),
      wire.optional_string("description", declaration.description),
      tool_annotations_json(declaration),
      case declaration.output_schema {
        None -> []
        Some(schema) -> [#("outputSchema", value_to_json(schema))]
      },
      wire.icons_field(declaration.icons),
      wire.meta_field(declaration.meta),
    ]),
  )
}

/// Encodes one `tools/list` page.
pub fn encode_tools_list_response(
  id: RequestId,
  tools: List(Declaration),
  next_cursor: Option(String),
  identity: Identity,
) -> json.Json {
  encode_result(
    id,
    json.object(
      list.flatten([
        [
          #("cacheScope", json.string("private")),
          #("resultType", json.string("complete")),
          #("tools", json.array(tools, tool_declaration_to_json)),
          #("ttlMs", json.int(0)),
          result_meta(identity),
        ],
        with_next_cursor(next_cursor),
      ]),
    ),
  )
}

fn optional_annotations(
  annotations: Option(content.Annotations),
) -> List(#(String, json.Json)) {
  case annotations {
    None -> []
    Some(annotations) -> [
      #("annotations", wire.annotations_to_json(annotations)),
    ]
  }
}

fn resource_to_json(resource: core.Resource(context)) -> json.Json {
  let #(location, size) = case resource.kind {
    core.Static(uri) -> #(
      #("uri", json.string(uri)),
      wire.optional_int("size", resource.size),
    )
    core.Template(uri_template, _) -> #(
      #("uriTemplate", json.string(uri_template)),
      [],
    )
  }
  json.object(
    list.flatten([
      [location, #("name", json.string(resource.name))],
      wire.optional_string("title", resource.title),
      wire.optional_string("description", resource.description),
      wire.optional_string("mimeType", resource.mime_type),
      size,
      optional_annotations(resource.annotations),
      wire.icons_field(resource.icons),
      wire.meta_field(resource.meta),
    ]),
  )
}

/// Encodes one `resources/list` page of static resources.
pub fn encode_resources_list_response(
  id: RequestId,
  resources: List(core.Resource(context)),
  next_cursor: Option(String),
) -> json.Json {
  encode_result(
    id,
    json.object(
      list.flatten([
        cache_fields(),
        [#("resources", json.array(resources, resource_to_json))],
        with_next_cursor(next_cursor),
      ]),
    ),
  )
}

/// Encodes one `resources/templates/list` page.
pub fn encode_resource_templates_list_response(
  id: RequestId,
  templates: List(core.Resource(context)),
  next_cursor: Option(String),
) -> json.Json {
  encode_result(
    id,
    json.object(
      list.flatten([
        cache_fields(),
        [#("resourceTemplates", json.array(templates, resource_to_json))],
        with_next_cursor(next_cursor),
      ]),
    ),
  )
}

/// Encodes a `resources/read` result.
pub fn encode_resources_read_response(
  id: RequestId,
  contents: List(ResourceContents),
) -> json.Json {
  encode_result(
    id,
    json.object([
      #("cacheScope", json.string("private")),
      #("contents", json.array(contents, wire.resource_contents_to_json)),
      #("resultType", json.string("complete")),
      #("ttlMs", json.int(0)),
    ]),
  )
}

fn prompt_to_json(prompt: core.Prompt(context)) -> json.Json {
  json.object(
    list.flatten([
      [
        #("name", json.string(prompt.name)),
        #(
          "arguments",
          json.array(prompt.arguments, fn(argument) {
            json.object(
              list.flatten([
                [
                  #("name", json.string(argument.name)),
                  #("required", json.bool(argument.required)),
                ],
                wire.optional_string("title", argument.title),
                wire.optional_string("description", argument.description),
              ]),
            )
          }),
        ),
      ],
      wire.optional_string("title", prompt.title),
      wire.optional_string("description", prompt.description),
      wire.icons_field(prompt.icons),
      wire.meta_field(prompt.meta),
    ]),
  )
}

/// Encodes one `prompts/list` page.
pub fn encode_prompts_list_response(
  id: RequestId,
  prompts: List(core.Prompt(context)),
  next_cursor: Option(String),
) -> json.Json {
  encode_result(
    id,
    json.object(
      list.flatten([
        cache_fields(),
        [#("prompts", json.array(prompts, prompt_to_json))],
        with_next_cursor(next_cursor),
      ]),
    ),
  )
}

/// Encodes a `prompts/get` result from the members the prompt encoded.
pub fn encode_prompts_get_response(
  id: RequestId,
  rendered: core.Encoded,
) -> json.Json {
  encode_result(
    id,
    json.object(
      list.flatten([
        [#("resultType", json.string("complete"))],
        rendered.fields,
        wire.meta_field(rendered.meta),
      ]),
    ),
  )
}

/// Encodes a `completion/complete` result around its `completion` object.
pub fn encode_completion_response(
  id: RequestId,
  completion: json.Json,
) -> json.Json {
  encode_result(
    id,
    json.object([
      #("completion", completion),
      #("resultType", json.string("complete")),
    ]),
  )
}

/// Encodes a complete `tools/call` result, a success or an `isError` one.
pub fn encode_call_response(
  id: RequestId,
  structured: Option(Value),
  blocks: List(ContentBlock),
  is_error: Bool,
  identity: Identity,
) -> json.Json {
  encode_result(
    id,
    json.object(
      list.flatten([
        [#("content", json.array(blocks, wire.content_block_to_json))],
        case is_error {
          True -> [#("isError", json.bool(True))]
          False -> []
        },
        [#("resultType", json.string("complete"))],
        case structured {
          None -> []
          Some(value) -> [#("structuredContent", value_to_json(value))]
        },
        [result_meta(identity)],
      ]),
    ),
  )
}

/// Encodes a result that pauses until the client supplies requested input.
pub fn encode_input_required_response(
  id: RequestId,
  requests: List(#(String, core.InputRequest)),
  request_state: String,
  identity: Identity,
) -> json.Json {
  let requests =
    list.map(requests, fn(entry) {
      let #(key, core.InputRequest(method, params)) = entry
      #(
        key,
        json.object([
          #("method", json.string(method)),
          #("params", value_to_json(params)),
        ]),
      )
    })
  encode_result(
    id,
    json.object([
      #("inputRequests", json.object(requests)),
      #("requestState", json.string(request_state)),
      #("resultType", json.string("input_required")),
      result_meta(identity),
    ]),
  )
}

/// Encodes a progress notification.
pub fn encode_progress_notification(
  token: ProgressToken,
  progress: Float,
  total: Option(Float),
  message: Option(String),
) -> json.Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("notifications/progress")),
    #(
      "params",
      json.object(
        list.flatten([
          [
            #("progressToken", jsonrpc.progress_token_to_json(token)),
            #("progress", number_json(progress)),
          ],
          case total {
            None -> []
            Some(total) -> [#("total", number_json(total))]
          },
          wire.optional_string("message", message),
        ]),
      ),
    ),
  ])
}

// A whole float encodes as an integer, so `3.0` reads as `3`.
fn number_json(number: Float) -> json.Json {
  let whole = float_truncate(number)
  case int_to_float(whole) == number {
    True -> json.int(whole)
    False -> json.float(number)
  }
}

@external(erlang, "erlang", "trunc")
fn float_truncate(number: Float) -> Int

@external(erlang, "erlang", "float")
fn int_to_float(number: Int) -> Float

fn subscription_meta(subscription_id: RequestId) -> #(String, json.Json) {
  #(
    "_meta",
    json.object([
      #(
        "io.modelcontextprotocol/subscriptionId",
        jsonrpc.request_id_to_json(subscription_id),
      ),
    ]),
  )
}

pub fn filter_to_json(filter: Filter) -> json.Json {
  json.object(
    list.flatten([
      case filter.tools_list_changed {
        True -> [#("toolsListChanged", json.bool(True))]
        False -> []
      },
      case filter.resources_list_changed {
        True -> [#("resourcesListChanged", json.bool(True))]
        False -> []
      },
      case filter.prompts_list_changed {
        True -> [#("promptsListChanged", json.bool(True))]
        False -> []
      },
      case filter.resource_subscriptions {
        [] -> []
        uris -> [#("resourceSubscriptions", json.array(uris, json.string))]
      },
    ]),
  )
}

/// Encodes the acknowledgement that opens a `subscriptions/listen` stream.
pub fn encode_subscriptions_acknowledged_notification(
  subscription_id: RequestId,
  filter: Filter,
) -> json.Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("notifications/subscriptions/acknowledged")),
    #(
      "params",
      json.object([
        subscription_meta(subscription_id),
        #("notifications", filter_to_json(filter)),
      ]),
    ),
  ])
}

/// Encodes one notification on a `subscriptions/listen` stream.
pub fn encode_stream_notification(
  subscription_id: RequestId,
  notification: subscriptions.Notification,
) -> json.Json {
  let #(method, fields) = case notification {
    subscriptions.ToolsListChanged -> #("notifications/tools/list_changed", [])
    subscriptions.ResourcesListChanged -> #(
      "notifications/resources/list_changed",
      [],
    )
    subscriptions.PromptsListChanged -> #(
      "notifications/prompts/list_changed",
      [],
    )
    subscriptions.ResourceUpdated(uri) -> #("notifications/resources/updated", [
      #("uri", json.string(uri)),
    ])
  }
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string(method)),
    #("params", json.object([subscription_meta(subscription_id), ..fields])),
  ])
}

/// Encodes the result that ends a `subscriptions/listen` stream.
pub fn encode_subscriptions_listen_result_response(
  id: RequestId,
  identity: Identity,
) -> json.Json {
  encode_result(
    id,
    json.object([
      #("resultType", json.string("complete")),
      #(
        "_meta",
        json.object([
          #("io.modelcontextprotocol/serverInfo", server_info(identity)),
          #(
            "io.modelcontextprotocol/subscriptionId",
            jsonrpc.request_id_to_json(id),
          ),
        ]),
      ),
    ]),
  )
}
