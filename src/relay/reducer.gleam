//// The pure core of an MCP server: a reducer from inputs to effects, for
//// authors of custom transports and runtimes.
////
//// `init(server)` returns the `State` of one connection. `step(state,
//// input)` admits a frame, finishes an invocation, applies a notification
//// or a registry change, and returns the next state with the `Effect`s to
//// perform: bytes to write on an exchange, an `Invocation` to run, an
//// invocation to cancel, and an exchange to close. It performs no I/O.
//// `perform(invocation, report_progress)` runs the handler and returns the
//// `Finished` input to feed back. `relay/runtime` is the supervised
//// interpreter of these effects that the bundled transports use; prefer it
//// unless you need to own the scheduling.
////
//// A transport allocates an `ExchangeId` with `new_exchange_id` before
//// parsing, so that a malformed frame still has a destination. `Input` and
//// `Effect` are revision-bound: they gain variants only in a major release.
//// The state keeps up to 10,000 closed exchange records to suppress late or
//// repeated output, and drops the oldest beyond that.
////
//// ```gleam
//// import gleam/option.{None}
//// import relay/reducer
//// import relay/server
////
//// pub fn admit(bytes: BitArray) -> List(reducer.Effect(Nil)) {
////   let state = reducer.init(server.new([]))
////   let exchange = reducer.new_exchange_id()
////   let #(_state, effects) =
////     reducer.step(state, reducer.Received(exchange, Nil, bytes, None))
////   effects
//// }
//// ```

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import json/blueprint/value.{type Value}
import relay/content.{type ResourceContents}
import relay/internal/carrier
import relay/internal/core
import relay/internal/jsonrpc.{type ProgressToken, type RequestId}
import relay/internal/protocol/v2026_07_28 as v2026
import relay/internal/subscriptions_state as subs
import relay/server.{type Server}
import relay/subscriptions.{type Notification}
import relay/telemetry.{type Status}
import relay/tool.{type Tool}
import sinal/correlation.{type Correlation}

// --- ids ---------------------------------------------------------------------

/// The destination of one inbound frame and everything written for it.
pub opaque type ExchangeId {
  ExchangeId(Int)
}

/// A fresh exchange id, unique within the node.
pub fn new_exchange_id() -> ExchangeId {
  ExchangeId(ffi_unique_integer())
}

/// The integer telemetry reports for an exchange.
pub fn exchange_id_to_int(id: ExchangeId) -> Int {
  let ExchangeId(n) = id
  n
}

/// One admitted unit of handler work.
pub opaque type InvocationId {
  InvocationId(Int)
}

/// The integer telemetry reports for an invocation.
pub fn invocation_id_to_int(id: InvocationId) -> Int {
  let InvocationId(n) = id
  n
}

@external(erlang, "relay_ffi", "unique_integer")
fn ffi_unique_integer() -> Int

@external(erlang, "relay_ffi", "make_cursor")
fn ffi_make_cursor(key: BitArray, family: String, offset: Int) -> String

@external(erlang, "relay_ffi", "read_cursor")
fn ffi_read_cursor(
  key: BitArray,
  family: String,
  token: String,
) -> Result(Int, Nil)

// --- inputs and effects ------------------------------------------------------

/// The result of `perform`, fed back with `Finished`.
pub opaque type Outcome {
  Outcome(response: json.Json, status: Status)
}

/// How the invocation behind an outcome finished.
pub fn outcome_status(outcome: Outcome) -> Status {
  outcome.status
}

