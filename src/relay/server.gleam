import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import json/blueprint/value.{type Value}
import relay/completion.{
  type CompletionArgument, type CompletionError, type CompletionRef,
  type CompletionValues, type ContextCompletion, ContextCompletion,
}
import relay/content.{type ContentBlock, type ResourceContents}
import relay/prompts.{
  type ContextPrompt, type Prompt, type PromptError, ContextPrompt,
  ContextPromptWithInputs,
}
import relay/protocol/jsonrpc.{type ProgressToken, type RequestId}
import relay/protocol/v2026_07_28 as v2026
import relay/resources.{
  type ContextResource, type ContextResourceTemplate, type Resource,
  type ResourceError, type ResourceTemplate, ContextResource,
  ContextResourceTemplate,
}
import relay/subscriptions.{type SubscriptionFilter, type Subscriptions}
import relay/tool.{
  type ContextTool, type DispatchError, type Registry, type RegistryError,
  type ToolName,
}

pub opaque type ExchangeId {
  ExchangeId(Int)
}

pub fn fresh_exchange() -> ExchangeId {
  ExchangeId(ffi_unique_integer())
}

pub fn exchange_id(n: Int) -> ExchangeId {
  ExchangeId(n)
}

pub fn exchange_id_to_int(id: ExchangeId) -> Int {
  let ExchangeId(n) = id
  n
}

pub fn exchange_id_to_string(id: ExchangeId) -> String {
  int.to_string(exchange_id_to_int(id))
}

/// Returns an HTTP admission error that must be decided before opening an SSE stream.
pub fn http_admission_failure(
  server: Server(context),
  bytes: BitArray,
) -> Option(#(Int, BitArray)) {
  case v2026.admit_bytes(bytes) {
    v2026.AdmittedRequest(v2026.ToolsCall(id, metadata, name, _, _, _)) -> {
      let missing =
        tool.required_client_capabilities(server.registry, name)
        |> list.filter(fn(capability) {
          !v2026.client_declares_capability(metadata, capability)
        })
      case missing {
        [] -> None
        [_, ..] ->
          Some(#(
            400,
            string_to_bytes(
              json.to_string(jsonrpc.error_to_json(
                Some(id),
                jsonrpc.missing_required_client_capability(missing),
              ))
              <> "\n",
            ),
          ))
      }
    }
    _ -> None
  }
}

/// Validates schema-declared custom parameter headers before HTTP admission.
pub fn http_custom_headers_valid(
  server: Server(context),
  name: String,
  arguments: Value,
  header_lookup: fn(String) -> Option(String),
) -> Bool {
  let tool_name = tool.tool_name_from_trusted(name)
  case tool.input_schema_document(server.registry, tool_name) {
    None -> True
    Some(value.Object(schema_fields)) -> {
      let schema_fields = dict.from_list(schema_fields)
      case dict.get(schema_fields, "properties") {
        Ok(value.Object(properties)) ->
          custom_properties_match(properties, arguments, header_lookup)
        _ -> True
      }
    }
    Some(_) -> True
  }
}

