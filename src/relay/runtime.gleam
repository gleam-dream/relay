//// The OTP actor that owns one connection's `relay/reducer` state and runs
//// its handlers, for authors of custom transports.
////
//// `start(server, config(), sink)` starts the runtime; the transport then
//// submits each inbound frame with `send_frame` on a fresh
//// `relay/reducer.ExchangeId`, and the runtime calls `sink` with
//// `OutputWrite` and `OutputClose` for that exchange. A sink that returns
//// `Error(Nil)` closes only its exchange. `exchange_closed` reports a peer
//// disconnect, which cancels that exchange's invocation. `notify`,
//// `register_tool`, `unregister_tool` and `end_streams` change the live
//// server. The stdio and HTTP transports run on this module.
////
//// Each handler runs in its own unlinked process with a timeout. Every
//// cancellation (a peer disconnect, `notifications/cancelled`, the
//// invocation timeout, `close`, `stop`, or the exit of the process that
//// started the runtime) first fires the handler's `relay/tool.cancelled`
//// selector, then gives it the cancellation grace period to stop work it
//// started elsewhere and return; Relay kills it only when the grace ends.
//// The runtime stays alive until every cancelled handler has returned or
//// been killed. A crash becomes the JSON-RPC internal error on its exchange
//// only.
////
//// | Setting | Default | Setter |
//// | --- | --- | --- |
//// | live exchanges | 100 | `with_max_live_exchanges` |
//// | frame size | 1 MiB | `with_max_frame_bytes` |
//// | JSON nesting depth | 64 | `with_max_json_depth` |
//// | invocation timeout | 30 s | `with_invocation_timeout` |
//// | cancellation grace | 5 s | `with_cancellation_grace` |
//// | tombstone retention | 60 s, at most 10,000 | `with_tombstone_retention`, `with_max_tombstones` |
////
//// ```gleam
//// import gleam/option.{None}
//// import relay/reducer
//// import relay/runtime
//// import relay/server
////
//// pub fn run(frame: BitArray) {
////   let assert Ok(rt) =
////     runtime.start(server.new([]), runtime.config(), fn(output) {
////       case output {
////         runtime.OutputWrite(_exchange, _bytes) -> Ok(Nil)
////         runtime.OutputClose(_exchange) -> Ok(Nil)
////       }
////     })
////   let _ = runtime.send_frame(rt, reducer.new_exchange_id(), Nil, frame, None)
////   runtime.stop(rt)
//// }
//// ```

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/time/duration.{type Duration}
import relay/internal/emit
import relay/internal/protocol/v2026_07_28 as v2026
import relay/reducer.{type ExchangeId, type Invocation, type InvocationId}
import relay/server.{type Server}
import relay/subscriptions.{type Notification}
import relay/telemetry
import relay/tool.{type Tool}
import sinal/correlation.{type Correlation}

// --- configuration -----------------------------------------------------------

/// Runtime limits. Build it with `config()` and the `with_*` setters;
/// `start` validates it.
pub opaque type Config {
  Config(
    max_live_exchanges: Int,
    max_frame_bytes: Int,
    max_json_depth: Int,
    invocation_timeout: Duration,
    cancellation_grace: Duration,
    tombstone_retention: Duration,
    max_tombstones: Int,
    label: Option(String),
  )
}

/// The default limits; see the module table.
pub fn config() -> Config {
  Config(
    max_live_exchanges: 100,
    max_frame_bytes: 1_048_576,
    max_json_depth: 64,
    invocation_timeout: duration.seconds(30),
    cancellation_grace: duration.seconds(5),
    tombstone_retention: duration.seconds(60),
    max_tombstones: 10_000,
    label: None,
  )
}

/// How many exchanges may be open at once; a frame beyond it fails with
/// `TooManyLiveExchanges`.
pub fn with_max_live_exchanges(config: Config, count: Int) -> Config {
  Config(..config, max_live_exchanges: count)
}

/// The largest frame `send_frame` accepts.
pub fn with_max_frame_bytes(config: Config, bytes: Int) -> Config {
  Config(..config, max_frame_bytes: bytes)
}

/// The deepest object and array nesting a frame may have, checked before
/// parsing.
pub fn with_max_json_depth(config: Config, depth: Int) -> Config {
  Config(..config, max_json_depth: depth)
}

