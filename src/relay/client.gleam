//// An MCP client for the `2026-07-28` revision, over Streamable HTTP, a
//// local stdio child process, or a server in the same VM.
////
//// Build a `Config` with `http(url)`, `stdio(executable, arguments)` or
//// `in_process(server, context)`, adjust it with the `with_*` setters, and
//// `connect`. Then:
////
//// - `call(client, definition, input)` calls a tool with the same
////   `relay/tool.Definition` the server registered, and decodes its output;
//// - `list_tools` and `call_discovered` serve tools known only at runtime;
//// - `read_resource`, `get_prompt`, `complete`, `discover`, the listings,
////   `listen` and the raw `call_raw` and `list_raw` cover the rest.
////
//// Every operation returns `Result(_, Error)`. `Error` carries the HTTP
//// status, the JSON-RPC error, or the transport failure with its
//// submission `Evidence`; branch on `kind(error)` or `evidence(error)` and
//// log `describe_error(error)` with `error_correlation(error)`, the
//// correlation the call was sent with, which finds the server's events for
//// it. A tool's own failure is not an `Error`: it is the `ToolFailed`
//// result.
////
//// Per-call controls are views on the client: `with_deadline`,
//// `with_cancellation`, `with_correlation` and `with_idempotency_key` return a
//// new handle over the same connection, and every operation through it
//// honours them. In MCP `2026-07-28` closing the connection cancels a
//// request, so a deadline or a cancellation that ends an HTTP call closes
//// that call's connection, and the server stops its handler; the next call
//// reconnects.
////
//// A view's correlation travels to the server: in the request's `_meta`
//// under `io.github.gleam-dream/correlation` on every transport, and over
//// HTTP also in the `x-correlation-id` header. A Relay server tags that
//// request's events with it and hands it to the handler and the verifier.
//// A view without a correlation mints a fresh one per request and sends
//// that, so the client's `[relay, client, call]` event and the server's
//// events always share one, and so does a failed call's `error_correlation`.
//// A listing, or a call and its `resume`, is one call: its requests share the
//// correlation. Only a correlation of visible ASCII characters
//// (`!` to `~`) is sent; the server mints its own for any other. The server treats the value as
//// untrusted telemetry and never uses it to authorize anything.
////
//// ```gleam
//// import gleam/result
//// import relay/client
//// import relay/tool
////
//// pub fn greet(
////   greet: tool.Definition(String, String),
//// ) -> Result(String, client.Error) {
////   use config <- result.try(client.http("http://127.0.0.1:3000/"))
////   use peer <- result.try(client.connect(config))
////   let outcome = client.call(peer, greet, "Ada")
////   client.close(peer)
////   case outcome {
////     Ok(client.Succeeded(text, _)) -> Ok(text)
////     Ok(_) -> Ok("the tool did not answer")
////     Error(error) -> Error(error)
////   }
//// }
//// ```
////
//// | Setting | Default | Setter |
//// | --- | --- | --- |
//// | request timeout | 30 s | `with_timeout`, per call `with_deadline` |
//// | connect | 10 s | `with_connect_timeout` |
//// | response size | 1 MiB | `with_max_response_bytes` |
//// | listings | 256 pages, 10,000 items | `with_listing_limits` |
//// | stdio pending calls | 64, then `TooManyPendingCalls` | `with_max_pending_calls` |
//// | input methods advertised | none | `with_input_methods` |
//// | headers over plain HTTP to a non-loopback host | refused | `allow_plaintext_headers` |
//// | retries | none: decide with `evidence` | |

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/uri
import http_gun
import http_gun/body
import http_gun/cancellation.{type Token}
import http_gun/config as gun_config
import http_gun/deadline.{type Deadline}
import http_gun/destination
import http_gun/error as gun_error
import json/blueprint/codec
import json/blueprint/value.{type Value}
import relay/completion
import relay/content.{type ContentBlock, type ResourceContents}
import relay/internal/carrier
import relay/internal/core
import relay/internal/emit
import relay/internal/protocol/v2026_07_28 as v2026
import relay/internal/subscriptions_state as subs
import relay/internal/transport/stdio_client
import relay/internal/wire
import relay/prompts
import relay/reducer
import relay/resources
import relay/runtime
import relay/server.{type Server}
import relay/subscriptions.{type Notification}
import relay/telemetry
import relay/tool
import sinal/correlation.{type Correlation}

const protocol_version = "2026-07-28"

// --- configuration -----------------------------------------------------------