fn custom_properties_match(
  properties: List(#(String, Value)),
  arguments: Value,
  header_lookup: fn(String) -> Option(String),
) -> Bool {
  let arguments = case arguments {
    value.Object(fields) -> dict.from_list(fields)
    _ -> dict.new()
  }
  list.all(properties, fn(pair) {
    let #(property_name, property_schema) = pair
    case property_schema {
      value.Object(schema_fields) -> {
        let schema_fields = dict.from_list(schema_fields)
        case dict.get(schema_fields, "x-mcp-header") {
          Ok(value.String(suffix)) ->
            custom_property_matches_header(
              property_name,
              suffix,
              arguments,
              header_lookup,
            )
          _ -> True
        }
      }
      _ -> True
    }
  })
}

fn custom_property_matches_header(
  property_name: String,
  suffix: String,
  arguments: Dict(String, Value),
  header_lookup: fn(String) -> Option(String),
) -> Bool {
  case suffix == "" {
    True -> False
    False -> {
      let argument = dict.get(arguments, property_name)
      let header = header_lookup("mcp-param-" <> string.lowercase(suffix))
      case argument, header {
        Error(_), None -> True
        Ok(_), None -> False
        Error(_), Some(_) -> False
        Ok(value.String(expected)), Some(raw_header) ->
          case decode_custom_header_value(string.trim(raw_header)) {
            Ok(decoded) -> decoded == expected
            Error(_) -> False
          }
        Ok(_), Some(_) -> False
      }
    }
  }
}

fn decode_custom_header_value(raw: String) -> Result(String, Nil) {
  let prefix = "=?base64?"
  let suffix = "?="
  case string.starts_with(raw, prefix) && string.ends_with(raw, suffix) {
    True ->
      raw
      |> string.drop_start(string.length(prefix))
      |> string.drop_end(string.length(suffix))
      |> ffi_decode_base64_strict
    False -> Ok(raw)
  }
}

/// Reports whether this server has already admitted or closed the exchange.
pub fn exchange_is_known(
  server: Server(context),
  exchange: ExchangeId,
) -> Bool {
  case find_exchange(server.exchanges, exchange) {
    Some(_) -> True
    None -> False
  }
}

pub opaque type InvocationId {
  InvocationId(Int)
}

pub fn fresh_invocation() -> InvocationId {
  InvocationId(ffi_unique_integer())
}

pub fn invocation_id_to_int(id: InvocationId) -> Int {
  let InvocationId(n) = id
  n
}

@external(erlang, "relay_ffi", "unique_integer")
fn ffi_unique_integer() -> Int

@external(erlang, "relay_ffi", "decode_base64_strict")
fn ffi_decode_base64_strict(encoded: String) -> Result(String, Nil)

@external(erlang, "relay_ffi", "new_cursor_key")
fn ffi_new_cursor_key() -> BitArray

@external(erlang, "relay_ffi", "make_cursor")
fn ffi_make_cursor(key: BitArray, family: String, offset: Int) -> String

@external(erlang, "relay_ffi", "read_cursor")
fn ffi_read_cursor(
  key: BitArray,
  family: String,
  token: String,
) -> Result(Int, Nil)

pub type UnhandledMessage {
  UnsupportedNotificationMessage
  UnexpectedResponseMessage
}

pub type InvocationOutcome {
  OutcomeSuccess(Value)
  OutcomeContentSuccess(List(ContentBlock))
  OutcomeStructuredContentSuccess(Value, List(ContentBlock))
  OutcomeApplicationError(Value)
  OutcomeJsonSuccess(json.Json)
  OutcomeJsonError(json.Json)
  OutcomeInvalidInput
  OutcomeInternalError(String)
}

pub type ServerInput(context) {
  MessageReceived(exchange: ExchangeId, context: context, bytes: BitArray)
  InvocationFinished(invocation: InvocationId, outcome: InvocationOutcome)
  InvocationProgress(invocation: InvocationId, value: Int)
  ExchangeClosed(exchange: ExchangeId)
  NotifyResourceUpdated(uri: String)
  NotifyToolsListChanged
  NotifyResourcesListChanged
  NotifyPromptsListChanged
  RegisterTool(tool: ContextTool(context))
  UnregisterTool(name: ToolName)
  TerminateSubscription(id: RequestId)
}

pub type ServerEffect(context) {
  Write(exchange: ExchangeId, bytes: BitArray)
  StartInvocation(Invocation(context))
  SendProgress(exchange: ExchangeId, token: ProgressToken, value: Int)
  CancelInvocation(InvocationId)
  CloseExchange(ExchangeId)
  Ignore(UnhandledMessage)
  EmitRequestAdmitted(exchange: ExchangeId, method: String)
}

pub opaque type Invocation(context) {
  Invocation(
    id: InvocationId,
    exchange: ExchangeId,
    request_id: RequestId,
    context: context,
    method: String,
    report_progress: tool.ProgressReporter,
    work: InvocationWork(context),
  )
}

type InvocationWork(context) {
  ToolWork(
    tool_name: ToolName,
    arguments: Value,
    client_metadata: v2026.RequestMetadata,
    input_responses: Option(Value),
    request_state: String,
    dispatch: fn(context, ToolName, Value, Option(Value), tool.ProgressReporter) ->
      Result(tool.ToolOutput, DispatchError),
  )
  ResourceWork(
    fn(context, String) -> Result(List(ResourceContents), ResourceError),
    String,
  )
  PromptWork(
    fn(context, Dict(String, String), Option(Value)) ->
      Result(prompts.PromptHandlerResult, PromptError),
    Dict(String, String),
    Option(Value),
    v2026.RequestMetadata,
    String,
  )
  CompletionWork(
    fn(context, CompletionRef, CompletionArgument, Option(Dict(String, String))) ->
      Result(CompletionValues, CompletionError),
    CompletionRef,
    CompletionArgument,
    Option(Dict(String, String)),
  )
}

pub fn invocation_id(invocation: Invocation(context)) -> InvocationId {
  invocation.id
}

pub fn invocation_exchange(invocation: Invocation(context)) -> ExchangeId {
  invocation.exchange
}

pub fn invocation_request_id(invocation: Invocation(context)) -> RequestId {
  invocation.request_id
}

pub fn invocation_context(invocation: Invocation(context)) -> context {
  invocation.context
}

pub fn invocation_method(invocation: Invocation(context)) -> String {
  invocation.method
}

/// Adds a runtime-owned progress callback before an invocation starts.
pub fn invocation_with_progress(
  invocation: Invocation(context),
  report_progress: tool.ProgressReporter,
) -> Invocation(context) {
  Invocation(..invocation, report_progress: report_progress)
}

/// Executes the invocation's handler outside the server reducer.
pub fn perform(invocation: Invocation(context)) -> ServerInput(context) {
  let Invocation(id, _, request_id, context, _, report_progress, work) =
    invocation
  let outcome = case work {
    ToolWork(
      tool_name,
      arguments,
      client_metadata,
      input_responses,
      request_state,
      dispatch,
    ) ->
      case
        dispatch(
          context,
          tool_name,
          arguments,
          input_responses,
          report_progress,
        )
      {
        Ok(tool.StructuredWithContent(value, [])) -> OutcomeSuccess(value)
        Ok(tool.StructuredWithContent(value, blocks)) ->
          OutcomeStructuredContentSuccess(value, blocks)
        Ok(tool.ContentOnly(blocks)) -> OutcomeContentSuccess(blocks)
        Ok(tool.InputRequired(input_requests)) -> {
          let input_requests =
            dict.to_list(input_requests)
            |> list.filter(fn(pair) {
              let #(_, request) = pair
              v2026.client_supports_input_request(
                client_metadata,
                request.method,
              )
            })
            |> dict.from_list
          OutcomeJsonSuccess(v2026.encode_tool_input_required_response(
            request_id,
            input_requests,
            request_state,
          ))
        }
        Error(tool.ApplicationFailure(val)) -> OutcomeApplicationError(val)
        Error(tool.ContentOnlyOutput) ->
          OutcomeInternalError("Invalid tool result")
        Error(tool.InputRequiredOutput) ->
          OutcomeInternalError("Invalid tool result")
        Error(tool.InvalidInput(_)) -> OutcomeInvalidInput
        Error(tool.UnknownTool(_)) -> OutcomeInvalidInput
        Error(tool.InvalidOutput(_)) ->
          OutcomeInternalError("Invalid tool output")
        Error(tool.ErrorEncodingFailure(_)) ->
          OutcomeInternalError("Failed to encode tool error")
      }
    ResourceWork(read, uri) ->
      case read(context, uri) {
        Ok(contents) ->
          OutcomeJsonSuccess(v2026.encode_resources_read_response(
            request_id,
            contents,
          ))
        Error(_) ->
          OutcomeJsonError(jsonrpc.error_to_json(
            Some(request_id),
            jsonrpc.resource_not_found(),
          ))
      }
    PromptWork(get, arguments, input_responses, client_metadata, request_state) ->
      case get(context, arguments, input_responses) {
        Ok(prompts.CompletePrompt(prompt_result)) ->
          OutcomeJsonSuccess(v2026.encode_prompts_get_response(
            request_id,
            prompt_result,
          ))
        Ok(prompts.RequestPromptInput(input_requests)) -> {
          let input_requests =
            dict.to_list(input_requests)
            |> list.filter(fn(pair) {
              let #(_, request) = pair
              v2026.client_supports_input_request(
                client_metadata,
                request.method,
              )
            })
            |> dict.from_list
          OutcomeJsonSuccess(v2026.encode_tool_input_required_response(
            request_id,
            input_requests,
            request_state,
          ))
        }
        Error(_) ->
          OutcomeJsonError(jsonrpc.error_to_json(
            Some(request_id),
            jsonrpc.invalid_params(),
          ))
      }
    CompletionWork(complete, reference, argument, completion_context) ->
      case complete(context, reference, argument, completion_context) {
        Ok(values) ->
          OutcomeJsonSuccess(v2026.encode_completion_response(
            request_id,
            values,
          ))
        Error(_) -> OutcomeInternalError("Completion handler failed")
      }
  }
  InvocationFinished(id, outcome)
}

type ExchangeStatus {
  StatusOpen
  StatusTerminal
  StatusClosed
}

type ExchangeRecord {
  ActiveExchange(
    exchange: ExchangeId,
    request_id: RequestId,
    progress_token: Option(ProgressToken),
    invocation: Option(InvocationId),
    status: ExchangeStatus,
    latest_progress: Option(Int),
  )
  StreamExchange(
    exchange: ExchangeId,
    request_id: RequestId,
    filter: SubscriptionFilter,
  )
  ImmediateExchange(ExchangeId)
  Preclosed(ExchangeId)
}

pub opaque type Server(context) {
  Server(
    registry: Registry(context),
    dispatch: fn(context, ToolName, Value, Option(Value), tool.ProgressReporter) ->
      Result(tool.ToolOutput, DispatchError),
    resources: List(ContextResource(context)),
    resource_templates: List(ContextResourceTemplate(context)),
    prompts: List(ContextPrompt(context)),
    completion: Option(ContextCompletion(context)),
    cursor_key: BitArray,
    exchanges: List(ExchangeRecord),
    subscriptions: Subscriptions,
  )
}

pub fn server(registry: Registry(context)) -> Server(context) {
  server_with_services(registry, [], [], [], None)
}

pub fn server_with_services(
  registry: Registry(context),
  resources: List(ContextResource(context)),
  resource_templates: List(ContextResourceTemplate(context)),
  prompts: List(ContextPrompt(context)),
  completion: Option(ContextCompletion(context)),
) -> Server(context) {
  Server(
    registry: registry,
    dispatch: fn(ctx, name, args, input_responses, report_progress) {
      tool.dispatch_with_inputs(
        registry,
        ctx,
        name,
        args,
        input_responses,
        report_progress,
      )
    },
    resources: resources,
    resource_templates: resource_templates,
    prompts: prompts,
    completion: completion,
    cursor_key: ffi_new_cursor_key(),
    exchanges: [],
    subscriptions: subscriptions.new(),
  )
}

pub fn server_with_dispatch(
  registry: Registry(context),
  dispatch: fn(context, ToolName, Value) -> Result(Value, DispatchError),
) -> Server(context) {
  let dispatch_with_content = fn(
    context,
    name,
    args,
    _input_responses,
    _report_progress,
  ) {
    case dispatch(context, name, args) {
      Ok(value) -> Ok(tool.StructuredWithContent(value, []))
      Error(error) -> Error(error)
    }
  }
  Server(
    registry: registry,
    dispatch: dispatch_with_content,
    resources: [],
    resource_templates: [],
    prompts: [],
    completion: None,
    cursor_key: ffi_new_cursor_key(),
    exchanges: [],
    subscriptions: subscriptions.new(),
  )
}

/// Returns a server with a new tool registered, or the registry validation error.
pub fn register_tool(
  server: Server(context),
  new_tool: ContextTool(context),
) -> Result(Server(context), RegistryError) {
  case tool.register(server.registry, new_tool) {
    Error(error) -> Error(error)
    Ok(next_registry) -> Ok(server_with_registry(server, next_registry))
  }
}

/// Returns a server with a tool removed and whether the registry changed.
pub fn unregister_tool(
  server: Server(context),
  name: ToolName,
) -> #(Server(context), Bool) {
  case tool.contains(server.registry, name) {
    False -> #(server, False)
    True -> #(
      server_with_registry(server, tool.unregister(server.registry, name)),
      True,
    )
  }
}

