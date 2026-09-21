import gleam/bit_array
import gleam/json
import gleam/option.{type Option, None, Some}
import json/blueprint/value.{type Value}
import relay/protocol/jsonrpc.{type ProgressToken, type RequestId}
import relay/protocol/v2026_07_28 as v2026
import relay/tool.{type DispatchError, type Registry, type ToolName}

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

pub type UnhandledMessage {
  UnsupportedNotificationMessage
  UnexpectedResponseMessage
}

pub type InvocationOutcome {
  OutcomeSuccess(Value)
  OutcomeApplicationError(Value)
  OutcomeInvalidInput
  OutcomeInternalError(String)
}

pub type ServerInput(context) {
  MessageReceived(exchange: ExchangeId, context: context, bytes: BitArray)
  InvocationFinished(invocation: InvocationId, outcome: InvocationOutcome)
  InvocationProgress(invocation: InvocationId, value: Int)
  ExchangeClosed(exchange: ExchangeId)
}

pub type ServerEffect(context) {
  Write(exchange: ExchangeId, bytes: BitArray)
  StartInvocation(Invocation(context))
  SendProgress(exchange: ExchangeId, token: ProgressToken, value: Int)
  CancelInvocation(InvocationId)
  CloseExchange(ExchangeId)
  Ignore(UnhandledMessage)
}

pub opaque type Invocation(context) {
  Invocation(
    id: InvocationId,
    exchange: ExchangeId,
    request_id: RequestId,
    context: context,
    tool_name: ToolName,
    arguments: Value,
    dispatch: fn(context, ToolName, Value) -> Result(Value, DispatchError),
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

pub fn invocation_tool_name(invocation: Invocation(context)) -> ToolName {
  invocation.tool_name
}

pub fn invocation_arguments(invocation: Invocation(context)) -> Value {
  invocation.arguments
}

/// Executes the invocation's handler outside the server reducer.
pub fn perform(invocation: Invocation(context)) -> ServerInput(context) {
  let Invocation(id, _, _, context, tool_name, arguments, dispatch) = invocation
  let outcome = case dispatch(context, tool_name, arguments) {
    Ok(val) -> OutcomeSuccess(val)
    Error(tool.ApplicationFailure(val)) -> OutcomeApplicationError(val)
    Error(tool.InvalidInput(_)) -> OutcomeInvalidInput
    Error(tool.UnknownTool(_)) -> OutcomeInvalidInput
    Error(tool.InvalidOutput(_)) -> OutcomeInternalError("Invalid tool output")
    Error(tool.ErrorEncodingFailure(_)) ->
      OutcomeInternalError("Failed to encode tool error")
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
  ImmediateExchange(ExchangeId)
  Preclosed(ExchangeId)
}

pub opaque type Server(context) {
  Server(
    registry: Registry(context),
    dispatch: fn(context, ToolName, Value) -> Result(Value, DispatchError),
    exchanges: List(ExchangeRecord),
  )
}

pub fn server(registry: Registry(context)) -> Server(context) {
  Server(
    registry: registry,
    dispatch: fn(ctx, name, args) { tool.dispatch(registry, ctx, name, args) },
    exchanges: [],
  )
}

pub fn server_with_dispatch(
  registry: Registry(context),
  dispatch: fn(context, ToolName, Value) -> Result(Value, DispatchError),
) -> Server(context) {
  Server(registry: registry, dispatch: dispatch, exchanges: [])
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
  }
}

fn handle_message_received(
  server: Server(context),
  exchange: ExchangeId,
  context: context,
  bytes: BitArray,
) -> #(Server(context), List(ServerEffect(context))) {
  let Server(reg, dispatch, exchanges) = server
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
          #(Server(reg, dispatch, updated), [
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
          #(Server(reg, dispatch, updated), [
            Ignore(unhandled),
            CloseExchange(exchange),
          ])
        }
        v2026.AdmittedNotification(v2026.Cancelled(req_id)) -> {
          handle_client_cancellation(server, exchange, req_id)
        }
        v2026.AdmittedNotification(v2026.OtherNotification(_)) -> {
          let updated = [ImmediateExchange(exchange), ..exchanges]
          #(Server(reg, dispatch, updated), [
            Ignore(UnsupportedNotificationMessage),
            CloseExchange(exchange),
          ])
        }
        v2026.AdmittedRequest(v2026.Discover(id, _meta)) -> {
          let updated = [ImmediateExchange(exchange), ..exchanges]
          let out_bytes =
            string_to_bytes(
              json.to_string(v2026.encode_discovery_response(id)) <> "\n",
            )
          #(Server(reg, dispatch, updated), [
            Write(exchange, out_bytes),
            CloseExchange(exchange),
          ])
        }
        v2026.AdmittedRequest(v2026.ToolsList(id, _meta, cursor)) -> {
          let updated = [ImmediateExchange(exchange), ..exchanges]
          case cursor {
            Some(_) -> {
              let out_bytes =
                string_to_bytes(
                  json.to_string(jsonrpc.error_to_json(
                    Some(id),
                    jsonrpc.invalid_params(),
                  ))
                  <> "\n",
                )
              #(Server(reg, dispatch, updated), [
                Write(exchange, out_bytes),
                CloseExchange(exchange),
              ])
            }
            None -> {
              let decls = tool.declarations(reg, context)
              let out_bytes =
                string_to_bytes(
                  json.to_string(v2026.encode_tools_list_response(id, decls))
                  <> "\n",
                )
              #(Server(reg, dispatch, updated), [
                Write(exchange, out_bytes),
                CloseExchange(exchange),
              ])
            }
          }
        }
        v2026.AdmittedRequest(v2026.ToolsCall(id, meta, tool_name, arguments)) -> {
          let inv_id = fresh_invocation()
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
              tool_name: tool_name,
              arguments: arguments,
              dispatch: dispatch,
            )
          #(Server(reg, dispatch, [record, ..exchanges]), [
            StartInvocation(inv),
          ])
        }
      }
    }
  }
}