/// What the reducer reacts to.
pub type Input(context) {
  /// A frame arrived on a new exchange, with the context and correlation
  /// the transport built for it. With `None`, the request uses the
  /// correlation the frame carries in `_meta`, or a fresh one.
  Received(
    exchange: ExchangeId,
    context: context,
    bytes: BitArray,
    correlation: Option(Correlation),
  )
  Finished(invocation: InvocationId, outcome: Outcome)
  Progressed(
    invocation: InvocationId,
    progress: Float,
    total: Option(Float),
    message: Option(String),
  )
  /// The handler crashed; the client receives an internal error.
  Crashed(invocation: InvocationId)
  /// The handler ran out of time; the client receives an internal error.
  TimedOut(invocation: InvocationId)
  /// The peer closed this exchange; its invocation is cancelled.
  ExchangeClosed(exchange: ExchangeId)
  /// Tells every listening stream that asked for this notification.
  Notify(notification: Notification)
  RegisterTool(tool: Tool(context))
  UnregisterTool(name: String)
  /// Ends every open `subscriptions/listen` stream with its result.
  EndStreams
}

/// What the interpreter must do.
pub type Effect(context) {
  Write(exchange: ExchangeId, bytes: BitArray)
  Start(invocation: Invocation(context))
  Cancel(invocation: InvocationId)
  Close(exchange: ExchangeId)
  /// The server admitted a request on this exchange; for telemetry.
  Admitted(exchange: ExchangeId, method: String)
}

