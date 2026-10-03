//// The Streamable HTTP endpoint of an MCP server: a handler you mount in
//// your own router, or a listener Relay runs on mist.
////
//// Describe the endpoint with `new(server)`, `new_with_context(server,
//// context)` or `new_protected(server, verifier, protection, context)`, and
//// adjust it with the `with_*` setters. Then either:
////
//// - call `start` (or `supervised`) to bind a mist listener, by default on
////   `127.0.0.1` with an ephemeral port; or
//// - call `handler` and mount the returned `Handler` in an application:
////   `handle(handler, request)` takes a `Request(BitArray)` and returns a
////   buffered `Response(BytesTree)` (one line in wisp:
////   `http.handle(mcp, request.set_body(req, body)) |> response.map(wisp.Bytes)`),
////   and `mist_handler(handler)` mounts the full streaming endpoint in a
////   mist application.
////
//// The context builder sees the request, so a context can carry a tenant
//// or a principal; an `Error(response)` answers the request before Relay
//// reads the body. `new_protected` reads the bearer token, admits it with
//// `relay/authorization`, answers a refusal with its RFC 6750 challenge, and
//// serves the RFC 9728 metadata document at
//// `authorization.metadata_path(protection)`.
////
//// ```gleam
//// import gleam/int
//// import relay/http
//// import relay/server
////
//// pub fn serve(service: server.Server(Nil)) -> String {
////   let assert Ok(mcp) = http.start(http.new(service))
////   "http://127.0.0.1:" <> int.to_string(http.port(mcp)) <> "/"
//// }
//// ```
////
//// | Setting | Default | Setter |
//// | --- | --- | --- |
//// | bind | `127.0.0.1`, ephemeral port | `with_bind` |
//// | non-loopback bind without protection | refused by `start` | `allow_unauthenticated` |
//// | Host and Origin allow-lists | loopback and the bind host | `with_allowed_hosts`, `with_allowed_origins` |
//// | request body | 1 MiB | `with_max_body_bytes` |
//// | response, or one stream's events | 1 MiB | `with_max_response_bytes` |
//// | request timeout (and handler timeout) | 30 s | `with_request_timeout` |
//// | cancellation grace | 5 s | `with_cancellation_grace` |
//// | SSE keepalive | 15 s | `with_sse_keepalive` |
//// | concurrent requests | 1,024, then 503 | `with_max_concurrent_requests` |
//// | concurrent `subscriptions/listen` streams | 64, then 503 | `with_max_listen_streams` |
//// | JSON nesting depth | 64 | `with_max_json_depth` |
////
//// MCP `2026-07-28` cancels a request when its client closes the
//// connection: the endpoint then cancels the invocation and writes nothing.
//// The handler's `relay/tool.cancelled` selector fires, and it has the
//// cancellation grace to stop work it started elsewhere and return before
//// Relay kills it; the endpoint does not hold the response for it.
//// A buffered `handle` cannot see the socket, so its requests end at the
//// request timeout instead, and it answers `subscriptions/listen` with 406;
//// use `mist_handler` or `start` for streaming.

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/float
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/uri
import json/blueprint/value
import mist
import relay/authorization.{
  type Grant, type Protection, type Verifier, VerificationFailed,
}
import relay/internal/emit
import relay/internal/http_mist
import relay/internal/jsonrpc
import relay/internal/protocol/v2026_07_28 as v2026
import relay/reducer
import relay/runtime
import relay/server.{type RegisterError, type Server}
import relay/subscriptions.{type Notification}
import relay/telemetry
import relay/tool.{type Tool}
import sinal/correlation.{type Correlation}

@external(erlang, "relay_url_ffi", "valid_bind_host")
fn valid_bind_host(host: String) -> Bool

@external(erlang, "relay_url_ffi", "loopback_bind_host")
fn loopback_bind_host(host: String) -> Bool

@external(erlang, "relay_url_ffi", "readable_file")
fn readable_file(path: String) -> Bool

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn monotonic_ms() -> Int

// --- configuration -----------------------------------------------------------

type ContextSource(context) {
  Plain(build: fn(Request(BitArray)) -> Result(context, Response(BytesTree)))
  Protected(
    protection: Protection,
    build: fn(Request(BitArray), Option(Correlation), Option(String)) ->
      Result(context, Response(BytesTree)),
  )
}