/// Returns the current tools registered on the server.
pub fn registered_tools(server: Server(context)) -> List(ContextTool(context)) {
  tool.registered_tools(server.registry)
}

fn server_with_registry(
  server: Server(context),
  registry: Registry(context),
) -> Server(context) {
  Server(
    ..server,
    registry: registry,
    dispatch: fn(ctx, name, arguments, input_responses, report_progress) {
      tool.dispatch_with_inputs(
        registry,
        ctx,
        name,
        arguments,
        input_responses,
        report_progress,
      )
    },
  )
}

/// Pure server step function.
pub fn step(
  server: Server(context),
  input: ServerInput(context),
) -> #(Server(context), List(ServerEffect(context))) {
  case input {
    MessageReceived(exchange, ctx, bytes) ->
      handle_message_received(server, exchange, ctx, bytes)
    InvocationFinished(invocation, outcome) ->
      handle_invocation_finished(server, invocation, outcome)
    InvocationProgress(invocation, value) ->
      handle_invocation_progress(server, invocation, value)
    ExchangeClosed(exchange) -> handle_exchange_closed(server, exchange)
    NotifyResourceUpdated(uri) -> handle_notify_resource_updated(server, uri)
    NotifyToolsListChanged -> handle_notify_tools_list_changed(server)
    NotifyResourcesListChanged -> handle_notify_resources_list_changed(server)
    NotifyPromptsListChanged -> handle_notify_prompts_list_changed(server)
    RegisterTool(tool) -> handle_register_tool(server, tool)
    UnregisterTool(name) -> handle_unregister_tool(server, name)
    TerminateSubscription(id) -> handle_terminate_subscription(server, id)
  }
}