/// How long a handler may run before the client receives an internal error.
pub fn with_invocation_timeout(config: Config, timeout: Duration) -> Config {
  Config(..config, invocation_timeout: timeout)
}

/// How long a cancelled or timed-out handler may keep running after its
/// `relay/tool.cancelled` selector fires, before Relay kills it.
pub fn with_cancellation_grace(config: Config, grace: Duration) -> Config {
  Config(..config, cancellation_grace: grace)
}

/// How long a finished or cancelled invocation is remembered, so a late
/// start or result for it is dropped.
pub fn with_tombstone_retention(config: Config, retention: Duration) -> Config {
  Config(..config, tombstone_retention: retention)
}

/// How many finished or cancelled invocations are remembered at most.
pub fn with_max_tombstones(config: Config, count: Int) -> Config {
  Config(..config, max_tombstones: count)
}

/// The `listener` label in this runtime's telemetry.
pub fn with_label(config: Config, label: String) -> Config {
  Config(..config, label: Some(label))
}

/// The setting `validate` refused.
pub type ConfigField {
  MaxLiveExchanges
  MaxFrameBytes
  MaxJsonDepth
  InvocationTimeout
  CancellationGrace
  TombstoneRetention
  MaxTombstones
}

/// Why `start` failed.
pub type StartError {
  /// A setting is out of range: counts, sizes and durations must be
  /// positive; the grace period may be zero.
  InvalidConfig(field: ConfigField)
  ActorStartFailed(actor.StartError)
}

/// A one-line description of a start error.
pub fn describe_start_error(error: StartError) -> String {
  case error {
    InvalidConfig(field) ->
      "invalid Relay runtime setting: "
      <> field_name(field)
      <> " is out of range"
    ActorStartFailed(_) -> "the Relay runtime actor failed to start"
  }
}

fn field_name(field: ConfigField) -> String {
  case field {
    MaxLiveExchanges -> "max_live_exchanges"
    MaxFrameBytes -> "max_frame_bytes"
    MaxJsonDepth -> "max_json_depth"
    InvocationTimeout -> "invocation_timeout"
    CancellationGrace -> "cancellation_grace"
    TombstoneRetention -> "tombstone_retention"
    MaxTombstones -> "max_tombstones"
  }
}

/// Checks the settings without starting anything.
pub fn validate(config: Config) -> Result(Config, StartError) {
  let ms = duration.to_milliseconds
  case Nil {
    _ if config.max_live_exchanges <= 0 -> Error(InvalidConfig(MaxLiveExchanges))
    _ if config.max_frame_bytes <= 0 -> Error(InvalidConfig(MaxFrameBytes))
    _ if config.max_json_depth <= 0 -> Error(InvalidConfig(MaxJsonDepth))
    _ -> {
      case ms(config.invocation_timeout) > 0 {
        False -> Error(InvalidConfig(InvocationTimeout))
        True ->
          case ms(config.cancellation_grace) >= 0 {
            False -> Error(InvalidConfig(CancellationGrace))
            True ->
              case ms(config.tombstone_retention) > 0 {
                False -> Error(InvalidConfig(TombstoneRetention))
                True ->
                  case config.max_tombstones > 0 {
                    False -> Error(InvalidConfig(MaxTombstones))
                    True -> Ok(config)
                  }
              }
          }
      }
    }
  }
}

/// The largest frame this configuration accepts.
pub fn max_frame_bytes(config: Config) -> Int {
  config.max_frame_bytes
}

/// The invocation timeout of this configuration.
pub fn invocation_timeout(config: Config) -> Duration {
  config.invocation_timeout
}

// --- transport interface -----------------------------------------------------

/// What the runtime asks the transport to do on an exchange.
pub type Output {
  OutputWrite(exchange: ExchangeId, bytes: BitArray)
  OutputClose(exchange: ExchangeId)
}

/// Why `send_frame` refused a frame. The transport answers the peer.
pub type FrameError {
  FrameTooLarge(size: Int, limit: Int)
  FrameTooDeep(limit: Int)
  TooManyLiveExchanges(current: Int, limit: Int)
  RuntimeStopped
}