/// An endpoint description. Build it with `new`, `new_with_context` or
/// `new_protected`; `handler`, `start` and `supervised` validate it.
pub opaque type Config(context) {
  Config(
    server: Server(context),
    context: ContextSource(context),
    host: String,
    port: Int,
    tls: Option(#(String, String)),
    allow_unauthenticated: Bool,
    max_body_bytes: Int,
    max_response_bytes: Int,
    request_timeout: Duration,
    cancellation_grace: Duration,
    sse_keepalive: Duration,
    allowed_hosts: Option(List(String)),
    allowed_origins: List(String),
    max_concurrent_requests: Int,
    max_listen_streams: Int,
    max_json_depth: Int,
    correlation: fn(Request(BitArray)) -> Option(Correlation),
    label: Option(String),
  )
}

/// An endpoint for a server whose handlers need no context.
pub fn new(server: Server(Nil)) -> Config(Nil) {
  new_with_context(server, fn(_) { Ok(Nil) })
}

/// An endpoint that builds each request's context from the request. An
/// `Error(response)` answers the request as is, before the body is read by
/// the server.
pub fn new_with_context(
  server: Server(context),
  context: fn(Request(BitArray)) -> Result(context, Response(BytesTree)),
) -> Config(context) {
  Config(
    server: server,
    context: Plain(context),
    host: "127.0.0.1",
    port: 0,
    tls: None,
    allow_unauthenticated: False,
    max_body_bytes: 1_048_576,
    max_response_bytes: 1_048_576,
    request_timeout: duration.seconds(30),
    cancellation_grace: duration.seconds(5),
    sse_keepalive: duration.seconds(15),
    allowed_hosts: None,
    allowed_origins: ["http://localhost", "http://127.0.0.1", "http://[::1]"],
    max_concurrent_requests: 1024,
    max_listen_streams: 64,
    max_json_depth: 64,
    correlation: fn(_) { None },
    label: None,
  )
}

/// An endpoint that admits only requests whose bearer token `verifier`
/// accepts for `protection`, and builds each request's context from the
/// request and the `Grant`. A refusal answers with the challenge from
/// `relay/authorization.challenge`; a `GET` of the RFC 9728 metadata path
/// returns `authorization.resource_metadata(protection)`.
pub fn new_protected(
  server: Server(context),
  verifier: Verifier(principal),
  protection: Protection,
  context: fn(Request(BitArray), Grant(principal)) ->
    Result(context, Response(BytesTree)),
) -> Config(context) {
  let build = fn(request, correlation, label) {
    let token = case request.get_header(request, "authorization") {
      Error(Nil) -> Error(authorization.MissingToken)
      Ok(header) -> authorization.parse_authorization(header)
    }
    let admitted =
      result.try(token, fn(token) {
        authorization.admit(verifier, token, protection)
      })
    emit.authorization_decided(
      authorization.verifier_name(verifier),
      decision(admitted),
      correlation,
      label,
    )
    case admitted {
      Ok(grant) -> context(request, grant)
      Error(error) -> Error(challenge_response(protection, error))
    }
  }
  Config(
    ..new_with_context(server, fn(_) { Error(plain(500, "")) }),
    context: Protected(protection, build),
  )
}

fn decision(
  admitted: Result(Grant(principal), authorization.AdmissionError),
) -> telemetry.Decision {
  case admitted {
    Ok(_) -> telemetry.Granted
    Error(authorization.MissingToken) -> telemetry.MissingToken
    Error(VerificationFailed(authorization.VerifierUnavailable)) ->
      telemetry.VerifierUnavailable
    Error(VerificationFailed(_)) -> telemetry.InvalidToken
    Error(authorization.ResourceNotGranted) -> telemetry.WrongResource
    Error(authorization.MissingEndpointScope(_)) -> telemetry.InsufficientScope
  }
}

fn challenge_response(
  protection: Protection,
  error: authorization.AdmissionError,
) -> Response(BytesTree) {
  let authorization.Challenge(status, header) =
    authorization.challenge(protection, error)
  let response = plain(status, "")
  case header {
    None -> response
    Some(header) -> response.set_header(response, "www-authenticate", header)
  }
}

/// The interface and port `start` binds. Port 0 picks a free port; read it
/// with `port`. A non-loopback host also needs a wider Host allow-list.
pub fn with_bind(
  config: Config(context),
  host: String,
  port: Int,
) -> Config(context) {
  Config(..config, host: host, port: port)
}

/// Serves HTTPS with these certificate and key files.
pub fn with_tls(
  config: Config(context),
  certfile: String,
  keyfile: String,
) -> Config(context) {
  Config(..config, tls: Some(#(certfile, keyfile)))
}

/// Lets `start` bind a non-loopback host without `new_protected`. Every
/// peer that can reach the address can then call every tool, read every
/// resource and run every prompt. This is unsafe outside a trusted network
/// or without a proxy that authenticates each request.
pub fn allow_unauthenticated(config: Config(context)) -> Config(context) {
  Config(..config, allow_unauthenticated: True)
}

/// The largest request body; a larger one gets 413.
pub fn with_max_body_bytes(
  config: Config(context),
  bytes: Int,
) -> Config(context) {
  Config(..config, max_body_bytes: bytes)
}

/// The largest buffered response, and the most event bytes one stream may
/// carry before it closes.
pub fn with_max_response_bytes(
  config: Config(context),
  bytes: Int,
) -> Config(context) {
  Config(..config, max_response_bytes: bytes)
}

/// How long a request may take, and how long a handler may run.
pub fn with_request_timeout(
  config: Config(context),
  timeout: Duration,
) -> Config(context) {
  Config(..config, request_timeout: timeout)
}

/// How long a cancelled handler may keep running after its
/// `relay/tool.cancelled` selector fires (the client disconnected, or the
/// handler timed out, or the endpoint stopped), before Relay kills it. Zero
/// kills it at once.
pub fn with_cancellation_grace(
  config: Config(context),
  grace: Duration,
) -> Config(context) {
  Config(..config, cancellation_grace: grace)
}

/// How often an idle event stream writes a keepalive comment; a failed
/// write detects a vanished client.
pub fn with_sse_keepalive(
  config: Config(context),
  interval: Duration,
) -> Config(context) {
  Config(..config, sse_keepalive: interval)
}

/// The `Host` header values the endpoint accepts, with or without a port.
/// The default is the bind host and the loopback names.
pub fn with_allowed_hosts(
  config: Config(context),
  hosts: List(String),
) -> Config(context) {
  Config(..config, allowed_hosts: Some(hosts))
}

/// The `Origin` header values the endpoint accepts, such as
/// `"https://app.example.com"`. A request without `Origin` is accepted.
pub fn with_allowed_origins(
  config: Config(context),
  origins: List(String),
) -> Config(context) {
  Config(..config, allowed_origins: origins)
}

/// How many requests, streams included, may be in flight; beyond it the
/// endpoint answers 503.
pub fn with_max_concurrent_requests(
  config: Config(context),
  count: Int,
) -> Config(context) {
  Config(..config, max_concurrent_requests: count)
}

/// How many `subscriptions/listen` streams may be open; beyond it the
/// endpoint answers 503.
pub fn with_max_listen_streams(
  config: Config(context),
  count: Int,
) -> Config(context) {
  Config(..config, max_listen_streams: count)
}

/// The deepest object and array nesting a request body may have.
pub fn with_max_json_depth(
  config: Config(context),
  depth: Int,
) -> Config(context) {
  Config(..config, max_json_depth: depth)
}

/// Builds each request's `sinal/correlation`, for example from a request-id
/// header; Relay's telemetry and `relay/tool.correlation` carry it. The
/// default attaches none.
pub fn with_correlation(
  config: Config(context),
  correlation: fn(Request(BitArray)) -> Option(Correlation),
) -> Config(context) {
  Config(..config, correlation: correlation)
}

/// The `listener` label in this endpoint's telemetry.
pub fn with_label(config: Config(context), label: String) -> Config(context) {
  Config(..config, label: Some(label))
}

/// The setting that `validate` refused.
pub type ConfigField {
  BindHost
  BindPort
  TlsFiles
  MaxBodyBytes
  MaxResponseBytes
  RequestTimeout
  CancellationGrace
  SseKeepalive
  AllowedHosts
  MaxConcurrentRequests
  MaxListenStreams
  MaxJsonDepth
}

/// Why an endpoint did not start.
pub type StartError {
  /// A setting is out of range.
  InvalidConfig(field: ConfigField)
  /// `start` refuses a non-loopback host without `new_protected` or
  /// `allow_unauthenticated`.
  UnauthenticatedNonLoopbackBind(host: String)
  /// The endpoint actor did not start.
  HandlerFailed(actor.StartError)
  /// mist could not bind the interface and port.
  BindFailed(host: String, port: Int)
}

/// A one-line description of a start error.
pub fn describe_start_error(error: StartError) -> String {
  case error {
    InvalidConfig(field) ->
      "invalid Relay HTTP setting: " <> field_name(field) <> " is out of range"
    UnauthenticatedNonLoopbackBind(host) ->
      "Relay HTTP refuses to bind non-loopback host "
      <> host
      <> " without authorization: bind a loopback host, use http.new_protected, "
      <> "or call http.allow_unauthenticated when a trusted network or proxy protects it"
    HandlerFailed(_) -> "the Relay HTTP endpoint actor failed to start"
    BindFailed(host, port) ->
      "Relay HTTP could not bind " <> host <> ":" <> int.to_string(port)
  }
}

fn field_name(field: ConfigField) -> String {
  case field {
    BindHost -> "bind host"
    BindPort -> "bind port"
    TlsFiles -> "TLS certificate or key file"
    MaxBodyBytes -> "max_body_bytes"
    MaxResponseBytes -> "max_response_bytes"
    RequestTimeout -> "request_timeout"
    CancellationGrace -> "cancellation_grace"
    SseKeepalive -> "sse_keepalive"
    AllowedHosts -> "allowed_hosts"
    MaxConcurrentRequests -> "max_concurrent_requests"
    MaxListenStreams -> "max_listen_streams"
    MaxJsonDepth -> "max_json_depth"
  }
}

/// Checks a description as `start` would, binding nothing.
pub fn validate(config: Config(context)) -> Result(Nil, StartError) {
  use _ <- result.try(validate_limits(config))
  use _ <- result.try(case valid_bind_host(config.host) {
    True -> Ok(Nil)
    False -> Error(InvalidConfig(BindHost))
  })
  use _ <- result.try(case config.port >= 0 && config.port < 65_536 {
    True -> Ok(Nil)
    False -> Error(InvalidConfig(BindPort))
  })
  use _ <- result.try(case config.tls {
    None -> Ok(Nil)
    Some(#(certfile, keyfile)) ->
      case readable_file(certfile) && readable_file(keyfile) {
        True -> Ok(Nil)
        False -> Error(InvalidConfig(TlsFiles))
      }
  })
  let protected = case config.context {
    Protected(..) -> True
    Plain(..) -> False
  }
  case
    protected || config.allow_unauthenticated || loopback_bind_host(config.host)
  {
    True -> Ok(Nil)
    False -> Error(UnauthenticatedNonLoopbackBind(config.host))
  }
}

fn validate_limits(config: Config(context)) -> Result(Nil, StartError) {
  let positive = fn(value, field) {
    case value > 0 {
      True -> Ok(Nil)
      False -> Error(InvalidConfig(field))
    }
  }
  use _ <- result.try(positive(config.max_body_bytes, MaxBodyBytes))
  use _ <- result.try(positive(config.max_response_bytes, MaxResponseBytes))
  use _ <- result.try(positive(
    duration.to_milliseconds(config.request_timeout),
    RequestTimeout,
  ))
  use _ <- result.try(
    case duration.to_milliseconds(config.cancellation_grace) >= 0 {
      True -> Ok(Nil)
      False -> Error(InvalidConfig(CancellationGrace))
    },
  )
  use _ <- result.try(positive(
    duration.to_milliseconds(config.sse_keepalive),
    SseKeepalive,
  ))
  use _ <- result.try(positive(
    config.max_concurrent_requests,
    MaxConcurrentRequests,
  ))
  use _ <- result.try(positive(config.max_listen_streams, MaxListenStreams))
  use _ <- result.try(positive(config.max_json_depth, MaxJsonDepth))
  case config.allowed_hosts {
    Some([]) -> Error(InvalidConfig(AllowedHosts))
    _ -> Ok(Nil)
  }
}

fn allowed_hosts(config: Config(context)) -> List(String) {
  case config.allowed_hosts {
    Some(hosts) -> hosts
    None -> [string.lowercase(config.host), "localhost", "127.0.0.1", "::1"]
  }
}

// --- the endpoint actor ------------------------------------------------------

/// The messages of an endpoint actor; used to name a supervised one.
pub opaque type Message(context) {
  Acquire(
    owner: Pid,
    stream: Bool,
    reply: Subject(Result(Lease(context), Refusal)),
  )
  Transfer(slot: Int, owner: Pid)
  Release(slot: Int)
  AddStream(slot: Int, runtime: runtime.Runtime(context), generation: Int)
  OwnerDown(down: process.Down)
  NotifyStreams(notification: Notification)
  Register(tool: Tool(context), reply: Subject(Result(Nil, RegisterError)))
  Unregister(name: String, reply: Subject(Bool))
  GetPort(reply: Subject(Option(Int)))
  GetBodyLimit(reply: Subject(Int))
  StopEndpoint(reply: Subject(Nil))
}

type Lease(context) {
  Lease(
    slot: Int,
    server: Server(context),
    config: Config(context),
    generation: Int,
  )
}

type Refusal {
  Overloaded
  StreamsExhausted
}

type Slot(context) {
  Slot(
    monitor: process.Monitor,
    stream: Bool,
    runtime: Option(runtime.Runtime(context)),
  )
}

type Hub(context) {
  Hub(
    config: Config(context),
    server: Server(context),
    generation: Int,
    slots: Dict(Int, Slot(context)),
    requests: Int,
    streams: Int,
    port: Option(Int),
    listener: Option(Pid),
  )
}

/// A running endpoint: a mounted handler, or a listener from `start` or
/// `supervised`.
pub opaque type Handler(context) {
  Handler(subject: Subject(Message(context)))
}

fn hub_builder(
  config: Config(context),
  name: Option(process.Name(Message(context))),
  listen: Bool,
) {
  let builder =
    actor.new_with_initialiser(10_000, fn(self) {
      let selector =
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(OwnerDown)
      let hub =
        Hub(
          config: config,
          server: config.server,
          generation: 0,
          slots: dict.new(),
          requests: 0,
          streams: 0,
          port: None,
          listener: None,
        )
      let started = case listen {
        False -> Ok(hub)
        True ->
          case
            http_mist.start(
              http_mist.handler(endpoint(Handler(self), config.max_body_bytes)),
              config.host,
              config.port,
              config.tls,
            )
          {
            Ok(#(pid, port)) ->
              Ok(Hub(..hub, port: Some(port), listener: Some(pid)))
            Error(Nil) ->
              Error(describe_start_error(BindFailed(config.host, config.port)))
          }
      }
      case started {
        Error(reason) -> Error(reason)
        Ok(hub) ->
          actor.initialised(hub)
          |> actor.selecting(selector)
          |> actor.returning(Handler(self))
          |> Ok
      }
    })
    |> actor.on_message(handle_hub)
  case name {
    None -> builder
    Some(name) -> actor.named(builder, name)
  }
}

fn start_hub(
  config: Config(context),
  listen: Bool,
) -> Result(Handler(context), StartError) {
  case actor.start(hub_builder(config, None, listen)) {
    Ok(started) -> Ok(started.data)
    Error(actor.InitFailed(_)) -> Error(BindFailed(config.host, config.port))
    Error(error) -> Error(HandlerFailed(error))
  }
}

/// Starts a mountable endpoint, linked to the caller. Mount it with
/// `handle` or `mist_handler`; it binds no port.
pub fn handler(
  config: Config(context),
) -> Result(Handler(context), StartError) {
  use _ <- result.try(validate_limits(config))
  start_hub(config, False)
}

/// Starts the endpoint and a mist listener on the configured bind, linked
/// to the caller. Refuses a non-loopback bind without protection.
pub fn start(config: Config(context)) -> Result(Handler(context), StartError) {
  use _ <- result.try(validate(config))
  start_hub(config, True)
}

/// A child specification for a listener registered under `name`. The
/// handle from `named(name)` stays valid across restarts; `port` reads the
/// current port.
pub fn supervised(
  config: Config(context),
  name: process.Name(Message(context)),
) -> supervision.ChildSpecification(Handler(context)) {
  supervision.worker(fn() {
    case validate(config) {
      Error(error) -> Error(actor.InitFailed(describe_start_error(error)))
      Ok(Nil) -> actor.start(hub_builder(config, Some(name), True))
    }
  })
}

/// The endpoint registered under `name` by `supervised`.
pub fn named(name: process.Name(Message(context))) -> Handler(context) {
  Handler(process.named_subject(name))
}

const hub_timeout = 5000

/// The port a listener is bound to. Panics for a handler from `handler`,
/// which binds none.
pub fn port(handler: Handler(context)) -> Int {
  case process.call(handler.subject, waiting: hub_timeout, sending: GetPort) {
    Some(port) -> port
    None ->
      panic as "relay/http.port: this handler was started with http.handler and binds no port"
  }
}

/// Stops the endpoint: closes its streams, stops its listener and its
/// actor. Waits at most 5 s.
pub fn stop(handler: Handler(context)) -> Nil {
  let reply = process.new_subject()
  process.send(handler.subject, StopEndpoint(reply))
  let _ = process.receive(reply, hub_timeout)
  Nil
}

/// Tells every open `subscriptions/listen` stream that asked for it.
pub fn notify(handler: Handler(context), notification: Notification) -> Nil {
  process.send(handler.subject, NotifyStreams(notification))
}

/// Registers a tool for later requests and tells listening streams the
/// tool list changed.
pub fn register_tool(
  handler: Handler(context),
  tool: Tool(context),
) -> Result(Nil, RegisterError) {
  process.call(handler.subject, waiting: hub_timeout, sending: Register(tool, _))
}

/// Removes a tool; returns whether it existed. Listening streams hear of a
/// change.
pub fn unregister_tool(handler: Handler(context), name: String) -> Bool {
  process.call(handler.subject, waiting: hub_timeout, sending: Unregister(
    name,
    _,
  ))
}

fn handle_hub(
  hub: Hub(context),
  message: Message(context),
) -> actor.Next(Hub(context), Message(context)) {
  case message {
    Acquire(owner, stream, reply) -> {
      let refusal = case hub.requests >= hub.config.max_concurrent_requests {
        True -> Some(Overloaded)
        False ->
          case stream && hub.streams >= hub.config.max_listen_streams {
            True -> Some(StreamsExhausted)
            False -> None
          }
      }
      case refusal {
        Some(refusal) -> {
          process.send(reply, Error(refusal))
          actor.continue(hub)
        }
        None -> {
          let slot = unique_integer()
          let monitor = process.monitor(owner)
          process.send(
            reply,
            Ok(Lease(slot, hub.server, hub.config, hub.generation)),
          )
          actor.continue(
            Hub(
              ..hub,
              slots: dict.insert(hub.slots, slot, Slot(monitor, stream, None)),
              requests: hub.requests + 1,
              streams: hub.streams
                + case stream {
                  True -> 1
                  False -> 0
                },
            ),
          )
        }
      }
    }
    Transfer(slot, owner) ->
      case dict.get(hub.slots, slot) {
        Error(Nil) -> actor.continue(hub)
        Ok(entry) -> {
          let _ = process.demonitor_process(entry.monitor)
          let monitor = process.monitor(owner)
          actor.continue(
            Hub(
              ..hub,
              slots: dict.insert(
                hub.slots,
                slot,
                Slot(..entry, monitor: monitor),
              ),
            ),
          )
        }
      }
    Release(slot) -> actor.continue(release_slot(hub, slot, True))
    OwnerDown(process.ProcessDown(monitor: monitor, ..)) ->
      case
        dict.to_list(hub.slots)
        |> list.find(fn(entry) {
          let #(_, slot) = entry
          slot.monitor == monitor
        })
      {
        Ok(#(slot, _)) -> actor.continue(release_slot(hub, slot, False))
        Error(Nil) -> actor.continue(hub)
      }
    OwnerDown(_) -> actor.continue(hub)
    AddStream(slot, stream_runtime, generation) ->
      case dict.get(hub.slots, slot) {
        Error(Nil) -> actor.continue(hub)
        Ok(entry) -> {
          case generation == hub.generation {
            True -> Nil
            False ->
              runtime.notify(stream_runtime, subscriptions.ToolsListChanged)
          }
          actor.continue(
            Hub(
              ..hub,
              slots: dict.insert(
                hub.slots,
                slot,
                Slot(..entry, runtime: Some(stream_runtime)),
              ),
            ),
          )
        }
      }
    NotifyStreams(notification) -> {
      each_stream(hub, fn(stream) { runtime.notify(stream, notification) })
      actor.continue(hub)
    }
    Register(new_tool, reply) ->
      case server.register_tool(hub.server, new_tool) {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(hub)
        }
        Ok(next) -> {
          each_stream(hub, fn(stream) {
            runtime.notify(stream, subscriptions.ToolsListChanged)
          })
          process.send(reply, Ok(Nil))
          actor.continue(
            Hub(..hub, server: next, generation: hub.generation + 1),
          )
        }
      }
    Unregister(name, reply) ->
      case server.has_tool(hub.server, name) {
        False -> {
          process.send(reply, False)
          actor.continue(hub)
        }
        True -> {
          each_stream(hub, fn(stream) {
            runtime.notify(stream, subscriptions.ToolsListChanged)
          })
          process.send(reply, True)
          actor.continue(
            Hub(
              ..hub,
              server: server.unregister_tool(hub.server, name),
              generation: hub.generation + 1,
            ),
          )
        }
      }
    GetPort(reply) -> {
      process.send(reply, hub.port)
      actor.continue(hub)
    }
    GetBodyLimit(reply) -> {
      process.send(reply, hub.config.max_body_bytes)
      actor.continue(hub)
    }
    StopEndpoint(reply) -> {
      each_stream(hub, runtime.close)
      case hub.listener {
        Some(listener) -> http_mist.stop(listener)
        None -> Nil
      }
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn each_stream(
  hub: Hub(context),
  run: fn(runtime.Runtime(context)) -> Nil,
) -> Nil {
  dict.each(hub.slots, fn(_, slot) {
    case slot.runtime {
      Some(stream) -> run(stream)
      None -> Nil
    }
  })
}

fn release_slot(hub: Hub(context), slot: Int, demonitor: Bool) -> Hub(context) {
  case dict.get(hub.slots, slot) {
    Error(Nil) -> hub
    Ok(entry) -> {
      case demonitor {
        True -> {
          let _ = process.demonitor_process(entry.monitor)
          Nil
        }
        False -> Nil
      }
      Hub(
        ..hub,
        slots: dict.delete(hub.slots, slot),
        requests: int.max(0, hub.requests - 1),
        streams: case entry.stream {
          True -> int.max(0, hub.streams - 1)
          False -> hub.streams
        },
      )
    }
  }
}

@external(erlang, "relay_ffi", "unique_integer")
fn unique_integer() -> Int

// --- serving -----------------------------------------------------------------

/// Answers one request with a buffered response, for mounting in any
/// `gleam_http` server. The body must already be read; a larger body than
/// the limit gets 413. Progress notifications are dropped, a disconnect is
/// not seen, and `subscriptions/listen` gets 406; use `mist_handler` for
/// streaming.
pub fn handle(
  handler: Handler(context),
  request: Request(BitArray),
) -> Response(BytesTree) {
  case serve(handler, request, process.new_selector(), False) {
    http_mist.Buffered(response) -> response
    // A buffered serve never streams.
    http_mist.Streamed(close: close, ..) -> {
      close()
      plain(500, "Relay could not answer the request")
    }
  }
}

/// The full streaming endpoint as a mist handler: server-sent events for
/// progress and `subscriptions/listen`, keepalives, and cancellation when
/// the client disconnects.
pub fn mist_handler(
  handler: Handler(context),
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  let limit =
    process.call(handler.subject, waiting: hub_timeout, sending: GetBodyLimit)
  http_mist.handler(endpoint(handler, limit))
}

fn endpoint(
  handler: Handler(context),
  max_body_bytes: Int,
) -> http_mist.Endpoint {
  http_mist.Endpoint(
    max_body_bytes: max_body_bytes,
    serve: fn(request, closed) { serve(handler, request, closed, True) },
    body_too_large: fn() {
      emit.http_rejected(413, telemetry.BodyTooLarge, None, None)
      plain(413, "Request body exceeds the configured limit")
    },
    malformed_body: fn() {
      emit.http_rejected(400, telemetry.MalformedBody, None, None)
      plain(400, "Malformed request body")
    },
  )
}

fn acquire(
  handler: Handler(context),
  stream: Bool,
) -> Result(Lease(context), Option(Refusal)) {
  let reply = process.new_subject()
  process.send(handler.subject, Acquire(process.self(), stream, reply))
  case process.receive(reply, hub_timeout) {
    Ok(Ok(lease)) -> Ok(lease)
    Ok(Error(refusal)) -> Error(Some(refusal))
    Error(Nil) -> Error(None)
  }
}

fn release(handler: Handler(context), slot: Int) -> Nil {
  process.send(handler.subject, Release(slot))
}

fn serve(
  handler: Handler(context),
  request: Request(BitArray),
  closed: process.Selector(Nil),
  streaming: Bool,
) -> http_mist.Reply {
  let listen = is_listen(request.body)
  case acquire(handler, listen) {
    Error(None) ->
      http_mist.Buffered(plain(503, "Relay HTTP endpoint is unavailable"))
    Error(Some(Overloaded)) -> {
      emit.http_rejected(503, telemetry.TooManyRequests, None, None)
      http_mist.Buffered(
        plain(503, "Too many concurrent requests")
        |> response.set_header("retry-after", "1"),
      )
    }
    Error(Some(StreamsExhausted)) -> {
      emit.http_rejected(503, telemetry.TooManyStreams, None, None)
      http_mist.Buffered(
        plain(503, "Too many open subscription streams")
        |> response.set_header("retry-after", "1"),
      )
    }
    Ok(lease) -> {
      let reply = serve_leased(handler, lease, request, closed, streaming)
      case reply {
        http_mist.Buffered(_) -> release(handler, lease.slot)
        http_mist.Streamed(..) -> Nil
      }
      reply
    }
  }
}

fn is_listen(body: BitArray) -> Bool {
  // Cheap pre-check: only a listen request needs a stream slot.
  case bit_array.to_string(body) {
    Ok(text) -> string.contains(text, "subscriptions/listen")
    Error(Nil) -> False
  }
  && case v2026.http_route(body) {
    Ok(route) -> route.method == "subscriptions/listen"
    Error(Nil) -> False
  }
}

fn reject(
  config: Config(context),
  status: Int,
  reason: telemetry.RejectReason,
  correlation: Option(Correlation),
  message: String,
) -> http_mist.Reply {
  emit.http_rejected(status, reason, correlation, config.label)
  http_mist.Buffered(plain(status, message))
}

fn serve_leased(
  handler: Handler(context),
  lease: Lease(context),
  request: Request(BitArray),
  closed: process.Selector(Nil),
  streaming: Bool,
) -> http_mist.Reply {
  let config = lease.config
  let correlation = config.correlation(request)
  case metadata_request(config, request) {
    Some(reply) -> reply
    None ->
      case request.method {
        Post ->
          case validate_headers(request, config) {
            Error(#(status, reason)) ->
              reject(
                config,
                status,
                reason,
                correlation,
                "Invalid or disallowed MCP request headers",
              )
            Ok(accepts_sse) ->
              case bit_array.byte_size(request.body) > config.max_body_bytes {
                True ->
                  reject(
                    config,
                    413,
                    telemetry.BodyTooLarge,
                    correlation,
                    "Request body exceeds the configured limit",
                  )
                False ->
                  case build_context(config, request, correlation) {
                    Error(response) -> http_mist.Buffered(response)
                    Ok(context) ->
                      dispatch(
                        handler,
                        lease,
                        request,
                        context,
                        correlation,
                        closed,
                        streaming && accepts_sse,
                      )
                  }
              }
          }
        _ ->
          reject(
            config,
            405,
            telemetry.MethodNotAllowed,
            correlation,
            "Only POST is supported by modern Streamable HTTP",
          )
          |> map_buffered(response.set_header(_, "allow", "POST"))
      }
  }
}

fn map_buffered(
  reply: http_mist.Reply,
  change: fn(Response(BytesTree)) -> Response(BytesTree),
) -> http_mist.Reply {
  case reply {
    http_mist.Buffered(response) -> http_mist.Buffered(change(response))
    other -> other
  }
}

fn metadata_request(
  config: Config(context),
  request: Request(BitArray),
) -> Option(http_mist.Reply) {
  case config.context, request.method {
    Protected(protection, _), Get ->
      case request.path == authorization.metadata_path(protection) {
        True ->
          Some(http_mist.Buffered(
            response.new(200)
            |> response.set_header("content-type", "application/json")
            |> response.set_header("cache-control", "max-age=300")
            |> response.set_body(
              bytes_tree.from_string(
                json.to_string(authorization.resource_metadata(protection)),
              ),
            ),
          ))
        False -> None
      }
    _, _ -> None
  }
}

fn build_context(
  config: Config(context),
  request: Request(BitArray),
  correlation: Option(Correlation),
) -> Result(context, Response(BytesTree)) {
  case config.context {
    Plain(build) -> build(request)
    Protected(_, build) ->
      case build(request, correlation, config.label) {
        Ok(context) -> Ok(context)
        Error(response) -> {
          case response.status {
            401 | 403 ->
              emit.http_rejected(
                response.status,
                telemetry.Unauthenticated,
                correlation,
                config.label,
              )
            _ -> Nil
          }
          Error(response)
        }
      }
  }
}

fn runtime_config(config: Config(context)) -> runtime.Config {
  let rt =
    runtime.config()
    |> runtime.with_max_live_exchanges(1)
    |> runtime.with_max_frame_bytes(config.max_body_bytes)
    |> runtime.with_max_json_depth(config.max_json_depth)
    |> runtime.with_invocation_timeout(config.request_timeout)
    |> runtime.with_cancellation_grace(config.cancellation_grace)
    |> runtime.with_tombstone_retention(duration.seconds(1))
  case config.label {
    Some(label) -> runtime.with_label(rt, label)
    None -> rt
  }
}

fn dispatch(
  handler: Handler(context),
  lease: Lease(context),
  request: Request(BitArray),
  context: context,
  correlation: Option(Correlation),
  closed: process.Selector(Nil),
  stream: Bool,
) -> http_mist.Reply {
  let config = lease.config
  let body = request.body
  case v2026.http_route(body) {
    Error(Nil) ->
      reject(
        config,
        400,
        telemetry.MalformedBody,
        correlation,
        "Invalid MCP JSON-RPC envelope",
      )
    Ok(route) ->
      case
        valid_route_headers(request, route)
        && valid_parameter_headers(request, lease.server, route)
      {
        False -> {
          emit.http_rejected(
            400,
            telemetry.RoutingHeaderMismatch,
            correlation,
            config.label,
          )
          http_mist.Buffered(json_response(
            400,
            v2026.encode_http_routing_error(body),
          ))
        }
        True ->
          case v2026.http_admission_failure(body) {
            Some(v2026.HttpFailure(status, failure)) ->
              http_mist.Buffered(json_response(status, failure))
            None ->
              case route.method == "subscriptions/listen" && !stream {
                True ->
                  reject(
                    config,
                    406,
                    telemetry.NotAcceptable,
                    correlation,
                    "subscriptions/listen needs a text/event-stream response",
                  )
                False ->
                  run(
                    handler,
                    lease,
                    route,
                    body,
                    context,
                    correlation,
                    closed,
                    stream,
                  )
              }
          }
      }
  }
}

fn run(
  handler: Handler(context),
  lease: Lease(context),
  route: v2026.HttpRoute,
  body: BitArray,
  context: context,
  correlation: Option(Correlation),
  closed: process.Selector(Nil),
  stream: Bool,
) -> http_mist.Reply {
  let config = lease.config
  let timeout_ms = duration.to_milliseconds(config.request_timeout)
  case start_broker(config.max_response_bytes) {
    Error(Nil) ->
      http_mist.Buffered(plain(500, "Relay could not answer the request"))
    Ok(broker) ->
      case
        runtime.start(lease.server, runtime_config(config), fn(output) {
          deliver(broker, output, timeout_ms)
        })
      {
        Error(_) -> {
          stop_broker(broker)
          http_mist.Buffered(plain(500, "Relay runtime failed to start"))
        }
        Ok(rt) -> {
          let exchange = reducer.new_exchange_id()
          attach_runtime(broker, rt, exchange)
          case runtime.send_frame(rt, exchange, context, body, correlation) {
            Error(runtime.FrameTooDeep(_)) -> {
              finish(broker, rt)
              emit.http_rejected(
                400,
                telemetry.MalformedBody,
                correlation,
                config.label,
              )
              http_mist.Buffered(json_response(
                400,
                bit_array.from_string(
                  json.to_string(jsonrpc.error_to_json(
                    None,
                    jsonrpc.RpcError(
                      jsonrpc.invalid_request_code,
                      "JSON nesting exceeds the configured depth.",
                      None,
                    ),
                  )),
                ),
              ))
            }
            Error(_) -> {
              finish(broker, rt)
              http_mist.Buffered(plain(
                500,
                "Relay could not accept the request",
              ))
            }
            Ok(Nil) ->
              case route.has_id {
                False -> {
                  finish(broker, rt)
                  http_mist.Buffered(empty_response(202))
                }
                True ->
                  case peek(broker) {
                    Ok(#(frames, True)) -> {
                      finish(broker, rt)
                      http_mist.Buffered(respond_with_frames(frames))
                    }
                    _ ->
                      case stream {
                        True -> {
                          case route.method == "subscriptions/listen" {
                            True ->
                              process.send(
                                handler.subject,
                                AddStream(lease.slot, rt, lease.generation),
                              )
                            False -> Nil
                          }
                          transfer(broker, handler, lease.slot)
                          streamed(broker, config)
                        }
                        False ->
                          buffered(broker, rt, exchange, closed, timeout_ms)
                      }
                  }
              }
          }
        }
      }
  }
}

fn streamed(
  broker: Broker(context),
  config: Config(context),
) -> http_mist.Reply {
  http_mist.Streamed(
    head: response.new(200)
      |> response.set_header("content-type", "text/event-stream")
      |> response.set_header("cache-control", "no-store")
      |> response.set_header("mcp-protocol-version", "2026-07-28")
      |> response.set_body(Nil),
    next: fn(wait_ms) { next(broker, wait_ms) },
    close: fn() { client_gone(broker) },
    keepalive_ms: duration.to_milliseconds(config.sse_keepalive),
    write_timeout_ms: duration.to_milliseconds(config.request_timeout),
  )
}

fn buffered(
  broker: Broker(context),
  rt: runtime.Runtime(context),
  exchange: reducer.ExchangeId,
  closed: process.Selector(Nil),
  timeout_ms: Int,
) -> http_mist.Reply {
  let deadline = monotonic_ms() + timeout_ms
  case collect(broker, closed, deadline, []) {
    Collected(frames) -> {
      finish(broker, rt)
      http_mist.Buffered(respond_with_frames(frames))
    }
    ClientClosed -> {
      // The same reducer path as a stdio cancellation: the exchange closes,
      // its invocation is cancelled, and no response is written.
      runtime.exchange_closed(rt, exchange)
      finish(broker, rt)
      http_mist.Buffered(
        plain(499, "Client closed the request")
        |> response.set_header("connection", "close"),
      )
    }
    TooLate -> {
      finish(broker, rt)
      http_mist.Buffered(plain(
        504,
        "Relay response timed out or exceeded its limit",
      ))
    }
  }
}

type Collection {
  Collected(List(BitArray))
  ClientClosed
  TooLate
}

const poll_ms = 50

fn collect(
  broker: Broker(context),
  closed: process.Selector(Nil),
  deadline: Int,
  frames: List(BitArray),
) -> Collection {
  case process.selector_receive(closed, 0) {
    Ok(Nil) -> ClientClosed
    Error(Nil) -> {
      let remaining = deadline - monotonic_ms()
      case remaining <= 0 {
        True -> TooLate
        False ->
          case next(broker, int.min(remaining, poll_ms)) {
            http_mist.Idle -> collect(broker, closed, deadline, frames)
            http_mist.Ended ->
              case frames {
                [] -> TooLate
                _ -> Collected(list.reverse(frames))
              }
            http_mist.Data(bytes) -> {
              let frames = [bytes, ..frames]
              case v2026.is_response_frame(bytes) {
                True -> Collected(list.reverse(frames))
                False -> collect(broker, closed, deadline, frames)
              }
            }
          }
      }
    }
  }
}

// --- the per-request broker --------------------------------------------------

// The broker holds one request's output between the runtime, which writes
// synchronously, and the reader: the buffered request process or the event
// stream. It never calls the runtime synchronously, so neither can block the
// other.
type BrokerMessage(context) {
  Deliver(output: runtime.Output, reply: Subject(Result(Nil, Nil)))
  Next(wait_ms: Int, reply: Subject(http_mist.Event))
  WaitExpired(ref: Int)
  Peek(reply: Subject(#(List(BitArray), Bool)))
  AttachRuntime(runtime: runtime.Runtime(context), exchange: reducer.ExchangeId)
  TransferSlot(hub: Subject(Message(context)), slot: Int)
  ClientGone
  Finish
}

type BrokerState(context) {
  BrokerState(
    self: Subject(BrokerMessage(context)),
    queue: List(BitArray),
    ended: Bool,
    failed: Bool,
    written: Int,
    limit: Int,
    waiting: Option(#(Int, Subject(http_mist.Event))),
    runtime: Option(#(runtime.Runtime(context), reducer.ExchangeId)),
    slot: Option(#(Subject(Message(context)), Int)),
  )
}

type Broker(context) =
  Subject(BrokerMessage(context))

fn start_broker(limit: Int) -> Result(Broker(context), Nil) {
  actor.new_with_initialiser(hub_timeout, fn(self) {
    BrokerState(
      self: self,
      queue: [],
      ended: False,
      failed: False,
      written: 0,
      limit: limit,
      waiting: None,
      runtime: None,
      slot: None,
    )
    |> actor.initialised
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_broker)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error(Nil)
}

fn attach_runtime(
  broker: Broker(context),
  rt: runtime.Runtime(context),
  exchange: reducer.ExchangeId,
) -> Nil {
  process.send(broker, AttachRuntime(rt, exchange))
}

fn transfer(
  broker: Broker(context),
  handler: Handler(context),
  slot: Int,
) -> Nil {
  process.send(broker, TransferSlot(handler.subject, slot))
  case process.subject_owner(broker) {
    Ok(pid) -> process.send(handler.subject, Transfer(slot, pid))
    Error(Nil) -> Nil
  }
}

// The runtime calls this synchronously, so it must not wait on a broker
// that already ended its stream: a dead broker fails the write at once and
// the runtime closes the exchange.
fn deliver(
  broker: Broker(context),
  output: runtime.Output,
  timeout_ms: Int,
) -> Result(Nil, Nil) {
  case process.subject_owner(broker) {
    Error(Nil) -> Error(Nil)
    Ok(owner) -> {
      let monitor = process.monitor(owner)
      let reply = process.new_subject()
      process.send(broker, Deliver(output, reply))
      let delivered =
        process.new_selector()
        |> process.select(reply)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        |> process.selector_receive(timeout_ms)
      let _ = process.demonitor_process(monitor)
      case delivered {
        Ok(result) -> result
        Error(Nil) -> Error(Nil)
      }
    }
  }
}

fn next(broker: Broker(context), wait_ms: Int) -> http_mist.Event {
  let reply = process.new_subject()
  process.send(broker, Next(wait_ms, reply))
  case process.receive(reply, wait_ms + hub_timeout) {
    Ok(event) -> event
    Error(Nil) -> http_mist.Ended
  }
}

fn peek(broker: Broker(context)) -> Result(#(List(BitArray), Bool), Nil) {
  let reply = process.new_subject()
  process.send(broker, Peek(reply))
  process.receive(reply, hub_timeout)
}

fn client_gone(broker: Broker(context)) -> Nil {
  process.send(broker, ClientGone)
}

// Ends a buffered request's runtime without holding its response: `close`
// cancels whatever still runs, and the runtime stops itself once each
// cancelled handler has returned or its grace has ended.
fn finish(broker: Broker(context), rt: runtime.Runtime(context)) -> Nil {
  runtime.close(rt)
  let _ = process.spawn_unlinked(fn() { runtime.stop(rt) })
  process.send(broker, Finish)
}

fn stop_broker(broker: Broker(context)) -> Nil {
  process.send(broker, Finish)
}

fn handle_broker(
  state: BrokerState(context),
  message: BrokerMessage(context),
) -> actor.Next(BrokerState(context), BrokerMessage(context)) {
  case message {
    Deliver(runtime.OutputWrite(_, bytes), reply) -> {
      let size = bit_array.byte_size(bytes)
      case state.failed || state.written + size > state.limit {
        True -> {
          process.send(reply, Error(Nil))
          actor.continue(BrokerState(..state, failed: True))
        }
        False -> {
          process.send(reply, Ok(Nil))
          let state = BrokerState(..state, written: state.written + size)
          case state.waiting {
            Some(#(_, waiter)) -> {
              process.send(waiter, http_mist.Data(bytes))
              actor.continue(BrokerState(..state, waiting: None))
            }
            None ->
              actor.continue(
                BrokerState(..state, queue: list.append(state.queue, [bytes])),
              )
          }
        }
      }
    }
    Deliver(runtime.OutputClose(_), reply) -> {
      process.send(reply, Ok(Nil))
      let state = BrokerState(..state, ended: True)
      case state.waiting, state.queue {
        Some(#(_, waiter)), [] -> {
          process.send(waiter, http_mist.Ended)
          end_stream(BrokerState(..state, waiting: None))
        }
        _, _ -> actor.continue(state)
      }
    }
    Next(wait_ms, reply) ->
      case state.queue, state.ended || state.failed {
        [bytes, ..rest], _ -> {
          process.send(reply, http_mist.Data(bytes))
          actor.continue(BrokerState(..state, queue: rest))
        }
        [], True -> {
          process.send(reply, http_mist.Ended)
          end_stream(state)
        }
        [], False -> {
          let ref = unique_integer()
          let _ = process.send_after(state.self, wait_ms, WaitExpired(ref))
          actor.continue(BrokerState(..state, waiting: Some(#(ref, reply))))
        }
      }
    WaitExpired(ref) ->
      case state.waiting {
        Some(#(waiting, waiter)) if waiting == ref -> {
          process.send(waiter, http_mist.Idle)
          actor.continue(BrokerState(..state, waiting: None))
        }
        _ -> actor.continue(state)
      }
    Peek(reply) -> {
      process.send(reply, #(state.queue, state.ended))
      case state.ended {
        True -> actor.continue(BrokerState(..state, queue: []))
        False -> actor.continue(state)
      }
    }
    AttachRuntime(rt, exchange) ->
      actor.continue(BrokerState(..state, runtime: Some(#(rt, exchange))))
    TransferSlot(hub, slot) ->
      actor.continue(BrokerState(..state, slot: Some(#(hub, slot))))
    ClientGone -> {
      case state.runtime {
        Some(#(rt, exchange)) -> runtime.exchange_closed(rt, exchange)
        None -> Nil
      }
      end_stream(state)
    }
    Finish -> actor.stop()
  }
}

// Ends a stream the broker owns: stops its runtime without waiting on it
// and frees its endpoint slot.
fn end_stream(
  state: BrokerState(context),
) -> actor.Next(BrokerState(context), BrokerMessage(context)) {
  case state.slot {
    Some(#(hub, slot)) -> {
      case state.runtime {
        Some(#(rt, _)) -> {
          runtime.close(rt)
          let _ = process.spawn_unlinked(fn() { runtime.stop(rt) })
          Nil
        }
        None -> Nil
      }
      process.send(hub, Release(slot))
      actor.stop()
    }
    // A buffered request finishes the broker itself.
    None -> actor.continue(state)
  }
}

// --- request checks ----------------------------------------------------------

fn validate_headers(
  request: Request(BitArray),
  config: Config(context),
) -> Result(Bool, #(Int, telemetry.RejectReason)) {
  use _ <- result.try(case host_allowed(request.host, allowed_hosts(config)) {
    True -> Ok(Nil)
    False -> Error(#(403, telemetry.HostNotAllowed))
  })
  use _ <- result.try(case request.get_header(request, "origin") {
    Error(Nil) -> Ok(Nil)
    Ok(origin) ->
      case origin_allowed(origin, config.allowed_origins) {
        True -> Ok(Nil)
        False -> Error(#(403, telemetry.OriginNotAllowed))
      }
  })
  use _ <- result.try(case request.get_header(request, "content-type") {
    Ok(content_type) ->
      case media_type(content_type) == "application/json" {
        True -> Ok(Nil)
        False -> Error(#(415, telemetry.UnsupportedMediaType))
      }
    Error(Nil) -> Error(#(415, telemetry.UnsupportedMediaType))
  })
  case request.get_header(request, "accept") {
    Error(Nil) -> Error(#(406, telemetry.NotAcceptable))
    Ok(accept) -> {
      let json_accepted = accepts(accept, "application/json")
      let sse_accepted = accepts(accept, "text/event-stream")
      case json_accepted || sse_accepted {
        True -> Ok(sse_accepted)
        False -> Error(#(406, telemetry.NotAcceptable))
      }
    }
  }
}

fn accepts(raw: String, wanted: String) -> Bool {
  string.split(string.lowercase(raw), on: ",")
  |> list.any(fn(entry) {
    case string.split(entry, on: ";") {
      [media, ..parameters] -> {
        let media = string.trim(media)
        { media == wanted || media == "*/*" } && acceptable_quality(parameters)
      }
      [] -> False
    }
  })
}

fn acceptable_quality(parameters: List(String)) -> Bool {
  case
    list.find_map(parameters, fn(parameter) {
      let parameter = string.trim(parameter)
      case string.starts_with(parameter, "q=") {
        True -> Ok(string.drop_start(parameter, 2))
        False -> Error(Nil)
      }
    })
  {
    Error(Nil) -> True
    Ok(raw) ->
      case float.parse(raw), int.parse(raw) {
        Ok(quality), _ -> quality >. 0.0 && quality <=. 1.0
        _, Ok(quality) -> quality == 1
        _, _ -> False
      }
  }
}

fn media_type(content_type: String) -> String {
  case string.split(string.lowercase(content_type), on: ";") {
    [first, ..] -> string.trim(first)
    [] -> ""
  }
}

fn host_allowed(authority: String, allowed: List(String)) -> Bool {
  let host = authority_host(string.lowercase(authority))
  list.any(allowed, fn(candidate) {
    host == authority_host(string.lowercase(candidate))
  })
}

fn origin_allowed(origin: String, allowed: List(String)) -> Bool {
  let origin = string.lowercase(origin)
  list.any(allowed, fn(candidate) {
    case origin_parts(origin), origin_parts(string.lowercase(candidate)) {
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

fn valid_route_headers(
  request: Request(BitArray),
  route: v2026.HttpRoute,
) -> Bool {
  let header = fn(name) { request.get_header(request, name) }
  let version_matches = case
    route.protocol_version,
    header("mcp-protocol-version")
  {
    Some(version), Ok(sent) -> string.trim(sent) == version
    Some(_), Error(Nil) -> False
    None, _ -> True
  }
  case header("mcp-method") {
    Error(Nil) -> False
    Ok(method) ->
      case uri.percent_decode(string.trim(method)) {
        Error(Nil) -> False
        Ok(method) -> {
          let name_matches = case route.name, header("mcp-name") {
            Some(name), Ok(sent) ->
              case uri.percent_decode(string.trim(sent)) {
                Ok(sent) -> sent == name
                Error(Nil) -> False
              }
            Some(_), Error(Nil) -> False
            None, Error(Nil) -> True
            None, Ok(_) -> False
          }
          method == route.method && name_matches && version_matches
        }
      }
  }
}

// A property whose schema declares `x-mcp-header` must arrive both in the
// arguments and in the matching `Mcp-Param-<suffix>` header, with the same
// value; base64 header values use the `=?base64?...?=` form.
fn valid_parameter_headers(
  request: Request(BitArray),
  srv: Server(context),
  route: v2026.HttpRoute,
) -> Bool {
  case route.method, route.name, route.arguments {
    "tools/call", Some(name), Some(arguments) ->
      case
        list.find(server.tools(srv), fn(declaration) {
          declaration.name == name
        })
      {
        Error(Nil) -> True
        Ok(declaration) ->
          case declaration.input_schema {
            value.Object(fields) ->
              case list.key_find(fields, "properties") {
                Ok(value.Object(properties)) ->
                  list.all(properties, fn(property) {
                    parameter_header_matches(request, property, arguments)
                  })
                _ -> True
              }
            _ -> True
          }
      }
    _, _, _ -> True
  }
}

fn parameter_header_matches(
  request: Request(BitArray),
  property: #(String, value.Value),
  arguments: value.Value,
) -> Bool {
  let #(name, schema) = property
  case schema {
    value.Object(fields) ->
      case list.key_find(fields, "x-mcp-header") {
        Ok(value.String("")) -> False
        Ok(value.String(suffix)) -> {
          let argument = case arguments {
            value.Object(members) -> list.key_find(members, name)
            _ -> Error(Nil)
          }
          let header =
            request.get_header(
              request,
              "mcp-param-" <> string.lowercase(suffix),
            )
          case argument, header {
            Error(Nil), Error(Nil) -> True
            Ok(value.String(expected)), Ok(raw) ->
              decode_parameter_header(string.trim(raw)) == Ok(expected)
            _, _ -> False
          }
        }
        _ -> True
      }
    _ -> True
  }
}

@external(erlang, "relay_ffi", "decode_base64_strict")
fn decode_base64_strict(encoded: String) -> Result(String, Nil)

fn decode_parameter_header(raw: String) -> Result(String, Nil) {
  let prefix = "=?base64?"
  let suffix = "?="
  case string.starts_with(raw, prefix) && string.ends_with(raw, suffix) {
    True ->
      raw
      |> string.drop_start(string.length(prefix))
      |> string.drop_end(string.length(suffix))
      |> decode_base64_strict
    False -> Ok(raw)
  }
}

// --- responses ---------------------------------------------------------------

fn respond_with_frames(frames: List(BitArray)) -> Response(BytesTree) {
  case list.last(frames) {
    Error(Nil) -> plain(500, "Relay produced no response")
    Ok(bytes) -> {
      let status = option.unwrap(v2026.http_response_status(bytes), 200)
      json_response(status, bytes)
    }
  }
}

fn json_response(status: Int, bytes: BitArray) -> Response(BytesTree) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_header("mcp-protocol-version", "2026-07-28")
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(bytes_tree.from_bit_array(bytes))
}

fn empty_response(status: Int) -> Response(BytesTree) {
  response.new(status)
  |> response.set_header("mcp-protocol-version", "2026-07-28")
  |> response.set_body(bytes_tree.new())
}

fn plain(status: Int, message: String) -> Response(BytesTree) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(bytes_tree.from_string(message))
}