fn handle_message_received(
  server: Server(context),
  exchange: ExchangeId,
  context: context,
  bytes: BitArray,
) -> #(Server(context), List(ServerEffect(context))) {
  let reg = server.registry
  let dispatch = server.dispatch
  let exchanges = server.exchanges
  case find_exchange(exchanges, exchange) {
    Some(_) -> #(server, [])
    None -> {
      case v2026.admit_bytes(bytes) {
        v2026.AdmittedRejected(opt_id, err) -> {
          let updated = [ImmediateExchange(exchange), ..exchanges]
          let out_bytes =
            string_to_bytes(
              json.to_string(jsonrpc.error_to_json(opt_id, err)) <> "\n",
            )
          #(Server(..server, exchanges: updated), [
            Write(exchange, out_bytes),
            CloseExchange(exchange),
          ])
        }
        v2026.AdmittedIgnored(reason) -> {
          let updated = [ImmediateExchange(exchange), ..exchanges]
          let unhandled = case reason {
            v2026.UnsupportedNotificationReason ->
              UnsupportedNotificationMessage
            v2026.UnexpectedResponseReason -> UnexpectedResponseMessage
          }
          #(Server(..server, exchanges: updated), [
            Ignore(unhandled),
            CloseExchange(exchange),
          ])
        }
        v2026.AdmittedNotification(v2026.Cancelled(req_id)) -> {
          handle_client_cancellation(server, exchange, req_id)
        }
        v2026.AdmittedNotification(v2026.OtherNotification(_)) -> {
          immediate_disposition(
            server,
            exchange,
            UnsupportedNotificationMessage,
          )
        }
        v2026.AdmittedRequest(v2026.Discover(id, _meta)) -> {
          let has_completions = case server.completion {
            Some(_) -> True
            None -> False
          }
          immediate_response(
            server,
            exchange,
            id,
            "server/discover",
            v2026.encode_discovery_response_with_capabilities(
              id,
              tool.declarations(reg, context) != [],
              server.resources != [],
              server.prompts != [],
              has_completions,
            ),
          )
        }
        v2026.AdmittedRequest(v2026.ToolsList(id, _meta, cursor)) -> {
          let declarations = tool.declarations(reg, context)
          case paginate(server, "tools/list", cursor, declarations) {
            Error(_) ->
              immediate_error(
                server,
                exchange,
                Some(id),
                jsonrpc.invalid_params(),
              )
            Ok(#(paged_server, page, next_cursor)) ->
              immediate_response(
                paged_server,
                exchange,
                id,
                "tools/list",
                v2026.encode_tools_list_response_with_cursor(
                  id,
                  page,
                  next_cursor,
                ),
              )
          }
        }
        v2026.AdmittedRequest(v2026.ResourcesList(id, _meta, cursor)) ->
          case
            paginate(
              server,
              "resources/list",
              cursor,
              resource_descriptors(server.resources),
            )
          {
            Error(_) ->
              immediate_error(
                server,
                exchange,
                Some(id),
                jsonrpc.invalid_params(),
              )
            Ok(#(paged_server, page, next_cursor)) ->
              immediate_response(
                paged_server,
                exchange,
                id,
                "resources/list",
                v2026.encode_resources_list_response(id, page, next_cursor),
              )
          }
        v2026.AdmittedRequest(v2026.ResourceTemplatesList(id, _meta, cursor)) ->
          case
            paginate(
              server,
              "resources/templates/list",
              cursor,
              resource_template_descriptors(server.resource_templates),
            )
          {
            Error(_) ->
              immediate_error(
                server,
                exchange,
                Some(id),
                jsonrpc.invalid_params(),
              )
            Ok(#(paged_server, page, next_cursor)) ->
              immediate_response(
                paged_server,
                exchange,
                id,
                "resources/templates/list",
                v2026.encode_resource_templates_list_response(
                  id,
                  page,
                  next_cursor,
                ),
              )
          }
        v2026.AdmittedRequest(v2026.ResourcesRead(id, meta, uri)) ->
          case find_resource_reader(server.resources, uri) {
            Some(read) ->
              start_invocation(
                server,
                exchange,
                context,
                id,
                meta.progress_token,
                "resources/read",
                ResourceWork(read, uri),
              )
            None ->
              case find_template_reader(server.resource_templates, uri) {
                Some(read) ->
                  start_invocation(
                    server,
                    exchange,
                    context,
                    id,
                    meta.progress_token,
                    "resources/read",
                    ResourceWork(read, uri),
                  )
                None ->
                  immediate_error(
                    server,
                    exchange,
                    Some(id),
                    jsonrpc.resource_not_found(),
                  )
              }
          }
        v2026.AdmittedRequest(v2026.PromptsList(id, _meta, cursor)) ->
          case
            paginate(
              server,
              "prompts/list",
              cursor,
              prompt_descriptors(server.prompts),
            )
          {
            Error(_) ->
              immediate_error(
                server,
                exchange,
                Some(id),
                jsonrpc.invalid_params(),
              )
            Ok(#(paged_server, page, next_cursor)) ->
              immediate_response(
                paged_server,
                exchange,
                id,
                "prompts/list",
                v2026.encode_prompts_list_response(id, page, next_cursor),
              )
          }
        v2026.AdmittedRequest(v2026.PromptsGet(
          id,
          meta,
          name,
          arguments,
          request_state,
          input_responses,
        )) ->
          case find_prompt_handler(server.prompts, name) {
            Some(get) -> {
              let state_family = "input:prompts/get:" <> name
              let state_valid = case request_state {
                None -> True
                Some(token) ->
                  case ffi_read_cursor(server.cursor_key, state_family, token) {
                    Ok(_) -> True
                    Error(_) -> False
                  }
              }
              case state_valid {
                False ->
                  immediate_error(
                    server,
                    exchange,
                    Some(id),
                    jsonrpc.invalid_params(),
                  )
                True -> {
                  let response_state =
                    ffi_make_cursor(
                      server.cursor_key,
                      state_family,
                      ffi_unique_integer(),
                    )
                  start_invocation(
                    server,
                    exchange,
                    context,
                    id,
                    meta.progress_token,
                    "prompts/get",
                    PromptWork(
                      get,
                      arguments,
                      input_responses,
                      meta,
                      response_state,
                    ),
                  )
                }
              }
            }
            None ->
              immediate_error(
                server,
                exchange,
                Some(id),
                jsonrpc.invalid_params(),
              )
          }
        v2026.AdmittedRequest(v2026.CompletionComplete(
          id,
          meta,
          reference,
          argument,
          completion_context,
        )) ->
          case server.completion {
            Some(ContextCompletion(complete)) ->
              start_invocation(
                server,
                exchange,
                context,
                id,
                meta.progress_token,
                "completion/complete",
                CompletionWork(
                  complete,
                  reference,
                  argument,
                  completion_context,
                ),
              )
            None ->
              immediate_error(
                server,
                exchange,
                Some(id),
                jsonrpc.method_not_found(),
              )
          }
        v2026.AdmittedRequest(v2026.ToolsCall(
          id,
          meta,
          tool_name,
          arguments,
          request_state,
          input_responses,
        )) -> {
          let state_family = "input:" <> tool.tool_name_to_string(tool_name)
          let state_valid = case request_state {
            None -> True
            Some(token) ->
              case ffi_read_cursor(server.cursor_key, state_family, token) {
                Ok(_) -> True
                Error(_) -> False
              }
          }
          let missing_capabilities =
            tool.required_client_capabilities(reg, tool_name)
            |> list.filter(fn(capability) {
              !v2026.client_declares_capability(meta, capability)
            })
          case missing_capabilities {
            [_, ..] ->
              immediate_error(
                server,
                exchange,
                Some(id),
                jsonrpc.missing_required_client_capability(missing_capabilities),
              )
            [] ->
              case state_valid {
                False ->
                  immediate_error(
                    server,
                    exchange,
                    Some(id),
                    jsonrpc.invalid_params(),
                  )
                True -> {
                  let inv_id = fresh_invocation()
                  let response_state =
                    ffi_make_cursor(
                      server.cursor_key,
                      state_family,
                      invocation_id_to_int(inv_id),
                    )
                  let record =
                    ActiveExchange(
                      exchange: exchange,
                      request_id: id,
                      progress_token: meta.progress_token,
                      invocation: Some(inv_id),
                      status: StatusOpen,
                      latest_progress: None,
                    )
                  let inv =
                    Invocation(
                      id: inv_id,
                      exchange: exchange,
                      request_id: id,
                      context: context,
                      method: "tools/call",
                      report_progress: fn(_value) { Nil },
                      work: ToolWork(
                        tool_name,
                        arguments,
                        meta,
                        input_responses,
                        response_state,
                        dispatch,
                      ),
                    )
                  #(Server(..server, exchanges: [record, ..exchanges]), [
                    EmitRequestAdmitted(exchange, "tools/call"),
                    StartInvocation(inv),
                  ])
                }
              }
          }
        }
        v2026.AdmittedRequest(v2026.SubscriptionsListen(id, _meta, filter)) -> {
          let has_tools = True
          let has_resources = server.resources != []
          let has_prompts = server.prompts != []
          let honored_filter =
            subscriptions.filter_supported(
              filter,
              has_tools,
              has_resources,
              has_prompts,
            )
          let owner = exchange_id_to_string(exchange)
          let next_subs =
            subscriptions.listen(
              server.subscriptions,
              owner,
              id,
              honored_filter,
            )
          let ack =
            v2026.encode_subscriptions_acknowledged_notification(
              id,
              honored_filter,
            )
          let ack_bytes = string_to_bytes(json.to_string(ack) <> "\n")
          let record = StreamExchange(exchange, id, honored_filter)
          #(
            Server(..server, subscriptions: next_subs, exchanges: [
              record,
              ..exchanges
            ]),
            [
              EmitRequestAdmitted(exchange, "subscriptions/listen"),
              Write(exchange, ack_bytes),
            ],
          )
        }
      }
    }
  }
}