/// The messages a runtime actor receives; used to name a supervised one.
pub opaque type Message(context) {
  ReceiveFrame(
    exchange: ExchangeId,
    context: context,
    bytes: BitArray,
    correlation: Option(Correlation),
    reply: Subject(Result(Nil, FrameError)),
  )
  WorkerFinished(id: Int, input: reducer.Input(context))
  WorkerProgress(
    id: Int,
    progress: Float,
    total: Option(Float),
    message: Option(String),
    reply: Subject(Nil),
  )
  WorkerTimeout(id: Int)
  KillAfterGrace(pid: Pid)
  WorkerDown(down: process.Down)
  OwnerExited(exit: process.ExitMessage)
  ExpireTombstone(id: Int)
  Apply(input: reducer.Input(context))
  PeerClosedExchange(exchange: ExchangeId)
  Close
  Stop(reply: Subject(StopReply))
}

// `Stop` answers `Draining` at once when handlers are still in their grace,
// then `Stopped` when the last one has exited.
type StopReply {
  Draining(grace_ms: Int)
  Stopped
}

/// A running runtime.
pub opaque type Runtime(context) {
  Runtime(subject: Subject(Message(context)))
}

type Worker {
  Worker(
    invocation: InvocationId,
    pid: Pid,
    monitor: process.Monitor,
    timer: process.Timer,
    started_at: Int,
    exchange: Int,
    method: String,
    tool: Option(String),
    correlation: Option(Correlation),
  )
}

// A cancelled handler in its grace: still monitored, killed by the timer.
type Cancelling {
  Cancelling(monitor: process.Monitor, kill: process.Timer)
}

type State(context) {
  State(
    config: Config,
    reducer: reducer.State(context),
    sink: fn(Output) -> Result(Nil, Nil),
    workers: Dict(Int, Worker),
    // Handlers in their cancellation grace. The runtime stops only once
    // this is empty.
    cancelling: Dict(Pid, Cancelling),
    // Set by `stop` or the owner's exit: stop once `cancelling` is empty,
    // answering these callers.
    stopping: Option(List(Subject(StopReply))),
    tombstones: Dict(Int, Nil),
    tombstone_order: List(Int),
    live_exchanges: Int,
    closed: Bool,
    self: Subject(Message(context)),
    frame_correlation: Option(Correlation),
  )
}

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn monotonic_ms() -> Int

@external(erlang, "relay_ffi", "rescue_run")
fn rescue_run(fun: fn() -> a) -> Result(a, String)

/// Starts a runtime linked to the caller.
pub fn start(
  server: Server(context),
  config: Config,
  sink: fn(Output) -> Result(Nil, Nil),
) -> Result(Runtime(context), StartError) {
  use config <- result.try(validate(config))
  builder(server, config, sink, None)
  |> actor.start
  |> result.map(fn(started) { Runtime(started.data) })
  |> result.map_error(ActorStartFailed)
}

/// A child specification for a runtime registered under `name`; find it with
/// `named`. A restart starts a fresh connection state.
pub fn supervised(
  server: Server(context),
  config: Config,
  sink: fn(Output) -> Result(Nil, Nil),
  name: process.Name(Message(context)),
) -> supervision.ChildSpecification(Runtime(context)) {
  supervision.worker(fn() {
    case validate(config) {
      Error(error) -> Error(actor.InitFailed(describe_start_error(error)))
      Ok(config) ->
        builder(server, config, sink, Some(name))
        |> actor.start
        |> result.map(fn(started) {
          actor.Started(started.pid, Runtime(started.data))
        })
    }
  })
}

/// The runtime registered under `name` by `supervised`.
pub fn named(name: process.Name(Message(context))) -> Runtime(context) {
  Runtime(process.named_subject(name))
}

