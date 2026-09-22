import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import relay/protocol/jsonrpc.{type RequestId}
import relay/server.{type ExchangeId, type InvocationId, type Server}
import relay/telemetry
import relay/tool.{type ContextTool, type ToolName}

pub type RuntimeConfig {
  RuntimeConfig(
    max_live_exchanges: Int,
    max_frame_bytes: Int,
    invocation_timeout_ms: Int,
    tombstone_retention_ms: Int,
  )
}

pub fn default_config() -> RuntimeConfig {
  RuntimeConfig(
    max_live_exchanges: 100,
    max_frame_bytes: 1_048_576,
    invocation_timeout_ms: 30_000,
    tombstone_retention_ms: 60_000,
  )
}

pub type RuntimeError {
  FrameTooLarge(size: Int, limit: Int)
  TooManyLiveExchanges(current: Int, limit: Int)
  RuntimeStopped
}

pub type RuntimeMessage(context) {
  ReceiveFrame(
    exchange: ExchangeId,
    context: context,
    bytes: BitArray,
    reply: Subject(Result(Nil, RuntimeError)),
  )
  WorkerFinished(
    invocation_id: InvocationId,
    exchange_id: ExchangeId,
    outcome: server.InvocationOutcome,
  )
  WorkerProgress(
    invocation_id: InvocationId,
    exchange_id: ExchangeId,
    value: Int,
    reply: Subject(Nil),
  )
  WorkerCrashed(
    invocation_id: InvocationId,
    exchange_id: ExchangeId,
    reason: String,
  )
  WorkerTimeout(invocation_id: InvocationId, exchange_id: ExchangeId)
  ProcessDownMessage(down: process.Down)
  ExpireTombstone(invocation_id: InvocationId)
  NotifyResource(uri: String)
  NotifyToolsChanged
  NotifyResourcesChanged
  NotifyPromptsChanged
  RegisterDynamicTool(tool: ContextTool(context))
  UnregisterDynamicTool(name: ToolName)
  TerminateSubscriptionStream(id: RequestId)
  Close
  Stop(reply: Subject(Nil))
}

type WorkerHandle {
  WorkerHandle(
    invocation_id: InvocationId,
    exchange_id: ExchangeId,
    pid: Pid,
    monitor: process.Monitor,
    timer: process.Timer,
    started_at: Int,
  )
}

type RuntimeState(context) {
  RuntimeState(
    config: RuntimeConfig,
    server: Server(context),
    write_sink: fn(BitArray) -> Result(Nil, Nil),
    workers: List(WorkerHandle),
    tombstones: List(InvocationId),
    live_exchanges: Int,
    is_closed: Bool,
    self_subject: Subject(RuntimeMessage(context)),
  )
}

pub opaque type Runtime(context) {
  Runtime(subject: Subject(RuntimeMessage(context)))
}

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn ffi_monotonic_time_ms() -> Int

@external(erlang, "relay_ffi", "rescue_run")
fn ffi_rescue_run(fun: fn() -> a) -> Result(a, String)

/// Starts the authoritative OTP runtime owner.
pub fn start(
  server: Server(context),
  config: RuntimeConfig,
  write_sink: fn(BitArray) -> Nil,
) -> Result(Runtime(context), actor.StartError) {
  start_with_status_sink(server, config, fn(bytes) {
    write_sink(bytes)
    Ok(Nil)
  })
}

/// Starts the runtime with a writer that can report transport failure.
/// Returning `Error(Nil)` closes the runtime and cancels active invocations.
pub fn start_with_status_sink(
  server: Server(context),
  config: RuntimeConfig,
  write_sink: fn(BitArray) -> Result(Nil, Nil),
) -> Result(Runtime(context), actor.StartError) {
  let builder =
    actor.new_with_initialiser(5000, fn(self_subject) {
      let selector =
        process.new_selector()
        |> process.select(for: self_subject)
        |> process.select_monitors(fn(down) { ProcessDownMessage(down) })

      let state =
        RuntimeState(
          config: config,
          server: server,
          write_sink: write_sink,
          workers: [],
          tombstones: [],
          live_exchanges: 0,
          is_closed: False,
          self_subject: self_subject,
        )

      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(self_subject)
      |> Ok
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> Ok(Runtime(started.data))
    Error(err) -> Error(err)
  }
}

/// Synchronously submits a frame to the runtime owner with bound checks.
pub fn send_frame(
  runtime: Runtime(context),
  exchange: ExchangeId,
  context: context,
  bytes: BitArray,
  timeout_ms: Int,
) -> Result(Nil, RuntimeError) {
  let Runtime(subject) = runtime
  process.call(subject, waiting: timeout_ms, sending: fn(reply) {
    ReceiveFrame(exchange, context, bytes, reply)
  })
}

/// Signals the connection is closed.
pub fn close(runtime: Runtime(context)) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, Close)
}