/// Handler work admitted by the reducer, to run outside it.
pub opaque type Invocation(context) {
  Invocation(
    id: InvocationId,
    exchange: ExchangeId,
    request_id: RequestId,
    context: context,
    method: String,
    tool: Option(String),
    correlation: Correlation,
    metadata: v2026.RequestMetadata,
    input_responses: List(#(String, Value)),
    identity: v2026.Identity,
    work: Work(context),
  )
}

type Work(context) {
  ToolWork(tool: core.Tool(context), arguments: Value, request_state: String)
  ResourceWork(
    read: fn(context, String) -> Result(List(ResourceContents), Nil),
    uri: String,
  )
  PromptWork(
    prompt: core.Prompt(context),
    arguments: Dict(String, String),
    request_state: String,
  )
  CompletionWork(
    complete: core.Completion(context),
    query: core.CompletionQuery,
  )
}

/// The invocation's id.
pub fn invocation_id(invocation: Invocation(context)) -> InvocationId {
  invocation.id
}

/// The exchange the invocation answers on.
pub fn invocation_exchange(invocation: Invocation(context)) -> ExchangeId {
  invocation.exchange
}

/// The JSON-RPC method, such as `"tools/call"`.
pub fn invocation_method(invocation: Invocation(context)) -> String {
  invocation.method
}

/// The tool name of a `tools/call`.
pub fn invocation_tool(invocation: Invocation(context)) -> Option(String) {
  invocation.tool
}

/// The request's correlation: the transport's, else the one the frame
/// carried, else a fresh one.
pub fn invocation_correlation(invocation: Invocation(context)) -> Correlation {
  invocation.correlation
}

/// The application context the transport built for the request.
pub fn invocation_context(invocation: Invocation(context)) -> context {
  invocation.context
}

// --- state -------------------------------------------------------------------

type Exchange {
  Active(
    request_id: RequestId,
    progress_token: Option(ProgressToken),
    invocation: InvocationId,
    latest_progress: Option(Float),
  )
  Stream(request_id: RequestId)
  Done
}

/// The reducer state of one connection.
pub opaque type State(context) {
  State(
    server: Server(context),
    cursor_key: BitArray,
    exchanges: Dict(Int, Exchange),
    invocations: Dict(Int, Int),
    closed: List(Int),
    closed_count: Int,
    subscriptions: subs.Subscriptions,
  )
}

const max_closed = 10_000

/// The state of a connection to this server.
pub fn init(server: Server(context)) -> State(context) {
  State(
    server: server,
    cursor_key: server.cursor_key,
    exchanges: dict.new(),
    invocations: dict.new(),
    closed: [],
    closed_count: 0,
    subscriptions: subs.new(),
  )
}

/// The server description, after any registry changes.
pub fn server(state: State(context)) -> Server(context) {
  state.server
}

/// The number of open `subscriptions/listen` streams.
pub fn open_streams(state: State(context)) -> Int {
  subs.count(state.subscriptions)
}

fn key(exchange: ExchangeId) -> Int {
  exchange_id_to_int(exchange)
}

fn identity(state: State(context)) -> v2026.Identity {
  v2026.Identity(state.server.name, state.server.version)
}

fn mark_done(state: State(context), exchange: ExchangeId) -> State(context) {
  let id = key(exchange)
  let invocations = case dict.get(state.exchanges, id) {
    Ok(Active(_, _, invocation, _)) ->
      dict.delete(state.invocations, invocation_id_to_int(invocation))
    _ -> state.invocations
  }
  let state =
    State(
      ..state,
      exchanges: dict.insert(state.exchanges, id, Done),
      invocations: invocations,
      closed: [id, ..state.closed],
      closed_count: state.closed_count + 1,
    )
  prune(state)
}

fn prune(state: State(context)) -> State(context) {
  case state.closed_count > max_closed {
    False -> state
    True -> {
      let keep = max_closed * 3 / 4
      let #(kept, dropped) = list.split(state.closed, keep)
      State(
        ..state,
        exchanges: dict.drop(state.exchanges, dropped),
        closed: kept,
        closed_count: keep,
      )
    }
  }
}

// --- step --------------------------------------------------------------------

/// Reduces one input.
pub fn step(
  state: State(context),
  input: Input(context),
) -> #(State(context), List(Effect(context))) {
  case input {
    Received(exchange, context, bytes, correlation) ->
      case dict.has_key(state.exchanges, key(exchange)) {
        True -> #(state, [])
        False -> admit(state, exchange, context, bytes, correlation)
      }
    Finished(invocation, outcome) -> finish(state, invocation, outcome.response)
    Crashed(invocation) | TimedOut(invocation) ->
      case dict.get(state.invocations, invocation_id_to_int(invocation)) {
        Error(Nil) -> #(state, [])
        Ok(exchange) ->
          case dict.get(state.exchanges, exchange) {
            Ok(Active(request_id, ..)) ->
              finish(
                state,
                invocation,
                jsonrpc.error_to_json(
                  Some(request_id),
                  jsonrpc.internal_error(),
                ),
              )
            _ -> #(state, [])
          }
      }
    Progressed(invocation, progress, total, message) ->
      progressed(state, invocation, progress, total, message)
    ExchangeClosed(exchange) -> exchange_closed(state, exchange)
    Notify(notification) -> #(state, notify(state, notification))
    RegisterTool(tool) ->
      case server.register_tool(state.server, tool) {
        Error(_) -> #(state, [])
        Ok(next) -> {
          let state = State(..state, server: next)
          #(state, notify(state, subscriptions.ToolsListChanged))
        }
      }
    UnregisterTool(name) ->
      case server.has_tool(state.server, name) {
        False -> #(state, [])
        True -> {
          let state =
            State(..state, server: server.unregister_tool(state.server, name))
          #(state, notify(state, subscriptions.ToolsListChanged))
        }
      }
    EndStreams -> end_streams(state)
  }
}

fn encode(response: json.Json) -> BitArray {
  bit_array.from_string(json.to_string(response) <> "\n")
}

fn admit(
  state: State(context),
  exchange: ExchangeId,
  context: context,
  bytes: BitArray,
  correlation: Option(Correlation),
) -> #(State(context), List(Effect(context))) {
  case v2026.admit_bytes(bytes) {
    v2026.AdmittedRejected(id, error) ->
      immediate(state, exchange, None, jsonrpc.error_to_json(id, error))
    v2026.AdmittedIgnored(_) -> #(mark_done(state, exchange), [Close(exchange)])
    v2026.AdmittedNotification(v2026.Cancelled(request_id)) ->
      client_cancelled(state, exchange, request_id)
    v2026.AdmittedNotification(v2026.OtherNotification(_)) -> #(
      mark_done(state, exchange),
      [Close(exchange)],
    )
    v2026.AdmittedRequest(request) ->
      route(
        state,
        exchange,
        context,
        carrier.resolve(correlation, bytes),
        request,
      )
  }
}