fn builder(
  server: Server(context),
  config: Config,
  sink: fn(Output) -> Result(Nil, Nil),
  name: Option(process.Name(Message(context))),
) {
  let builder =
    actor.new_with_initialiser(5000, fn(self) {
      // The owner's exit closes the runtime like `stop`, so cancelled
      // handlers keep their grace even when the owner does not wait.
      process.trap_exits(True)
      let selector =
        process.new_selector()
        |> process.select(for: self)
        |> process.select_monitors(WorkerDown)
        |> process.select_trapped_exits(OwnerExited)
      State(
        config: config,
        reducer: reducer.init(server),
        sink: sink,
        workers: dict.new(),
        cancelling: dict.new(),
        stopping: None,
        tombstones: dict.new(),
        tombstone_order: [],
        live_exchanges: 0,
        closed: False,
        self: self,
        frame_correlation: None,
      )
      |> actor.initialised
      |> actor.selecting(selector)
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle_message)
  case name {
    None -> builder
    Some(name) -> actor.named(builder, name)
  }
}

const call_timeout = 5000

/// Submits one frame on a fresh exchange, with the context and the
/// correlation the transport built for it. Returns once the runtime has
/// admitted or refused the frame; responses arrive through the sink.
pub fn send_frame(
  runtime: Runtime(context),
  exchange: ExchangeId,
  context: context,
  bytes: BitArray,
  correlation: Option(Correlation),
) -> Result(Nil, FrameError) {
  let Runtime(subject) = runtime
  process.call(subject, waiting: call_timeout, sending: fn(reply) {
    ReceiveFrame(exchange, context, bytes, correlation, reply)
  })
}

/// Reports that the peer closed one exchange; its invocation is cancelled
/// and nothing more is written to it.
pub fn exchange_closed(runtime: Runtime(context), exchange: ExchangeId) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, PeerClosedExchange(exchange))
}

/// Tells every listening stream that asked for this notification.
pub fn notify(runtime: Runtime(context), notification: Notification) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, Apply(reducer.Notify(notification)))
}

/// Registers a tool and tells listening streams the tool list changed. A
/// duplicate name is ignored.
pub fn register_tool(runtime: Runtime(context), tool: Tool(context)) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, Apply(reducer.RegisterTool(tool)))
}

/// Removes a tool and tells listening streams when it existed.
pub fn unregister_tool(runtime: Runtime(context), name: String) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, Apply(reducer.UnregisterTool(name)))
}

/// Ends every open `subscriptions/listen` stream with its result.
pub fn end_streams(runtime: Runtime(context)) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, Apply(reducer.EndStreams))
}

/// Closes the connection: cancels every invocation and refuses new frames.
/// Each cancelled handler keeps its grace period. Returns at once.
pub fn close(runtime: Runtime(context)) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, Close)
}

/// Closes the connection, then stops the actor once every cancelled handler
/// has returned or been killed at the end of its grace period. Returns when
/// the runtime has stopped, waiting at most the grace period plus 5 s. To
/// stop without waiting, call `close` and then `stop` from another process.
pub fn stop(runtime: Runtime(context)) -> Nil {
  let Runtime(subject) = runtime
  let reply = process.new_subject()
  process.send(subject, Stop(reply))
  case process.receive(reply, call_timeout) {
    Ok(Draining(grace_ms)) -> {
      let _ = process.receive(reply, grace_ms + call_timeout)
      Nil
    }
    Ok(Stopped) | Error(Nil) -> Nil
  }
}

// --- actor -------------------------------------------------------------------