/// Stops the runtime actor gracefully.
pub fn stop(runtime: Runtime(context), timeout_ms: Int) -> Nil {
  let Runtime(subject) = runtime
  process.call(subject, waiting: timeout_ms, sending: Stop)
}

/// Notifies that a resource has changed, sending notifications to all active subscribers.
pub fn notify_resource_updated(runtime: Runtime(context), uri: String) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, NotifyResource(uri))
}

/// Notifies that the list of available tools has changed.
pub fn notify_tools_list_changed(runtime: Runtime(context)) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, NotifyToolsChanged)
}

/// Notifies that the list of available resources has changed.
pub fn notify_resources_list_changed(runtime: Runtime(context)) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, NotifyResourcesChanged)
}

/// Notifies that the list of available prompts has changed.
pub fn notify_prompts_list_changed(runtime: Runtime(context)) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, NotifyPromptsChanged)
}

/// Dynamically registers a new tool and notifies subscribers if tools list changed.
pub fn register_tool(
  runtime: Runtime(context),
  tool: ContextTool(context),
) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, RegisterDynamicTool(tool))
}

/// Dynamically unregisters a tool by name and notifies subscribers if tools list changed.
pub fn unregister_tool(runtime: Runtime(context), name: ToolName) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, UnregisterDynamicTool(name))
}

/// Gracefully terminates a subscription stream by JSON-RPC request ID.
pub fn terminate_subscription(runtime: Runtime(context), id: RequestId) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, TerminateSubscriptionStream(id))
}