fn immediate(
  state: State(context),
  exchange: ExchangeId,
  method: Option(String),
  response: json.Json,
) -> #(State(context), List(Effect(context))) {
  let admitted = case method {
    Some(method) -> [Admitted(exchange, method)]
    None -> []
  }
  #(
    mark_done(state, exchange),
    list.append(admitted, [Write(exchange, encode(response)), Close(exchange)]),
  )
}

fn invalid_params(
  state: State(context),
  exchange: ExchangeId,
  id: RequestId,
) -> #(State(context), List(Effect(context))) {
  immediate(
    state,
    exchange,
    None,
    jsonrpc.error_to_json(Some(id), jsonrpc.invalid_params()),
  )
}

fn route(
  state: State(context),
  exchange: ExchangeId,
  context: context,
  correlation: Correlation,
  request: v2026.Request,
) -> #(State(context), List(Effect(context))) {
  let srv = state.server
  case request {
    v2026.Discover(id, _) ->
      immediate(
        state,
        exchange,
        Some("server/discover"),
        v2026.encode_discovery_response(
          id,
          v2026.Capabilities(
            tools: srv.tools != [],
            resources: srv.resources != [],
            prompts: srv.prompts != [],
            completions: option.is_some(srv.completion),
          ),
          identity(state),
          srv.instructions,
        ),
      )
    v2026.ToolsList(id, _, cursor) -> {
      let visible =
        srv.tools
        |> list.filter(fn(entry) { srv.visible(context, entry) })
        |> list.map(tool.tool_declaration)
      case paginate(state, "tools/list", cursor, visible) {
        Error(Nil) -> invalid_params(state, exchange, id)
        Ok(#(page, next)) ->
          immediate(
            state,
            exchange,
            Some("tools/list"),
            v2026.encode_tools_list_response(id, page, next, identity(state)),
          )
      }
    }
    v2026.ResourcesList(id, _, cursor) -> {
      let statics =
        list.filter(srv.resources, fn(resource) {
          case resource.kind {
            core.Static(_) -> True
            core.Template(..) -> False
          }
        })
      case paginate(state, "resources/list", cursor, statics) {
        Error(Nil) -> invalid_params(state, exchange, id)
        Ok(#(page, next)) ->
          immediate(
            state,
            exchange,
            Some("resources/list"),
            v2026.encode_resources_list_response(id, page, next),
          )
      }
    }
    v2026.ResourceTemplatesList(id, _, cursor) -> {
      let templates =
        list.filter(srv.resources, fn(resource) {
          case resource.kind {
            core.Static(_) -> False
            core.Template(..) -> True
          }
        })
      case paginate(state, "resources/templates/list", cursor, templates) {
        Error(Nil) -> invalid_params(state, exchange, id)
        Ok(#(page, next)) ->
          immediate(
            state,
            exchange,
            Some("resources/templates/list"),
            v2026.encode_resource_templates_list_response(id, page, next),
          )
      }
    }
    v2026.ResourcesRead(id, meta, uri) ->
      case find_reader(srv.resources, uri) {
        Error(Nil) ->
          immediate(
            state,
            exchange,
            None,
            jsonrpc.error_to_json(Some(id), jsonrpc.resource_not_found()),
          )
        Ok(read) ->
          start(
            state,
            exchange,
            context,
            correlation,
            id,
            meta,
            "resources/read",
            None,
            None,
            ResourceWork(read, uri),
          )
      }
    v2026.PromptsList(id, _, cursor) ->
      case paginate(state, "prompts/list", cursor, srv.prompts) {
        Error(Nil) -> invalid_params(state, exchange, id)
        Ok(#(page, next)) ->
          immediate(
            state,
            exchange,
            Some("prompts/list"),
            v2026.encode_prompts_list_response(id, page, next),
          )
      }
    v2026.PromptsGet(id, meta, name, arguments, request_state, responses) ->
      case list.find(srv.prompts, fn(prompt) { prompt.name == name }) {
        Error(Nil) -> invalid_params(state, exchange, id)
        Ok(prompt) -> {
          let family = "input:prompts/get:" <> name
          case valid_state(state, family, request_state) {
            False -> invalid_params(state, exchange, id)
            True ->
              start(
                state,
                exchange,
                context,
                correlation,
                id,
                meta,
                "prompts/get",
                None,
                responses,
                PromptWork(
                  prompt,
                  arguments,
                  ffi_make_cursor(state.cursor_key, family, state_nonce()),
                ),
              )
          }
        }
      }
    v2026.CompletionComplete(id, meta, query) ->
      case srv.completion {
        None ->
          immediate(
            state,
            exchange,
            None,
            jsonrpc.error_to_json(Some(id), jsonrpc.method_not_found()),
          )
        Some(complete) ->
          start(
            state,
            exchange,
            context,
            correlation,
            id,
            meta,
            "completion/complete",
            None,
            None,
            CompletionWork(complete, query),
          )
      }
    v2026.ToolsCall(id, meta, name, arguments, request_state, responses) ->
      case core.find_tool(srv.tools, name) {
        Error(Nil) -> invalid_params(state, exchange, id)
        Ok(entry) ->
          case srv.visible(context, entry) && srv.callable(context, entry) {
            False -> invalid_params(state, exchange, id)
            True -> {
              let missing =
                list.filter(entry.info.required_capabilities, fn(capability) {
                  !v2026.client_declares_capability(meta, capability)
                })
              let family = "input:" <> name
              case missing, valid_state(state, family, request_state) {
                [_, ..], _ ->
                  immediate(
                    state,
                    exchange,
                    None,
                    jsonrpc.error_to_json(
                      Some(id),
                      jsonrpc.missing_required_client_capability(missing),
                    ),
                  )
                [], False -> invalid_params(state, exchange, id)
                [], True ->
                  start(
                    state,
                    exchange,
                    context,
                    correlation,
                    id,
                    meta,
                    "tools/call",
                    Some(name),
                    responses,
                    ToolWork(
                      entry,
                      arguments,
                      ffi_make_cursor(state.cursor_key, family, state_nonce()),
                    ),
                  )
              }
            }
          }
      }
    v2026.SubscriptionsListen(id, _, filter) -> {
      let honored =
        subs.filter_supported(
          filter,
          True,
          srv.resources != [],
          srv.prompts != [],
        )
      let owner = int.to_string(key(exchange))
      let state =
        State(
          ..state,
          subscriptions: subs.listen(state.subscriptions, owner, id, honored),
          exchanges: dict.insert(state.exchanges, key(exchange), Stream(id)),
        )
      let ack =
        v2026.encode_subscriptions_acknowledged_notification(id, honored)
      #(state, [
        Admitted(exchange, "subscriptions/listen"),
        Write(exchange, encode(ack)),
      ])
    }
  }
}

// Each round gets a fresh state, kept below the cursor offset bound
// (10^9) that a node-wide counter would outgrow on a long-lived node.
fn state_nonce() -> Int {
  ffi_unique_integer() % 1_000_000_000
}

fn valid_state(
  state: State(context),
  family: String,
  request_state: Option(String),
) -> Bool {
  case request_state {
    None -> True
    Some(token) ->
      result.is_ok(ffi_read_cursor(state.cursor_key, family, token))
  }
}

fn start(
  state: State(context),
  exchange: ExchangeId,
  context: context,
  correlation: Correlation,
  request_id: RequestId,
  metadata: v2026.RequestMetadata,
  method: String,
  tool_name: Option(String),
  responses: Option(Value),
  work: Work(context),
) -> #(State(context), List(Effect(context))) {
  let id = InvocationId(ffi_unique_integer())
  let input_responses = case responses {
    Some(value.Object(members)) -> members
    _ -> []
  }
  let invocation =
    Invocation(
      id: id,
      exchange: exchange,
      request_id: request_id,
      context: context,
      method: method,
      tool: tool_name,
      correlation: correlation,
      metadata: metadata,
      input_responses: input_responses,
      identity: identity(state),
      work: work,
    )
  let record = Active(request_id, metadata.progress_token, id, None)
  let state =
    State(
      ..state,
      exchanges: dict.insert(state.exchanges, key(exchange), record),
      invocations: dict.insert(
        state.invocations,
        invocation_id_to_int(id),
        key(exchange),
      ),
    )
  #(state, [Admitted(exchange, method), Start(invocation)])
}