fn immediate_disposition(
  server: Server(context),
  exchange: ExchangeId,
  disposition: UnhandledMessage,
) -> #(Server(context), List(ServerEffect(context))) {
  let exchanges = server.exchanges
  #(Server(..server, exchanges: [ImmediateExchange(exchange), ..exchanges]), [
    Ignore(disposition),
    CloseExchange(exchange),
  ])
}

fn immediate_error(
  server: Server(context),
  exchange: ExchangeId,
  id: Option(RequestId),
  error: jsonrpc.RpcError,
) -> #(Server(context), List(ServerEffect(context))) {
  let exchanges = server.exchanges
  let out_bytes =
    string_to_bytes(json.to_string(jsonrpc.error_to_json(id, error)) <> "\n")
  #(Server(..server, exchanges: [ImmediateExchange(exchange), ..exchanges]), [
    Write(exchange, out_bytes),
    CloseExchange(exchange),
  ])
}

fn immediate_response(
  server: Server(context),
  exchange: ExchangeId,
  _id: RequestId,
  method: String,
  response: json.Json,
) -> #(Server(context), List(ServerEffect(context))) {
  let exchanges = server.exchanges
  let out_bytes = string_to_bytes(json.to_string(response) <> "\n")
  #(Server(..server, exchanges: [ImmediateExchange(exchange), ..exchanges]), [
    EmitRequestAdmitted(exchange, method),
    Write(exchange, out_bytes),
    CloseExchange(exchange),
  ])
}

fn start_invocation(
  server: Server(context),
  exchange: ExchangeId,
  context: context,
  request_id: RequestId,
  progress_token: Option(ProgressToken),
  method: String,
  work: InvocationWork(context),
) -> #(Server(context), List(ServerEffect(context))) {
  let exchanges = server.exchanges
  let invocation_id = fresh_invocation()
  let record =
    ActiveExchange(
      exchange: exchange,
      request_id: request_id,
      progress_token: progress_token,
      invocation: Some(invocation_id),
      status: StatusOpen,
      latest_progress: None,
    )
  let invocation =
    Invocation(
      id: invocation_id,
      exchange: exchange,
      request_id: request_id,
      context: context,
      method: method,
      report_progress: fn(_value) { Nil },
      work: work,
    )
  #(Server(..server, exchanges: [record, ..exchanges]), [
    EmitRequestAdmitted(exchange, method),
    StartInvocation(invocation),
  ])
}

fn resource_descriptors(
  resources: List(ContextResource(context)),
) -> List(Resource) {
  list.map(resources, fn(resource) {
    let ContextResource(description, _) = resource
    description
  })
}