fn handle_message(
  state: State(context),
  message: Message(context),
) -> actor.Next(State(context), Message(context)) {
  case message {
    ReceiveFrame(exchange, context, bytes, correlation, reply) -> {
      let #(state, result) =
        receive_frame(state, exchange, context, bytes, correlation)
      process.send(reply, result)
      actor.continue(state)
    }
    WorkerProgress(id, progress, total, text, reply) -> {
      let state = case dict.get(state.workers, id) {
        Error(Nil) -> state
        Ok(worker) ->
          apply(
            state,
            reducer.Progressed(worker.invocation, progress, total, text),
          )
      }
      process.send(reply, Nil)
      actor.continue(state)
    }
    WorkerFinished(id, input) -> actor.continue(finish_worker(state, id, input))
    WorkerTimeout(id) ->
      case dict.get(state.workers, id) {
        Error(Nil) -> actor.continue(state)
        Ok(worker) -> {
          emit.invocation_crashed(crash_meta(
            state,
            id,
            worker,
            telemetry.HandlerTimedOut,
          ))
          let state = cancel_worker(state, id, worker)
          actor.continue(apply(state, reducer.TimedOut(worker.invocation)))
        }
      }
    KillAfterGrace(pid) ->
      case dict.get(state.cancelling, pid) {
        // The handler already returned.
        Error(Nil) -> actor.continue(state)
        Ok(cancelling) -> {
          process.kill(pid)
          let _ = process.demonitor_process(cancelling.monitor)
          State(..state, cancelling: dict.delete(state.cancelling, pid))
          |> continue_or_stop
        }
      }
    WorkerDown(process.ProcessDown(monitor: _, pid: pid, reason: reason)) ->
      case find_worker_by_pid(state.workers, pid), reason {
        // A worker that exits normally has already sent its result.
        Ok(_), process.Normal -> actor.continue(state)
        Ok(#(id, worker)), _ -> {
          emit.invocation_crashed(crash_meta(
            state,
            id,
            worker,
            telemetry.HandlerCrashed,
          ))
          let state = remove_worker(state, id, worker)
          actor.continue(apply(state, reducer.Crashed(worker.invocation)))
        }
        // A cancelled handler returned, or exited, within its grace.
        Error(Nil), _ ->
          case dict.get(state.cancelling, pid) {
            Error(Nil) -> actor.continue(state)
            Ok(cancelling) -> {
              let _ = process.cancel_timer(cancelling.kill)
              State(..state, cancelling: dict.delete(state.cancelling, pid))
              |> continue_or_stop
            }
          }
      }
    WorkerDown(_) -> actor.continue(state)
    // Handlers are unlinked, so a trapped exit comes from the process that
    // started the runtime, or its supervisor.
    OwnerExited(process.ExitMessage(pid: _, reason: process.Normal)) ->
      actor.continue(state)
    OwnerExited(_) -> begin_stop(state, None)
    ExpireTombstone(id) ->
      actor.continue(
        State(
          ..state,
          tombstones: dict.delete(state.tombstones, id),
          tombstone_order: list.filter(state.tombstone_order, fn(t) { t != id }),
        ),
      )
    Apply(input) -> actor.continue(apply(state, input))
    PeerClosedExchange(exchange) ->
      actor.continue(apply(state, reducer.ExchangeClosed(exchange)))
    Close -> actor.continue(close_all(state))
    Stop(reply) -> begin_stop(state, Some(reply))
  }
}

// Moves every worker into its cancellation grace and stops once the last
// cancelled handler has exited.
fn begin_stop(
  state: State(context),
  reply: Option(Subject(StopReply)),
) -> actor.Next(State(context), Message(context)) {
  let state = close_all(state)
  let replies = option.unwrap(state.stopping, [])
  let replies = case reply {
    Some(reply) -> {
      case dict.is_empty(state.cancelling) {
        True -> Nil
        False ->
          process.send(
            reply,
            Draining(duration.to_milliseconds(state.config.cancellation_grace)),
          )
      }
      [reply, ..replies]
    }
    None -> replies
  }
  continue_or_stop(State(..state, stopping: Some(replies)))
}

fn continue_or_stop(
  state: State(context),
) -> actor.Next(State(context), Message(context)) {
  case state.stopping, dict.is_empty(state.cancelling) {
    Some(replies), True -> {
      list.each(replies, process.send(_, Stopped))
      actor.stop()
    }
    _, _ -> actor.continue(state)
  }
}

fn receive_frame(
  state: State(context),
  exchange: ExchangeId,
  context: context,
  bytes: BitArray,
  correlation: Option(Correlation),
) -> #(State(context), Result(Nil, FrameError)) {
  let size = bit_array.byte_size(bytes)
  let exchange_int = reducer.exchange_id_to_int(exchange)
  let config = state.config
  case Nil {
    _ if state.closed -> #(state, Error(RuntimeStopped))
    _ if size > config.max_frame_bytes -> {
      emit.frame_rejected(exchange_int, telemetry.FrameTooLarge, config.label)
      #(state, Error(FrameTooLarge(size, config.max_frame_bytes)))
    }
    _ ->
      case v2026.depth_within(bytes, config.max_json_depth) {
        False -> {
          emit.frame_rejected(
            exchange_int,
            telemetry.NestingTooDeep,
            config.label,
          )
          #(state, Error(FrameTooDeep(config.max_json_depth)))
        }
        True ->
          case state.live_exchanges >= config.max_live_exchanges {
            True -> {
              emit.frame_rejected(
                exchange_int,
                telemetry.TooManyExchanges,
                config.label,
              )
              #(
                state,
                Error(TooManyLiveExchanges(
                  state.live_exchanges,
                  config.max_live_exchanges,
                )),
              )
            }
            False -> {
              let #(next, effects) =
                reducer.step(
                  state.reducer,
                  reducer.Received(exchange, context, bytes, correlation),
                )
              // The reducer drops a frame on an exchange it already knows
              // without effects; only an admitted exchange holds a slot.
              let live = case effects {
                [] -> state.live_exchanges
                _ -> state.live_exchanges + 1
              }
              let state =
                State(
                  ..state,
                  reducer: next,
                  live_exchanges: live,
                  frame_correlation: correlation,
                )
              let state = list.fold(effects, state, interpret)
              #(State(..state, frame_correlation: None), Ok(Nil))
            }
          }
      }
  }
}