fn paginate(
  state: State(context),
  family: String,
  cursor: Option(String),
  items: List(a),
) -> Result(#(List(a), Option(String)), Nil) {
  use offset <- result.try(case cursor {
    None -> Ok(0)
    Some(token) -> ffi_read_cursor(state.cursor_key, family, token)
  })
  let page = items |> list.drop(offset) |> list.take(100)
  let next_offset = offset + list.length(page)
  case next_offset < list.length(items) {
    True ->
      Ok(#(page, Some(ffi_make_cursor(state.cursor_key, family, next_offset))))
    False -> Ok(#(page, None))
  }
}

fn find_reader(
  resources: List(core.Resource(context)),
  uri: String,
) -> Result(fn(context, String) -> Result(List(ResourceContents), Nil), Nil) {
  let static =
    list.find(resources, fn(resource) {
      case resource.kind {
        core.Static(candidate) -> candidate == uri
        core.Template(..) -> False
      }
    })
  case static {
    Ok(resource) -> Ok(resource.read)
    Error(Nil) ->
      list.find(resources, fn(resource) {
        case resource.kind {
          core.Static(_) -> False
          core.Template(_, matches) -> matches(uri)
        }
      })
      |> result.map(fn(resource) { resource.read })
  }
}

fn client_cancelled(
  state: State(context),
  notification_exchange: ExchangeId,
  request_id: RequestId,
) -> #(State(context), List(Effect(context))) {
  let state = mark_done(state, notification_exchange)
  let target =
    dict.to_list(state.exchanges)
    |> list.find(fn(entry) {
      case entry.1 {
        Active(candidate, ..) -> candidate == request_id
        Stream(candidate) -> candidate == request_id
        Done -> False
      }
    })
  case target {
    Error(Nil) -> #(state, [Close(notification_exchange)])
    Ok(#(id, Active(_, _, invocation, _))) -> #(
      mark_done(state, ExchangeId(id)),
      [
        Cancel(invocation),
        Close(ExchangeId(id)),
        Close(notification_exchange),
      ],
    )
    Ok(#(id, Stream(stream_request))) -> {
      let state = close_stream(state, ExchangeId(id), stream_request)
      #(state, [Close(ExchangeId(id)), Close(notification_exchange)])
    }
    Ok(#(_, Done)) -> #(state, [Close(notification_exchange)])
  }
}

fn close_stream(
  state: State(context),
  exchange: ExchangeId,
  request_id: RequestId,
) -> State(context) {
  let owner = int.to_string(key(exchange))
  let state =
    State(
      ..state,
      subscriptions: subs.close_stream(state.subscriptions, owner, request_id),
    )
  mark_done(state, exchange)
}

fn finish(
  state: State(context),
  invocation: InvocationId,
  response: json.Json,
) -> #(State(context), List(Effect(context))) {
  case dict.get(state.invocations, invocation_id_to_int(invocation)) {
    Error(Nil) -> #(state, [])
    Ok(id) ->
      case dict.get(state.exchanges, id) {
        Ok(Active(..)) -> #(mark_done(state, ExchangeId(id)), [
          Write(ExchangeId(id), encode(response)),
          Close(ExchangeId(id)),
        ])
        _ -> #(state, [])
      }
  }
}