fn resource_template_descriptors(
  resources: List(ContextResourceTemplate(context)),
) -> List(ResourceTemplate) {
  list.map(resources, fn(resource) {
    let ContextResourceTemplate(description, _) = resource
    description
  })
}

fn prompt_descriptors(prompts: List(ContextPrompt(context))) -> List(Prompt) {
  list.map(prompts, fn(prompt) {
    case prompt {
      ContextPrompt(description, _) -> description
      ContextPromptWithInputs(description, _) -> description
    }
  })
}

fn paginate(
  server: Server(context),
  family: String,
  cursor: Option(String),
  items: List(a),
) -> Result(#(Server(context), List(a), Option(String)), Nil) {
  let cursor_key = server.cursor_key
  let offset = case cursor {
    None -> Ok(0)
    Some(token) -> ffi_read_cursor(cursor_key, family, token)
  }
  case offset {
    Error(_) -> Error(Nil)
    Ok(offset) -> {
      let page = items |> list.drop(offset) |> list.take(100)
      let next_offset = offset + list.length(page)
      case next_offset < list.length(items) {
        True -> {
          let token = ffi_make_cursor(cursor_key, family, next_offset)
          Ok(#(server, page, Some(token)))
        }
        False -> Ok(#(server, page, None))
      }
    }
  }
}

fn find_resource_reader(
  resources: List(ContextResource(context)),
  uri: String,
) -> Option(
  fn(context, String) -> Result(List(ResourceContents), ResourceError),
) {
  case resources {
    [] -> None
    [ContextResource(resource, read), ..rest] ->
      case resource.uri == uri {
        True -> Some(read)
        False -> find_resource_reader(rest, uri)
      }
  }
}

fn find_template_reader(
  resources: List(ContextResourceTemplate(context)),
  uri: String,
) -> Option(
  fn(context, String) -> Result(List(ResourceContents), ResourceError),
) {
  case resources {
    [] -> None
    [ContextResourceTemplate(template, read), ..rest] ->
      case uri_template_matches(template.uri_template, uri) {
        True -> Some(read)
        False -> find_template_reader(rest, uri)
      }
  }
}

fn uri_template_matches(template: String, uri: String) -> Bool {
  match_uri_segments(
    string.split(template, on: "/"),
    string.split(uri, on: "/"),
  )
}

fn match_uri_segments(template: List(String), uri: List(String)) -> Bool {
  case template, uri {
    [], [] -> True
    [template_segment, ..template_rest], [uri_segment, ..uri_rest] -> {
      let variable =
        string.starts_with(template_segment, "{")
        && string.ends_with(template_segment, "}")
        && string.length(template_segment) > 2
      let matches =
        variable && uri_segment != "" || template_segment == uri_segment
      case matches {
        True -> match_uri_segments(template_rest, uri_rest)
        False -> False
      }
    }
    _, _ -> False
  }
}

fn find_prompt_handler(
  prompts: List(ContextPrompt(context)),
  name: String,
) -> Option(
  fn(context, Dict(String, String), Option(Value)) ->
    Result(prompts.PromptHandlerResult, PromptError),
) {
  case prompts {
    [] -> None
    [entry, ..rest] ->
      case entry {
        ContextPrompt(prompt, get) ->
          case prompt.name == name {
            True ->
              Some(fn(context, arguments, _input_responses) {
                case get(context, arguments) {
                  Ok(result) -> Ok(prompts.CompletePrompt(result))
                  Error(error) -> Error(error)
                }
              })
            False -> find_prompt_handler(rest, name)
          }
        ContextPromptWithInputs(prompt, get) ->
          case prompt.name == name {
            True -> Some(get)
            False -> find_prompt_handler(rest, name)
          }
      }
  }
}

fn handle_client_cancellation(
  server: Server(context),
  notify_exchange: ExchangeId,
  target_req_id: RequestId,
) -> #(Server(context), List(ServerEffect(context))) {
  let exchanges = server.exchanges
  let updated_notify = [ImmediateExchange(notify_exchange), ..exchanges]
  case find_active_by_request_id(exchanges, target_req_id) {
    None -> #(Server(..server, exchanges: updated_notify), [
      CloseExchange(notify_exchange),
    ])
    Some(ActiveExchange(
      ex_id,
      _req_id,
      _token,
      Some(inv_id),
      StatusOpen,
      _latest,
    )) -> {
      let next_exchanges =
        replace_exchange_status(updated_notify, ex_id, StatusClosed)
      #(Server(..server, exchanges: next_exchanges), [
        CancelInvocation(inv_id),
        CloseExchange(ex_id),
        CloseExchange(notify_exchange),
      ])
    }
    Some(StreamExchange(ex_id, req_id, _)) -> {
      let owner = exchange_id_to_string(ex_id)
      let next_subs =
        subscriptions.close_stream(server.subscriptions, owner, req_id)
      let next_exchanges =
        list.filter(updated_notify, fn(rec) {
          case rec {
            StreamExchange(target, _, _) -> target != ex_id
            _ -> True
          }
        })
      #(Server(..server, subscriptions: next_subs, exchanges: next_exchanges), [
        CloseExchange(ex_id),
        CloseExchange(notify_exchange),
      ])
    }
    Some(_) -> #(Server(..server, exchanges: updated_notify), [
      CloseExchange(notify_exchange),
    ])
  }
}

fn handle_invocation_finished(
  server: Server(context),
  invocation: InvocationId,
  outcome: InvocationOutcome,
) -> #(Server(context), List(ServerEffect(context))) {
  let exchanges = server.exchanges
  case find_invocation(exchanges, invocation) {
    Some(ActiveExchange(exchange, request_id, _, Some(_), StatusOpen, _)) -> {
      let updated =
        replace_invocation_status(exchanges, invocation, StatusTerminal)
      let out_json = case outcome {
        OutcomeSuccess(structured) ->
          v2026.encode_call_success_response(request_id, structured)
        OutcomeContentSuccess(blocks) ->
          v2026.encode_call_content_response(request_id, None, blocks)
        OutcomeStructuredContentSuccess(structured, blocks) ->
          v2026.encode_call_content_response(
            request_id,
            Some(structured),
            blocks,
          )
        OutcomeJsonSuccess(response) -> response
        OutcomeJsonError(response) -> response
        OutcomeApplicationError(error) ->
          v2026.encode_call_error_response(
            request_id,
            application_error_text(error),
          )
        OutcomeInvalidInput ->
          jsonrpc.error_to_json(Some(request_id), jsonrpc.invalid_params())
        OutcomeInternalError(_) ->
          jsonrpc.error_to_json(Some(request_id), jsonrpc.internal_error())
      }
      let out_bytes = string_to_bytes(json.to_string(out_json) <> "\n")
      #(Server(..server, exchanges: updated), [
        Write(exchange, out_bytes),
        CloseExchange(exchange),
      ])
    }
    _ -> #(server, [])
  }
}