fn handle_client_cancellation(
  server: Server(context),
  notify_exchange: ExchangeId,
  target_req_id: RequestId,
) -> #(Server(context), List(ServerEffect(context))) {
  let Server(reg, dispatch, exchanges) = server
  let updated_notify = [ImmediateExchange(notify_exchange), ..exchanges]
  case find_active_by_request_id(exchanges, target_req_id) {
    None -> #(Server(reg, dispatch, updated_notify), [
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
      #(Server(reg, dispatch, next_exchanges), [
        CancelInvocation(inv_id),
        CloseExchange(ex_id),
        CloseExchange(notify_exchange),
      ])
    }
    Some(_) -> #(Server(reg, dispatch, updated_notify), [
      CloseExchange(notify_exchange),
    ])
  }
}

fn handle_invocation_finished(
  server: Server(context),
  invocation: InvocationId,
  outcome: InvocationOutcome,
) -> #(Server(context), List(ServerEffect(context))) {
  let Server(reg, dispatch, exchanges) = server
  case find_invocation(exchanges, invocation) {
    Some(ActiveExchange(exchange, request_id, _, Some(_), StatusOpen, _)) -> {
      let updated =
        replace_invocation_status(exchanges, invocation, StatusTerminal)
      let out_json = case outcome {
        OutcomeSuccess(structured) ->
          v2026.encode_call_success_response(request_id, structured)
        OutcomeApplicationError(_) ->
          v2026.encode_call_error_response(
            request_id,
            "The tool reported an error.",
          )
        OutcomeInvalidInput ->
          jsonrpc.error_to_json(Some(request_id), jsonrpc.invalid_params())
        OutcomeInternalError(_) ->
          jsonrpc.error_to_json(Some(request_id), jsonrpc.internal_error())
      }
      let out_bytes = string_to_bytes(json.to_string(out_json) <> "\n")
      #(Server(reg, dispatch, updated), [
        Write(exchange, out_bytes),
        CloseExchange(exchange),
      ])
    }
    _ -> #(server, [])
  }
}

fn handle_invocation_progress(
  server: Server(context),
  invocation: InvocationId,
  value: Int,
) -> #(Server(context), List(ServerEffect(context))) {
  let Server(reg, dispatch, exchanges) = server
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
          #(Server(reg, dispatch, updated), [
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
  let Server(reg, dispatch, exchanges) = server
  case find_exchange(exchanges, exchange) {
    None -> #(Server(reg, dispatch, [Preclosed(exchange), ..exchanges]), [])
    Some(Preclosed(_)) -> #(server, [])
    Some(ActiveExchange(_, _, _, Some(inv_id), StatusOpen, _)) -> {
      let next = replace_exchange_status(exchanges, exchange, StatusClosed)
      #(Server(reg, dispatch, next), [
        CancelInvocation(inv_id),
        CloseExchange(exchange),
      ])
    }
    Some(_) -> #(server, [])
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