fn progressed(
  state: State(context),
  invocation: InvocationId,
  progress: Float,
  total: Option(Float),
  message: Option(String),
) -> #(State(context), List(Effect(context))) {
  case dict.get(state.invocations, invocation_id_to_int(invocation)) {
    Error(Nil) -> #(state, [])
    Ok(id) ->
      case dict.get(state.exchanges, id) {
        Ok(Active(request_id, Some(token), inv, latest)) ->
          case progress >=. 0.0 && increases(progress, latest) {
            False -> #(state, [])
            True -> {
              let record = Active(request_id, Some(token), inv, Some(progress))
              let state =
                State(
                  ..state,
                  exchanges: dict.insert(state.exchanges, id, record),
                )
              let notification =
                v2026.encode_progress_notification(
                  token,
                  progress,
                  total,
                  message,
                )
              #(state, [Write(ExchangeId(id), encode(notification))])
            }
          }
        _ -> #(state, [])
      }
  }
}

fn increases(progress: Float, latest: Option(Float)) -> Bool {
  case latest {
    None -> True
    Some(previous) -> progress >. previous
  }
}

fn exchange_closed(
  state: State(context),
  exchange: ExchangeId,
) -> #(State(context), List(Effect(context))) {
  case dict.get(state.exchanges, key(exchange)) {
    Error(Nil) -> #(mark_done(state, exchange), [])
    Ok(Done) -> #(state, [])
    Ok(Active(_, _, invocation, _)) -> #(mark_done(state, exchange), [
      Cancel(invocation),
      Close(exchange),
    ])
    Ok(Stream(request_id)) -> #(close_stream(state, exchange, request_id), [
      Close(exchange),
    ])
  }
}