fn application_error_text(error: Value) -> String {
  // The declared error codec has already produced this JSON value. Keeping its
  // exact JSON representation in text content lets clients decode it again.
  json.to_string(v2026.value_to_json(error))
}

fn handle_invocation_progress(
  server: Server(context),
  invocation: InvocationId,
  value: Int,
) -> #(Server(context), List(ServerEffect(context))) {
  let exchanges = server.exchanges
  case find_invocation(exchanges, invocation) {
    Some(ActiveExchange(exchange, _, Some(token), _, StatusOpen, latest)) -> {
      case valid_progress(value, latest) {
        True -> {
          let updated = replace_progress(exchanges, invocation, value)
          let out_bytes =
            string_to_bytes(
              json.to_string(v2026.encode_progress_notification(token, value))
              <> "\n",
            )
          #(Server(..server, exchanges: updated), [
            SendProgress(exchange, token, value),
            Write(exchange, out_bytes),
          ])
        }
        False -> #(server, [])
      }
    }
    _ -> #(server, [])
  }
}

fn handle_exchange_closed(
  server: Server(context),
  exchange: ExchangeId,
) -> #(Server(context), List(ServerEffect(context))) {
  let exchanges = server.exchanges
  case find_exchange(exchanges, exchange) {
    None -> #(
      Server(..server, exchanges: [Preclosed(exchange), ..exchanges]),
      [],
    )
    Some(Preclosed(_)) -> #(server, [])
    Some(ActiveExchange(_, _, _, Some(inv_id), StatusOpen, _)) -> {
      let next = replace_exchange_status(exchanges, exchange, StatusClosed)
      #(Server(..server, exchanges: next), [
        CancelInvocation(inv_id),
        CloseExchange(exchange),
      ])
    }
    Some(StreamExchange(ex, req_id, _)) -> {
      let owner = exchange_id_to_string(ex)
      let next_subs =
        subscriptions.close_stream(server.subscriptions, owner, req_id)
      let next =
        list.filter(exchanges, fn(rec) {
          case rec {
            StreamExchange(target, _, _) -> target != exchange
            _ -> True
          }
        })
      #(Server(..server, subscriptions: next_subs, exchanges: next), [
        CloseExchange(exchange),
      ])
    }
    Some(_) -> #(server, [])
  }
}

fn handle_notify_resource_updated(
  server: Server(context),
  uri: String,
) -> #(Server(context), List(ServerEffect(context))) {
  let subscribers =
    subscriptions.stream_subscribers_for_resource(server.subscriptions, uri)
  let effects =
    list.filter_map(subscribers, fn(pair) {
      let #(owner, sub_id) = pair
      case find_stream_exchange(server.exchanges, owner, sub_id) {
        Some(ex) -> {
          let notif = v2026.encode_resource_updated_notification(sub_id, uri)
          let bytes = string_to_bytes(json.to_string(notif) <> "\n")
          Ok(Write(ex, bytes))
        }
        None -> Error(Nil)
      }
    })
  #(server, effects)
}

fn handle_notify_tools_list_changed(
  server: Server(context),
) -> #(Server(context), List(ServerEffect(context))) {
  let subscribers =
    subscriptions.stream_subscribers_for_tools(server.subscriptions)
  let effects =
    list.filter_map(subscribers, fn(pair) {
      let #(owner, sub_id) = pair
      case find_stream_exchange(server.exchanges, owner, sub_id) {
        Some(ex) -> {
          let notif = v2026.encode_tools_list_changed_notification(sub_id)
          let bytes = string_to_bytes(json.to_string(notif) <> "\n")
          Ok(Write(ex, bytes))
        }
        None -> Error(Nil)
      }
    })
  #(server, effects)
}

fn handle_notify_resources_list_changed(
  server: Server(context),
) -> #(Server(context), List(ServerEffect(context))) {
  let subscribers =
    subscriptions.stream_subscribers_for_resources(server.subscriptions)
  let effects =
    list.filter_map(subscribers, fn(pair) {
      let #(owner, sub_id) = pair
      case find_stream_exchange(server.exchanges, owner, sub_id) {
        Some(ex) -> {
          let notif = v2026.encode_resources_list_changed_notification(sub_id)
          let bytes = string_to_bytes(json.to_string(notif) <> "\n")
          Ok(Write(ex, bytes))
        }
        None -> Error(Nil)
      }
    })
  #(server, effects)
}

fn handle_notify_prompts_list_changed(
  server: Server(context),
) -> #(Server(context), List(ServerEffect(context))) {
  let subscribers =
    subscriptions.stream_subscribers_for_prompts(server.subscriptions)
  let effects =
    list.filter_map(subscribers, fn(pair) {
      let #(owner, sub_id) = pair
      case find_stream_exchange(server.exchanges, owner, sub_id) {
        Some(ex) -> {
          let notif = v2026.encode_prompts_list_changed_notification(sub_id)
          let bytes = string_to_bytes(json.to_string(notif) <> "\n")
          Ok(Write(ex, bytes))
        }
        None -> Error(Nil)
      }
    })
  #(server, effects)
}

fn handle_register_tool(
  server: Server(context),
  new_tool: ContextTool(context),
) -> #(Server(context), List(ServerEffect(context))) {
  case register_tool(server, new_tool) {
    Ok(next_server) -> {
      let #(updated, effects) = handle_notify_tools_list_changed(next_server)
      #(updated, effects)
    }
    Error(_) -> #(server, [])
  }
}

