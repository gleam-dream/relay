import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode as dyn_decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import json/blueprint/codec.{type Codec, decode, encode}
import json/blueprint/parser as blueprint_parser
import json/blueprint/value as blueprint_value
import relay/completion
import relay/content
import relay/internal/protocol/v2026_07_28 as v2026
import relay/internal/transport/stdio_client
import relay/prompts
import relay/protocol/jsonrpc.{RequestString}
import relay/subscriptions.{type SubscriptionFilter, SubscriptionFilter}
import relay/tool.{type ToolName}

const protocol_version = "2026-07-28"

/// Validated connection parameters derived from one endpoint URL.
type ClientConfig {
  ClientConfig(
    host: String,
    port: Int,
    path: String,
    secure: Bool,
    timeout_ms: Int,
    max_response_bytes: Int,
  )
}

/// URL-derived HTTP settings with explicit bounds and optional CA trust.
pub opaque type HttpClientConfig {
  HttpClientConfig(connection: ClientConfig, ca_cert_file: Option(String))
}

@external(erlang, "relay_url_ffi", "valid_ipv6")
fn valid_ipv6(host: String) -> Bool

@external(erlang, "relay_url_ffi", "path_without_controls")
fn path_without_controls(path: String) -> Bool

fn parse_http_url(url: String) -> Result(uri.Uri, Nil) {
  case
    string.starts_with(string.lowercase(url), "http://[")
    || string.starts_with(string.lowercase(url), "https://[")
  {
    False -> uri.parse(url)
    True ->
      case string.split_once(url, "[") {
        Error(_) -> Error(Nil)
        Ok(#(prefix, bracketed)) ->
          case string.split_once(bracketed, "]") {
            Error(_) -> Error(Nil)
            Ok(#(address, suffix)) ->
              case
                valid_ipv6(address)
                && {
                  suffix == ""
                  || string.starts_with(suffix, "/")
                  || string.starts_with(suffix, ":")
                }
              {
                False -> Error(Nil)
                True ->
                  case uri.parse(prefix <> "relay-ipv6.invalid" <> suffix) {
                    Error(_) -> Error(Nil)
                    Ok(parsed) ->
                      Ok(uri.Uri(..parsed, host: Some("[" <> address <> "]")))
                  }
              }
          }
      }
  }
}

/// Parses an absolute HTTP(S) endpoint. Query, fragment, and userinfo are not
/// MCP endpoint components. A missing path becomes `/`.
pub fn http_config(url: String) -> Result(HttpClientConfig, ClientError) {
  case parse_http_url(url) {
    Error(_) -> Error(InvalidClientConfiguration)
    Ok(parsed) -> {
      let secure = case parsed.scheme {
        Some(scheme) -> string.lowercase(scheme) == "https"
        None -> False
      }
      let scheme_valid = case parsed.scheme {
        Some(scheme) -> {
          let scheme = string.lowercase(scheme)
          scheme == "http" || scheme == "https"
        }
        None -> False
      }
      case parsed.host {
        Some(host) -> {
          let port = case parsed.port {
            Some(explicit) -> explicit
            None if secure -> 443
            None -> 80
          }
          let path = case parsed.path {
            "" -> "/"
            other -> other
          }
          case
            scheme_valid
            && parsed.userinfo == None
            && parsed.query == None
            && parsed.fragment == None
            && valid_raw_authority(url)
            && valid_url_host(host)
            && valid_url_path(path)
            && port > 0
            && port < 65_536
            && string.starts_with(path, "/")
          {
            False -> Error(InvalidClientConfiguration)
            True ->
              Ok(HttpClientConfig(
                connection: ClientConfig(
                  host: unbracket_host(host),
                  port: port,
                  path: path,
                  secure: secure,
                  timeout_ms: 30_000,
                  max_response_bytes: 1_048_576,
                ),
                ca_cert_file: None,
              ))
          }
        }
        _ -> Error(InvalidClientConfiguration)
      }
    }
  }
}

fn valid_raw_authority(url: String) -> Bool {
  case string.split_once(url, "://") {
    Error(_) -> False
    Ok(#(_, rest)) -> {
      let authority = case string.split_once(rest, "/") {
        Ok(#(before_path, _)) -> before_path
        Error(_) -> rest
      }
      authority != ""
      && !string.ends_with(authority, ":")
      && !string.contains(authority, "%")
      && !string.contains(authority, "\\")
    }
  }
}

fn valid_url_path(path: String) -> Bool {
  path_without_controls(path)
  && valid_percent_escapes(string.to_graphemes(path))
}

fn valid_percent_escapes(chars: List(String)) -> Bool {
  case chars {
    [] -> True
    ["%", first, second, ..rest] ->
      is_hex_digit(first) && is_hex_digit(second) && valid_percent_escapes(rest)
    ["%", ..] -> False
    [_, ..rest] -> valid_percent_escapes(rest)
  }
}

fn is_hex_digit(char: String) -> Bool {
  string.contains("0123456789abcdefABCDEF", char)
}

fn valid_url_host(host: String) -> Bool {
  host != ""
  && path_without_controls(host)
  && string.trim(host) == host
  && !string.contains(host, " ")
  && !string.contains(host, "\n")
  && !string.contains(host, "\t")
  && { !string.starts_with(host, "[") || string.ends_with(host, "]") }
}

fn unbracket_host(host: String) -> String {
  case string.starts_with(host, "[") && string.ends_with(host, "]") {
    True -> host |> string.drop_start(1) |> string.drop_end(1)
    False -> host
  }
}

/// Last timeout value wins; validation occurs before connecting.
pub fn with_timeout(
  config: HttpClientConfig,
  timeout_ms: Int,
) -> HttpClientConfig {
  HttpClientConfig(
    ..config,
    connection: ClientConfig(..config.connection, timeout_ms: timeout_ms),
  )
}

/// Last response limit wins; validation occurs before connecting.
pub fn with_max_response_bytes(
  config: HttpClientConfig,
  max_response_bytes: Int,
) -> HttpClientConfig {
  HttpClientConfig(
    ..config,
    connection: ClientConfig(
      ..config.connection,
      max_response_bytes: max_response_bytes,
    ),
  )
}

/// Selects a CA certificate file for HTTPS. Plain HTTP rejects this setting.
pub fn with_ca_cert_file(
  config: HttpClientConfig,
  ca_cert_file: String,
) -> HttpClientConfig {
  HttpClientConfig(..config, ca_cert_file: Some(ca_cert_file))
}

/// Connects using the URL-derived settings and optional explicit CA.
pub fn connect_http(config: HttpClientConfig) -> Result(Client, ClientError) {
  connect_with_ca_option(config.connection, config.ca_cert_file)
}

/// Configuration for a local stdio client process.
pub type StdioConfig {
  StdioConfig(
    executable: String,
    args: List(String),
    timeout_ms: Int,
    max_response_bytes: Int,
  )
}

/// Bounded local stdio defaults; callers can update the public record by name.
pub fn stdio_config(executable: String, args: List(String)) -> StdioConfig {
  StdioConfig(executable, args, 30_000, 1_048_576)
}

/// Opaque owner-bound HTTP or local stdio client.
pub opaque type Client {
  Client(
    transport: ClientTransport,
    path: String,
    timeout_ms: Int,
    max_response_bytes: Int,
  )
}

type ClientTransport {
  HttpTransport(process.Pid)
  StdioTransport(stdio_client.Client)
}

pub type ClientError {
  InvalidClientConfiguration
  ConnectionFailed(String)
}

pub type ServerInfo {
  ServerInfo(name: String, version: String)
}

/// Capabilities and server identity discovered from a live peer.
pub type Discovery {
  Discovery(
    server_info: Option(ServerInfo),
    supported_versions: List(String),
    capabilities: Dynamic,
  )
}

pub type IconTheme {
  IconLight
  IconDark
}

pub type Icon {
  Icon(
    src: String,
    mime_type: Option(String),
    sizes: Option(List(String)),
    theme: Option(IconTheme),
  )
}

pub type Annotations {
  Annotations(
    audience: Option(List(content.Role)),
    priority: Option(Float),
    last_modified: Option(String),
  )
}

/// A typed tool declaration received from a peer. Schema documents remain
/// ordinary Gleam JSON values because peers may use arbitrary JSON Schema.
pub type ToolDeclaration {
  ToolDeclaration(
    name: String,
    title: Option(String),
    description: Option(String),
    input_schema: json.Json,
    output_schema: Option(json.Json),
    annotations: Option(tool.ToolAnnotations),
    icons: Option(List(Icon)),
    meta: Option(json.Json),
  )
}

/// A typed resource declaration received from a peer.
pub type ResourceDeclaration {
  ResourceDeclaration(
    uri: String,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    size: Option(Int),
    annotations: Option(Annotations),
    icons: Option(List(Icon)),
    meta: Option(json.Json),
  )
}

/// A typed resource-template declaration received from a peer.
pub type ResourceTemplateDeclaration {
  ResourceTemplateDeclaration(
    uri_template: String,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    annotations: Option(Annotations),
    icons: Option(List(Icon)),
    meta: Option(json.Json),
  )
}

/// A typed prompt declaration received from a peer.
pub type PromptDeclaration {
  PromptDeclaration(
    name: String,
    title: Option(String),
    description: Option(String),
    arguments: List(prompts.PromptArgument),
    icons: Option(List(Icon)),
    meta: Option(json.Json),
  )
}

/// The outcomes of a typed tool call remain distinct at the client boundary.
pub type ToolCallOutcome(output) {
  StructuredSuccess(output, content: List(content.ContentBlock))
  ContentOnlySuccess(content: List(content.ContentBlock))
  ToolFailure(content: List(content.ContentBlock))
  ProtocolFailure(reason: String)
  TransportFailure(reason: String)
  Cancelled
  InputEncodingFailure
}

/// A content-only definition cannot yield a typed structured value.
pub type ContentCallError {
  ContentToolFailure(List(content.ContentBlock))
  ContentProtocolFailure(String)
  ContentTransportFailure(String)
  ContentCancelled
  ContentInputEncodingFailure
  UnexpectedStructuredContent
}

/// A correlated notification received on one live subscriptions/listen stream.
pub type SubscriptionNotification {
  ResourceUpdated(uri: String)
  ToolsListChanged
  ResourcesListChanged
  PromptsListChanged
}

/// An HTTP subscription stream owned by one Gun connection.
pub opaque type Subscription {
  HttpSubscription(
    reader: process.Pid,
    request_id: String,
    notifications: SubscriptionFilter,
  )
  StdioSubscription(
    client: stdio_client.Client,
    request_id: String,
    notifications: SubscriptionFilter,
    max_response_bytes: Int,
  )
}

@external(erlang, "relay_gun_ffi", "open")
fn ffi_open(
  host: String,
  port: Int,
  secure: Bool,
  timeout_ms: Int,
) -> Result(process.Pid, String)

@external(erlang, "relay_gun_ffi", "open_with_ca")
fn ffi_open_with_ca(
  host: String,
  port: Int,
  secure: Bool,
  ca_cert_file: String,
  timeout_ms: Int,
) -> Result(process.Pid, String)

@external(erlang, "relay_gun_ffi", "request")
fn ffi_request(
  pid: process.Pid,
  path: String,
  body: BitArray,
  method: String,
  name: String,
  version: String,
  timeout_ms: Int,
  max_response_bytes: Int,
) -> Result(#(Int, BitArray), String)

@external(erlang, "relay_gun_ffi", "open_sse")
fn ffi_open_sse(
  pid: process.Pid,
  path: String,
  body: BitArray,
  version: String,
  timeout_ms: Int,
  max_buffered_bytes: Int,
) -> Result(process.Pid, String)

@external(erlang, "relay_gun_ffi", "next_sse")
fn ffi_next_sse(
  reader: process.Pid,
  timeout_ms: Int,
) -> Result(BitArray, String)

@external(erlang, "relay_gun_ffi", "close_sse")
fn ffi_close_sse(reader: process.Pid) -> Nil

@external(erlang, "relay_gun_ffi", "close")
fn ffi_close(pid: process.Pid) -> Nil

@external(erlang, "relay_gun_ffi", "unique_integer")
fn ffi_unique_integer() -> Int

fn connect_with_ca_option(
  config: ClientConfig,
  ca_cert_file: Option(String),
) -> Result(Client, ClientError) {
  case
    string.trim(config.host) != ""
    && config.port > 0
    && config.port < 65_536
    && string.starts_with(config.path, "/")
    && config.timeout_ms > 0
    && config.max_response_bytes > 0
    && valid_ca_configuration(config.secure, ca_cert_file)
  {
    False -> Error(InvalidClientConfiguration)
    True ->
      case open_connection(config, ca_cert_file) {
        Ok(pid) ->
          Ok(Client(
            transport: HttpTransport(pid),
            path: config.path,
            timeout_ms: config.timeout_ms,
            max_response_bytes: config.max_response_bytes,
          ))
        Error(reason) -> Error(ConnectionFailed(reason))
      }
  }
}

fn valid_ca_configuration(secure: Bool, ca_cert_file: Option(String)) -> Bool {
  case secure, ca_cert_file {
    True, None -> True
    True, Some(path) -> path != ""
    False, None -> True
    False, Some(_) -> False
  }
}

fn open_connection(
  config: ClientConfig,
  ca_cert_file: Option(String),
) -> Result(process.Pid, String) {
  case ca_cert_file {
    Some(path) ->
      ffi_open_with_ca(
        config.host,
        config.port,
        config.secure,
        path,
        config.timeout_ms,
      )
    None -> ffi_open(config.host, config.port, config.secure, config.timeout_ms)
  }
}

/// Starts a typed client for a local stdio-speaking child process.
pub fn connect_stdio(config: StdioConfig) -> Result(Client, ClientError) {
  case config.timeout_ms > 0 && config.max_response_bytes > 0 {
    False -> Error(InvalidClientConfiguration)
    True ->
      case
        stdio_client.connect(stdio_client.Config(
          executable: config.executable,
          args: config.args,
          timeout_ms: config.timeout_ms,
          max_frame_bytes: config.max_response_bytes,
        ))
      {
        Ok(child) ->
          Ok(Client(
            transport: StdioTransport(child),
            path: "",
            timeout_ms: config.timeout_ms,
            max_response_bytes: config.max_response_bytes,
          ))
        Error(reason) -> Error(ConnectionFailed(reason))
      }
  }
}

/// Closes the underlying Gun connection and its in-flight streams.
pub fn close(client: Client) -> Nil {
  case client.transport {
    HttpTransport(pid) -> ffi_close(pid)
    StdioTransport(child) -> stdio_client.close(child)
  }
}

/// Discovers server capabilities and pins use to the retained 2026 revision.
pub fn discover(client: Client) -> Result(Discovery, String) {
  let id = request_id()
  let body = request_envelope(id, "server/discover", [])
  case request(client, body, id, "server/discover", "") {
    Error(reason) -> Error(reason)
    Ok(#(status, bytes)) ->
      case status {
        200 -> decode_discovery(bytes, id)
        _ -> Error("server discovery returned HTTP " <> int.to_string(status))
      }
  }
}

/// Performs a raw method call while checking the JSON-RPC version and response ID.
/// The returned bytes preserve the peer's exact JSON representation.
pub fn raw_json_call(
  client: Client,
  method: String,
  name: Option(String),
  params: List(#(String, json.Json)),
) -> Result(BitArray, String) {
  let requires_name = case method {
    "tools/call" | "prompts/get" | "resources/read" -> True
    _ -> False
  }
  case requires_name, name {
    True, None ->
      Error(method <> " requires a routing name for MCP header agreement")
    False, Some(_) -> Error("Mcp-Name is not valid for " <> method)
    _, _ -> {
      let id = request_id()
      let body = request_envelope(id, method, params)
      let name = case name {
        None -> ""
        Some(value) -> value
      }
      case request(client, body, id, method, name) {
        Error(reason) -> Error(reason)
        Ok(#(status, _)) if status != 200 ->
          Error("raw method call returned HTTP " <> int.to_string(status))
        Ok(#(_, bytes)) ->
          validate_jsonrpc_response(bytes, id)
          |> result.map(fn(_) { bytes })
      }
    }
  }
}

/// Traverses all tools/list pages and returns typed declarations.
pub fn list_tools(client: Client) -> Result(List(ToolDeclaration), String) {
  case list_json_pages(client, "tools/list", "tools") {
    Error(reason) -> Error(reason)
    Ok(items) -> decode_json_items(items, decode_tool_declaration)
  }
}

/// Preserves each remote declaration as checked JSON for raw integrations.
pub fn list_tools_json(client: Client) -> Result(List(String), String) {
  list_json_pages(client, "tools/list", "tools")
}

/// Traverses all resources/list pages and returns typed declarations.
pub fn list_resources(
  client: Client,
) -> Result(List(ResourceDeclaration), String) {
  case list_json_pages(client, "resources/list", "resources") {
    Error(reason) -> Error(reason)
    Ok(items) -> decode_json_items(items, decode_resource_declaration)
  }
}

/// Preserves each remote declaration as checked JSON for raw integrations.
pub fn list_resources_json(client: Client) -> Result(List(String), String) {
  list_json_pages(client, "resources/list", "resources")
}

/// Traverses all resources/templates/list pages as typed declarations.
pub fn list_resource_templates(
  client: Client,
) -> Result(List(ResourceTemplateDeclaration), String) {
  case
    list_json_pages(client, "resources/templates/list", "resourceTemplates")
  {
    Error(reason) -> Error(reason)
    Ok(items) -> decode_json_items(items, decode_resource_template_declaration)
  }
}

/// Preserves each remote declaration as checked JSON for raw integrations.
pub fn list_resource_templates_json(
  client: Client,
) -> Result(List(String), String) {
  list_json_pages(client, "resources/templates/list", "resourceTemplates")
}

/// Traverses all prompts/list pages and returns typed declarations.
pub fn list_prompts(client: Client) -> Result(List(PromptDeclaration), String) {
  case list_json_pages(client, "prompts/list", "prompts") {
    Error(reason) -> Error(reason)
    Ok(items) -> decode_json_items(items, decode_prompt_declaration)
  }
}

/// Preserves each remote declaration as checked JSON for raw integrations.
pub fn list_prompts_json(client: Client) -> Result(List(String), String) {
  list_json_pages(client, "prompts/list", "prompts")
}

fn call_tool(
  client: Client,
  name: ToolName,
  input: input,
  input_codec: Codec(input),
  output_codec: Codec(output),
) -> ToolCallOutcome(output) {
  case encode(input_codec, input) {
    Error(_) -> InputEncodingFailure
    Ok(arguments) -> {
      let id = request_id()
      let tool_name = tool.tool_name_to_string(name)
      let params = [
        #("name", json.string(tool_name)),
        #("arguments", v2026.value_to_json(arguments)),
      ]
      let body = request_envelope(id, "tools/call", params)
      case request(client, body, id, "tools/call", tool_name) {
        Error("cancelled") -> Cancelled
        Error(reason) -> TransportFailure(reason)
        Ok(#(status, _)) if status != 200 ->
          TransportFailure("tool call returned HTTP " <> int.to_string(status))
        Ok(#(_, bytes)) ->
          case decode_tool_response(bytes, id) {
            Error(reason) -> ProtocolFailure(reason)
            Ok(#(is_error, maybe_structured, texts)) ->
              case is_error, maybe_structured {
                True, _ -> ToolFailure(texts)
                False, None -> ContentOnlySuccess(texts)
                False, Some(value) ->
                  case decode(output_codec, value) {
                    Ok(output) -> StructuredSuccess(output, texts)
                    Error(_) ->
                      ProtocolFailure(
                        "structured content did not match the output codec",
                      )
                  }
              }
          }
      }
    }
  }
}

/// Calls a tool using the same admitted native contract used at registration.
pub fn call_definition(
  client: Client,
  definition: tool.Definition(input, output),
  input: input,
) -> ToolCallOutcome(output) {
  call_tool(
    client,
    tool.definition_name(definition),
    input,
    tool.definition_input_codec(definition),
    tool.definition_output_codec(definition),
  )
}

/// Calls an admitted content-only tool without requiring an output codec.
pub fn call_content_definition(
  client: Client,
  definition: tool.ContentDefinition(input),
  input: input,
) -> Result(List(content.ContentBlock), ContentCallError) {
  case encode(tool.content_definition_input_codec(definition), input) {
    Error(_) -> Error(ContentInputEncodingFailure)
    Ok(arguments) -> {
      let id = request_id()
      let tool_name =
        tool.content_definition_name(definition) |> tool.tool_name_to_string
      let body =
        request_envelope(id, "tools/call", [
          #("name", json.string(tool_name)),
          #("arguments", v2026.value_to_json(arguments)),
        ])
      case request(client, body, id, "tools/call", tool_name) {
        Error("cancelled") -> Error(ContentCancelled)
        Error(reason) -> Error(ContentTransportFailure(reason))
        Ok(#(status, _)) if status != 200 ->
          Error(ContentTransportFailure(
            "tool call returned HTTP " <> int.to_string(status),
          ))
        Ok(#(_, bytes)) ->
          case decode_tool_response(bytes, id) {
            Error(reason) -> Error(ContentProtocolFailure(reason))
            Ok(#(True, _, blocks)) -> Error(ContentToolFailure(blocks))
            Ok(#(False, Some(_), _)) -> Error(UnexpectedStructuredContent)
            Ok(#(False, None, blocks)) -> Ok(blocks)
          }
      }
    }
  }
}

/// Reads a resource and decodes its text or base64 content.
pub fn read_resource(
  client: Client,
  uri: String,
) -> Result(List(content.ResourceContents), String) {
  use result_value <- result.try(
    jsonrpc_call_result(client, "resources/read", uri, [
      #("uri", json.string(uri)),
    ]),
  )
  use raw_contents <- result.try(
    dyn_decode.run(
      result_value,
      dyn_decode.at(["contents"], dyn_decode.list(dyn_decode.dynamic)),
    )
    |> result.map_error(fn(_) { "resource result is missing its contents" }),
  )
  decode_resource_contents_list(raw_contents)
}

/// Fetches a prompt result with string-valued arguments.
pub fn get_prompt(
  client: Client,
  name: String,
  arguments: Dict(String, String),
) -> Result(prompts.PromptResult, String) {
  use result_value <- result.try(
    jsonrpc_call_result(client, "prompts/get", name, [
      #("name", json.string(name)),
      #(
        "arguments",
        json.object(
          list.map(dict.to_list(arguments), fn(pair) {
            let #(key, value) = pair
            #(key, json.string(value))
          }),
        ),
      ),
    ]),
  )
  decode_prompt_result(result_value)
}

/// Requests completions using a typed reference, argument, and optional context.
pub fn complete(
  client: Client,
  reference: completion.CompletionRef,
  argument: completion.CompletionArgument,
  context: Option(Dict(String, String)),
) -> Result(completion.CompletionValues, String) {
  let fields = [
    #("ref", completion_ref_to_json(reference)),
    #(
      "argument",
      json.object([
        #("name", json.string(argument.name)),
        #("value", json.string(argument.value)),
      ]),
    ),
  ]
  let fields = case context {
    None -> fields
    Some(values) ->
      list.append(fields, [
        #(
          "context",
          json.object(
            list.map(dict.to_list(values), fn(pair) {
              let #(key, value) = pair
              #(key, json.string(value))
            }),
          ),
        ),
      ])
  }
  use result_value <- result.try(jsonrpc_call_result(
    client,
    "completion/complete",
    "",
    fields,
  ))
  decode_completion_values(result_value)
}

/// Opens a typed server-notification stream and verifies its acknowledgement.
pub fn listen(
  client: Client,
  requested: SubscriptionFilter,
) -> Result(Subscription, String) {
  case client.transport {
    StdioTransport(child) -> {
      let id = request_id()
      let body =
        v2026.encode_subscriptions_listen_request(RequestString(id), requested)
        |> json.to_string
        |> bit_array.from_string
      case
        stdio_client.subscribe(
          child,
          body,
          id,
          client.timeout_ms,
          client.max_response_bytes,
        )
      {
        Error(reason) ->
          Error("subscription acknowledgement failed: " <> reason)
        Ok(bytes) ->
          case decode_subscription_acknowledgement(bytes, id) {
            Error(reason) -> Error(reason)
            Ok(notifications) ->
              Ok(StdioSubscription(
                child,
                id,
                notifications,
                client.max_response_bytes,
              ))
          }
      }
    }
    HttpTransport(pid) -> {
      let id = request_id()
      let body =
        v2026.encode_subscriptions_listen_request(RequestString(id), requested)
        |> json.to_string
        |> bit_array.from_string
      case
        ffi_open_sse(
          pid,
          client.path,
          body,
          protocol_version,
          client.timeout_ms,
          client.max_response_bytes,
        )
      {
        Error(reason) -> Error(reason)
        Ok(reader) ->
          case ffi_next_sse(reader, client.timeout_ms) {
            Error(reason) -> {
              ffi_close_sse(reader)
              Error("subscription acknowledgement failed: " <> reason)
            }
            Ok(bytes) ->
              case decode_subscription_acknowledgement(bytes, id) {
                Error(reason) -> {
                  ffi_close_sse(reader)
                  Error(reason)
                }
                Ok(notifications) ->
                  Ok(HttpSubscription(reader, id, notifications))
              }
          }
      }
    }
  }
}

/// Returns the notification filter the server confirmed for this stream.
pub fn acknowledged_notifications(
  subscription: Subscription,
) -> SubscriptionFilter {
  case subscription {
    HttpSubscription(_, _, notifications) -> notifications
    StdioSubscription(_, _, notifications, _) -> notifications
  }
}

/// Waits for and decodes the next notification from a subscription stream.
pub fn next_notification(
  subscription: Subscription,
  timeout_ms: Int,
) -> Result(SubscriptionNotification, String) {
  case timeout_ms > 0 {
    False -> Error("subscription wait timeout must be positive")
    True ->
      case subscription {
        HttpSubscription(reader, request_id, _) ->
          case ffi_next_sse(reader, timeout_ms) {
            Error("timeout") -> Error("subscription notification timed out")
            Error(reason) -> Error(reason)
            Ok(bytes) -> decode_subscription_notification(bytes, request_id)
          }
        StdioSubscription(child, request_id, _, max_response_bytes) ->
          case
            stdio_client.next_notification(
              child,
              request_id,
              timeout_ms,
              max_response_bytes,
            )
          {
            Error("stdio notification timed out") ->
              Error("subscription notification timed out")
            Error(reason) -> Error(reason)
            Ok(bytes) -> decode_subscription_notification(bytes, request_id)
          }
      }
  }
}

/// Cancels this stream without closing other requests on the shared connection.
pub fn close_subscription(subscription: Subscription) -> Nil {
  case subscription {
    HttpSubscription(reader, _, _) -> ffi_close_sse(reader)
    StdioSubscription(child, request_id, _, _) -> {
      let _ = stdio_client.cancel_subscription(child, request_id)
      Nil
    }
  }
}

fn decode_subscription_acknowledgement(
  bytes: BitArray,
  expected_id: String,
) -> Result(SubscriptionFilter, String) {
  use raw <- result.try(subscription_json(bytes))
  use version <- result.try(string_field(raw, ["jsonrpc"]))
  use method <- result.try(string_field(raw, ["method"]))
  case version, method {
    "2.0", "notifications/subscriptions/acknowledged" -> {
      use params <- result.try(dynamic_field(raw, ["params"]))
      use _ <- result.try(validate_subscription_id(params, expected_id))
      use notifications <- result.try(dynamic_field(params, ["notifications"]))
      decode_subscription_filter(notifications)
    }
    _, _ -> Error("subscription stream did not begin with its acknowledgement")
  }
}

fn decode_subscription_notification(
  bytes: BitArray,
  expected_id: String,
) -> Result(SubscriptionNotification, String) {
  use raw <- result.try(subscription_json(bytes))
  use version <- result.try(string_field(raw, ["jsonrpc"]))
  use method <- result.try(string_field(raw, ["method"]))
  case version {
    "2.0" -> {
      use params <- result.try(dynamic_field(raw, ["params"]))
      use _ <- result.try(validate_subscription_id(params, expected_id))
      case method {
        "notifications/resources/updated" ->
          string_field(params, ["uri"])
          |> result.map(ResourceUpdated)
        "notifications/tools/list_changed" -> Ok(ToolsListChanged)
        "notifications/resources/list_changed" -> Ok(ResourcesListChanged)
        "notifications/prompts/list_changed" -> Ok(PromptsListChanged)
        _ -> Error("subscription stream contained an unsupported notification")
      }
    }
    _ -> Error("subscription notification used an unsupported JSON-RPC version")
  }
}

fn subscription_json(bytes: BitArray) -> Result(Dynamic, String) {
  case bit_array.to_string(bytes) {
    Error(_) -> Error("subscription event was not UTF-8")
    Ok(raw) ->
      json.parse(raw, dyn_decode.dynamic)
      |> result.map_error(fn(_) { "subscription event was not valid JSON" })
  }
}

fn dynamic_field(
  value: Dynamic,
  path: List(String),
) -> Result(Dynamic, String) {
  dyn_decode.run(value, dyn_decode.at(path, dyn_decode.dynamic))
  |> result.map_error(fn(_) {
    "subscription event is missing a required object"
  })
}

fn validate_subscription_id(
  params: Dynamic,
  expected_id: String,
) -> Result(Nil, String) {
  use actual_id <- result.try(
    string_field(params, ["_meta", "io.modelcontextprotocol/subscriptionId"]),
  )
  case actual_id == expected_id {
    True -> Ok(Nil)
    False ->
      Error("subscription notification had an uncorrelated subscription ID")
  }
}

fn decode_subscription_filter(
  value: Dynamic,
) -> Result(SubscriptionFilter, String) {
  use fields <- result.try(
    dyn_decode.run(
      value,
      dyn_decode.dict(dyn_decode.string, dyn_decode.dynamic),
    )
    |> result.map_error(fn(_) { "subscription filter was not an object" }),
  )
  use tools_list_changed <- result.try(optional_filter_bool(
    fields,
    "toolsListChanged",
  ))
  use resources_list_changed <- result.try(optional_filter_bool(
    fields,
    "resourcesListChanged",
  ))
  use prompts_list_changed <- result.try(optional_filter_bool(
    fields,
    "promptsListChanged",
  ))
  use resource_subscriptions <- result.try(optional_filter_uris(fields))
  Ok(SubscriptionFilter(
    tools_list_changed,
    resources_list_changed,
    prompts_list_changed,
    resource_subscriptions,
  ))
}

fn optional_filter_bool(
  fields: Dict(String, Dynamic),
  key: String,
) -> Result(Bool, String) {
  case dict.get(fields, key) {
    Error(_) -> Ok(False)
    Ok(value) ->
      dyn_decode.run(value, dyn_decode.bool)
      |> result.map_error(fn(_) { "subscription filter flag was not a boolean" })
  }
}

fn optional_filter_uris(
  fields: Dict(String, Dynamic),
) -> Result(List(String), String) {
  case dict.get(fields, "resourceSubscriptions") {
    Error(_) -> Ok([])
    Ok(value) ->
      dyn_decode.run(value, dyn_decode.list(dyn_decode.string))
      |> result.map_error(fn(_) {
        "resourceSubscriptions was not a string array"
      })
  }
}

fn request(
  client: Client,
  body: BitArray,
  id: String,
  method: String,
  name: String,
) -> Result(#(Int, BitArray), String) {
  case client.transport {
    HttpTransport(pid) ->
      ffi_request(
        pid,
        client.path,
        body,
        method,
        name,
        protocol_version,
        client.timeout_ms,
        client.max_response_bytes,
      )
    StdioTransport(child) ->
      stdio_client.request(
        child,
        body,
        id,
        client.timeout_ms,
        client.max_response_bytes,
      )
      |> result.map(fn(bytes) { #(200, bytes) })
  }
}

fn jsonrpc_call_result(
  client: Client,
  method: String,
  name: String,
  params: List(#(String, json.Json)),
) -> Result(Dynamic, String) {
  let id = request_id()
  let body = request_envelope(id, method, params)
  case request(client, body, id, method, name) {
    Error(reason) -> Error(reason)
    Ok(#(status, _)) if status != 200 ->
      Error(method <> " returned HTTP " <> int.to_string(status))
    Ok(#(_, bytes)) ->
      case bit_array.to_string(bytes) {
        Error(_) -> Error(method <> " response was not UTF-8")
        Ok(raw) ->
          case json.parse(raw, dyn_decode.dynamic) {
            Error(_) -> Error(method <> " response was not valid JSON")
            Ok(response) -> validate_jsonrpc_result(response, id)
          }
      }
  }
}

fn completion_ref_to_json(reference: completion.CompletionRef) -> json.Json {
  case reference {
    completion.PromptRef(name) ->
      json.object([
        #("type", json.string("ref/prompt")),
        #("name", json.string(name)),
      ])
    completion.ResourceRef(uri) ->
      json.object([
        #("type", json.string("ref/resource")),
        #("uri", json.string(uri)),
      ])
  }
}

fn decode_resource_contents_list(
  contents: List(Dynamic),
) -> Result(List(content.ResourceContents), String) {
  case contents {
    [] -> Ok([])
    [raw, ..rest] ->
      decode_resource_contents(raw)
      |> result.try(fn(decoded) {
        decode_resource_contents_list(rest)
        |> result.map(fn(rest) { [decoded, ..rest] })
      })
  }
}

fn decode_prompt_result(
  value: Dynamic,
) -> Result(prompts.PromptResult, String) {
  use description <- result.try(optional_string_field(value, ["description"]))
  use raw_messages <- result.try(
    dyn_decode.run(
      value,
      dyn_decode.at(["messages"], dyn_decode.list(dyn_decode.dynamic)),
    )
    |> result.map_error(fn(_) { "prompt result is missing its messages" }),
  )
  use messages <- result.try(decode_prompt_messages(raw_messages))
  Ok(prompts.PromptResult(description, messages))
}

fn decode_prompt_messages(
  messages: List(Dynamic),
) -> Result(List(prompts.PromptMessage), String) {
  case messages {
    [] -> Ok([])
    [raw, ..rest] ->
      decode_prompt_message(raw)
      |> result.try(fn(decoded) {
        decode_prompt_messages(rest)
        |> result.map(fn(rest) { [decoded, ..rest] })
      })
  }
}

fn decode_prompt_message(
  value: Dynamic,
) -> Result(prompts.PromptMessage, String) {
  use role <- result.try(string_field(value, ["role"]))
  let role = case role {
    "user" -> Ok(content.UserRole)
    "assistant" -> Ok(content.AssistantRole)
    _ -> Error("prompt message has an unknown role")
  }
  use role <- result.try(role)
  use raw_content <- result.try(
    dyn_decode.run(value, dyn_decode.at(["content"], dyn_decode.dynamic))
    |> result.map_error(fn(_) { "prompt message is missing its content" }),
  )
  use content <- result.try(decode_content_block(raw_content))
  Ok(prompts.PromptMessage(role, content))
}

fn decode_completion_values(
  value: Dynamic,
) -> Result(completion.CompletionValues, String) {
  use values <- result.try(
    dyn_decode.run(
      value,
      dyn_decode.at(
        ["completion", "values"],
        dyn_decode.list(dyn_decode.string),
      ),
    )
    |> result.map_error(fn(_) { "completion result is missing its values" }),
  )
  use total <- result.try(optional_int_field(value, ["completion", "total"]))
  use has_more <- result.try(
    optional_bool_field(value, ["completion", "hasMore"]),
  )
  Ok(completion.CompletionValues(values, total, has_more))
}

fn validate_jsonrpc_response(
  bytes: BitArray,
  expected_id: String,
) -> Result(Nil, String) {
  case bit_array.to_string(bytes) {
    Error(_) -> Error("response was not UTF-8")
    Ok(raw) ->
      case json.parse(raw, dyn_decode.dynamic) {
        Error(_) -> Error("response was not valid JSON")
        Ok(response) -> {
          let version =
            dyn_decode.run(
              response,
              dyn_decode.at(["jsonrpc"], dyn_decode.string),
            )
          let response_id =
            dyn_decode.run(response, dyn_decode.at(["id"], dyn_decode.string))
          let result_field =
            dyn_decode.run(
              response,
              dyn_decode.at(["result"], dyn_decode.dynamic),
            )
          let error_field =
            dyn_decode.run(
              response,
              dyn_decode.at(["error"], dyn_decode.dynamic),
            )
          case version, response_id, result_field, error_field {
            Ok("2.0"), Ok(actual), Ok(_), Error(_) if actual == expected_id ->
              Ok(Nil)
            Ok("2.0"), Ok(actual), Error(_), Ok(_) if actual == expected_id ->
              Ok(Nil)
            _, _, _, _ -> Error("malformed or uncorrelated JSON-RPC response")
          }
        }
      }
  }
}

fn validate_jsonrpc_result(
  response: Dynamic,
  expected_id: String,
) -> Result(Dynamic, String) {
  let version =
    dyn_decode.run(response, dyn_decode.at(["jsonrpc"], dyn_decode.string))
  let response_id =
    dyn_decode.run(response, dyn_decode.at(["id"], dyn_decode.string))
  let result_field =
    dyn_decode.run(response, dyn_decode.at(["result"], dyn_decode.dynamic))
  let error_field =
    dyn_decode.run(response, dyn_decode.at(["error"], dyn_decode.dynamic))
  case version, response_id, result_field, error_field {
    Ok("2.0"), Ok(actual), Ok(result), Error(_) if actual == expected_id ->
      Ok(result)
    _, _, _, _ -> Error("malformed or uncorrelated JSON-RPC result")
  }
}

fn decode_tool_response(
  bytes: BitArray,
  expected_id: String,
) -> Result(
  #(Bool, Option(blueprint_value.Value), List(content.ContentBlock)),
  String,
) {
  case bit_array.to_string(bytes) {
    Error(_) -> Error("tool response was not UTF-8")
    Ok(raw) ->
      case json.parse(raw, dyn_decode.dynamic) {
        Error(_) -> Error("tool response was not valid JSON")
        Ok(response) ->
          case validate_jsonrpc_result(response, expected_id) {
            Error(reason) -> Error(reason)
            Ok(result_value) -> {
              let content =
                dyn_decode.run(
                  result_value,
                  dyn_decode.at(
                    ["content"],
                    dyn_decode.list(dyn_decode.dynamic),
                  ),
                )
              let is_error = optional_bool(result_value, ["isError"], False)
              case content, is_error {
                Ok(blocks), Ok(is_error) ->
                  case decode_content_blocks(blocks) {
                    Error(reason) -> Error(reason)
                    Ok(texts) ->
                      case decode_structured_content(bytes, result_value) {
                        Error(reason) -> Error(reason)
                        Ok(structured) -> Ok(#(is_error, structured, texts))
                      }
                  }
                _, _ -> Error("tool result has invalid content or isError")
              }
            }
          }
      }
  }
}

fn optional_bool(
  value: Dynamic,
  path: List(String),
  default: Bool,
) -> Result(Bool, String) {
  case dyn_decode.run(value, dyn_decode.at(path, dyn_decode.dynamic)) {
    Error(_) -> Ok(default)
    Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.bool)
      |> result.map_error(fn(_) { "tool result boolean field is invalid" })
  }
}

fn decode_content_blocks(
  blocks: List(Dynamic),
) -> Result(List(content.ContentBlock), String) {
  case blocks {
    [] -> Ok([])
    [block, ..rest] ->
      decode_content_block(block)
      |> result.try(fn(decoded) {
        decode_content_blocks(rest)
        |> result.map(fn(rest) { [decoded, ..rest] })
      })
  }
}

fn decode_content_block(
  block: Dynamic,
) -> Result(content.ContentBlock, String) {
  use block_type <- result.try(string_field(block, ["type"]))
  case block_type {
    "text" ->
      decode_annotations(block)
      |> result.try(fn(annotations) {
        string_field(block, ["text"])
        |> result.map(fn(text) { content.TextContent(text, annotations) })
      })
    "image" ->
      decode_annotations(block)
      |> result.try(fn(annotations) {
        use data <- result.try(string_field(block, ["data"]))
        use mime_type <- result.try(string_field(block, ["mimeType"]))
        Ok(content.ImageContent(data, mime_type, annotations))
      })
    "audio" ->
      decode_annotations(block)
      |> result.try(fn(annotations) {
        use data <- result.try(string_field(block, ["data"]))
        use mime_type <- result.try(string_field(block, ["mimeType"]))
        Ok(content.AudioContent(data, mime_type, annotations))
      })
    "resource_link" ->
      decode_resource_link(block)
      |> result.map(content.ResourceLinkBlock)
    "resource" ->
      decode_annotations(block)
      |> result.try(fn(annotations) {
        dyn_decode.run(block, dyn_decode.at(["resource"], dyn_decode.dynamic))
        |> result.map_error(fn(_) { "embedded resource is missing" })
        |> result.try(fn(resource) {
          decode_resource_contents(resource)
          |> result.map(fn(contents) {
            content.EmbeddedResourceBlock(content.EmbeddedResource(
              contents,
              annotations,
            ))
          })
        })
      })
    _ -> Error("tool result contains an unsupported content block")
  }
}

fn decode_resource_link(
  value: Dynamic,
) -> Result(content.ResourceLink, String) {
  use uri <- result.try(string_field(value, ["uri"]))
  use name <- result.try(string_field(value, ["name"]))
  use title <- result.try(optional_string_field(value, ["title"]))
  use description <- result.try(optional_string_field(value, ["description"]))
  use mime_type <- result.try(optional_string_field(value, ["mimeType"]))
  use size <- result.try(optional_int_field(value, ["size"]))
  use annotations <- result.try(decode_annotations(value))
  Ok(content.ResourceLink(
    uri,
    name,
    title,
    description,
    mime_type,
    size,
    annotations,
  ))
}

fn decode_resource_contents(
  value: Dynamic,
) -> Result(content.ResourceContents, String) {
  use uri <- result.try(string_field(value, ["uri"]))
  use mime_type <- result.try(optional_string_field(value, ["mimeType"]))
  use fields <- result.try(
    dyn_decode.run(
      value,
      dyn_decode.dict(dyn_decode.string, dyn_decode.dynamic),
    )
    |> result.map_error(fn(_) { "resource contents must be an object" }),
  )
  case dict.get(fields, "text"), dict.get(fields, "blob") {
    Ok(raw), Error(_) ->
      dyn_decode.run(raw, dyn_decode.string)
      |> result.map(content.TextResourceContents(uri, _, mime_type))
      |> result.map_error(fn(_) { "resource text must be a string" })
    Error(_), Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.string)
      |> result.map(content.BlobResourceContents(uri, _, mime_type))
      |> result.map_error(fn(_) { "resource blob must be a string" })
    _, _ -> Error("resource contents must contain exactly one of text or blob")
  }
}

fn decode_annotations(
  value: Dynamic,
) -> Result(Option(content.Annotations), String) {
  case
    dyn_decode.run(value, dyn_decode.at(["annotations"], dyn_decode.dynamic))
  {
    Error(_) -> Ok(None)
    Ok(raw) ->
      decode_annotation_object(raw)
      |> result.map(Some)
  }
}

fn decode_annotation_object(
  value: Dynamic,
) -> Result(content.Annotations, String) {
  use fields <- result.try(
    dyn_decode.run(
      value,
      dyn_decode.dict(dyn_decode.string, dyn_decode.dynamic),
    )
    |> result.map_error(fn(_) { "content annotations must be an object" }),
  )
  use audience <- result.try(optional_roles(fields, "audience"))
  use priority <- result.try(optional_float(fields, "priority"))
  use title <- result.try(optional_string(fields, "title"))
  use description <- result.try(optional_string(fields, "description"))
  Ok(content.Annotations(audience, priority, title, description))
}

fn decode_declaration_annotations(
  value: Dynamic,
) -> Result(Option(Annotations), String) {
  case
    dyn_decode.run(value, dyn_decode.at(["annotations"], dyn_decode.dynamic))
  {
    Error(_) -> Ok(None)
    Ok(raw) -> {
      use fields <- result.try(
        dyn_decode.run(
          raw,
          dyn_decode.dict(dyn_decode.string, dyn_decode.dynamic),
        )
        |> result.map_error(fn(_) {
          "declaration annotations must be an object"
        }),
      )
      use audience <- result.try(optional_roles(fields, "audience"))
      use priority <- result.try(optional_float(fields, "priority"))
      use last_modified <- result.try(optional_string(fields, "lastModified"))
      Ok(Some(Annotations(audience, priority, last_modified)))
    }
  }
}

fn decode_tool_annotations(
  value: Dynamic,
) -> Result(Option(tool.ToolAnnotations), String) {
  case
    dyn_decode.run(value, dyn_decode.at(["annotations"], dyn_decode.dynamic))
  {
    Error(_) -> Ok(None)
    Ok(raw) -> {
      use fields <- result.try(
        dyn_decode.run(
          raw,
          dyn_decode.dict(dyn_decode.string, dyn_decode.dynamic),
        )
        |> result.map_error(fn(_) { "tool annotations must be an object" }),
      )
      use title <- result.try(optional_string(fields, "title"))
      use read_only_hint <- result.try(optional_bool_dict(
        fields,
        "readOnlyHint",
      ))
      use destructive_hint <- result.try(optional_bool_dict(
        fields,
        "destructiveHint",
      ))
      use idempotent_hint <- result.try(optional_bool_dict(
        fields,
        "idempotentHint",
      ))
      use open_world_hint <- result.try(optional_bool_dict(
        fields,
        "openWorldHint",
      ))
      Ok(
        Some(tool.ToolAnnotations(
          title,
          read_only_hint,
          destructive_hint,
          idempotent_hint,
          open_world_hint,
        )),
      )
    }
  }
}

fn decode_icons(value: Dynamic) -> Result(Option(List(Icon)), String) {
  case dyn_decode.run(value, dyn_decode.at(["icons"], dyn_decode.dynamic)) {
    Error(_) -> Ok(None)
    Ok(raw) -> {
      use values <- result.try(
        dyn_decode.run(raw, dyn_decode.list(dyn_decode.dynamic))
        |> result.map_error(fn(_) { "declaration icons must be an array" }),
      )
      decode_icon_values(values)
      |> result.map(Some)
    }
  }
}

fn decode_icon_values(values: List(Dynamic)) -> Result(List(Icon), String) {
  case values {
    [] -> Ok([])
    [value, ..rest] ->
      decode_icon(value)
      |> result.try(fn(icon) {
        decode_icon_values(rest)
        |> result.map(fn(decoded_rest) { [icon, ..decoded_rest] })
      })
  }
}

fn decode_icon(value: Dynamic) -> Result(Icon, String) {
  use src <- result.try(string_field(value, ["src"]))
  use mime_type <- result.try(optional_string_field(value, ["mimeType"]))
  use sizes <- result.try(
    case dyn_decode.run(value, dyn_decode.at(["sizes"], dyn_decode.dynamic)) {
      Error(_) -> Ok(None)
      Ok(raw) ->
        dyn_decode.run(raw, dyn_decode.list(dyn_decode.string))
        |> result.map(Some)
        |> result.map_error(fn(_) { "icon sizes must be an array of strings" })
    },
  )
  use theme <- result.try(
    case dyn_decode.run(value, dyn_decode.at(["theme"], dyn_decode.dynamic)) {
      Error(_) -> Ok(None)
      Ok(raw) ->
        case dyn_decode.run(raw, dyn_decode.string) {
          Error(_) -> Error("icon theme is invalid")
          Ok(name) ->
            case name {
              "light" -> Ok(Some(IconLight))
              "dark" -> Ok(Some(IconDark))
              _ -> Error("icon theme must be light or dark")
            }
        }
    },
  )
  Ok(Icon(src, mime_type, sizes, theme))
}

fn optional_roles(
  fields: Dict(String, Dynamic),
  key: String,
) -> Result(Option(List(content.Role)), String) {
  case dict.get(fields, key) {
    Error(_) -> Ok(None)
    Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.list(dyn_decode.string))
      |> result.map_error(fn(_) {
        "content annotation audience must be an array"
      })
      |> result.try(fn(roles) {
        decode_roles(roles)
        |> result.map(Some)
      })
  }
}

fn decode_roles(values: List(String)) -> Result(List(content.Role), String) {
  case values {
    [] -> Ok([])
    [value, ..rest] ->
      case value {
        "user" ->
          decode_roles(rest)
          |> result.map(fn(rest) { [content.UserRole, ..rest] })
        "assistant" ->
          decode_roles(rest)
          |> result.map(fn(rest) { [content.AssistantRole, ..rest] })
        _ -> Error("content annotation audience has an unknown role")
      }
  }
}

fn optional_float(
  fields: Dict(String, Dynamic),
  key: String,
) -> Result(Option(Float), String) {
  case dict.get(fields, key) {
    Error(_) -> Ok(None)
    Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.float)
      |> result.map(Some)
      |> result.map_error(fn(_) {
        "content annotation priority must be numeric"
      })
  }
}

fn optional_bool_dict(
  fields: Dict(String, Dynamic),
  key: String,
) -> Result(Option(Bool), String) {
  case dict.get(fields, key) {
    Error(_) -> Ok(None)
    Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.bool)
      |> result.map(Some)
      |> result.map_error(fn(_) { "tool annotation hint must be boolean" })
  }
}

fn optional_string(
  fields: Dict(String, Dynamic),
  key: String,
) -> Result(Option(String), String) {
  case dict.get(fields, key) {
    Error(_) -> Ok(None)
    Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.string)
      |> result.map(Some)
      |> result.map_error(fn(_) { "content annotation field must be a string" })
  }
}

fn string_field(value: Dynamic, path: List(String)) -> Result(String, String) {
  dyn_decode.run(value, dyn_decode.at(path, dyn_decode.string))
  |> result.map_error(fn(_) { "result object is missing a required string" })
}

fn optional_string_field(
  value: Dynamic,
  path: List(String),
) -> Result(Option(String), String) {
  case dyn_decode.run(value, dyn_decode.at(path, dyn_decode.dynamic)) {
    Error(_) -> Ok(None)
    Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.string)
      |> result.map(Some)
      |> result.map_error(fn(_) { "optional result string is invalid" })
  }
}

fn optional_int_field(
  value: Dynamic,
  path: List(String),
) -> Result(Option(Int), String) {
  case dyn_decode.run(value, dyn_decode.at(path, dyn_decode.dynamic)) {
    Error(_) -> Ok(None)
    Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.int)
      |> result.map(Some)
      |> result.map_error(fn(_) { "optional result integer is invalid" })
  }
}

fn optional_bool_field(
  value: Dynamic,
  path: List(String),
) -> Result(Option(Bool), String) {
  case dyn_decode.run(value, dyn_decode.at(path, dyn_decode.dynamic)) {
    Error(_) -> Ok(None)
    Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.bool)
      |> result.map(Some)
      |> result.map_error(fn(_) { "optional result boolean is invalid" })
  }
}

fn decode_structured_content(
  bytes: BitArray,
  result_value: Dynamic,
) -> Result(Option(blueprint_value.Value), String) {
  case
    dyn_decode.run(
      result_value,
      dyn_decode.at(["structuredContent"], dyn_decode.dynamic),
    )
  {
    Error(_) -> Ok(None)
    Ok(_) ->
      case
        blueprint_parser.parse_value(blueprint_parser.default_limits(), bytes)
      {
        Error(_) ->
          Error("structured tool result contains an invalid JSON value")
        Ok(root) ->
          case blueprint_at(root, ["result", "structuredContent"]) {
            None -> Error("structured tool result is missing its value")
            Some(value) -> Ok(Some(value))
          }
      }
  }
}

fn decode_json_list_page(
  bytes: BitArray,
  expected_id: String,
  collection_key: String,
) -> Result(#(List(String), Option(String)), String) {
  case bit_array.to_string(bytes) {
    Error(_) -> Error("list response was not UTF-8")
    Ok(raw) ->
      case json.parse(raw, dyn_decode.dynamic) {
        Error(_) -> Error("list response was not valid JSON")
        Ok(response) ->
          case validate_jsonrpc_result(response, expected_id) {
            Error(reason) -> Error(reason)
            Ok(result_value) -> {
              use items <- result.try(
                dyn_decode.run(
                  result_value,
                  dyn_decode.at(
                    [collection_key],
                    dyn_decode.list(dyn_decode.dynamic),
                  ),
                )
                |> result.map_error(fn(_) {
                  "list response is missing its collection array"
                }),
              )
              use encoded_items <- result.try(dynamic_json_strings(items))
              use next_cursor <- result.try(
                optional_string_field(result_value, ["nextCursor"]),
              )
              Ok(#(encoded_items, next_cursor))
            }
          }
      }
  }
}

fn dynamic_json_strings(values: List(Dynamic)) -> Result(List(String), String) {
  case values {
    [] -> Ok([])
    [value, ..rest] ->
      dynamic_to_json(value)
      |> result.map(json.to_string)
      |> result.try(fn(encoded) {
        dynamic_json_strings(rest)
        |> result.map(fn(encoded_rest) { [encoded, ..encoded_rest] })
      })
  }
}

fn decode_json_items(
  items: List(String),
  decoder: fn(Dynamic) -> Result(value, String),
) -> Result(List(value), String) {
  case items {
    [] -> Ok([])
    [raw, ..rest] ->
      case json.parse(raw, dyn_decode.dynamic) {
        Error(_) -> Error("list item was not valid JSON")
        Ok(value) ->
          case decoder(value) {
            Error(reason) -> Error(reason)
            Ok(decoded) ->
              decode_json_items(rest, decoder)
              |> result.map(fn(decoded_rest) { [decoded, ..decoded_rest] })
          }
      }
  }
}

fn decode_tool_declaration(value: Dynamic) -> Result(ToolDeclaration, String) {
  use name <- result.try(string_field(value, ["name"]))
  use title <- result.try(optional_string_field(value, ["title"]))
  use description <- result.try(optional_string_field(value, ["description"]))
  use raw_input <- result.try(dynamic_field(value, ["inputSchema"]))
  use input_schema <- result.try(dynamic_to_json(raw_input))
  use output_schema <- result.try(optional_json_field(value, ["outputSchema"]))
  use annotations <- result.try(decode_tool_annotations(value))
  use icons <- result.try(decode_icons(value))
  use meta <- result.try(optional_json_field(value, ["_meta"]))
  Ok(ToolDeclaration(
    name,
    title,
    description,
    input_schema,
    output_schema,
    annotations,
    icons,
    meta,
  ))
}

fn decode_resource_declaration(
  value: Dynamic,
) -> Result(ResourceDeclaration, String) {
  use uri <- result.try(string_field(value, ["uri"]))
  use name <- result.try(string_field(value, ["name"]))
  use title <- result.try(optional_string_field(value, ["title"]))
  use description <- result.try(optional_string_field(value, ["description"]))
  use mime_type <- result.try(optional_string_field(value, ["mimeType"]))
  use size <- result.try(optional_int_field(value, ["size"]))
  use annotations <- result.try(decode_declaration_annotations(value))
  use icons <- result.try(decode_icons(value))
  use meta <- result.try(optional_json_field(value, ["_meta"]))
  Ok(ResourceDeclaration(
    uri,
    name,
    title,
    description,
    mime_type,
    size,
    annotations,
    icons,
    meta,
  ))
}

fn decode_resource_template_declaration(
  value: Dynamic,
) -> Result(ResourceTemplateDeclaration, String) {
  use uri_template <- result.try(string_field(value, ["uriTemplate"]))
  use name <- result.try(string_field(value, ["name"]))
  use title <- result.try(optional_string_field(value, ["title"]))
  use description <- result.try(optional_string_field(value, ["description"]))
  use mime_type <- result.try(optional_string_field(value, ["mimeType"]))
  use annotations <- result.try(decode_declaration_annotations(value))
  use icons <- result.try(decode_icons(value))
  use meta <- result.try(optional_json_field(value, ["_meta"]))
  Ok(ResourceTemplateDeclaration(
    uri_template,
    name,
    title,
    description,
    mime_type,
    annotations,
    icons,
    meta,
  ))
}

fn decode_prompt_declaration(
  value: Dynamic,
) -> Result(PromptDeclaration, String) {
  use name <- result.try(string_field(value, ["name"]))
  use title <- result.try(optional_string_field(value, ["title"]))
  use description <- result.try(optional_string_field(value, ["description"]))
  use raw_arguments <- result.try(optional_prompt_arguments(value))
  use arguments <- result.try(decode_prompt_arguments(raw_arguments))
  use icons <- result.try(decode_icons(value))
  use meta <- result.try(optional_json_field(value, ["_meta"]))
  Ok(PromptDeclaration(name, title, description, arguments, icons, meta))
}

fn optional_prompt_arguments(value: Dynamic) -> Result(List(Dynamic), String) {
  use fields <- result.try(
    dyn_decode.run(
      value,
      dyn_decode.dict(dyn_decode.string, dyn_decode.dynamic),
    )
    |> result.map_error(fn(_) { "prompt declaration must be an object" }),
  )
  case dict.get(fields, "arguments") {
    Error(_) -> Ok([])
    Ok(raw) ->
      dyn_decode.run(raw, dyn_decode.list(dyn_decode.dynamic))
      |> result.map_error(fn(_) { "prompt declaration arguments are invalid" })
  }
}

fn decode_prompt_arguments(
  values: List(Dynamic),
) -> Result(List(prompts.PromptArgument), String) {
  case values {
    [] -> Ok([])
    [value, ..rest] -> {
      use name <- result.try(string_field(value, ["name"]))
      use description <- result.try(
        optional_string_field(value, ["description"]),
      )
      use required <- result.try(optional_bool_field(value, ["required"]))
      use title <- result.try(optional_string_field(value, ["title"]))
      let required = case required {
        Some(value) -> value
        None -> False
      }
      let argument = prompts.PromptArgument(name, description, required, title)
      decode_prompt_arguments(rest)
      |> result.map(fn(decoded_rest) { [argument, ..decoded_rest] })
    }
  }
}

fn optional_json_field(
  value: Dynamic,
  path: List(String),
) -> Result(Option(json.Json), String) {
  case dyn_decode.run(value, dyn_decode.at(path, dyn_decode.dynamic)) {
    Error(_) -> Ok(None)
    Ok(raw) -> dynamic_to_json(raw) |> result.map(Some)
  }
}

fn dynamic_to_json(value: Dynamic) -> Result(json.Json, String) {
  case dyn_decode.run(value, dyn_decode.optional(dyn_decode.dynamic)) {
    Ok(None) -> Ok(json.null())
    Error(_) -> Error("JSON value could not be inspected")
    Ok(Some(non_null)) ->
      case dyn_decode.run(non_null, dyn_decode.bool) {
        Ok(boolean) -> Ok(json.bool(boolean))
        Error(_) ->
          case dyn_decode.run(non_null, dyn_decode.int) {
            Ok(integer) -> Ok(json.int(integer))
            Error(_) ->
              case dyn_decode.run(non_null, dyn_decode.float) {
                Ok(decimal) -> Ok(json.float(decimal))
                Error(_) ->
                  case dyn_decode.run(non_null, dyn_decode.string) {
                    Ok(text) -> Ok(json.string(text))
                    Error(_) ->
                      case
                        dyn_decode.run(
                          non_null,
                          dyn_decode.list(dyn_decode.dynamic),
                        )
                      {
                        Ok(values) ->
                          dynamic_json_list(values)
                          |> result.map(fn(items) {
                            json.array(items, fn(item) { item })
                          })
                        Error(_) ->
                          case
                            dyn_decode.run(
                              non_null,
                              dyn_decode.dict(
                                dyn_decode.string,
                                dyn_decode.dynamic,
                              ),
                            )
                          {
                            Ok(fields) -> dynamic_json_object(fields)
                            Error(_) ->
                              Error("JSON value has an unsupported type")
                          }
                      }
                  }
              }
          }
      }
  }
}

fn dynamic_json_list(values: List(Dynamic)) -> Result(List(json.Json), String) {
  case values {
    [] -> Ok([])
    [value, ..rest] ->
      dynamic_to_json(value)
      |> result.try(fn(decoded) {
        dynamic_json_list(rest)
        |> result.map(fn(decoded_rest) { [decoded, ..decoded_rest] })
      })
  }
}

fn dynamic_json_object(
  fields: Dict(String, Dynamic),
) -> Result(json.Json, String) {
  dict.to_list(fields)
  |> dynamic_json_fields
  |> result.map(json.object)
}

fn dynamic_json_fields(
  fields: List(#(String, Dynamic)),
) -> Result(List(#(String, json.Json)), String) {
  case fields {
    [] -> Ok([])
    [#(key, value), ..rest] ->
      dynamic_to_json(value)
      |> result.try(fn(decoded) {
        dynamic_json_fields(rest)
        |> result.map(fn(decoded_rest) { [#(key, decoded), ..decoded_rest] })
      })
  }
}

fn blueprint_at(
  value: blueprint_value.Value,
  path: List(String),
) -> Option(blueprint_value.Value) {
  case path {
    [] -> Some(value)
    [key, ..rest] ->
      case value {
        blueprint_value.Object(fields) ->
          case list.key_find(fields, key) {
            Ok(child) -> blueprint_at(child, rest)
            Error(_) -> None
          }
        _ -> None
      }
  }
}

fn request_id() -> String {
  "relay-" <> int.to_string(ffi_unique_integer())
}

fn list_json_pages(
  client: Client,
  method: String,
  collection_key: String,
) -> Result(List(String), String) {
  list_json_page(client, method, collection_key, None, [], [], 10_000)
}

fn list_json_page(
  client: Client,
  method: String,
  collection_key: String,
  cursor: Option(String),
  seen_cursors: List(String),
  accumulated: List(String),
  remaining_pages: Int,
) -> Result(List(String), String) {
  case remaining_pages <= 0 {
    True -> Error(method <> " exceeded the client page limit")
    False -> {
      let params = case cursor {
        None -> []
        Some(value) -> [#("cursor", json.string(value))]
      }
      let id = request_id()
      let body = request_envelope(id, method, params)
      case request(client, body, id, method, "") {
        Error(reason) -> Error(reason)
        Ok(#(status, _)) if status != 200 ->
          Error(method <> " returned HTTP " <> int.to_string(status))
        Ok(#(_, bytes)) ->
          case decode_json_list_page(bytes, id, collection_key) {
            Error(reason) -> Error(reason)
            Ok(#(items, next_cursor)) -> {
              let accumulated = list.append(accumulated, items)
              case next_cursor {
                None -> Ok(accumulated)
                Some(next) ->
                  case list.contains(seen_cursors, next) {
                    True -> Error(method <> " cursor repeated")
                    False ->
                      list_json_page(
                        client,
                        method,
                        collection_key,
                        Some(next),
                        [next, ..seen_cursors],
                        accumulated,
                        remaining_pages - 1,
                      )
                  }
              }
            }
          }
      }
    }
  }
}

fn request_envelope(
  id: String,
  method: String,
  params: List(#(String, json.Json)),
) -> BitArray {
  let metadata =
    json.object([
      #(
        "io.modelcontextprotocol/protocolVersion",
        json.string(protocol_version),
      ),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ])
  let params = json.object([#("_meta", metadata), ..params])
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string(method)),
    #("params", params),
  ])
  |> json.to_string
  |> bit_array.from_string
}

fn decode_discovery(
  bytes: BitArray,
  expected_id: String,
) -> Result(Discovery, String) {
  case bit_array.to_string(bytes) {
    Error(_) -> Error("server discovery response was not UTF-8")
    Ok(raw) ->
      case json.parse(raw, dyn_decode.dynamic) {
        Error(_) -> Error("server discovery response was not valid JSON")
        Ok(dynamic) -> {
          let versions =
            dyn_decode.run(
              dynamic,
              dyn_decode.at(
                ["result", "supportedVersions"],
                dyn_decode.list(dyn_decode.string),
              ),
            )
          let wire_version =
            dyn_decode.run(
              dynamic,
              dyn_decode.at(["jsonrpc"], dyn_decode.string),
            )
          let response_id =
            dyn_decode.run(dynamic, dyn_decode.at(["id"], dyn_decode.string))
          let capabilities =
            dyn_decode.run(
              dynamic,
              dyn_decode.at(["result", "capabilities"], dyn_decode.dynamic),
            )
          case versions, capabilities, wire_version, response_id {
            Ok(supported), Ok(capabilities), Ok("2.0"), Ok(id) ->
              case
                id == expected_id && list.contains(supported, protocol_version)
              {
                False ->
                  Error(
                    "server discovery response was uncorrelated or did not support "
                    <> protocol_version,
                  )
                True ->
                  Ok(Discovery(
                    server_info: decode_server_info(dynamic),
                    supported_versions: supported,
                    capabilities: capabilities,
                  ))
              }
            _, _, _, _ ->
              Error("server discovery response is missing required fields")
          }
        }
      }
  }
}

fn decode_server_info(dynamic: Dynamic) -> Option(ServerInfo) {
  let name =
    dyn_decode.run(
      dynamic,
      dyn_decode.at(
        ["result", "_meta", "io.modelcontextprotocol/serverInfo", "name"],
        dyn_decode.string,
      ),
    )
  let version =
    dyn_decode.run(
      dynamic,
      dyn_decode.at(
        ["result", "_meta", "io.modelcontextprotocol/serverInfo", "version"],
        dyn_decode.string,
      ),
    )
  case name, version {
    Ok(name), Ok(version) -> Some(ServerInfo(name, version))
    _, _ -> None
  }
}