fn notify(
  state: State(context),
  notification: Notification,
) -> List(Effect(context)) {
  subs.subscribers(state.subscriptions, notification)
  |> list.filter_map(fn(subscriber) {
    let #(owner, request_id) = subscriber
    case int.parse(owner) {
      Error(Nil) -> Error(Nil)
      Ok(id) ->
        case dict.get(state.exchanges, id) {
          Ok(Stream(_)) ->
            Ok(Write(
              ExchangeId(id),
              encode(v2026.encode_stream_notification(request_id, notification)),
            ))
          _ -> Error(Nil)
        }
    }
  })
}

fn end_streams(
  state: State(context),
) -> #(State(context), List(Effect(context))) {
  let streams =
    dict.to_list(state.exchanges)
    |> list.filter_map(fn(entry) {
      case entry.1 {
        Stream(request_id) -> Ok(#(entry.0, request_id))
        _ -> Error(Nil)
      }
    })
  list.fold(streams, #(state, []), fn(acc, stream) {
    let #(state, effects) = acc
    let #(id, request_id) = stream
    let response =
      v2026.encode_subscriptions_listen_result_response(
        request_id,
        identity(state),
      )
    #(
      close_stream(state, ExchangeId(id), request_id),
      list.append(effects, [
        Write(ExchangeId(id), encode(response)),
        Close(ExchangeId(id)),
      ]),
    )
  })
}

// --- perform -----------------------------------------------------------------

@external(erlang, "relay_ffi", "signal_cancelled")
fn ffi_signal_cancelled(worker: process.Pid, invocation: Int) -> Nil

/// Tells the process running an invocation that it was cancelled, which
/// fires its handler's `relay/tool.cancelled` selector.
pub fn signal_cancelled(worker: process.Pid, invocation: InvocationId) -> Nil {
  ffi_signal_cancelled(worker, invocation_id_to_int(invocation))
}

// A worker runs one invocation, so any cancellation signal it receives is
// for that invocation.
fn cancelled_selector() -> process.Selector(Nil) {
  process.new_selector()
  |> process.select_record(
    tag: atom.create("relay_invocation_cancelled"),
    fields: 1,
    mapping: fn(_) { Nil },
  )
}