fn handle_unregister_tool(
  server: Server(context),
  name: ToolName,
) -> #(Server(context), List(ServerEffect(context))) {
  let #(next_server, changed) = unregister_tool(server, name)
  case changed {
    True -> handle_notify_tools_list_changed(next_server)
    False -> #(server, [])
  }
}

fn handle_terminate_subscription(
  server: Server(context),
  id: RequestId,
) -> #(Server(context), List(ServerEffect(context))) {
  case find_stream_by_request_id(server.exchanges, id) {
    Some(StreamExchange(ex, req_id, _)) -> {
      let owner = exchange_id_to_string(ex)
      let next_subs =
        subscriptions.close_stream(server.subscriptions, owner, req_id)
      let next_exchanges =
        list.filter(server.exchanges, fn(rec) {
          case rec {
            StreamExchange(target, _, _) -> target != ex
            _ -> True
          }
        })
      let resp = v2026.encode_subscriptions_listen_result_response(req_id)
      let bytes = string_to_bytes(json.to_string(resp) <> "\n")
      #(Server(..server, subscriptions: next_subs, exchanges: next_exchanges), [
        Write(ex, bytes),
        CloseExchange(ex),
      ])
    }
    _ -> #(server, [])
  }
}

fn find_stream_exchange(
  exchanges: List(ExchangeRecord),
  target_owner: String,
  target_id: RequestId,
) -> Option(ExchangeId) {
  case exchanges {
    [] -> None
    [StreamExchange(ex, id, _), ..rest] ->
      case exchange_id_to_string(ex) == target_owner && id == target_id {
        True -> Some(ex)
        False -> find_stream_exchange(rest, target_owner, target_id)
      }
    [_, ..rest] -> find_stream_exchange(rest, target_owner, target_id)
  }
}

fn find_stream_by_request_id(
  exchanges: List(ExchangeRecord),
  target_id: RequestId,
) -> Option(ExchangeRecord) {
  case exchanges {
    [] -> None
    [StreamExchange(_, id, _) as rec, ..rest] ->
      case id == target_id {
        True -> Some(rec)
        False -> find_stream_by_request_id(rest, target_id)
      }
    [_, ..rest] -> find_stream_by_request_id(rest, target_id)
  }
}

fn valid_progress(value: Int, latest: Option(Int)) -> Bool {
  case latest {
    None -> value >= 0
    Some(prev) -> value >= 0 && value > prev
  }
}

fn find_exchange(
  exchanges: List(ExchangeRecord),
  target: ExchangeId,
) -> Option(ExchangeRecord) {
  case exchanges {
    [] -> None
    [ActiveExchange(id, _, _, _, _, _) as r, ..rest] ->
      case id == target {
        True -> Some(r)
        False -> find_exchange(rest, target)
      }
    [StreamExchange(id, _, _) as r, ..rest] ->
      case id == target {
        True -> Some(r)
        False -> find_exchange(rest, target)
      }
    [Preclosed(id) as r, ..rest] ->
      case id == target {
        True -> Some(r)
        False -> find_exchange(rest, target)
      }
    [ImmediateExchange(id) as r, ..rest] ->
      case id == target {
        True -> Some(r)
        False -> find_exchange(rest, target)
      }
  }
}

fn find_invocation(
  exchanges: List(ExchangeRecord),
  target: InvocationId,
) -> Option(ExchangeRecord) {
  case exchanges {
    [] -> None
    [ActiveExchange(_, _, _, Some(id), _, _) as r, ..rest] ->
      case id == target {
        True -> Some(r)
        False -> find_invocation(rest, target)
      }
    [_, ..rest] -> find_invocation(rest, target)
  }
}

fn find_active_by_request_id(
  exchanges: List(ExchangeRecord),
  target_id: RequestId,
) -> Option(ExchangeRecord) {
  case exchanges {
    [] -> None
    [ActiveExchange(_, req_id, _, _, StatusOpen, _) as r, ..rest] ->
      case req_id == target_id {
        True -> Some(r)
        False -> find_active_by_request_id(rest, target_id)
      }
    [StreamExchange(_, req_id, _) as r, ..rest] ->
      case req_id == target_id {
        True -> Some(r)
        False -> find_active_by_request_id(rest, target_id)
      }
    [_, ..rest] -> find_active_by_request_id(rest, target_id)
  }
}

fn replace_invocation_status(
  exchanges: List(ExchangeRecord),
  invocation: InvocationId,
  status: ExchangeStatus,
) -> List(ExchangeRecord) {
  case exchanges {
    [] -> []
    [ActiveExchange(exchange, request_id, token, Some(id), _, latest), ..rest]
      if id == invocation
    -> [
      ActiveExchange(
        exchange: exchange,
        request_id: request_id,
        progress_token: token,
        invocation: Some(id),
        status: status,
        latest_progress: latest,
      ),
      ..rest
    ]
    [record, ..rest] -> [
      record,
      ..replace_invocation_status(rest, invocation, status)
    ]
  }
}

fn replace_progress(
  exchanges: List(ExchangeRecord),
  invocation: InvocationId,
  value: Int,
) -> List(ExchangeRecord) {
  case exchanges {
    [] -> []
    [ActiveExchange(exchange, request_id, token, Some(id), status, _), ..rest]
      if id == invocation
    -> [
      ActiveExchange(
        exchange: exchange,
        request_id: request_id,
        progress_token: token,
        invocation: Some(id),
        status: status,
        latest_progress: Some(value),
      ),
      ..rest
    ]
    [record, ..rest] -> [record, ..replace_progress(rest, invocation, value)]
  }
}

fn replace_exchange_status(
  exchanges: List(ExchangeRecord),
  target: ExchangeId,
  status: ExchangeStatus,
) -> List(ExchangeRecord) {
  case exchanges {
    [] -> []
    [ActiveExchange(exchange, request_id, token, invocation, _, latest), ..rest]
      if exchange == target
    -> [
      ActiveExchange(
        exchange: exchange,
        request_id: request_id,
        progress_token: token,
        invocation: invocation,
        status: status,
        latest_progress: latest,
      ),
      ..rest
    ]
    [record, ..rest] -> [
      record,
      ..replace_exchange_status(rest, target, status)
    ]
  }
}

fn string_to_bytes(s: String) -> BitArray {
  bit_array.from_string(s)
}
