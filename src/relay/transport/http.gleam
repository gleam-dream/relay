import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/float
import gleam/http.{Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import gleam/uri
import mist
import relay/protocol/v2026_07_28 as v2026
import relay/runtime
import relay/server.{type Server}

/// Streamable HTTP listener options. Bind `host` to a loopback interface for
/// local development; remote listeners should use an explicit policy.
pub type HttpOptions {
  HttpOptions(port: Int, host: String)
}

/// Limits and allow-lists enforced before protocol admission.
pub type HttpPolicy {
  HttpPolicy(
    max_body_bytes: Int,
    max_response_bytes: Int,
    request_timeout_ms: Int,
    allowed_hosts: List(String),
    allowed_origins: List(String),
  )
}

pub opaque type HttpServer {
  HttpServer(pid: process.Pid, port: Int)
}

type SseControlMessage {
  SseClientDisconnected
  SseResponseTooLarge
  SseResponseFinished
}

type SseActorMessage {
  SseFrame(BitArray, process.Subject(Result(Nil, Nil)))
  SseProbe
  SseStop(process.Subject(Nil))
}

type SseActorLoopState {
  SseActorLoopState(
    subject: process.Subject(SseActorMessage),
    control: process.Subject(SseControlMessage),
    probe_interval_ms: Int,
    write_timeout_ms: Int,
  )
}

type SseBrokerMessage {
  AttachSseActor(process.Subject(SseActorMessage), process.Subject(Nil))
  DeliverSseFrame(BitArray, process.Subject(SseDeliveryResult))
  StopSseBroker(process.Subject(Nil))
}

type SseDeliveryResult {
  SseDelivered
  SseDeliveryRejected
}

type SseBrokerState {
  SseBrokerState(
    sse_actor: Option(process.Subject(SseActorMessage)),
    control: process.Subject(SseControlMessage),
    timeout_ms: Int,
    response_limit: Int,
    response_bytes: Int,
    failed: Bool,
  )
}

type SseBroker {
  SseBroker(subject: process.Subject(SseBrokerMessage))
}

pub fn http_server_port(server: HttpServer) -> Int {
  server.port
}

pub fn stop_http_server(server: HttpServer) -> Nil {
  ffi_stop_supervisor(server.pid)
}

@external(erlang, "relay_ffi", "stop_supervisor")
fn ffi_stop_supervisor(pid: process.Pid) -> Nil

@external(erlang, "relay_ffi", "set_sse_send_timeout")
fn ffi_set_sse_send_timeout(
  connection: mist.SSEConnection,
  timeout_ms: Int,
) -> Result(Nil, Nil)

@external(erlang, "relay_ffi", "send_sse_comment")
fn ffi_send_sse_comment(
  connection: mist.SSEConnection,
  timeout_ms: Int,
) -> Result(Nil, Nil)

pub fn local_http_policy(host: String) -> HttpPolicy {
  HttpPolicy(
    max_body_bytes: 1_048_576,
    max_response_bytes: 1_048_576,
    request_timeout_ms: 30_000,
    allowed_hosts: [string.lowercase(host), "localhost", "127.0.0.1", "::1"],
    allowed_origins: [
      "http://localhost",
      "http://127.0.0.1",
      "http://[::1]",
    ],
  )
}

/// Starts the local, unprotected modern Streamable HTTP endpoint.
pub fn start_http_server(
  server: Server(Nil),
  options: HttpOptions,
) -> Result(HttpServer, String) {
  start_http_server_with_policy(
    server,
    options,
    local_http_policy(options.host),
  )
}

pub fn start_http_server_with_policy(
  server: Server(Nil),
  options: HttpOptions,
  policy: HttpPolicy,
) -> Result(HttpServer, String) {
  case valid_policy(policy) {
    False ->
      Error("Relay HTTP limits and allow-lists must be non-empty and positive")
    True -> {
      let port_subject = process.new_subject()
      let handler = fn(req) {
        handle_request(req, server, fn() { Nil }, policy)
      }
      let builder =
        mist.new(handler)
        |> mist.port(options.port)
        |> mist.bind(options.host)
        |> mist.after_start(fn(port, _scheme, _interface) {
          process.send(port_subject, port)
        })
      start_listener(builder, port_subject)
    }
  }
}

/// Starts the modern endpoint with an application-owned request context.
pub fn start_http_server_with_context(
  server: Server(context),
  options: HttpOptions,
  context: fn() -> context,
  policy: HttpPolicy,
) -> Result(HttpServer, String) {
  case valid_policy(policy) {
    False ->
      Error("Relay HTTP limits and allow-lists must be non-empty and positive")
    True -> {
      let port_subject = process.new_subject()
      let handler = fn(req) { handle_request(req, server, context, policy) }
      let builder =
        mist.new(handler)
        |> mist.port(options.port)
        |> mist.bind(options.host)
        |> mist.after_start(fn(port, _scheme, _interface) {
          process.send(port_subject, port)
        })
      start_listener(builder, port_subject)
    }
  }
}

fn start_listener(
  builder: mist.Builder(mist.Connection, mist.ResponseData),
  port_subject: process.Subject(Int),
) -> Result(HttpServer, String) {
  case mist.start(builder) {
    Error(_) -> Error("Mist failed to start the Relay HTTP listener")
    Ok(started) -> {
      process.unlink(started.pid)
      case process.receive(port_subject, 5000) {
        Ok(port) -> Ok(HttpServer(pid: started.pid, port: port))
        Error(_) -> {
          ffi_stop_supervisor(started.pid)
          Error("Mist started without reporting its bound port")
        }
      }
    }
  }
}

fn valid_policy(policy: HttpPolicy) -> Bool {
  policy.max_body_bytes > 0
  && policy.max_response_bytes > 0
  && policy.request_timeout_ms > 0
  && policy.allowed_hosts != []
}

type BodyError {
  BodyTooLarge
  BodyMalformed
}

fn handle_request(
  req: Request(mist.Connection),
  server: Server(context),
  context: fn() -> context,
  policy: HttpPolicy,
) -> Response(mist.ResponseData) {
  case req.method {
    Post ->
      case validate_request_headers(req, policy) {
        Error(status) ->
          plain_response(status, "Invalid or disallowed MCP request headers")
        Ok(accept_sse) ->
          case read_bounded_body(req, policy.max_body_bytes) {
            Error(BodyTooLarge) ->
              plain_response(413, "Request body exceeds the configured limit")
            Error(BodyMalformed) ->
              plain_response(400, "Malformed request body")
            Ok(body) ->
              handle_body(req, server, context, policy, accept_sse, body)
          }
      }
    _ -> plain_response(405, "Only POST is supported by modern Streamable HTTP")
  }
}

fn validate_request_headers(
  req: Request(mist.Connection),
  policy: HttpPolicy,
) -> Result(Bool, Int) {
  let host_allowed = host_matches_allowlist(req.host, policy.allowed_hosts)
  let origin_allowed = case request.get_header(req, "origin") {
    Error(_) -> True
    Ok(origin) -> origin_matches_allowlist(origin, policy.allowed_origins)
  }
  case host_allowed && origin_allowed {
    False -> Error(403)
    True ->
      case request.get_header(req, "content-type") {
        Error(_) -> Error(415)
        Ok(content_type) ->
          case media_type(content_type) == "application/json" {
            False -> Error(415)
            True ->
              case request.get_header(req, "accept") {
                Error(_) -> Error(406)
                Ok(raw_accept) -> {
                  let json_accepted =
                    accepts_media_type(raw_accept, "application/json")
                  let sse_accepted =
                    accepts_media_type(raw_accept, "text/event-stream")
                  case json_accepted || sse_accepted {
                    True -> Ok(sse_accepted)
                    False -> Error(406)
                  }
                }
              }
          }
      }
  }
}

fn accepts_media_type(raw_accept: String, wanted: String) -> Bool {
  string.split(string.lowercase(raw_accept), on: ",")
  |> list.any(fn(entry) {
    case string.split(entry, on: ";") {
      [media_type, ..parameters] -> {
        let normalized_media = string.trim(media_type)
        let matches = normalized_media == wanted || normalized_media == "*/*"
        matches && acceptable_quality(parameters)
      }
      [] -> False
    }
  })
}

fn acceptable_quality(parameters: List(String)) -> Bool {
  case quality_parameter(parameters) {
    None -> True
    Some(raw) ->
      case float.parse(raw) {
        Ok(quality) -> quality >. 0.0 && quality <=. 1.0
        Error(_) -> False
      }
  }
}

fn quality_parameter(parameters: List(String)) -> Option(String) {
  case parameters {
    [] -> None
    [parameter, ..rest] -> {
      let parameter = string.trim(parameter)
      case string.starts_with(parameter, "q=") {
        True -> Some(string.drop_start(parameter, 2))
        False -> quality_parameter(rest)
      }
    }
  }
}

fn media_type(content_type: String) -> String {
  case string.split(string.lowercase(content_type), on: ";") {
    [first, ..] -> string.trim(first)
    [] -> ""
  }
}

fn host_matches_allowlist(authority: String, allowlist: List(String)) -> Bool {
  let host = authority_host(string.lowercase(authority))
  list.any(allowlist, fn(allowed) {
    host == authority_host(string.lowercase(allowed))
  })
}

fn origin_matches_allowlist(origin: String, allowlist: List(String)) -> Bool {
  let normalized_origin = string.lowercase(origin)
  list.any(allowlist, fn(allowed) {
    case
      origin_parts(normalized_origin),
      origin_parts(string.lowercase(allowed))
    {
      Some(#(scheme, host)), Some(#(allowed_scheme, allowed_host)) ->
        scheme == allowed_scheme && host == allowed_host
      _, _ -> False
    }
  })
}

fn origin_parts(origin: String) -> Option(#(String, String)) {
  case string.split(origin, on: "://") {
    [scheme, authority] if scheme != "" && authority != "" ->
      case string.split(authority, on: "/") {
        [authority] -> Some(#(scheme, authority_host(authority)))
        _ -> None
      }
    _ -> None
  }
}

fn authority_host(authority: String) -> String {
  case string.starts_with(authority, "[") {
    True ->
      case string.split(authority, on: "]") {
        [host, ..] -> string.drop_start(host, 1)
        _ -> authority
      }
    False ->
      case string.split(authority, on: ":") {
        [host, port] ->
          case int.parse(port) {
            Ok(_) -> host
            Error(_) -> authority
          }
        _ -> authority
      }
  }
}

fn read_bounded_body(
  req: Request(mist.Connection),
  limit: Int,
) -> Result(BitArray, BodyError) {
  case mist.stream(req) {
    Error(_) -> Error(BodyMalformed)
    Ok(consume) -> read_bounded_chunk(consume, limit, <<>>)
  }
}

fn read_bounded_chunk(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  limit: Int,
  body: BitArray,
) -> Result(BitArray, BodyError) {
  let remaining = limit - bit_array.byte_size(body)
  let ask = int.min(16_384, remaining + 1)
  case consume(ask) {
    Error(_) -> Error(BodyMalformed)
    Ok(mist.Done) -> Ok(body)
    Ok(mist.Chunk(chunk, next)) ->
      case bit_array.byte_size(chunk) > remaining {
        True -> Error(BodyTooLarge)
        False -> read_bounded_chunk(next, limit, bit_array.append(body, chunk))
      }
  }
}

fn handle_body(
  req: Request(mist.Connection),
  server: Server(context),
  context: fn() -> context,
  policy: HttpPolicy,
  accept_sse: Bool,
  body: BitArray,
) -> Response(mist.ResponseData) {
  case v2026.http_route(body) {
    Error(_) -> plain_response(400, "Invalid MCP JSON-RPC envelope")
    Ok(route) ->
      case
        validate_route_headers(req, route)
        && validate_custom_parameter_headers(req, server, route)
      {
        False -> json_rpc_response(400, v2026.encode_http_routing_error(body))
        True ->
          case server.http_admission_failure(server, body) {
            Some(#(status_code, response_body)) ->
              json_rpc_response(status_code, response_body)
            None ->
              case v2026.http_admission_failure(body) {
                Some(v2026.HttpFailure(status_code, response_body)) ->
                  json_rpc_response(status_code, response_body)
                None -> {
                  case accept_sse && route.has_id {
                    True ->
                      handle_live_sse_request(
                        req,
                        server,
                        context,
                        policy,
                        body,
                      )
                    False ->
                      handle_buffered_request(
                        server,
                        context,
                        policy,
                        route,
                        body,
                      )
                  }
                }
              }
          }
      }
  }
}

fn handle_buffered_request(
  server: Server(context),
  context: fn() -> context,
  policy: HttpPolicy,
  route: v2026.HttpRoute,
  body: BitArray,
) -> Response(mist.ResponseData) {
  let reply_subject = process.new_subject()
  let config =
    runtime.RuntimeConfig(
      max_live_exchanges: 1,
      max_frame_bytes: policy.max_body_bytes,
      invocation_timeout_ms: policy.request_timeout_ms,
      tombstone_retention_ms: 1000,
    )
  case
    runtime.start(server, config, fn(bytes) {
      process.send(reply_subject, bytes)
    })
  {
    Error(_) -> plain_response(500, "Relay runtime failed to start")
    Ok(runtime_instance) -> {
      let exchange = server.fresh_exchange()
      case
        runtime.send_frame(
          runtime_instance,
          exchange,
          context(),
          body,
          policy.request_timeout_ms,
        )
      {
        Error(_) -> {
          runtime.stop(runtime_instance, 1000)
          plain_response(500, "Relay could not accept the request")
        }
        Ok(_) ->
          case route.has_id {
            False -> {
              runtime.stop(runtime_instance, 1000)
              empty_response(202)
            }
            True -> {
              let collected =
                collect_response(
                  reply_subject,
                  policy.request_timeout_ms,
                  policy.max_response_bytes,
                  0,
                  [],
                )
              runtime.stop(runtime_instance, 1000)
              case collected {
                Error(_) ->
                  plain_response(
                    504,
                    "Relay response timed out or exceeded its limit",
                  )
                Ok(events) -> respond_with_events(events)
              }
            }
          }
      }
    }
  }
}

fn handle_live_sse_request(
  req: Request(mist.Connection),
  server: Server(context),
  context: fn() -> context,
  policy: HttpPolicy,
  body: BitArray,
) -> Response(mist.ResponseData) {
  let control = process.new_subject()
  case start_sse_broker(control, policy) {
    Error(_) -> plain_response(500, "Relay SSE writer failed to start")
    Ok(broker) -> {
      let config =
        runtime.RuntimeConfig(
          max_live_exchanges: 1,
          max_frame_bytes: policy.max_body_bytes,
          invocation_timeout_ms: policy.request_timeout_ms,
          tombstone_retention_ms: 1000,
        )
      case
        runtime.start_with_status_sink(server, config, fn(bytes) {
          sse_broker_deliver(broker, bytes, policy.request_timeout_ms)
        })
      {
        Error(_) -> {
          stop_sse_broker(broker, 1000)
          plain_response(500, "Relay runtime failed to start")
        }
        Ok(runtime_instance) -> {
          let ready_subject = process.new_subject()
          let init = fn(actor_subject) {
            process.send(ready_subject, actor_subject)
            process.send_after(actor_subject, 250, SseProbe)
            SseActorLoopState(
              subject: actor_subject,
              control: control,
              probe_interval_ms: 250,
              write_timeout_ms: policy.request_timeout_ms,
            )
          }
          let loop = fn(state, message, connection) {
            handle_sse_actor_message(state, message, connection)
          }
          let initial_response =
            response.new(200)
            |> response.set_header("mcp-protocol-version", "2026-07-28")
            |> response.set_header("cache-control", "no-store")
          let response =
            mist.server_sent_events(req, initial_response, init, loop)
          case process.receive(ready_subject, 5000) {
            Error(_) -> {
              runtime.stop(runtime_instance, 1000)
              stop_sse_broker(broker, 1000)
              response
            }
            Ok(sse_actor) -> {
              attach_sse_actor(broker, sse_actor, 1000)
              let exchange = server.fresh_exchange()
              case
                runtime.send_frame(
                  runtime_instance,
                  exchange,
                  context(),
                  body,
                  policy.request_timeout_ms,
                )
              {
                Error(_) -> {
                  stop_live_sse(runtime_instance, broker, sse_actor, 1000)
                  response
                }
                Ok(_) -> {
                  wait_for_sse_terminal(
                    control,
                    runtime_instance,
                    broker,
                    sse_actor,
                    policy.request_timeout_ms,
                  )
                  response
                }
              }
            }
          }
        }
      }
    }
  }
}

fn handle_sse_actor_message(
  state: SseActorLoopState,
  message: SseActorMessage,
  connection: mist.SSEConnection,
) -> actor.Next(SseActorLoopState, SseActorMessage) {
  case message {
    SseFrame(bytes, reply) ->
      case bit_array.to_string(bytes) {
        Error(_) -> {
          process.send(reply, Error(Nil))
          actor.stop()
        }
        Ok(text) -> {
          let sent = case
            ffi_set_sse_send_timeout(connection, state.write_timeout_ms)
          {
            Error(_) -> Error(Nil)
            Ok(_) ->
              mist.send_event(
                connection,
                mist.event(string_tree.from_string(text)),
              )
          }
          process.send(reply, sent)
          case sent {
            Ok(_) -> actor.continue(state)
            Error(_) -> actor.stop()
          }
        }
      }
    SseProbe ->
      case ffi_send_sse_comment(connection, state.write_timeout_ms) {
        Ok(Nil) -> {
          process.send_after(state.subject, state.probe_interval_ms, SseProbe)
          actor.continue(state)
        }
        Error(Nil) -> {
          process.send(state.control, SseClientDisconnected)
          actor.stop()
        }
      }
    SseStop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn start_sse_broker(
  control: process.Subject(SseControlMessage),
  policy: HttpPolicy,
) -> Result(SseBroker, actor.StartError) {
  let builder =
    actor.new_with_initialiser(5000, fn(self_subject) {
      let state =
        SseBrokerState(
          sse_actor: None,
          control: control,
          timeout_ms: policy.request_timeout_ms,
          response_limit: policy.max_response_bytes,
          response_bytes: 0,
          failed: False,
        )
      actor.initialised(state)
      |> actor.returning(self_subject)
      |> Ok
    })
    |> actor.on_message(handle_sse_broker_message)
  case actor.start(builder) {
    Error(error) -> Error(error)
    Ok(started) -> Ok(SseBroker(started.data))
  }
}

fn handle_sse_broker_message(
  state: SseBrokerState,
  message: SseBrokerMessage,
) -> actor.Next(SseBrokerState, SseBrokerMessage) {
  case message {
    AttachSseActor(sse_actor, reply) -> {
      process.send(reply, Nil)
      actor.continue(SseBrokerState(..state, sse_actor: Some(sse_actor)))
    }
    DeliverSseFrame(bytes, reply) -> {
      let frame_size = bit_array.byte_size(bytes)
      case
        state.failed || state.response_bytes + frame_size > state.response_limit
      {
        True -> {
          case state.failed {
            True -> Nil
            False -> process.send(state.control, SseResponseTooLarge)
          }
          process.send(reply, SseDeliveryRejected)
          actor.continue(SseBrokerState(..state, failed: True))
        }
        False ->
          case state.sse_actor {
            None -> {
              process.send(state.control, SseClientDisconnected)
              process.send(reply, SseDeliveryRejected)
              actor.continue(SseBrokerState(..state, failed: True))
            }
            Some(sse_actor) -> {
              let event_reply = process.new_subject()
              process.send(sse_actor, SseFrame(bytes, event_reply))
              case process.receive(event_reply, state.timeout_ms) {
                Ok(Ok(Nil)) -> {
                  process.send(reply, SseDelivered)
                  let response_bytes = state.response_bytes + frame_size
                  case v2026.is_response_frame(bytes) {
                    True -> process.send(state.control, SseResponseFinished)
                    False -> Nil
                  }
                  actor.continue(
                    SseBrokerState(..state, response_bytes: response_bytes),
                  )
                }
                Ok(Error(Nil)) | Error(_) -> {
                  process.send(state.control, SseClientDisconnected)
                  process.send(reply, SseDeliveryRejected)
                  actor.continue(SseBrokerState(..state, failed: True))
                }
              }
            }
          }
      }
    }
    StopSseBroker(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn attach_sse_actor(
  broker: SseBroker,
  sse_actor: process.Subject(SseActorMessage),
  timeout_ms: Int,
) -> Nil {
  let SseBroker(subject) = broker
  let reply = process.new_subject()
  process.send(subject, AttachSseActor(sse_actor, reply))
  let _ = process.receive(reply, timeout_ms)
  Nil
}

fn sse_broker_deliver(
  broker: SseBroker,
  bytes: BitArray,
  timeout_ms: Int,
) -> Result(Nil, Nil) {
  let SseBroker(subject) = broker
  let reply = process.new_subject()
  process.send(subject, DeliverSseFrame(bytes, reply))
  case process.receive(reply, timeout_ms) {
    Ok(SseDelivered) -> Ok(Nil)
    Ok(SseDeliveryRejected) | Error(_) -> Error(Nil)
  }
}

fn wait_for_sse_terminal(
  control: process.Subject(SseControlMessage),
  runtime_instance: runtime.Runtime(context),
  broker: SseBroker,
  sse_actor: process.Subject(SseActorMessage),
  timeout_ms: Int,
) -> Nil {
  case process.receive(control, timeout_ms) {
    Ok(SseResponseFinished)
    | Ok(SseClientDisconnected)
    | Ok(SseResponseTooLarge)
    | Error(_) -> stop_live_sse(runtime_instance, broker, sse_actor, timeout_ms)
  }
}

fn stop_live_sse(
  runtime_instance: runtime.Runtime(context),
  broker: SseBroker,
  sse_actor: process.Subject(SseActorMessage),
  timeout_ms: Int,
) -> Nil {
  runtime.close(runtime_instance)
  runtime.stop(runtime_instance, timeout_ms)
  let actor_reply = process.new_subject()
  process.send(sse_actor, SseStop(actor_reply))
  let _ = process.receive(actor_reply, timeout_ms)
  stop_sse_broker(broker, timeout_ms)
  Nil
}

fn stop_sse_broker(broker: SseBroker, timeout_ms: Int) -> Nil {
  let SseBroker(subject) = broker
  let reply = process.new_subject()
  process.send(subject, StopSseBroker(reply))
  let _ = process.receive(reply, timeout_ms)
  Nil
}

fn validate_route_headers(
  req: Request(mist.Connection),
  route: v2026.HttpRoute,
) -> Bool {
  let protocol_method = header_value(req, "mcp-method")
  let protocol_name = header_value(req, "mcp-name")
  let protocol_version = header_value(req, "mcp-protocol-version")
  let version_matches = case route.protocol_version, protocol_version {
    Some(body_version), Ok(header_version) ->
      string.trim(header_version) == body_version
    Some(_), Error(_) -> False
    None, _ -> True
  }
  case protocol_method {
    Error(_) -> False
    Ok(method) ->
      case uri.percent_decode(string.trim(method)) {
        Error(_) -> False
        Ok(method) -> {
          let method_matches = method == route.method
          let name_matches = case route.name, protocol_name {
            Some(body_name), Ok(header_name) ->
              case uri.percent_decode(string.trim(header_name)) {
                Ok(header_name) -> header_name == body_name
                Error(_) -> False
              }
            Some(_), Error(_) -> False
            None, Error(_) -> True
            None, Ok(_) -> False
          }
          method_matches && name_matches && version_matches
        }
      }
  }
}

fn validate_custom_parameter_headers(
  req: Request(mist.Connection),
  server: Server(context),
  route: v2026.HttpRoute,
) -> Bool {
  case route.method, route.name, route.arguments {
    "tools/call", Some(name), Some(arguments) ->
      server.http_custom_headers_valid(server, name, arguments, fn(header_name) {
        case request.get_header(req, header_name) {
          Ok(value) -> Some(value)
          Error(_) -> None
        }
      })
    _, _, _ -> True
  }
}

fn header_value(
  req: Request(mist.Connection),
  name: String,
) -> Result(String, Nil) {
  request.get_header(req, name)
}

fn collect_response(
  subject: process.Subject(BitArray),
  timeout_ms: Int,
  limit: Int,
  used: Int,
  events: List(BitArray),
) -> Result(List(BitArray), Nil) {
  case process.receive(subject, timeout_ms) {
    Error(_) -> Error(Nil)
    Ok(bytes) -> {
      let new_size = used + bit_array.byte_size(bytes)
      case new_size > limit {
        True -> Error(Nil)
        False ->
          case v2026.is_response_frame(bytes) {
            True -> Ok(list.append(events, [bytes]))
            False ->
              collect_response(
                subject,
                timeout_ms,
                limit,
                new_size,
                list.append(events, [bytes]),
              )
          }
      }
    }
  }
}

fn respond_with_events(events: List(BitArray)) -> Response(mist.ResponseData) {
  case list.last(events) {
    Error(_) -> plain_response(500, "Relay produced no response")
    Ok(bytes) -> {
      let status = case v2026.http_response_status(bytes) {
        Some(status) -> status
        None -> 200
      }
      response.new(status)
      |> response.set_header("content-type", "application/json")
      |> response.set_header("mcp-protocol-version", "2026-07-28")
      |> response.set_header("cache-control", "no-store")
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bytes)))
    }
  }
}

fn json_rpc_response(
  status: Int,
  bytes: BitArray,
) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_header("mcp-protocol-version", "2026-07-28")
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bytes)))
}

fn empty_response(status: Int) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("mcp-protocol-version", "2026-07-28")
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn plain_response(status: Int, message: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(message)))
}