fn handle_message(
  state: RuntimeState(context),
  msg: RuntimeMessage(context),
) -> actor.Next(RuntimeState(context), RuntimeMessage(context)) {
  case msg {
    ReceiveFrame(exchange, context, bytes, reply) -> {
      case state.is_closed {
        True -> {
          process.send(reply, Error(RuntimeStopped))
          actor.continue(state)
        }
        False -> {
          let byte_size = bit_array.byte_size(bytes)
          case byte_size > state.config.max_frame_bytes {
            True -> {
              telemetry.emit_frame_rejected(
                server.exchange_id_to_int(exchange),
                "frame exceeds configured limit",
              )
              process.send(
                reply,
                Error(FrameTooLarge(byte_size, state.config.max_frame_bytes)),
              )
              actor.continue(state)
            }
            False -> {
              case server.exchange_is_known(state.server, exchange) {
                True -> {
                  process.send(reply, Ok(Nil))
                  actor.continue(state)
                }
                False -> {
                  case state.live_exchanges >= state.config.max_live_exchanges {
                    True -> {
                      telemetry.emit_frame_rejected(
                        server.exchange_id_to_int(exchange),
                        "live exchanges exceed configured limit",
                      )
                      process.send(
                        reply,
                        Error(TooManyLiveExchanges(
                          state.live_exchanges,
                          state.config.max_live_exchanges,
                        )),
                      )
                      actor.continue(state)
                    }
                    False -> {
                      let st_inc =
                        RuntimeState(
                          ..state,
                          live_exchanges: state.live_exchanges + 1,
                        )
                      let #(next_server, effects) =
                        server.step(
                          st_inc.server,
                          server.MessageReceived(exchange, context, bytes),
                        )
                      let next_st =
                        interpret_effects(
                          RuntimeState(..st_inc, server: next_server),
                          effects,
                        )
                      process.send(reply, Ok(Nil))
                      actor.continue(next_st)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    WorkerProgress(inv_id, ex_id, value, reply) -> {
      let next_st = handle_worker_progress(state, inv_id, ex_id, value)
      process.send(reply, Nil)
      actor.continue(next_st)
    }

    WorkerFinished(inv_id, ex_id, outcome) -> {
      let next_st = handle_worker_finished(state, inv_id, ex_id, outcome)
      actor.continue(next_st)
    }

    WorkerCrashed(inv_id, ex_id, reason) -> {
      let next_st = handle_worker_crashed(state, inv_id, ex_id, reason)
      actor.continue(next_st)
    }

    WorkerTimeout(inv_id, ex_id) -> {
      let next_st = handle_worker_timeout(state, inv_id, ex_id)
      actor.continue(next_st)
    }

    ProcessDownMessage(down) -> {
      let next_st = handle_process_down(state, down)
      actor.continue(next_st)
    }

    ExpireTombstone(inv_id) -> {
      let next_st = handle_expire_tombstone(state, inv_id)
      actor.continue(next_st)
    }

    NotifyResource(uri) -> {
      let #(next_server, effects) =
        server.step(state.server, server.NotifyResourceUpdated(uri))
      let next_st =
        interpret_effects(RuntimeState(..state, server: next_server), effects)
      actor.continue(next_st)
    }

    NotifyToolsChanged -> {
      let #(next_server, effects) =
        server.step(state.server, server.NotifyToolsListChanged)
      let next_st =
        interpret_effects(RuntimeState(..state, server: next_server), effects)
      actor.continue(next_st)
    }

    NotifyResourcesChanged -> {
      let #(next_server, effects) =
        server.step(state.server, server.NotifyResourcesListChanged)
      let next_st =
        interpret_effects(RuntimeState(..state, server: next_server), effects)
      actor.continue(next_st)
    }

    NotifyPromptsChanged -> {
      let #(next_server, effects) =
        server.step(state.server, server.NotifyPromptsListChanged)
      let next_st =
        interpret_effects(RuntimeState(..state, server: next_server), effects)
      actor.continue(next_st)
    }

    RegisterDynamicTool(tool) -> {
      let #(next_server, effects) =
        server.step(state.server, server.RegisterTool(tool))
      let next_st =
        interpret_effects(RuntimeState(..state, server: next_server), effects)
      actor.continue(next_st)
    }

    UnregisterDynamicTool(name) -> {
      let #(next_server, effects) =
        server.step(state.server, server.UnregisterTool(name))
      let next_st =
        interpret_effects(RuntimeState(..state, server: next_server), effects)
      actor.continue(next_st)
    }

    TerminateSubscriptionStream(id) -> {
      let #(next_server, effects) =
        server.step(state.server, server.TerminateSubscription(id))
      let next_st =
        interpret_effects(RuntimeState(..state, server: next_server), effects)
      actor.continue(next_st)
    }

    Close -> {
      let next_st = handle_close(state)
      actor.continue(next_st)
    }

    Stop(reply) -> {
      let _ = handle_close(state)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn interpret_effects(
  state: RuntimeState(context),
  effects: List(server.ServerEffect(context)),
) -> RuntimeState(context) {
  list.fold(effects, state, fn(st, eff) {
    case eff {
      server.Write(_ex, bytes) -> {
        case st.write_sink(bytes) {
          Ok(Nil) -> st
          Error(Nil) -> handle_close(st)
        }
      }
      server.StartInvocation(inv) -> {
        start_invocation(st, inv)
      }
      server.CancelInvocation(inv_id) -> {
        cancel_invocation(st, inv_id)
      }
      server.CloseExchange(ex) -> {
        telemetry.emit_exchange_closed(server.exchange_id_to_int(ex))
        RuntimeState(..st, live_exchanges: int.max(0, st.live_exchanges - 1))
      }
      server.SendProgress(_ex, _token, _val) -> {
        st
      }
      server.EmitRequestAdmitted(ex_id, method) -> {
        telemetry.emit_request_admitted(
          server.exchange_id_to_int(ex_id),
          method,
        )
        st
      }
      server.Ignore(_) -> st
    }
  })
}

fn start_invocation(
  state: RuntimeState(context),
  inv: server.Invocation(context),
) -> RuntimeState(context) {
  let inv_id = server.invocation_id(inv)
  let ex_id = server.invocation_exchange(inv)
  case state.is_closed, list.contains(state.tombstones, inv_id) {
    True, _ | False, True -> state
    False, False ->
      case find_worker(state.workers, inv_id) {
        Some(_) -> state
        None -> {
          let now = ffi_monotonic_time_ms()
          let inv_id_int = server.invocation_id_to_int(inv_id)
          let ex_id_int = server.exchange_id_to_int(ex_id)
          telemetry.emit_invocation_started(
            ex_id_int,
            inv_id_int,
            server.invocation_method(inv),
          )

          let self_subj = state.self_subject
          let inv =
            server.invocation_with_progress(inv, fn(value) {
              process.call_forever(self_subj, fn(reply) {
                WorkerProgress(inv_id, ex_id, value, reply)
              })
            })
          let timer =
            process.send_after(
              self_subj,
              state.config.invocation_timeout_ms,
              WorkerTimeout(inv_id, ex_id),
            )

          let worker_pid =
            process.spawn_unlinked(fn() {
              let res = ffi_rescue_run(fn() { server.perform(inv) })
              case res {
                Ok(server.InvocationFinished(_, outcome)) -> {
                  process.send(
                    self_subj,
                    WorkerFinished(inv_id, ex_id, outcome),
                  )
                }
                Error(reason) -> {
                  process.send(self_subj, WorkerCrashed(inv_id, ex_id, reason))
                }
                _ -> {
                  process.send(
                    self_subj,
                    WorkerCrashed(inv_id, ex_id, "unknown worker return"),
                  )
                }
              }
            })

          let worker_mon = process.monitor(worker_pid)
          let handle =
            WorkerHandle(
              invocation_id: inv_id,
              exchange_id: ex_id,
              pid: worker_pid,
              monitor: worker_mon,
              timer: timer,
              started_at: now,
            )
          RuntimeState(..state, workers: [handle, ..state.workers])
        }
      }
  }
}

fn cancel_invocation(
  state: RuntimeState(context),
  inv_id: server.InvocationId,
) -> RuntimeState(context) {
  case find_worker(state.workers, inv_id) {
    None -> RuntimeState(..state, tombstones: [inv_id, ..state.tombstones])
    Some(handle) -> {
      let _ = process.cancel_timer(handle.timer)
      let _ = process.demonitor_process(handle.monitor)
      process.kill(handle.pid)
      telemetry.emit_invocation_cancelled(server.invocation_id_to_int(inv_id))
      let new_workers = remove_worker(state.workers, inv_id)
      let new_tombstones = [inv_id, ..state.tombstones]
      process.send_after(
        state.self_subject,
        state.config.tombstone_retention_ms,
        ExpireTombstone(inv_id),
      )
      RuntimeState(..state, workers: new_workers, tombstones: new_tombstones)
    }
  }
}

fn handle_worker_progress(
  state: RuntimeState(context),
  inv_id: server.InvocationId,
  _ex_id: server.ExchangeId,
  value: Int,
) -> RuntimeState(context) {
  case
    list.contains(state.tombstones, inv_id),
    find_worker(state.workers, inv_id)
  {
    True, _ | _, None -> state
    False, Some(_) -> {
      let #(next_server, effects) =
        server.step(state.server, server.InvocationProgress(inv_id, value))
      interpret_effects(RuntimeState(..state, server: next_server), effects)
    }
  }
}

fn handle_worker_finished(
  state: RuntimeState(context),
  inv_id: server.InvocationId,
  ex_id: server.ExchangeId,
  outcome: server.InvocationOutcome,
) -> RuntimeState(context) {
  case list.contains(state.tombstones, inv_id) {
    True -> state
    False ->
      case find_worker(state.workers, inv_id) {
        None -> state
        Some(handle) -> {
          let _ = process.cancel_timer(handle.timer)
          let _ = process.demonitor_process(handle.monitor)
          let now = ffi_monotonic_time_ms()
          let duration = int.max(0, now - handle.started_at)
          let status_str = case outcome {
            server.OutcomeSuccess(_) -> "success"
            server.OutcomeContentSuccess(_) -> "success"
            server.OutcomeStructuredContentSuccess(_, _) -> "success"
            _ -> "error"
          }
          telemetry.emit_invocation_completed(
            server.exchange_id_to_int(ex_id),
            server.invocation_id_to_int(inv_id),
            duration,
            status_str,
          )
          let new_workers = remove_worker(state.workers, inv_id)
          let new_tombstones = [inv_id, ..state.tombstones]
          process.send_after(
            state.self_subject,
            state.config.tombstone_retention_ms,
            ExpireTombstone(inv_id),
          )
          let st_cleaned =
            RuntimeState(
              ..state,
              workers: new_workers,
              tombstones: new_tombstones,
            )
          let #(next_server, effects) =
            server.step(
              st_cleaned.server,
              server.InvocationFinished(inv_id, outcome),
            )
          interpret_effects(
            RuntimeState(..st_cleaned, server: next_server),
            effects,
          )
        }
      }
  }
}

fn handle_worker_crashed(
  state: RuntimeState(context),
  inv_id: server.InvocationId,
  _ex_id: server.ExchangeId,
  reason: String,
) -> RuntimeState(context) {
  case list.contains(state.tombstones, inv_id) {
    True -> state
    False ->
      case find_worker(state.workers, inv_id) {
        None -> state
        Some(handle) -> {
          let _ = process.cancel_timer(handle.timer)
          let _ = process.demonitor_process(handle.monitor)
          telemetry.emit_invocation_crashed(
            server.invocation_id_to_int(inv_id),
            reason,
          )
          let new_workers = remove_worker(state.workers, inv_id)
          let new_tombstones = [inv_id, ..state.tombstones]
          process.send_after(
            state.self_subject,
            state.config.tombstone_retention_ms,
            ExpireTombstone(inv_id),
          )
          let st_cleaned =
            RuntimeState(
              ..state,
              workers: new_workers,
              tombstones: new_tombstones,
            )
          let outcome =
            server.OutcomeInternalError("Internal error: handler crashed")
          let #(next_server, effects) =
            server.step(
              st_cleaned.server,
              server.InvocationFinished(inv_id, outcome),
            )
          interpret_effects(
            RuntimeState(..st_cleaned, server: next_server),
            effects,
          )
        }
      }
  }
}

fn handle_worker_timeout(
  state: RuntimeState(context),
  inv_id: server.InvocationId,
  _ex_id: server.ExchangeId,
) -> RuntimeState(context) {
  case find_worker(state.workers, inv_id) {
    None -> state
    Some(handle) -> {
      let _ = process.demonitor_process(handle.monitor)
      process.kill(handle.pid)
      telemetry.emit_invocation_crashed(
        server.invocation_id_to_int(inv_id),
        "timeout",
      )
      let new_workers = remove_worker(state.workers, inv_id)
      let new_tombstones = [inv_id, ..state.tombstones]
      process.send_after(
        state.self_subject,
        state.config.tombstone_retention_ms,
        ExpireTombstone(inv_id),
      )
      let st_cleaned =
        RuntimeState(..state, workers: new_workers, tombstones: new_tombstones)
      let outcome = server.OutcomeInternalError("Invocation timed out")
      let #(next_server, effects) =
        server.step(
          st_cleaned.server,
          server.InvocationFinished(inv_id, outcome),
        )
      interpret_effects(
        RuntimeState(..st_cleaned, server: next_server),
        effects,
      )
    }
  }
}

fn handle_process_down(
  state: RuntimeState(context),
  down: process.Down,
) -> RuntimeState(context) {
  case down {
    process.ProcessDown(monitor, pid, reason) -> {
      case find_worker_by_monitor_or_pid(state.workers, monitor, pid) {
        None -> state
        Some(handle) -> {
          case reason {
            process.Normal -> state
            _ ->
              handle_worker_crashed(
                state,
                handle.invocation_id,
                handle.exchange_id,
                "process exited abnormally",
              )
          }
        }
      }
    }
    _ -> state
  }
}

fn handle_expire_tombstone(
  state: RuntimeState(context),
  inv_id: server.InvocationId,
) -> RuntimeState(context) {
  let new_tombstones = list.filter(state.tombstones, fn(id) { id != inv_id })
  RuntimeState(..state, tombstones: new_tombstones)
}

fn handle_close(state: RuntimeState(context)) -> RuntimeState(context) {
  list.each(state.workers, fn(w) {
    let _ = process.cancel_timer(w.timer)
    let _ = process.demonitor_process(w.monitor)
    process.kill(w.pid)
    telemetry.emit_invocation_cancelled(server.invocation_id_to_int(
      w.invocation_id,
    ))
  })
  RuntimeState(..state, workers: [], is_closed: True)
}

fn find_worker(
  workers: List(WorkerHandle),
  target: InvocationId,
) -> Option(WorkerHandle) {
  case workers {
    [] -> None
    [w, ..rest] ->
      case w.invocation_id == target {
        True -> Some(w)
        False -> find_worker(rest, target)
      }
  }
}

fn find_worker_by_monitor_or_pid(
  workers: List(WorkerHandle),
  monitor: process.Monitor,
  pid: Pid,
) -> Option(WorkerHandle) {
  case workers {
    [] -> None
    [w, ..rest] ->
      case w.monitor == monitor || w.pid == pid {
        True -> Some(w)
        False -> find_worker_by_monitor_or_pid(rest, monitor, pid)
      }
  }
}

fn remove_worker(
  workers: List(WorkerHandle),
  target: InvocationId,
) -> List(WorkerHandle) {
  list.filter(workers, fn(w) { w.invocation_id != target })
}