/// Runs the invocation's handler in the calling process and returns the
/// `Finished` input for the reducer. `report_progress` receives each
/// progress report; the caller feeds it back as `Progressed`. Call it from
/// the process that `signal_cancelled` will address.
pub fn perform(
  invocation: Invocation(context),
  report_progress: fn(Float, Option(Float), Option(String)) -> Nil,
) -> Input(context) {
  let call =
    core.Call(
      context: invocation.context,
      input_responses: invocation.input_responses,
      invocation_id: invocation_id_to_int(invocation.id),
      request_id: invocation.request_id,
      idempotency_key: invocation.metadata.idempotency_key,
      correlation: invocation.correlation,
      client_info: option.map(invocation.metadata.client_info, fn(info) {
        #(info.name, info.version)
      }),
      progress: report_progress,
      cancelled: cancelled_selector(),
    )
  let id = invocation.request_id
  let outcome = case invocation.work {
    ToolWork(entry, arguments, request_state) ->
      case entry.invoke(call, arguments) {
        core.Completed(structured, blocks) ->
          Outcome(
            v2026.encode_call_response(
              id,
              structured,
              blocks,
              False,
              invocation.identity,
            ),
            telemetry.Succeeded,
          )
        core.Failed(blocks, structured) ->
          Outcome(
            v2026.encode_call_response(
              id,
              structured,
              blocks,
              True,
              invocation.identity,
            ),
            telemetry.ToolFailed,
          )
        core.AwaitingInput(requests) ->
          input_required(invocation, requests, request_state)
        core.InvalidArguments(_) ->
          Outcome(
            jsonrpc.error_to_json(Some(id), jsonrpc.invalid_params()),
            telemetry.Failed,
          )
        core.InvalidOutput ->
          Outcome(
            jsonrpc.error_to_json(Some(id), jsonrpc.internal_error()),
            telemetry.Failed,
          )
      }
    ResourceWork(read, uri) ->
      case read(invocation.context, uri) {
        Ok(contents) ->
          Outcome(
            v2026.encode_resources_read_response(id, contents),
            telemetry.Succeeded,
          )
        Error(Nil) ->
          Outcome(
            jsonrpc.error_to_json(Some(id), jsonrpc.resource_not_found()),
            telemetry.Failed,
          )
      }
    PromptWork(prompt, arguments, request_state) ->
      case prompt.get(call, arguments) {
        Ok(core.Complete(rendered, _)) ->
          Outcome(
            v2026.encode_prompts_get_response(id, rendered),
            telemetry.Succeeded,
          )
        Ok(core.NeedsInput(requests)) ->
          input_required(invocation, requests, request_state)
        Error(Nil) ->
          Outcome(
            jsonrpc.error_to_json(Some(id), jsonrpc.invalid_params()),
            telemetry.Failed,
          )
      }
    CompletionWork(core.Completion(complete), query) ->
      case complete(invocation.context, query) {
        Ok(completion) ->
          Outcome(
            v2026.encode_completion_response(id, completion),
            telemetry.Succeeded,
          )
        Error(Nil) ->
          Outcome(
            jsonrpc.error_to_json(Some(id), jsonrpc.internal_error()),
            telemetry.Failed,
          )
      }
  }
  Finished(invocation.id, outcome)
}

fn input_required(
  invocation: Invocation(context),
  requests: List(#(String, core.InputRequest)),
  request_state: String,
) -> Outcome {
  let supported =
    list.filter(requests, fn(entry) {
      let #(_, request) = entry
      v2026.client_supports_input_request(invocation.metadata, request.method)
    })
  Outcome(
    v2026.encode_input_required_response(
      invocation.request_id,
      supported,
      request_state,
      invocation.identity,
    ),
    telemetry.InputRequested,
  )
}