type Target {
  HttpTarget(secure: Bool, host: String, port: Int, path: String)
  StdioTarget(command: fn() -> #(String, List(String)))
  InProcessTarget(open: fn(Int) -> Result(Peer, Nil))
}

/// How to reach a server. Build it with `http`, `stdio` or `in_process`;
/// `connect` validates it.
pub opaque type Config {
  Config(
    target: Target,
    timeout: Duration,
    connect_timeout: Duration,
    max_response_bytes: Int,
    input_methods: List(tool.InputMethod),
    max_listing_pages: Int,
    max_listing_items: Int,
    headers: Option(fn() -> List(#(String, String))),
    plaintext_headers: Bool,
    ca_cert_file: Option(String),
    http_client: Option(http_gun.Client),
    max_pending_calls: Int,
    label: Option(String),
  )
}

fn defaults(target: Target) -> Config {
  Config(
    target: target,
    timeout: duration.seconds(30),
    connect_timeout: duration.seconds(10),
    max_response_bytes: 1_048_576,
    input_methods: [],
    max_listing_pages: 256,
    max_listing_items: 10_000,
    headers: None,
    plaintext_headers: False,
    ca_cert_file: None,
    http_client: None,
    max_pending_calls: 64,
    label: None,
  )
}

@external(erlang, "relay_url_ffi", "valid_ipv6")
fn valid_ipv6(host: String) -> Bool

@external(erlang, "relay_url_ffi", "path_without_controls")
fn path_without_controls(path: String) -> Bool

/// A Streamable HTTP server at an absolute `http` or `https` URL, such as
/// `"https://mcp.example.com/mcp"`. A URL with userinfo, a query or a
/// fragment fails with `InvalidConfig(Url)`; a missing path becomes `/`.
pub fn http(url: String) -> Result(Config, Error) {
  case parse_http_url(url) {
    Ok(target) -> Ok(defaults(target))
    Error(Nil) -> Error(config_error(Url))
  }
}

fn parse_http_url(url: String) -> Result(Target, Nil) {
  use parsed <- result.try(parse_uri(url))
  use scheme <- result.try(option.to_result(parsed.scheme, Nil))
  let secure = string.lowercase(scheme) == "https"
  use host <- result.try(option.to_result(parsed.host, Nil))
  let port = case parsed.port {
    Some(port) -> port
    None if secure -> 443
    None -> 80
  }
  let path = case parsed.path {
    "" -> "/"
    path -> path
  }
  case
    { string.lowercase(scheme) == "http" || secure }
    && parsed.userinfo == None
    && parsed.query == None
    && parsed.fragment == None
    && valid_authority(url)
    && valid_host(host)
    && path_without_controls(path)
    && valid_percent_escapes(string.to_graphemes(path))
    && string.starts_with(path, "/")
    && port > 0
    && port < 65_536
  {
    True -> Ok(HttpTarget(secure, unbracket(host), port, path))
    False -> Error(Nil)
  }
}

fn parse_uri(url: String) -> Result(uri.Uri, Nil) {
  let lowered = string.lowercase(url)
  case
    string.starts_with(lowered, "http://[")
    || string.starts_with(lowered, "https://[")
  {
    False -> uri.parse(url)
    True -> {
      use #(prefix, bracketed) <- result.try(string.split_once(url, "["))
      use #(address, suffix) <- result.try(string.split_once(bracketed, "]"))
      case
        valid_ipv6(address)
        && {
          suffix == ""
          || string.starts_with(suffix, "/")
          || string.starts_with(suffix, ":")
        }
      {
        False -> Error(Nil)
        True -> {
          use parsed <- result.map(uri.parse(
            prefix <> "relay-ipv6.invalid" <> suffix,
          ))
          uri.Uri(..parsed, host: Some("[" <> address <> "]"))
        }
      }
    }
  }
}

fn valid_authority(url: String) -> Bool {
  case string.split_once(url, "://") {
    Error(Nil) -> False
    Ok(#(_, rest)) -> {
      let authority = case string.split_once(rest, "/") {
        Ok(#(authority, _)) -> authority
        Error(Nil) -> rest
      }
      authority != ""
      && !string.ends_with(authority, ":")
      && !string.contains(authority, "%")
      && !string.contains(authority, "\\")
    }
  }
}

fn valid_percent_escapes(chars: List(String)) -> Bool {
  case chars {
    [] -> True
    ["%", first, second, ..rest] ->
      is_hex(first) && is_hex(second) && valid_percent_escapes(rest)
    ["%", ..] -> False
    [_, ..rest] -> valid_percent_escapes(rest)
  }
}

fn is_hex(char: String) -> Bool {
  string.contains("0123456789abcdefABCDEF", char)
}

fn valid_host(host: String) -> Bool {
  host != ""
  && path_without_controls(host)
  && string.trim(host) == host
  && !string.contains(host, " ")
  && { !string.starts_with(host, "[") || string.ends_with(host, "]") }
}

fn unbracket(host: String) -> String {
  case string.starts_with(host, "[") && string.ends_with(host, "]") {
    True -> host |> string.drop_start(1) |> string.drop_end(1)
    False -> host
  }
}

/// A server launched as a local child process that speaks MCP on its
/// standard input and output. The executable runs directly, never through a
/// shell. The command is held in a closure, so it does not print in
/// `string.inspect`, crash reports or logs.
pub fn stdio(executable: String, arguments: List(String)) -> Config {
  defaults(StdioTarget(fn() { #(executable, arguments) }))
}

/// A server in this VM, served through its own `relay/runtime` with this
/// context: no socket and no child process, the same wire messages. Useful
/// for tests (`relay/testing.connect`) and for composing servers.
pub fn in_process(server: Server(context), context: context) -> Config {
  defaults(
    InProcessTarget(fn(max_frame_bytes) {
      in_process_peer(server, context, max_frame_bytes)
    }),
  )
}

/// How long one request may take; a view's `with_deadline` can shorten it.
pub fn with_timeout(config: Config, timeout: Duration) -> Config {
  Config(..config, timeout: timeout)
}

/// How long connecting, or starting the stdio child, may take.
pub fn with_connect_timeout(config: Config, timeout: Duration) -> Config {
  Config(..config, connect_timeout: timeout)
}

/// The largest response, or listen event, the client reads.
pub fn with_max_response_bytes(config: Config, bytes: Int) -> Config {
  Config(..config, max_response_bytes: bytes)
}

/// Advertises the server-initiated input methods this application will
/// answer itself; a request for another method fails with
/// `UnsupportedInputRequest`.
pub fn with_input_methods(
  config: Config,
  methods: List(tool.InputMethod),
) -> Config {
  Config(..config, input_methods: methods)
}

/// Bounds the listings: at most `pages` pages and `items` items.
pub fn with_listing_limits(config: Config, pages: Int, items: Int) -> Config {
  Config(..config, max_listing_pages: pages, max_listing_items: items)
}

/// Adds headers to every HTTP request, computed per request so a
/// refreshing token source plugs in:
/// `with_headers(config, fn() { [#("authorization", "Bearer " <> token())] })`.
/// Header names must be lowercase. Over plain `http://`, a client with
/// headers reaches only loopback addresses unless `allow_plaintext_headers`.
pub fn with_headers(
  config: Config,
  headers: fn() -> List(#(String, String)),
) -> Config {
  Config(..config, headers: Some(headers))
}

/// Lets a client with headers send them over plain `http://` to a
/// non-loopback host, where anyone on the path can read them.
pub fn allow_plaintext_headers(config: Config) -> Config {
  Config(..config, plaintext_headers: True)
}

/// Trusts the CA certificates in this PEM file instead of the system's, for
/// HTTPS.
pub fn with_ca_cert_file(config: Config, path: String) -> Config {
  Config(..config, ca_cert_file: Some(path))
}

/// Sends through this HTTP Gun client instead of starting one, sharing its
/// pool, destination policy, cassettes and telemetry. Relay narrows each
/// request to the URL's host and never stops the client.
pub fn with_http_client(config: Config, client: http_gun.Client) -> Config {
  Config(..config, http_client: Some(client))
}

/// How many calls may wait for a stdio child at once.
pub fn with_max_pending_calls(config: Config, count: Int) -> Config {
  Config(..config, max_pending_calls: count)
}

/// The `client` label in Relay's client telemetry, and the HTTP Gun label of
/// a client Relay starts.
pub fn with_label(config: Config, label: String) -> Config {
  Config(..config, label: Some(label))
}

// --- errors ------------------------------------------------------------------

/// The setting `connect` refused.
pub type ConfigField {
  Url
  RequestTimeout
  ConnectTimeout
  MaxResponseBytes
  ListingLimits
  CaCertFile
  MaxPendingCalls
  Headers
}

/// Whether the server may have received a request.
pub type Evidence {
  /// Nothing reached the server; sending again cannot duplicate an effect.
  NotSent
  /// The request may have reached the server, which may have acted on it.
  MaybeSent
  /// The server received the request and answered it.
  Completed
}

/// Why an operation failed. It may gain variants in a minor release:
/// branch on `kind` and `evidence`, and match variants with a `_` arm.
///
/// Every variant ends with the `correlation` the operation was sent with,
/// so a caller can tie the failure to the server's logs; read it with
/// `error_correlation`, and match payloads with `..` so the pattern does not
/// depend on it: `HttpStatus(401, Some(challenge), ..)`. An error that
/// precedes any call, from `http`, `connect` or a bad setting, carries a
/// fresh correlation that no server saw.
pub type Error {
  InvalidConfig(field: ConfigField, correlation: Correlation)
  /// The connection or the child process could not be established.
  ConnectFailed(correlation: Correlation)
  /// The HTTP client's destination policy refused the host.
  Refused(correlation: Correlation)
  TimedOut(evidence: Evidence, correlation: Correlation)
  Cancelled(evidence: Evidence, correlation: Correlation)
  ConnectionClosed(evidence: Evidence, correlation: Correlation)
  ResponseTooLarge(limit: Int, correlation: Correlation)
  TooManyPendingCalls(limit: Int, correlation: Correlation)
  /// The server answered with a non-success HTTP status and no JSON-RPC
  /// error; a 401 or 403 carries its `WWW-Authenticate` challenge.
  HttpStatus(
    status: Int,
    www_authenticate: Option(String),
    correlation: Correlation,
  )
  /// The server answered with a JSON-RPC error object.
  RpcError(
    code: Int,
    message: String,
    data: Option(Value),
    correlation: Correlation,
  )
  /// The response broke the protocol; `detail` is for logs only.
  MalformedResponse(detail: String, correlation: Correlation)
  /// The server does not support the `2026-07-28` revision.
  UnsupportedVersion(supported: List(String), correlation: Correlation)
  /// The server asked for an input method this client did not advertise.
  UnsupportedInputRequest(method: String, correlation: Correlation)
  /// The arguments could not be encoded or are not a JSON object; `detail`
  /// is for logs only.
  InvalidArguments(detail: String, correlation: Correlation)
  /// `resume` needs exactly one JSON object response per request key.
  InvalidInputResponses(correlation: Correlation)
  ListingLimitExceeded(limit: Int, correlation: Correlation)
}

/// The correlation the failed operation was sent with: the view's
/// (`with_correlation`), else the one minted for that call. Log it to find
/// the server's events for the request, or hand it to the caller who
/// reports the failure.
///
/// ```gleam
/// case client.call(peer, greet, "Ada") {
///   Error(error) ->
///     log.warning(
///       client.describe_error(error)
///       <> " correlation="
///       <> correlation.to_string(client.error_correlation(error)),
///     )
///   Ok(_) -> Nil
/// }
/// ```
pub fn error_correlation(error: Error) -> Correlation {
  case error {
    InvalidConfig(_, correlation)
    | ConnectFailed(correlation)
    | Refused(correlation)
    | TimedOut(_, correlation)
    | Cancelled(_, correlation)
    | ConnectionClosed(_, correlation)
    | ResponseTooLarge(_, correlation)
    | TooManyPendingCalls(_, correlation)
    | HttpStatus(_, _, correlation)
    | RpcError(_, _, _, correlation)
    | MalformedResponse(_, correlation)
    | UnsupportedVersion(_, correlation)
    | UnsupportedInputRequest(_, correlation)
    | InvalidArguments(_, correlation)
    | InvalidInputResponses(correlation)
    | ListingLimitExceeded(_, correlation) -> correlation
  }
}

/// The closed classification of an `Error`. It never gains variants.
pub type Kind {
  /// Fix the configuration.
  Configuration
  /// The server could not be reached, or the connection broke.
  Unreachable
  Timeout
  Cancellation
  /// Too many calls were waiting.
  Overloaded
  /// The server refused the request with an HTTP status.
  Rejected
  /// The server answered with a JSON-RPC error or broke the protocol.
  Protocol
  /// Fix the arguments or the input responses.
  InvalidInput
  /// A response or listing exceeded its bound.
  TooLarge
}

/// The closed classification of an error, for branching.
pub fn kind(error: Error) -> Kind {
  case error {
    InvalidConfig(..) -> Configuration
    ConnectFailed(..) | Refused(..) | ConnectionClosed(..) -> Unreachable
    TimedOut(..) -> Timeout
    Cancelled(..) -> Cancellation
    TooManyPendingCalls(..) -> Overloaded
    HttpStatus(..) -> Rejected
    RpcError(..)
    | MalformedResponse(..)
    | UnsupportedVersion(..)
    | UnsupportedInputRequest(..) -> Protocol
    InvalidArguments(..) | InvalidInputResponses(..) -> InvalidInput
    ResponseTooLarge(..) | ListingLimitExceeded(..) -> TooLarge
  }
}

/// Whether the server may have received the request.
pub fn evidence(error: Error) -> Evidence {
  case error {
    InvalidConfig(..)
    | ConnectFailed(..)
    | Refused(..)
    | TooManyPendingCalls(..)
    | InvalidArguments(..)
    | InvalidInputResponses(..) -> NotSent
    TimedOut(evidence, _)
    | Cancelled(evidence, _)
    | ConnectionClosed(evidence, _) -> evidence
    ResponseTooLarge(..) | MalformedResponse(..) -> MaybeSent
    HttpStatus(..)
    | RpcError(..)
    | UnsupportedVersion(..)
    | UnsupportedInputRequest(..)
    | ListingLimitExceeded(..) -> Completed
  }
}

/// Whether sending the same request again is safe: always for a failure
/// that sent nothing, for a lost connection or a timeout only when the
/// operation is idempotent, and for HTTP 429 and 503.
pub fn is_retryable(error: Error, idempotent idempotent: Bool) -> Bool {
  case kind(error), evidence(error) {
    Unreachable, NotSent | Timeout, NotSent | Overloaded, _ -> True
    Unreachable, MaybeSent | Timeout, MaybeSent -> idempotent
    Rejected, _ ->
      case error {
        HttpStatus(429, ..) | HttpStatus(503, ..) -> True
        _ -> False
      }
    _, _ -> False
  }
}

/// A stable identifier for logs and stored records, such as
/// `"timed_out.maybe_sent"`.
pub fn name(error: Error) -> String {
  let evidence_name = fn(evidence) {
    case evidence {
      NotSent -> "not_sent"
      MaybeSent -> "maybe_sent"
      Completed -> "completed"
    }
  }
  case error {
    InvalidConfig(..) -> "invalid_config"
    ConnectFailed(..) -> "connect_failed"
    Refused(..) -> "refused"
    TimedOut(evidence, _) -> "timed_out." <> evidence_name(evidence)
    Cancelled(evidence, _) -> "cancelled." <> evidence_name(evidence)
    ConnectionClosed(evidence, _) ->
      "connection_closed." <> evidence_name(evidence)
    ResponseTooLarge(..) -> "response_too_large"
    TooManyPendingCalls(..) -> "too_many_pending_calls"
    HttpStatus(status, ..) -> "http_status." <> int.to_string(status)
    RpcError(code, ..) -> "rpc_error." <> int.to_string(code)
    MalformedResponse(..) -> "malformed_response"
    UnsupportedVersion(..) -> "unsupported_version"
    UnsupportedInputRequest(..) -> "unsupported_input_request"
    InvalidArguments(..) -> "invalid_arguments"
    InvalidInputResponses(..) -> "invalid_input_responses"
    ListingLimitExceeded(..) -> "listing_limit_exceeded"
  }
}

/// A one-line description for logs.
pub fn describe_error(error: Error) -> String {
  case error {
    InvalidConfig(field, _) ->
      "invalid Relay client setting: " <> config_field_name(field)
    ConnectFailed(_) -> "the MCP server could not be reached"
    Refused(_) -> "the destination policy refused the MCP server's address"
    TimedOut(..) -> "the MCP request timed out"
    Cancelled(..) -> "the MCP request was cancelled"
    ConnectionClosed(..) -> "the connection to the MCP server closed"
    ResponseTooLarge(limit, _) ->
      "the MCP response exceeds " <> int.to_string(limit) <> " bytes"
    TooManyPendingCalls(limit, _) ->
      "more than " <> int.to_string(limit) <> " calls wait for the stdio server"
    HttpStatus(status, ..) ->
      "the MCP server answered HTTP " <> int.to_string(status)
    RpcError(code, message, ..) ->
      "the MCP server answered JSON-RPC error "
      <> int.to_string(code)
      <> ": "
      <> message
    MalformedResponse(detail, _) -> "malformed MCP response: " <> detail
    UnsupportedVersion(supported, _) ->
      "the MCP server supports "
      <> string.join(supported, ", ")
      <> ", not "
      <> protocol_version
    UnsupportedInputRequest(method, _) ->
      "the MCP server asked for "
      <> method
      <> ", which this client did not advertise"
    InvalidArguments(detail, _) -> "invalid tool arguments: " <> detail
    InvalidInputResponses(_) ->
      "input responses must answer every request key with one JSON object"
    ListingLimitExceeded(limit, _) ->
      "the listing exceeds its limit of " <> int.to_string(limit)
  }
}

fn config_field_name(field: ConfigField) -> String {
  case field {
    Url -> "the URL"
    RequestTimeout -> "the request timeout"
    ConnectTimeout -> "the connect timeout"
    MaxResponseBytes -> "the response size limit"
    ListingLimits -> "the listing limits"
    CaCertFile -> "the CA certificate file"
    MaxPendingCalls -> "the pending call limit"
    Headers -> "the request headers"
  }
}

// --- the connection ----------------------------------------------------------

type Outgoing {
  Outgoing(body: BitArray, id: String, method: String, name: Option(String))
}

type Budget {
  Budget(
    timeout_ms: Int,
    deadline: Option(Deadline),
    cancellation: Option(Token),
    correlation: Correlation,
    max_bytes: Int,
  )
}

fn carried(budget: Budget) -> Option(String) {
  carrier.sendable(budget.correlation)
}

type Incoming {
  Incoming(status: Int, body: BitArray, www_authenticate: Option(String))
}

type Stream {
  Stream(next: fn(Int) -> Result(Option(BitArray), Error), close: fn() -> Nil)
}

type Peer {
  Peer(
    send: fn(Outgoing, Budget) -> Result(Incoming, Error),
    listen: fn(Outgoing, Budget) -> Result(Stream, Error),
    close: fn() -> Nil,
  )
}

/// A connected client. Copies share the connection; `with_deadline`,
/// `with_cancellation` and `with_correlation` return views of it.
pub opaque type Client {
  Client(
    peer: Peer,
    config: Config,
    deadline: Option(Deadline),
    cancellation: Option(Token),
    correlation: Option(Correlation),
    idempotency_key: Option(String),
  )
}

fn ms(value: Duration) -> Int {
  duration.to_milliseconds(value)
}

// An error before any call has no request to join: it carries a fresh
// correlation that no server saw.
fn config_error(field: ConfigField) -> Error {
  InvalidConfig(field, correlation.unique())
}

fn setup_error(make: fn(Correlation) -> Error) -> Error {
  make(correlation.unique())
}

fn validate(config: Config) -> Result(Config, Error) {
  case Nil {
    _ if config.max_response_bytes <= 0 -> Error(config_error(MaxResponseBytes))
    _ if config.max_listing_pages <= 0 || config.max_listing_items <= 0 ->
      Error(config_error(ListingLimits))
    _ if config.max_pending_calls <= 0 -> Error(config_error(MaxPendingCalls))
    _ ->
      case ms(config.timeout) > 0, ms(config.connect_timeout) > 0 {
        False, _ -> Error(config_error(RequestTimeout))
        _, False -> Error(config_error(ConnectTimeout))
        True, True ->
          case config.ca_cert_file, config.target {
            Some(""), _ -> Error(config_error(CaCertFile))
            Some(_), HttpTarget(secure: False, ..) ->
              Error(config_error(CaCertFile))
            Some(_), StdioTarget(_) | Some(_), InProcessTarget(_) ->
              Error(config_error(CaCertFile))
            _, _ -> Ok(config)
          }
      }
  }
}

/// Validates the configuration and connects: starts the HTTP client, the
/// stdio child or the in-process runtime. The connection is linked to the
/// calling process.
pub fn connect(config: Config) -> Result(Client, Error) {
  use config <- result.try(validate(config))
  use peer <- result.try(case config.target {
    HttpTarget(secure, host, port, path) ->
      http_peer(config, secure, host, port, path)
    StdioTarget(command) -> stdio_peer(config, command)
    InProcessTarget(open) ->
      open(config.max_response_bytes)
      |> result.replace_error(setup_error(ConnectFailed))
  })
  // A caller's HTTP Gun view may carry a correlation; Relay's telemetry
  // copies it unless a Relay view sets its own.
  let correlation = case config.http_client {
    Some(gun) -> http_gun.correlation(gun)
    None -> None
  }
  Ok(Client(peer, config, None, None, correlation, None))
}

/// Closes the connection and every request and stream on it, without
/// waiting for them. An in-flight call ends with `Cancelled(MaybeSent)`: over
/// HTTP its connection closes, which cancels it on the server; over stdio the
/// child is closed; in process its handler is cancelled and keeps the
/// runtime's cancellation grace. A caller's HTTP Gun client
/// (`with_http_client`) is not stopped, so calls in flight through it run
/// until they end; cancel them with `with_cancellation`.
pub fn close(client: Client) -> Nil {
  client.peer.close()
}

/// A view whose operations all end by `deadline`, a budget shared across
/// calls; the client's timeout still applies when it is shorter.
pub fn with_deadline(client: Client, deadline: Deadline) -> Client {
  Client(..client, deadline: Some(deadline))
}

/// A view whose operations end when `token` is cancelled. A cancelled HTTP
/// call closes its connection, which cancels it on the server; a stdio call
/// sends `notifications/cancelled`.
pub fn with_cancellation(client: Client, token: Token) -> Client {
  Client(..client, cancellation: Some(token))
}

/// A view whose operations carry this correlation in Relay's and HTTP
/// Gun's telemetry, and send it to the server, which tags the request's
/// events with it and hands it to the tool handler (`tool.correlation`).
/// Without a view correlation, each request mints a fresh one and uses it
/// the same way, so a `[relay, client, call]` event always shares its
/// correlation with the server's events. A correlation that is not visible
/// ASCII stays local: the server mints its own.
pub fn with_correlation(client: Client, correlation: Correlation) -> Client {
  Client(..client, correlation: Some(correlation))
}

/// A view whose requests carry `key` as their idempotency key, in `_meta`
/// under `io.github.gleam-dream/idempotency-key`; the handler reads it with
/// `relay/tool.idempotency_key`. Sending the same key again is your promise
/// that the request is the same one, so a server can answer a retry
/// without doing the work twice.
///
/// Use one view for one logical request and its retries, with a key unique
/// to that request, such as an order id: every request through the view
/// carries the key. A key must be 1 to 128 visible ASCII characters (`!` to
/// `~`); otherwise each request fails with `InvalidArguments` before it is
/// sent.
pub fn with_idempotency_key(client: Client, key: String) -> Client {
  Client(..client, idempotency_key: Some(key))
}

// A view without a correlation gets a fresh one per request, so the
// client's events and the server's always share one.
fn call_correlation(client: Client) -> #(Client, Correlation) {
  case client.correlation {
    Some(found) -> #(client, found)
    None -> {
      let minted = correlation.unique()
      #(Client(..client, correlation: Some(minted)), minted)
    }
  }
}

fn check_idempotency_key(
  client: Client,
  call: Correlation,
) -> Result(Nil, Error) {
  case client.idempotency_key {
    None -> Ok(Nil)
    Some(key) ->
      case carrier.valid(key) {
        True -> Ok(Nil)
        False ->
          Error(InvalidArguments(
            "the idempotency key must be 1 to 128 visible ASCII characters",
            call,
          ))
      }
  }
}

fn budget(client: Client, call: Correlation) -> Budget {
  Budget(
    timeout_ms: ms(client.config.timeout),
    deadline: client.deadline,
    cancellation: client.cancellation,
    correlation: call,
    max_bytes: client.config.max_response_bytes,
  )
}

fn remaining_ms(budget: Budget) -> Int {
  case budget.deadline {
    None -> budget.timeout_ms
    Some(deadline) ->
      int.min(budget.timeout_ms, ms(deadline.remaining(deadline)))
  }
}

fn is_cancelled(budget: Budget) -> Bool {
  case budget.cancellation {
    Some(token) -> cancellation.is_cancelled(token)
    None -> False
  }
}

// --- HTTP --------------------------------------------------------------------

fn http_peer(
  config: Config,
  secure: Bool,
  host: String,
  port: Int,
  path: String,
) -> Result(Peer, Error) {
  let entry = case string.contains(host, ":") {
    True -> "[" <> host <> "]:" <> int.to_string(port)
    False -> host <> ":" <> int.to_string(port)
  }
  let plaintext = case config.headers, config.plaintext_headers, secure {
    Some(_), False, False -> destination.PlaintextToLoopbackOnly
    _, _, _ -> destination.AllowPlaintext
  }
  let policy =
    destination.default()
    |> destination.allow_loopback
    |> destination.allow_private
    |> destination.only_hosts([entry])
    |> destination.with_plaintext(plaintext)
  use #(gun, owned) <- result.try(case config.http_client {
    Some(gun) -> Ok(#(http_gun.with_destination(gun, policy), False))
    None -> {
      let settings =
        gun_config.default()
        |> gun_config.with_destination(policy)
        |> gun_config.with_connect_timeout(config.connect_timeout)
        |> gun_config.with_request_timeout(gun_config.After(config.timeout))
        |> gun_config.with_max_response_body_bytes(config.max_response_bytes)
        // `close` cancels in-flight calls instead of draining them: stopping
        // closes each open response's connection at once, which is how MCP
        // cancels a request over Streamable HTTP.
        |> gun_config.with_shutdown_timeout(duration.milliseconds(0))
      let settings = case config.ca_cert_file {
        Some(path) -> gun_config.with_trust(settings, gun_config.CustomCa(path))
        None -> settings
      }
      let settings = case config.label {
        Some(label) -> gun_config.with_label(settings, label)
        None -> settings
      }
      case http_gun.start(settings) {
        Ok(gun) -> Ok(#(gun, True))
        Error(http_gun.InvalidConfig(_)) -> Error(config_error(Url))
        Error(_) -> Error(setup_error(ConnectFailed))
      }
    }
  })
  let scheme = case secure {
    True -> http.Https
    False -> http.Http
  }
  let build = fn(out: Outgoing, accept: String, budget: Budget) {
    let extra = case config.headers {
      Some(headers) -> headers()
      None -> []
    }
    let base =
      request.new()
      |> request.set_method(http.Post)
      |> request.set_scheme(scheme)
      |> request.set_host(host)
      |> request.set_port(port)
      |> request.set_path(path)
      |> request.set_body(out.body)
      |> request.set_header("content-type", "application/json")
      |> request.set_header("accept", accept)
      |> request.set_header("mcp-protocol-version", protocol_version)
      |> request.set_header("mcp-method", out.method)
    let base = case out.name {
      Some(name) ->
        request.set_header(base, "mcp-name", uri.percent_encode(name))
      None -> base
    }
    let base = case carried(budget) {
      Some(text) -> request.set_header(base, carrier.header, text)
      None -> base
    }
    list.fold(extra, base, fn(req, header) {
      request.set_header(req, string.lowercase(header.0), header.1)
    })
  }
  let view = fn(budget: Budget, timeout: gun_config.Timeout) {
    let view = http_gun.with_timeout(gun, timeout)
    let view = case budget.deadline {
      Some(deadline) -> http_gun.with_deadline(view, deadline)
      None -> view
    }
    let view = case budget.cancellation {
      Some(token) -> http_gun.with_cancellation(view, token)
      None -> view
    }
    http_gun.with_correlation(view, budget.correlation)
  }
  Ok(
    Peer(
      send: fn(out, budget) {
        let client =
          view(
            budget,
            gun_config.After(duration.milliseconds(budget.timeout_ms)),
          )
          |> http_gun.with_body_limit(budget.max_bytes, http_gun.Fail)
        case http_gun.send(client, build(out, "application/json", budget)) {
          Ok(buffered) ->
            Ok(Incoming(
              buffered.response.status,
              buffered.response.body,
              www_authenticate(buffered.response.headers),
            ))
          Error(failure) ->
            Error(gun_failure(failure, budget.max_bytes, budget.correlation))
        }
      },
      listen: fn(out, budget) {
        let client = view(budget, gun_config.Infinity)
        case http_gun.open(client, build(out, "text/event-stream", budget)) {
          Error(failure) ->
            Error(gun_failure(failure, budget.max_bytes, budget.correlation))
          Ok(response) ->
            case response.status {
              200 ->
                Ok(sse_stream(
                  response.body,
                  budget.max_bytes,
                  budget.correlation,
                ))
              status -> {
                let collected = body.collect(response.body, budget.max_bytes)
                body.close(response.body)
                case collected {
                  Ok(collected) ->
                    Error(status_error(
                      Incoming(
                        status,
                        collected.bytes,
                        www_authenticate(response.headers),
                      ),
                      budget.correlation,
                    ))
                  Error(failure) ->
                    Error(gun_failure(
                      failure,
                      budget.max_bytes,
                      budget.correlation,
                    ))
                }
              }
            }
        }
      },
      close: fn() {
        case owned {
          True -> http_gun.stop(gun)
          False -> Nil
        }
      },
    ),
  )
}

fn www_authenticate(headers: List(#(String, String))) -> Option(String) {
  list.key_find(headers, "www-authenticate") |> option.from_result
}

fn gun_failure(
  failure: gun_error.Failure,
  limit: Int,
  call: Correlation,
) -> Error {
  let evidence = case gun_error.evidence(failure) {
    gun_error.NotSent -> NotSent
    gun_error.MaybeSent -> MaybeSent
  }
  case gun_error.kind(failure) {
    gun_error.InvalidInput -> InvalidConfig(Headers, call)
    gun_error.Refused -> Refused(call)
    gun_error.TimedOut -> TimedOut(evidence, call)
    gun_error.TooLarge -> ResponseTooLarge(limit, call)
    gun_error.CancelledLocally -> Cancelled(evidence, call)
    gun_error.Network ->
      case evidence {
        NotSent -> ConnectFailed(call)
        _ -> ConnectionClosed(evidence, call)
      }
    gun_error.Unavailable | gun_error.Misuse | gun_error.Playback ->
      ConnectionClosed(evidence, call)
  }
}

// Server-sent events: blank-line separated, `data:` lines joined, comments
// and other fields ignored.
fn sse_stream(stream: body.Body, limit: Int, call: Correlation) -> Stream {
  let buffer = process.new_subject()
  process.send(buffer, <<>>)
  Stream(
    next: fn(wait_ms) {
      let assert Ok(pending) = process.receive(buffer, 0)
      let #(event, rest, outcome) =
        next_event(stream, pending, wait_ms, limit, call)
      process.send(buffer, rest)
      case outcome {
        Error(error) -> Error(error)
        Ok(Nil) -> Ok(event)
      }
    },
    close: fn() { body.close(stream) },
  )
}

fn next_event(
  stream: body.Body,
  pending: BitArray,
  wait_ms: Int,
  limit: Int,
  call: Correlation,
) -> #(Option(BitArray), BitArray, Result(Nil, Error)) {
  case split_event(pending) {
    Some(#(event, rest)) ->
      case event_data(event) {
        Some(data) -> #(Some(data), rest, Ok(Nil))
        None -> next_event(stream, rest, wait_ms, limit, call)
      }
    None ->
      case bit_array.byte_size(pending) > limit {
        True -> #(None, <<>>, Error(ResponseTooLarge(limit, call)))
        False ->
          case body.next_within(stream, duration.milliseconds(wait_ms)) {
            Ok(None) -> #(None, pending, Ok(Nil))
            Ok(Some(body.Chunk(chunk))) ->
              next_event(
                stream,
                bit_array.append(pending, chunk),
                0,
                limit,
                call,
              )
            Ok(Some(body.End(_))) -> #(
              None,
              pending,
              Error(ConnectionClosed(Completed, call)),
            )
            Error(failure) -> #(
              None,
              pending,
              Error(gun_failure(failure, limit, call)),
            )
          }
      }
  }
}

fn split_event(pending: BitArray) -> Option(#(String, BitArray)) {
  case bit_array.to_string(pending) {
    Error(Nil) -> None
    Ok(text) -> {
      let text = string.replace(text, "\r\n", "\n")
      case string.split_once(text, "\n\n") {
        Ok(#(event, rest)) -> Some(#(event, bit_array.from_string(rest)))
        Error(Nil) -> None
      }
    }
  }
}

fn event_data(event: String) -> Option(BitArray) {
  let data =
    string.split(event, "\n")
    |> list.filter_map(fn(line) {
      case string.starts_with(line, "data:") {
        True -> {
          let rest = string.drop_start(line, 5)
          Ok(case string.starts_with(rest, " ") {
            True -> string.drop_start(rest, 1)
            False -> rest
          })
        }
        False -> Error(Nil)
      }
    })
  case data {
    [] -> None
    lines -> Some(bit_array.from_string(string.join(lines, "\n")))
  }
}

// --- stdio -------------------------------------------------------------------

fn stdio_peer(
  config: Config,
  command: fn() -> #(String, List(String)),
) -> Result(Peer, Error) {
  case
    stdio_client.connect(
      command,
      ms(config.connect_timeout),
      config.max_response_bytes,
    )
  {
    Error(Nil) -> Error(setup_error(ConnectFailed))
    Ok(child) ->
      Ok(
        Peer(
          send: fn(out, budget) {
            stdio_client.request(
              child,
              out.body,
              out.id,
              remaining_ms(budget),
              budget.max_bytes,
              config.max_pending_calls,
              fn() { is_cancelled(budget) },
            )
            |> result.map(fn(frame) { Incoming(200, frame, None) })
            |> result.map_error(stdio_failure(_, budget.correlation))
          },
          listen: fn(out, budget) {
            stdio_client.subscribe(
              child,
              out.body,
              out.id,
              remaining_ms(budget),
              budget.max_bytes,
            )
            |> result.map_error(stdio_failure(_, budget.correlation))
            |> result.map(fn(acknowledgement) {
              let first = process.new_subject()
              process.send(first, Some(acknowledgement))
              Stream(
                next: fn(wait_ms) {
                  case process.receive(first, 0) {
                    Ok(Some(frame)) -> {
                      process.send(first, None)
                      Ok(Some(frame))
                    }
                    _ -> {
                      process.send(first, None)
                      stdio_client.next_notification(
                        child,
                        out.id,
                        wait_ms,
                        budget.max_bytes,
                      )
                      |> result.map_error(stdio_failure(_, budget.correlation))
                    }
                  }
                },
                close: fn() { stdio_client.cancel_subscription(child, out.id) },
              )
            })
          },
          close: fn() { stdio_client.close(child) },
        ),
      )
  }
}

fn stdio_failure(failure: stdio_client.Failure, call: Correlation) -> Error {
  case failure {
    stdio_client.NotRunning -> ConnectionClosed(NotSent, call)
    stdio_client.Busy(limit) -> TooManyPendingCalls(limit, call)
    stdio_client.TimedOut -> TimedOut(MaybeSent, call)
    stdio_client.Exited -> ConnectionClosed(MaybeSent, call)
    stdio_client.ClientClosed -> Cancelled(MaybeSent, call)
    stdio_client.Cancelled -> Cancelled(MaybeSent, call)
    stdio_client.TooLarge(limit) -> ResponseTooLarge(limit, call)
    stdio_client.Malformed(detail) -> MalformedResponse(detail, call)
  }
}

// --- in process --------------------------------------------------------------

type RouterMessage {
  Register(exchange: Int, subject: Subject(Routed), reply: Subject(Nil))
  Unregister(exchange: Int)
  Route(output: runtime.Output)
  StopRouter
}

// What the router hands one in-process exchange: a runtime output, or the
// client's `close`, which ends the exchange's call as cancelled.
type Routed {
  Routed(runtime.Output)
  PeerClosed
}

fn in_process_peer(
  srv: Server(context),
  context: context,
  max_frame_bytes: Int,
) -> Result(Peer, Nil) {
  use router <- result.try(
    actor.new(dict.new())
    |> actor.on_message(fn(routes, message) {
      case message {
        Register(exchange, subject, reply) -> {
          process.send(reply, Nil)
          actor.continue(dict.insert(routes, exchange, subject))
        }
        Unregister(exchange) -> actor.continue(dict.delete(routes, exchange))
        Route(output) -> {
          let exchange = case output {
            runtime.OutputWrite(exchange, _) | runtime.OutputClose(exchange) ->
              reducer.exchange_id_to_int(exchange)
          }
          case dict.get(routes, exchange) {
            Ok(subject) -> process.send(subject, Routed(output))
            Error(Nil) -> Nil
          }
          actor.continue(routes)
        }
        StopRouter -> {
          dict.each(routes, fn(_, subject) { process.send(subject, PeerClosed) })
          actor.stop()
        }
      }
    })
    |> actor.start
    |> result.map(fn(started) { started.data })
    |> result.replace_error(Nil),
  )
  use rt <- result.try(
    runtime.start(
      srv,
      runtime.config() |> runtime.with_max_frame_bytes(max_frame_bytes),
      fn(output) {
        process.send(router, Route(output))
        Ok(Nil)
      },
    )
    |> result.replace_error(Nil),
  )
  let open = fn(out: Outgoing, call: Correlation) {
    let exchange = reducer.new_exchange_id()
    let outputs = process.new_subject()
    let _ =
      process.call(router, waiting: 5000, sending: Register(
        reducer.exchange_id_to_int(exchange),
        outputs,
        _,
      ))
    // The correlation travels in the frame's `_meta`, as on stdio, so the
    // in-process server accepts exactly what a wire server would.
    case runtime.send_frame(rt, exchange, context, out.body, None) {
      Ok(Nil) -> Ok(#(exchange, outputs))
      Error(runtime.FrameTooLarge(..)) | Error(runtime.FrameTooDeep(..)) -> {
        process.send(router, Unregister(reducer.exchange_id_to_int(exchange)))
        Error(InvalidArguments(
          "the request exceeds the server's frame limits",
          call,
        ))
      }
      Error(_) -> {
        process.send(router, Unregister(reducer.exchange_id_to_int(exchange)))
        Error(ConnectionClosed(NotSent, call))
      }
    }
  }
  Ok(
    Peer(
      send: fn(out, budget) {
        use #(exchange, outputs) <- result.try(open(out, budget.correlation))
        let deadline = monotonic_ms() + remaining_ms(budget)
        let outcome = await_frame(outputs, budget, deadline)
        case outcome {
          Error(_) -> runtime.exchange_closed(rt, exchange)
          Ok(_) -> Nil
        }
        process.send(router, Unregister(reducer.exchange_id_to_int(exchange)))
        result.map(outcome, fn(frame) { Incoming(200, frame, None) })
      },
      listen: fn(out, budget) {
        let call = budget.correlation
        use #(exchange, outputs) <- result.map(open(out, call))
        Stream(
          next: fn(wait_ms) {
            case process.receive(outputs, wait_ms) {
              Error(Nil) -> Ok(None)
              Ok(Routed(runtime.OutputWrite(_, bytes))) -> Ok(Some(bytes))
              Ok(Routed(runtime.OutputClose(_))) | Ok(PeerClosed) ->
                Error(ConnectionClosed(Completed, call))
            }
          },
          close: fn() {
            runtime.exchange_closed(rt, exchange)
            process.send(
              router,
              Unregister(reducer.exchange_id_to_int(exchange)),
            )
          },
        )
      },
      close: fn() {
        // Cancels every invocation without waiting for the handlers: the
        // runtime stops itself once each has returned or its grace has ended.
        runtime.close(rt)
        let _ = process.spawn_unlinked(fn() { runtime.stop(rt) })
        process.send(router, StopRouter)
      },
    ),
  )
}

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn monotonic_ms() -> Int

fn await_frame(
  outputs: Subject(Routed),
  budget: Budget,
  deadline: Int,
) -> Result(BitArray, Error) {
  let left = deadline - monotonic_ms()
  case left <= 0, is_cancelled(budget) {
    _, True -> Error(Cancelled(MaybeSent, budget.correlation))
    True, _ -> Error(TimedOut(MaybeSent, budget.correlation))
    False, False ->
      case process.receive(outputs, int.min(left, 50)) {
        Error(Nil) -> await_frame(outputs, budget, deadline)
        Ok(PeerClosed) -> Error(Cancelled(MaybeSent, budget.correlation))
        Ok(Routed(runtime.OutputWrite(_, bytes))) ->
          case v2026.is_response_frame(bytes) {
            True -> Ok(bytes)
            False -> await_frame(outputs, budget, deadline)
          }
        Ok(Routed(runtime.OutputClose(_))) ->
          Error(ConnectionClosed(MaybeSent, budget.correlation))
      }
  }
}

// --- requests ----------------------------------------------------------------

@external(erlang, "relay_ffi", "unique_integer")
fn unique_integer() -> Int

fn new_id() -> String {
  "relay-" <> int.to_string(unique_integer())
}

fn input_capabilities(methods: List(tool.InputMethod)) -> json.Json {
  json.object(
    list.flatten([
      case list.contains(methods, tool.Elicitation) {
        True -> [#("elicitation", json.object([]))]
        False -> []
      },
      case list.contains(methods, tool.Sampling) {
        True -> [#("sampling", json.object([]))]
        False -> []
      },
      case list.contains(methods, tool.Roots) {
        True -> [#("roots", json.object([]))]
        False -> []
      },
    ]),
  )
}

fn envelope(
  client: Client,
  id: String,
  method: String,
  params: List(#(String, json.Json)),
) -> BitArray {
  let meta =
    json.object([
      #(
        "io.modelcontextprotocol/protocolVersion",
        json.string(protocol_version),
      ),
      #(
        "io.modelcontextprotocol/clientCapabilities",
        input_capabilities(client.config.input_methods),
      ),
      ..list.append(
        case option.then(client.correlation, carrier.sendable) {
          Some(text) -> [#(carrier.meta_key, json.string(text))]
          None -> []
        },
        case client.idempotency_key {
          Some(key) -> [#(carrier.idempotency_meta_key, json.string(key))]
          None -> []
        },
      )
    ])
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string(method)),
    #("params", json.object([#("_meta", meta), ..params])),
  ])
  |> json.to_string
  |> bit_array.from_string
}

type Response {
  Response(result: Dynamic, body: BitArray, call: Correlation)
}

fn request(
  client: Client,
  method: String,
  name: Option(String),
  params: List(#(String, json.Json)),
) -> Result(Response, Error) {
  let #(client, call) = call_correlation(client)
  use Nil <- result.try(check_idempotency_key(client, call))
  let id = new_id()
  let started = monotonic_ms()
  let outcome =
    client.peer.send(
      Outgoing(envelope(client, id, method, params), id, method, name),
      budget(client, call),
    )
    |> result.try(interpret(_, id, call))
  let call_outcome = case outcome {
    Error(_) -> telemetry.CallFailed
    Ok(response) ->
      case method {
        "tools/call" -> tool_call_outcome(response.result)
        _ -> telemetry.CallCompleted
      }
  }
  emit.client_call(
    int.max(0, monotonic_ms() - started),
    telemetry.ClientCallMeta(
      method: method,
      tool: case method {
        "tools/call" -> name
        _ -> None
      },
      outcome: call_outcome,
      correlation: call,
      client: client.config.label,
    ),
  )
  outcome
}

fn tool_call_outcome(result: Dynamic) -> telemetry.CallOutcome {
  case
    decode.run(result, decode.at(["resultType"], decode.string)),
    decode.run(result, decode.at(["isError"], decode.bool))
  {
    Ok("input_required"), _ -> telemetry.CallInputRequired
    _, Ok(True) -> telemetry.CallToolFailed
    _, _ -> telemetry.CallCompleted
  }
}

fn interpret(
  incoming: Incoming,
  id: String,
  call: Correlation,
) -> Result(Response, Error) {
  let parsed =
    bit_array.to_string(incoming.body)
    |> result.try(fn(text) {
      json.parse(text, decode.dynamic) |> result.replace_error(Nil)
    })
  case parsed {
    Error(Nil) -> Error(status_error(incoming, call))
    Ok(message) ->
      case
        decode.run(message, decode.at(["jsonrpc"], decode.string)),
        decode.run(message, decode.at(["id"], decode.string))
      {
        Ok("2.0"), Ok(found) if found == id ->
          case
            decode.run(message, decode.at(["error"], rpc_error_decoder(call)))
          {
            Ok(error) -> Error(error)
            Error(_) ->
              case
                incoming.status,
                decode.run(message, decode.at(["result"], decode.dynamic))
              {
                200, Ok(result) -> Ok(Response(result, incoming.body, call))
                200, Error(_) ->
                  Error(MalformedResponse("the response has no result", call))
                _, _ -> Error(status_error(incoming, call))
              }
          }
        _, _ ->
          case incoming.status {
            200 ->
              Error(MalformedResponse("the response is not correlated", call))
            _ -> Error(status_error(incoming, call))
          }
      }
  }
}

fn status_error(incoming: Incoming, call: Correlation) -> Error {
  case incoming.status {
    200 -> MalformedResponse("the response was not valid JSON-RPC", call)
    status ->
      case
        bit_array.to_string(incoming.body)
        |> result.try(fn(text) {
          json.parse(text, decode.at(["error"], rpc_error_decoder(call)))
          |> result.replace_error(Nil)
        })
      {
        Ok(error) -> error
        Error(Nil) -> HttpStatus(status, incoming.www_authenticate, call)
      }
  }
}

fn rpc_error_decoder(call: Correlation) -> Decoder(Error) {
  use code <- decode.field("code", decode.int)
  use message <- decode.field("message", decode.string)
  use data <- decode.optional_field(
    "data",
    None,
    decode.optional(value.decoder()),
  )
  decode.success(RpcError(code, message, data, call))
}

fn decode_result(response: Response, decoder: Decoder(a)) -> Result(a, Error) {
  decode.run(response.result, decoder)
  |> result.map_error(fn(errors) {
    MalformedResponse(
      case errors {
        [decode.DecodeError(expected, _, path), ..] ->
          "expected " <> expected <> " at " <> string.join(path, ".")
        [] -> "the result did not match the expected shape"
      },
      response.call,
    )
  })
}

// An exact value from the response body: numbers keep their digits.
fn exact(
  response: Response,
  path: List(String),
) -> Result(Option(Value), Error) {
  let limits =
    value.default_limits()
    |> value.with_max_bytes(bit_array.byte_size(response.body) + 1)
  case value.parse_bits(response.body, limits) {
    Error(_) ->
      Error(MalformedResponse("the response is not valid JSON", response.call))
    Ok(root) -> Ok(at(root, path))
  }
}

fn at(found: Value, path: List(String)) -> Option(Value) {
  case path {
    [] -> Some(found)
    [key, ..rest] ->
      case found {
        value.Object(members) ->
          case list.key_find(members, key) {
            Ok(child) -> at(child, rest)
            Error(Nil) -> None
          }
        _ -> None
      }
  }
}

// --- discovery ---------------------------------------------------------------

/// The server's name and version.
pub type ServerInfo {
  ServerInfo(name: String, version: String)
}

/// What `server/discover` returned. `capabilities` is the server's
/// capabilities object; read it with `has_capability` or by pattern. Read
/// fields by label.
pub type Discovery {
  Discovery(
    server_info: Option(ServerInfo),
    supported_versions: List(String),
    capabilities: Value,
    instructions: Option(String),
  )
}

/// Whether the server advertised a top-level capability, such as `"tools"`
/// or `"completions"`.
pub fn has_capability(discovery: Discovery, name: String) -> Bool {
  case discovery.capabilities {
    value.Object(members) -> list.key_find(members, name) |> result.is_ok
    _ -> False
  }
}

/// Asks the server what it supports. Fails with `UnsupportedVersion` when
/// it does not support `2026-07-28`.
pub fn discover(client: Client) -> Result(Discovery, Error) {
  use response <- result.try(request(client, "server/discover", None, []))
  use discovery <- result.try(
    decode_result(response, {
      use supported <- decode.field(
        "supportedVersions",
        decode.list(decode.string),
      )
      use capabilities <- decode.field("capabilities", value.decoder())
      use instructions <- wire.optional_string_field("instructions")
      use server_info <- decode.optional_field(
        "_meta",
        None,
        decode.optional_field(
          "io.modelcontextprotocol/serverInfo",
          None,
          decode.optional({
            use name <- decode.field("name", decode.string)
            use version <- decode.field("version", decode.string)
            decode.success(ServerInfo(name, version))
          }),
          decode.success,
        ),
      )
      decode.success(Discovery(
        server_info,
        supported,
        capabilities,
        instructions,
      ))
    }),
  )
  case list.contains(discovery.supported_versions, protocol_version) {
    True -> Ok(discovery)
    False ->
      Error(UnsupportedVersion(discovery.supported_versions, response.call))
  }
}

// --- tools -------------------------------------------------------------------

/// How a tool call ended, when the server answered it.
pub type ToolResult(output) {
  /// The tool succeeded; `content` holds its content blocks.
  Succeeded(output: output, content: List(ContentBlock))
  /// The tool failed and said why in `content`; nothing went wrong in the
  /// protocol.
  ToolFailed(content: List(ContentBlock), structured: Option(Value))
  /// The tool needs answers first: handle each request and `resume`.
  InputRequired(
    continuation: Continuation(output),
    requests: Dict(String, tool.InputRequest),
  )
}

/// A paused call: its client, arguments and output decoder. The client must
/// stay open until the call ends.
pub opaque type Continuation(output) {
  Continuation(
    client: Client,
    name: String,
    arguments: json.Json,
    request_state: Option(String),
    keys: List(String),
    decode_output: fn(Option(Value), List(ContentBlock)) ->
      Result(output, String),
  )
}

/// Calls a tool with the definition the server registered: encodes the
/// input with its codec and decodes the structured output.
pub fn call(
  client: Client,
  definition: tool.Definition(input, output),
  input: input,
) -> Result(ToolResult(output), Error) {
  let #(client, call) = call_correlation(client)
  case codec.encode(definition.input, input) {
    Error(error) ->
      Error(InvalidArguments(codec.describe_encode_error(error), call))
    Ok(arguments) ->
      invoke(
        client,
        definition.info.name,
        wire.value_to_json(arguments),
        None,
        None,
        output_decoder(definition.output),
      )
  }
}

fn output_decoder(
  output: core.Output(output),
) -> fn(Option(Value), List(ContentBlock)) -> Result(output, String) {
  case output {
    core.ContentOnly(from_content, _) -> fn(_, blocks) {
      Ok(from_content(blocks))
    }
    core.Structured(output_codec, _) -> fn(structured, _) {
      case structured {
        None -> Error("the result has no structured content")
        Some(found) ->
          codec.decode(output_codec, found)
          |> result.map_error(fn(error) {
            "the structured content does not match the output codec: "
            <> codec.describe_decode_error(error)
          })
      }
    }
  }
}

/// Calls a tool known from `list_tools` with exact JSON arguments, which
/// must be an object; the output is the exact structured value, or `Null`
/// for a content-only result.
pub fn call_discovered(
  client: Client,
  declaration: tool.Declaration,
  arguments: Value,
) -> Result(ToolResult(Value), Error) {
  let #(client, call) = call_correlation(client)
  case arguments {
    value.Object(_) ->
      invoke(
        client,
        declaration.name,
        wire.value_to_json(arguments),
        None,
        None,
        fn(structured, _) { Ok(option.unwrap(structured, value.Null)) },
      )
    _ -> Error(InvalidArguments("tool arguments must be a JSON object", call))
  }
}

/// Continues a paused call with one JSON object per request key. Further
/// rounds may follow.
pub fn resume(
  continuation: Continuation(output),
  responses: Dict(String, json.Json),
) -> Result(ToolResult(output), Error) {
  let keys = dict.keys(responses)
  let #(client, call) = call_correlation(continuation.client)
  case
    list.length(keys) == list.length(continuation.keys)
    && list.all(keys, list.contains(continuation.keys, _))
    && list.all(dict.values(responses), is_object)
  {
    False -> Error(InvalidInputResponses(call))
    True ->
      invoke(
        client,
        continuation.name,
        continuation.arguments,
        continuation.request_state,
        Some(responses),
        continuation.decode_output,
      )
  }
}

fn is_object(found: json.Json) -> Bool {
  case
    json.parse(
      json.to_string(found),
      decode.dict(decode.string, decode.dynamic),
    )
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn invoke(
  client: Client,
  name: String,
  arguments: json.Json,
  request_state: Option(String),
  responses: Option(Dict(String, json.Json)),
  decode_output: fn(Option(Value), List(ContentBlock)) -> Result(output, String),
) -> Result(ToolResult(output), Error) {
  let params =
    list.flatten([
      [#("name", json.string(name)), #("arguments", arguments)],
      case request_state {
        Some(state) -> [#("requestState", json.string(state))]
        None -> []
      },
      case responses {
        Some(responses) -> [
          #("inputResponses", json.object(dict.to_list(responses))),
        ]
        None -> []
      },
    ])
  use response <- result.try(request(client, "tools/call", Some(name), params))
  use result_type <- result.try(
    decode_result(response, {
      use found <- wire.optional_string_field("resultType")
      decode.success(found)
    }),
  )
  case result_type {
    Some("input_required") -> {
      use #(requests, state) <- result.try(
        decode_result(response, {
          use requests <- decode.optional_field(
            "inputRequests",
            None,
            decode.optional(decode.dict(
              decode.string,
              raw_input_request_decoder(),
            )),
          )
          use state <- wire.optional_string_field("requestState")
          decode.success(#(requests, state))
        }),
      )
      // The revision requires at least one of the two members.
      use requests <- result.try(case requests, state {
        None, None ->
          Error(MalformedResponse(
            "an input_required result has no inputRequests or requestState",
            response.call,
          ))
        Some(requests), _ -> Ok(requests)
        None, Some(_) -> Ok(dict.new())
      })
      use requests <- result.try(admit_input_requests(
        client,
        requests,
        response.call,
      ))
      Ok(InputRequired(
        Continuation(
          client,
          name,
          arguments,
          state,
          dict.keys(requests),
          decode_output,
        ),
        requests,
      ))
    }
    None | Some("complete") -> {
      use #(blocks, is_error) <- result.try(
        decode_result(response, {
          use blocks <- decode.field(
            "content",
            decode.list(wire.content_block_decoder()),
          )
          use is_error <- decode.optional_field("isError", False, decode.bool)
          decode.success(#(blocks, is_error))
        }),
      )
      use structured <- result.try(
        exact(response, ["result", "structuredContent"]),
      )
      case is_error {
        True -> Ok(ToolFailed(blocks, structured))
        False ->
          case decode_output(structured, blocks) {
            Ok(output) -> Ok(Succeeded(output, blocks))
            Error(detail) -> Error(MalformedResponse(detail, response.call))
          }
      }
    }
    Some(other) ->
      Error(MalformedResponse("unknown resultType " <> other, response.call))
  }
}

fn raw_input_request_decoder() -> Decoder(#(String, Value)) {
  use method <- decode.field("method", decode.string)
  use params <- decode.field("params", value.decoder())
  decode.success(#(method, params))
}

fn admit_input_requests(
  client: Client,
  requests: Dict(String, #(String, Value)),
  call: Correlation,
) -> Result(Dict(String, tool.InputRequest), Error) {
  dict.to_list(requests)
  |> list.try_map(fn(entry) {
    let #(key, #(method_name, params)) = entry
    let method = case method_name {
      "elicitation/create" -> Ok(tool.Elicitation)
      "sampling/createMessage" -> Ok(tool.Sampling)
      "roots/list" -> Ok(tool.Roots)
      _ -> Error(UnsupportedInputRequest(method_name, call))
    }
    use method <- result.try(method)
    case list.contains(client.config.input_methods, method), params {
      False, _ -> Error(UnsupportedInputRequest(method_name, call))
      True, value.Object(_) -> Ok(#(key, tool.InputRequest(method, params)))
      True, _ ->
        Error(MalformedResponse("input request params must be an object", call))
    }
  })
  |> result.map(dict.from_list)
}

// --- listings ----------------------------------------------------------------

fn pages(
  client: Client,
  method: String,
  collection: String,
  item: Decoder(a),
) -> Result(List(a), Error) {
  // One listing is one call: every page carries the same correlation.
  let #(client, call) = call_correlation(client)
  page(client, call, method, collection, item, None, [], [], 0, 0)
}

fn page(
  client: Client,
  call: Correlation,
  method: String,
  collection: String,
  item: Decoder(a),
  cursor: Option(String),
  seen: List(String),
  pages: List(List(a)),
  page_count: Int,
  item_count: Int,
) -> Result(List(a), Error) {
  case page_count >= client.config.max_listing_pages {
    True -> Error(ListingLimitExceeded(client.config.max_listing_pages, call))
    False -> {
      let params = case cursor {
        Some(cursor) -> [#("cursor", json.string(cursor))]
        None -> []
      }
      use response <- result.try(request(client, method, None, params))
      use #(items, next) <- result.try(
        decode_result(response, {
          use items <- decode.field(collection, decode.list(item))
          use next <- wire.optional_string_field("nextCursor")
          decode.success(#(items, next))
        }),
      )
      let item_count = item_count + list.length(items)
      let pages = [items, ..pages]
      case item_count > client.config.max_listing_items, next {
        True, _ ->
          Error(ListingLimitExceeded(client.config.max_listing_items, call))
        False, None -> Ok(list.flatten(list.reverse(pages)))
        False, Some(next) ->
          case list.contains(seen, next) {
            True ->
              Error(MalformedResponse("the listing repeated a cursor", call))
            False ->
              page(
                client,
                call,
                method,
                collection,
                item,
                Some(next),
                [next, ..seen],
                pages,
                page_count + 1,
                item_count,
              )
          }
      }
    }
  }
}

fn tool_declaration_decoder() -> Decoder(tool.Declaration) {
  let hint = fn(key, next) {
    decode.optional_field(key, None, decode.optional(decode.bool), next)
  }
  let annotations = {
    use title <- wire.optional_string_field("title")
    use read_only <- hint("readOnlyHint")
    use destructive <- hint("destructiveHint")
    use idempotent <- hint("idempotentHint")
    use open_world <- hint("openWorldHint")
    decode.success(tool.ToolAnnotations(
      title,
      read_only,
      destructive,
      idempotent,
      open_world,
    ))
  }
  use name <- decode.field("name", decode.string)
  use title <- wire.optional_string_field("title")
  use description <- wire.optional_string_field("description")
  use input_schema <- decode.field("inputSchema", value.decoder())
  use output_schema <- decode.optional_field(
    "outputSchema",
    None,
    decode.optional(value.decoder()),
  )
  use annotations <- decode.optional_field(
    "annotations",
    tool.ToolAnnotations(None, None, None, None, None),
    annotations,
  )
  use icons <- wire.optional_icons
  use meta <- wire.optional_meta
  decode.success(tool.Declaration(
    name:,
    title:,
    description:,
    input_schema:,
    output_schema:,
    annotations:,
    icons:,
    meta:,
  ))
}

/// Every tool the server lists, across all pages.
pub fn list_tools(client: Client) -> Result(List(tool.Declaration), Error) {
  pages(client, "tools/list", "tools", tool_declaration_decoder())
}

/// Every static resource the server lists.
pub fn list_resources(
  client: Client,
) -> Result(List(resources.Declaration), Error) {
  pages(client, "resources/list", "resources", {
    use uri <- decode.field("uri", decode.string)
    use name <- decode.field("name", decode.string)
    use title <- wire.optional_string_field("title")
    use description <- wire.optional_string_field("description")
    use mime_type <- wire.optional_string_field("mimeType")
    use size <- decode.optional_field("size", None, decode.optional(decode.int))
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(wire.annotations_decoder()),
    )
    use icons <- wire.optional_icons
    use meta <- wire.optional_meta
    decode.success(resources.Declaration(
      uri:,
      name:,
      title:,
      description:,
      mime_type:,
      size:,
      annotations:,
      icons:,
      meta:,
    ))
  })
}

/// Every resource template the server lists.
pub fn list_resource_templates(
  client: Client,
) -> Result(List(resources.TemplateDeclaration), Error) {
  pages(client, "resources/templates/list", "resourceTemplates", {
    use uri_template <- decode.field("uriTemplate", decode.string)
    use name <- decode.field("name", decode.string)
    use title <- wire.optional_string_field("title")
    use description <- wire.optional_string_field("description")
    use mime_type <- wire.optional_string_field("mimeType")
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(wire.annotations_decoder()),
    )
    use icons <- wire.optional_icons
    use meta <- wire.optional_meta
    decode.success(resources.TemplateDeclaration(
      uri_template:,
      name:,
      title:,
      description:,
      mime_type:,
      annotations:,
      icons:,
      meta:,
    ))
  })
}

fn prompt_argument_decoder() -> Decoder(prompts.PromptArgument) {
  use name <- decode.field("name", decode.string)
  use title <- wire.optional_string_field("title")
  use description <- wire.optional_string_field("description")
  use required <- decode.optional_field("required", False, decode.bool)
  decode.success(prompts.PromptArgument(name:, title:, description:, required:))
}

/// Every prompt the server lists.
pub fn list_prompts(
  client: Client,
) -> Result(List(prompts.Declaration), Error) {
  pages(client, "prompts/list", "prompts", {
    use name <- decode.field("name", decode.string)
    use title <- wire.optional_string_field("title")
    use description <- wire.optional_string_field("description")
    use arguments <- decode.optional_field(
      "arguments",
      [],
      decode.list(prompt_argument_decoder()),
    )
    use icons <- wire.optional_icons
    use meta <- wire.optional_meta
    decode.success(prompts.Declaration(
      name:,
      title:,
      description:,
      arguments:,
      icons:,
      meta:,
    ))
  })
}

/// Every item of a paginated listing method, such as `"tools/list"` with
/// collection `"tools"`, as exact JSON values.
pub fn list_raw(
  client: Client,
  method: String,
  collection: String,
) -> Result(List(Value), Error) {
  let #(client, call) = call_correlation(client)
  raw_page(client, call, method, collection, None, [], [], 0, 0)
}

fn raw_page(
  client: Client,
  call: Correlation,
  method: String,
  collection: String,
  cursor: Option(String),
  seen: List(String),
  pages: List(List(Value)),
  page_count: Int,
  item_count: Int,
) -> Result(List(Value), Error) {
  case page_count >= client.config.max_listing_pages {
    True -> Error(ListingLimitExceeded(client.config.max_listing_pages, call))
    False -> {
      let params = case cursor {
        Some(cursor) -> [#("cursor", json.string(cursor))]
        None -> []
      }
      use response <- result.try(request(client, method, None, params))
      use items <- result.try(exact(response, ["result", collection]))
      use items <- result.try(case items {
        Some(value.Array(items)) -> Ok(items)
        _ -> Error(MalformedResponse("the listing has no " <> collection, call))
      })
      use next <- result.try(
        decode_result(response, {
          use next <- wire.optional_string_field("nextCursor")
          decode.success(next)
        }),
      )
      let item_count = item_count + list.length(items)
      let pages = [items, ..pages]
      case item_count > client.config.max_listing_items, next {
        True, _ ->
          Error(ListingLimitExceeded(client.config.max_listing_items, call))
        False, None -> Ok(list.flatten(list.reverse(pages)))
        False, Some(next) ->
          case list.contains(seen, next) {
            True ->
              Error(MalformedResponse("the listing repeated a cursor", call))
            False ->
              raw_page(
                client,
                call,
                method,
                collection,
                Some(next),
                [next, ..seen],
                pages,
                page_count + 1,
                item_count,
              )
          }
      }
    }
  }
}

/// Sends any request method with these params and returns its result object
/// as an exact JSON value. `tools/call`, `prompts/get` and `resources/read`
/// need the `name` their routing header carries; other methods take `None`.
pub fn call_raw(
  client: Client,
  method: String,
  name: Option(String),
  params: List(#(String, json.Json)),
) -> Result(Value, Error) {
  let needs_name = case method {
    "tools/call" | "prompts/get" | "resources/read" -> True
    _ -> False
  }
  let #(client, call) = call_correlation(client)
  case needs_name, name {
    True, None ->
      Error(InvalidArguments(method <> " needs a routing name", call))
    False, Some(_) ->
      Error(InvalidArguments(method <> " takes no routing name", call))
    _, _ -> {
      use response <- result.try(request(client, method, name, params))
      use found <- result.try(exact(response, ["result"]))
      option.to_result(
        found,
        MalformedResponse("the response has no result", call),
      )
    }
  }
}

// --- resources, prompts, completion ------------------------------------------

/// Reads a resource.
pub fn read_resource(
  client: Client,
  uri: String,
) -> Result(List(ResourceContents), Error) {
  use response <- result.try(
    request(client, "resources/read", Some(uri), [#("uri", json.string(uri))]),
  )
  decode_result(
    response,
    decode.at(["contents"], decode.list(wire.resource_contents_decoder())),
  )
}

/// Renders a prompt with string arguments.
pub fn get_prompt(
  client: Client,
  name: String,
  arguments: Dict(String, String),
) -> Result(prompts.PromptResult, Error) {
  use response <- result.try(
    request(client, "prompts/get", Some(name), [
      #("name", json.string(name)),
      #(
        "arguments",
        json.object(
          dict.to_list(arguments)
          |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) }),
        ),
      ),
    ]),
  )
  decode_result(response, {
    use description <- wire.optional_string_field("description")
    use messages <- decode.field(
      "messages",
      decode.list({
        use role <- decode.field("role", {
          use found <- decode.then(decode.string)
          case found {
            "user" -> decode.success(content.UserRole)
            "assistant" -> decode.success(content.AssistantRole)
            _ -> decode.failure(content.UserRole, "role")
          }
        })
        use block <- decode.field("content", wire.content_block_decoder())
        decode.success(prompts.PromptMessage(role, block))
      }),
    )
    use meta <- wire.optional_meta
    decode.success(prompts.PromptResult(description, messages, meta))
  })
}

/// Asks the server to complete an argument.
pub fn complete(
  client: Client,
  query: completion.Request,
) -> Result(completion.Values, Error) {
  let reference = case query.reference {
    completion.PromptReference(name) ->
      json.object([
        #("type", json.string("ref/prompt")),
        #("name", json.string(name)),
      ])
    completion.ResourceReference(uri_template) ->
      json.object([
        #("type", json.string("ref/resource")),
        #("uri", json.string(uri_template)),
      ])
  }
  let context = case dict.to_list(query.context) {
    [] -> []
    known -> [
      #(
        "context",
        json.object([
          #(
            "arguments",
            json.object(
              list.map(known, fn(pair) { #(pair.0, json.string(pair.1)) }),
            ),
          ),
        ]),
      ),
    ]
  }
  use response <- result.try(
    request(client, "completion/complete", None, [
      #("ref", reference),
      #(
        "argument",
        json.object([
          #("name", json.string(query.argument)),
          #("value", json.string(query.value)),
        ]),
      ),
      ..context
    ]),
  )
  decode_result(
    response,
    decode.at(["completion"], {
      use values <- decode.field("values", decode.list(decode.string))
      use total <- decode.optional_field(
        "total",
        None,
        decode.optional(decode.int),
      )
      use has_more <- decode.optional_field(
        "hasMore",
        None,
        decode.optional(decode.bool),
      )
      decode.success(completion.Values(values, total, has_more))
    }),
  )
}

// --- listening ---------------------------------------------------------------

/// An open `subscriptions/listen` stream. Read it from the process that
/// opened it.
pub opaque type Subscription {
  Subscription(
    stream: Stream,
    id: String,
    notifications: List(Notification),
    call: Correlation,
  )
}

/// Opens a stream for these notifications; `ResourceUpdated(uri)` subscribes
/// to one resource. Returns once the server acknowledged it.
pub fn listen(
  client: Client,
  notifications: List(Notification),
) -> Result(Subscription, Error) {
  let #(client, call) = call_correlation(client)
  use Nil <- result.try(check_idempotency_key(client, call))
  let id = new_id()
  let body =
    envelope(client, id, "subscriptions/listen", [
      #("notifications", v2026.filter_to_json(subs.filter_of(notifications))),
    ])
  use stream <- result.try(client.peer.listen(
    Outgoing(body, id, "subscriptions/listen", None),
    budget(client, call),
  ))
  let wait = remaining_ms(budget(client, call))
  case stream.next(wait) {
    Error(error) -> {
      stream.close()
      Error(error)
    }
    Ok(None) -> {
      stream.close()
      Error(TimedOut(MaybeSent, call))
    }
    Ok(Some(frame)) ->
      case acknowledgement(frame, id, call) {
        Ok(confirmed) -> Ok(Subscription(stream, id, confirmed, call))
        Error(error) -> {
          stream.close()
          Error(error)
        }
      }
  }
}

/// The notifications the server confirmed for this stream.
pub fn listening(subscription: Subscription) -> List(Notification) {
  subscription.notifications
}

/// Waits at most `wait` for the next notification; `Ok(None)` means none
/// arrived. The stream stays open after a wait.
pub fn next_notification(
  subscription: Subscription,
  wait: Duration,
) -> Result(Option(Notification), Error) {
  case subscription.stream.next(int.max(0, ms(wait))) {
    Error(error) -> Error(error)
    Ok(None) -> Ok(None)
    Ok(Some(frame)) ->
      notification(frame, subscription.id, subscription.call)
      |> result.map(Some)
  }
}

/// Ends the stream; other requests on the client continue.
pub fn close_subscription(subscription: Subscription) -> Nil {
  subscription.stream.close()
}

fn parse_frame(frame: BitArray, call: Correlation) -> Result(Dynamic, Error) {
  bit_array.to_string(frame)
  |> result.try(fn(text) {
    json.parse(text, decode.dynamic) |> result.replace_error(Nil)
  })
  |> result.replace_error(MalformedResponse(
    "a stream event is not valid JSON",
    call,
  ))
}

fn subscription_matches(message: Dynamic, id: String) -> Bool {
  decode.run(
    message,
    decode.at(
      ["params", "_meta", "io.modelcontextprotocol/subscriptionId"],
      decode.string,
    ),
  )
  == Ok(id)
}

fn acknowledgement(
  frame: BitArray,
  id: String,
  call: Correlation,
) -> Result(List(Notification), Error) {
  use message <- result.try(parse_frame(frame, call))
  case
    decode.run(message, decode.at(["method"], decode.string)),
    subscription_matches(message, id)
  {
    Ok("notifications/subscriptions/acknowledged"), True ->
      decode.run(
        message,
        decode.at(["params", "notifications"], {
          let flag = fn(key, next) {
            decode.optional_field(key, False, decode.bool, next)
          }
          use tools <- flag("toolsListChanged")
          use resources <- flag("resourcesListChanged")
          use prompts <- flag("promptsListChanged")
          use uris <- decode.optional_field(
            "resourceSubscriptions",
            [],
            decode.list(decode.string),
          )
          decode.success(subs.Filter(tools, resources, prompts, uris))
        }),
      )
      |> result.map(subs.notifications_of)
      |> result.replace_error(MalformedResponse(
        "the acknowledgement has no notification filter",
        call,
      ))
    _, _ ->
      case decode.run(message, decode.at(["error"], rpc_error_decoder(call))) {
        Ok(error) -> Error(error)
        Error(_) ->
          Error(MalformedResponse(
            "the stream did not begin with its acknowledgement",
            call,
          ))
      }
  }
}

fn notification(
  frame: BitArray,
  id: String,
  call: Correlation,
) -> Result(Notification, Error) {
  use message <- result.try(parse_frame(frame, call))
  case subscription_matches(message, id) {
    False -> Error(MalformedResponse("a stream event is not correlated", call))
    True ->
      case decode.run(message, decode.at(["method"], decode.string)) {
        Ok("notifications/tools/list_changed") ->
          Ok(subscriptions.ToolsListChanged)
        Ok("notifications/resources/list_changed") ->
          Ok(subscriptions.ResourcesListChanged)
        Ok("notifications/prompts/list_changed") ->
          Ok(subscriptions.PromptsListChanged)
        Ok("notifications/resources/updated") ->
          decode.run(message, decode.at(["params", "uri"], decode.string))
          |> result.map(subscriptions.ResourceUpdated)
          |> result.replace_error(MalformedResponse(
            "a resource update has no uri",
            call,
          ))
        _ ->
          Error(MalformedResponse("a stream event has an unknown method", call))
      }
  }
}