fn apply(
  state: State(context),
  input: reducer.Input(context),
) -> State(context) {
  let #(next, effects) = reducer.step(state.reducer, input)
  list.fold(effects, State(..state, reducer: next), interpret)
}

fn interpret(
  state: State(context),
  effect: reducer.Effect(context),
) -> State(context) {
  case effect {
    reducer.Write(exchange, bytes) ->
      case state.sink(OutputWrite(exchange, bytes)) {
        Ok(Nil) -> state
        Error(Nil) -> apply(state, reducer.ExchangeClosed(exchange))
      }
    reducer.Close(exchange) -> {
      emit.exchange_closed(
        reducer.exchange_id_to_int(exchange),
        state.config.label,
      )
      let _ = state.sink(OutputClose(exchange))
      State(..state, live_exchanges: int.max(0, state.live_exchanges - 1))
    }
    reducer.Start(invocation) -> start_worker(state, invocation)
    reducer.Cancel(invocation) -> {
      let id = reducer.invocation_id_to_int(invocation)
      case dict.get(state.workers, id) {
        Error(Nil) -> remember(state, id)
        Ok(worker) -> {
          emit.invocation_cancelled(telemetry.InvocationCancelledMeta(
            invocation_id: id,
            method: worker.method,
            tool: worker.tool,
            correlation: worker.correlation,
            listener: state.config.label,
          ))
          cancel_worker(state, id, worker)
        }
      }
    }
    reducer.Admitted(exchange, method) -> {
      emit.request_admitted(
        reducer.exchange_id_to_int(exchange),
        method,
        state.frame_correlation,
        state.config.label,
      )
      state
    }
  }
}

fn start_worker(
  state: State(context),
  invocation: Invocation(context),
) -> State(context) {
  let id = reducer.invocation_id_to_int(reducer.invocation_id(invocation))
  case
    state.closed
    || dict.has_key(state.tombstones, id)
    || dict.has_key(state.workers, id)
  {
    True -> state
    False -> {
      let exchange =
        reducer.exchange_id_to_int(reducer.invocation_exchange(invocation))
      let method = reducer.invocation_method(invocation)
      let tool = reducer.invocation_tool(invocation)
      let correlation = reducer.invocation_correlation(invocation)
      emit.invocation_started(telemetry.InvocationStartedMeta(
        exchange_id: exchange,
        invocation_id: id,
        method: method,
        tool: tool,
        correlation: correlation,
        listener: state.config.label,
      ))
      let self = state.self
      let report = fn(progress, total, message) {
        let _ =
          process.call(self, waiting: call_timeout, sending: fn(reply) {
            WorkerProgress(id, progress, total, message, reply)
          })
        Nil
      }
      let invocation_id = reducer.invocation_id(invocation)
      let pid =
        process.spawn_unlinked(fn() {
          let input = case
            rescue_run(fn() { reducer.perform(invocation, report) })
          {
            Ok(input) -> input
            Error(_) -> reducer.Crashed(invocation_id)
          }
          process.send(self, WorkerFinished(id, input))
        })
      let monitor = process.monitor(pid)
      let timer =
        process.send_after(
          self,
          duration.to_milliseconds(state.config.invocation_timeout),
          WorkerTimeout(id),
        )
      let worker =
        Worker(
          invocation: invocation_id,
          pid: pid,
          monitor: monitor,
          timer: timer,
          started_at: monotonic_ms(),
          exchange: exchange,
          method: method,
          tool: tool,
          correlation: correlation,
        )
      State(..state, workers: dict.insert(state.workers, id, worker))
    }
  }
}

fn finish_worker(
  state: State(context),
  id: Int,
  input: reducer.Input(context),
) -> State(context) {
  case dict.get(state.workers, id) {
    Error(Nil) -> state
    Ok(worker) -> {
      let state = remove_worker(state, id, worker)
      case input {
        reducer.Finished(_, outcome) ->
          emit.invocation_completed(
            int.max(0, monotonic_ms() - worker.started_at),
            telemetry.InvocationCompletedMeta(
              exchange_id: worker.exchange,
              invocation_id: id,
              method: worker.method,
              tool: worker.tool,
              status: reducer.outcome_status(outcome),
              correlation: worker.correlation,
              listener: state.config.label,
            ),
          )
        _ ->
          emit.invocation_crashed(crash_meta(
            state,
            id,
            worker,
            telemetry.HandlerCrashed,
          ))
      }
      apply(state, input)
    }
  }
}

fn crash_meta(
  state: State(context),
  id: Int,
  worker: Worker,
  reason: telemetry.CrashReason,
) -> telemetry.InvocationCrashedMeta {
  telemetry.InvocationCrashedMeta(
    invocation_id: id,
    method: worker.method,
    tool: worker.tool,
    reason: reason,
    correlation: worker.correlation,
    listener: state.config.label,
  )
}

fn remove_worker(
  state: State(context),
  id: Int,
  worker: Worker,
) -> State(context) {
  let _ = process.cancel_timer(worker.timer)
  let _ = process.demonitor_process(worker.monitor)
  remember(State(..state, workers: dict.delete(state.workers, id)), id)
}

// Signals the handler, then kills it after the grace period unless it
// returns first. Its monitor stays, so the runtime sees it exit.
fn cancel_worker(
  state: State(context),
  id: Int,
  worker: Worker,
) -> State(context) {
  reducer.signal_cancelled(worker.pid, worker.invocation)
  let _ = process.cancel_timer(worker.timer)
  let state =
    remember(State(..state, workers: dict.delete(state.workers, id)), id)
  let grace = duration.to_milliseconds(state.config.cancellation_grace)
  case grace <= 0 {
    True -> {
      process.kill(worker.pid)
      let _ = process.demonitor_process(worker.monitor)
      state
    }
    False -> {
      let kill =
        process.send_after(state.self, grace, KillAfterGrace(worker.pid))
      let cancelling = Cancelling(monitor: worker.monitor, kill: kill)
      State(
        ..state,
        cancelling: dict.insert(state.cancelling, worker.pid, cancelling),
      )
    }
  }
}

fn remember(state: State(context), id: Int) -> State(context) {
  case dict.has_key(state.tombstones, id) {
    True -> state
    False -> {
      let _ =
        process.send_after(
          state.self,
          duration.to_milliseconds(state.config.tombstone_retention),
          ExpireTombstone(id),
        )
      let order = [id, ..state.tombstone_order]
      let tombstones = dict.insert(state.tombstones, id, Nil)
      case list.length(order) > state.config.max_tombstones {
        False -> State(..state, tombstones: tombstones, tombstone_order: order)
        True -> {
          let #(kept, dropped) = list.split(order, state.config.max_tombstones)
          State(
            ..state,
            tombstones: dict.drop(tombstones, dropped),
            tombstone_order: kept,
          )
        }
      }
    }
  }
}

fn close_all(state: State(context)) -> State(context) {
  let state =
    dict.fold(state.workers, state, fn(state, id, worker) {
      emit.invocation_cancelled(telemetry.InvocationCancelledMeta(
        invocation_id: id,
        method: worker.method,
        tool: worker.tool,
        correlation: worker.correlation,
        listener: state.config.label,
      ))
      cancel_worker(state, id, worker)
    })
  State(..state, closed: True)
}

fn find_worker_by_pid(
  workers: Dict(Int, Worker),
  pid: Pid,
) -> Result(#(Int, Worker), Nil) {
  dict.to_list(workers)
  |> list.find(fn(entry) {
    let #(_, worker) = entry
    worker.pid == pid
  })
}
