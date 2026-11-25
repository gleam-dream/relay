//// The client side of the stdio transport: one child process, one request
//// at a time, newline framing, and listen streams read from the same pipe.
////
//// A request belongs to its caller. The actor writes it only while the
//// caller still waits: a request whose deadline passed, whose caller
//// cancelled or whose caller exited before its turn is answered without
//// being written. While a request is in flight the actor monitors its
//// caller and cancels the request when the caller exits. The ids of
//// requests given up in flight are remembered, so a response that crosses
//// the cancellation on the pipe is dropped instead of being taken for the
//// next request's answer. A wait for a notification serves requests that
//// arrive meanwhile.
////
//// The command is held in a closure, so `string.inspect` and crash reports
//// print a function reference instead of the executable and its arguments.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import relay/internal/stdio_frames.{
  type Framer, Frame, FrameOversized, InvalidTrailingBytes, feed_framer,
  new_framer,
}

const max_buffered_frames = 256

// How many given-up request ids are remembered. Ids are unique per request,
// so forgetting the oldest only matters for a response more than this many
// cancellations late.
const max_abandoned = 256

/// Why a request failed.
pub type Failure {
  /// No child is running: it never started or it exited earlier.
  NotRunning
  /// Too many calls are already waiting for the child.
  Busy(limit: Int)
  TimedOut
  /// The request's time ran out while it waited for its turn; it was never
  /// written to the child.
  TimedOutUnsent
  /// The child exited while the request was in flight.
  Exited
  /// The client was closed while the request was in flight.
  ClientClosed
  /// The caller cancelled the request; the child was told.
  Cancelled
  /// The caller cancelled the request while it waited for its turn; it was
  /// never written to the child.
  CancelledUnsent
  TooLarge(limit: Int)
  Malformed(detail: String)
}

pub opaque type Client {
  Client(subject: Subject(Message))
}

type Message {
  OpenPort(command: fn() -> Command, reply: Subject(Result(Nil, Nil)))
  Request(
    bytes: BitArray,
    id: String,
    /// Monotonic milliseconds after which the caller no longer waits.
    deadline: Int,
    max_pending: Int,
    reply: Subject(Result(BitArray, Failure)),
  )
  /// The caller of `id` gave up, whether the request is in flight, still
  /// waiting or already answered.
  CancelInFlight(id: String)
  /// The caller of the exchange in progress exited.
  CallerDown
  Subscribe(
    bytes: BitArray,
    id: String,
    timeout_ms: Int,
    reply: Subject(Result(BitArray, Failure)),
  )
  NextNotification(
    id: String,
    timeout_ms: Int,
    reply: Subject(Result(Option(BitArray), Failure)),
  )
  CancelSubscription(id: String, reply: Subject(Nil))
  ClientPortMessage(PortMessage)
  CloseClient(reply: Subject(Nil))
}

type PortMessage {
  PortData(BitArray)
  PortExit(Int)
}

type State {
  State(
    port: Option(Pid),
    framer: Framer,
    frames: List(BitArray),
    notifications: List(BitArray),
    closed_subscriptions: List(String),
    /// Ids of requests whose caller gave up, newest first, at most
    /// `max_abandoned`.
    abandoned: List(String),
    subject: Subject(Message),
    max_frame_bytes: Int,
  )
}

/// What to launch: the executable, its arguments, and the variables added
/// to the child's allow-listed environment.
pub type Command {
  Command(
    executable: String,
    arguments: List(String),
    environment: List(#(String, String)),
  )
}

@external(erlang, "relay_ffi", "start_stdio_client_port")
fn start_port(
  executable: String,
  args: List(String),
  environment: List(#(String, String)),
  subject: Subject(Message),
) -> Result(Pid, String)

@external(erlang, "relay_ffi", "send_stdio_client_command")
fn send_command(port: Pid, bytes: BitArray) -> Nil

@external(erlang, "relay_ffi", "close_stdio_client_port")
fn close_port_owner(port: Pid) -> Nil

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn monotonic_ms() -> Int

@external(erlang, "relay_ffi", "mailbox_size")
fn mailbox_size(pid: Pid) -> Int

/// Starts the child. `command` returns what to launch; the executable is
/// launched directly, never through a shell, with an allow-listed
/// environment and the command's own variables.
pub fn connect(
  command: fn() -> Command,
  timeout_ms: Int,
  max_frame_bytes: Int,
) -> Result(Client, Nil) {
  let started =
    actor.new_with_initialiser(5000, fn(subject) {
      State(
        port: None,
        framer: new_framer(max_frame_bytes),
        frames: [],
        notifications: [],
        closed_subscriptions: [],
        abandoned: [],
        subject: subject,
        max_frame_bytes: max_frame_bytes,
      )
      |> actor.initialised
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.start
  case started {
    Error(_) -> Error(Nil)
    Ok(started) -> {
      let client = Client(started.data)
      let reply = process.new_subject()
      process.send(started.data, OpenPort(command, reply))
      case process.receive(reply, timeout_ms + 1000) {
        Ok(Ok(Nil)) -> Ok(client)
        _ -> {
          close(client)
          Error(Nil)
        }
      }
    }
  }
}

/// Writes one frame and waits for its response. `cancelled` is polled while
/// waiting; when it turns true the child receives `notifications/cancelled`.
pub fn request(
  client: Client,
  bytes: BitArray,
  id: String,
  timeout_ms: Int,
  max_bytes: Int,
  max_pending: Int,
  cancelled: fn() -> Bool,
) -> Result(BitArray, Failure) {
  let Client(subject) = client
  let busy = case process.subject_owner(subject) {
    Ok(owner) -> mailbox_size(owner) >= max_pending
    Error(Nil) -> False
  }
  case busy, cancelled() {
    True, _ -> Error(Busy(max_pending))
    _, True -> Error(Cancelled)
    False, False -> {
      let reply = process.new_subject()
      let deadline = monotonic_ms() + timeout_ms
      process.send(subject, Request(bytes, id, deadline, max_pending, reply))
      await_reply(subject, reply, id, deadline + 1000, cancelled)
      |> result.try(within(_, max_bytes))
    }
  }
}

const poll_ms = 50

fn await_reply(
  subject: Subject(Message),
  reply: Subject(Result(BitArray, Failure)),
  id: String,
  deadline: Int,
  cancelled: fn() -> Bool,
) -> Result(BitArray, Failure) {
  case process.receive(reply, poll_ms) {
    Ok(result) -> result
    Error(Nil) ->
      case cancelled(), monotonic_ms() > deadline {
        True, _ -> {
          process.send(subject, CancelInFlight(id))
          case process.receive(reply, 1000) {
            Ok(Ok(frame)) -> Ok(frame)
            Ok(Error(CancelledUnsent)) -> Error(CancelledUnsent)
            _ -> Error(Cancelled)
          }
        }
        False, True -> Error(TimedOut)
        False, False -> await_reply(subject, reply, id, deadline, cancelled)
      }
  }
}

fn within(frame: BitArray, max_bytes: Int) -> Result(BitArray, Failure) {
  case bit_array.byte_size(frame) > max_bytes {
    True -> Error(TooLarge(max_bytes))
    False -> Ok(frame)
  }
}

/// Opens a `subscriptions/listen` exchange and returns its acknowledgement.
pub fn subscribe(
  client: Client,
  bytes: BitArray,
  id: String,
  timeout_ms: Int,
  max_bytes: Int,
) -> Result(BitArray, Failure) {
  let Client(subject) = client
  let reply = process.new_subject()
  process.send(subject, Subscribe(bytes, id, timeout_ms, reply))
  case process.receive(reply, timeout_ms + 1000) {
    Ok(result) -> result.try(result, within(_, max_bytes))
    Error(Nil) -> Error(TimedOut)
  }
}

/// The next notification of one listen exchange, or `None` when none
/// arrived within the wait.
pub fn next_notification(
  client: Client,
  id: String,
  timeout_ms: Int,
  max_bytes: Int,
) -> Result(Option(BitArray), Failure) {
  let Client(subject) = client
  let reply = process.new_subject()
  process.send(subject, NextNotification(id, timeout_ms, reply))
  case process.receive(reply, timeout_ms + 1000) {
    Ok(Ok(Some(frame))) -> within(frame, max_bytes) |> result.map(Some)
    Ok(other) -> other
    Error(Nil) -> Ok(None)
  }
}

/// Ends one listen exchange; the child stays running.
pub fn cancel_subscription(client: Client, id: String) -> Nil {
  let Client(subject) = client
  let reply = process.new_subject()
  process.send(subject, CancelSubscription(id, reply))
  let _ = process.receive(reply, 1000)
  Nil
}

/// Closes the child and stops the client.
pub fn close(client: Client) -> Nil {
  let Client(subject) = client
  case process.subject_owner(subject) {
    Error(Nil) -> Nil
    Ok(owner) ->
      case process.is_alive(owner) {
        False -> Nil
        True -> {
          let reply = process.new_subject()
          let monitor = process.monitor(owner)
          process.send(subject, CloseClient(reply))
          let _ =
            process.new_selector()
            |> process.select_map(reply, fn(_) { Nil })
            |> process.select_specific_monitor(monitor, fn(_) { Nil })
            |> process.selector_receive(within: 1000)
          let _ = process.demonitor_process(monitor)
          Nil
        }
      }
  }
}

// --- actor -------------------------------------------------------------------

type Await {
  Answered(frame: BitArray, state: State, queued: List(Message))
  Failed(failure: Failure, state: State, queued: List(Message))
  CloseRequested(failure: Failure, state: State, queued: List(Message))
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    OpenPort(command, reply) -> {
      let Command(executable, args, environment) = command()
      case start_port(executable, args, environment, state.subject) {
        Error(_) -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
        Ok(port) -> {
          process.send(reply, Ok(Nil))
          actor.continue(State(..state, port: Some(port)))
        }
      }
    }
    Request(bytes, id, deadline, _, reply) ->
      case admit(state, id, deadline, reply) {
        Error(#(failure, state)) -> {
          process.send(reply, Error(failure))
          actor.continue(state)
        }
        Ok(#(port, caller)) ->
          settle(
            state,
            exchange(state, port, caller, bytes, id, deadline, []),
            reply_to(reply),
          )
      }
    Subscribe(bytes, id, timeout_ms, reply) ->
      case state.port {
        None -> {
          process.send(reply, Error(NotRunning))
          actor.continue(state)
        }
        Some(port) -> {
          send_command(port, bit_array.append(bytes, <<"\n">>))
          let deadline = monotonic_ms() + timeout_ms
          settle(
            state,
            await_notification(state, deadline, id, [], mailbox(state)),
            reply_to(reply),
          )
        }
      }
    NextNotification(id, timeout_ms, reply) ->
      case list.contains(state.closed_subscriptions, id) {
        True -> {
          process.send(reply, Error(NotRunning))
          actor.continue(state)
        }
        False -> {
          let deadline = monotonic_ms() + timeout_ms
          // A listener that exits stops its wait, like a wait that ran out.
          let #(selector, monitor) = case process.subject_owner(reply) {
            Ok(listener) -> {
              let monitor = process.monitor(listener)
              #(watching(state, monitor), Some(monitor))
            }
            Error(Nil) -> #(mailbox(state), None)
          }
          let outcome = await_notification(state, deadline, id, [], selector)
          option.map(monitor, process.demonitor_process)
          case outcome {
            Answered(frame, next, queued) -> {
              process.send(reply, Ok(Some(frame)))
              requeue(next, queued)
            }
            Failed(TimedOut, next, queued) -> {
              process.send(reply, Ok(None))
              requeue(next, queued)
            }
            other ->
              settle(
                state,
                other,
                #(
                  fn(frame) { process.send(reply, Ok(Some(frame))) },
                  fn(failure) { process.send(reply, Error(failure)) },
                ),
              )
          }
        }
      }
    CancelSubscription(id, reply) -> {
      case state.port, list.contains(state.closed_subscriptions, id) {
        Some(port), False -> send_command(port, cancellation_frame(id))
        _, _ -> Nil
      }
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          frames: list.filter(state.frames, fn(frame) { !belongs_to(frame, id) }),
          notifications: list.filter(state.notifications, fn(frame) {
            !belongs_to(frame, id)
          }),
          closed_subscriptions: [id, ..state.closed_subscriptions],
        ),
      )
    }
    // The request is still waiting in the mailbox, or was already answered.
    CancelInFlight(id) -> actor.continue(abandon(state, id))
    // The monitor of a finished exchange; nothing is in progress.
    CallerDown -> actor.continue(state)
    ClientPortMessage(PortData(chunk)) ->
      case collect(state, chunk) {
        Ok(state) -> actor.continue(state)
        Error(_) -> actor.continue(reset(state))
      }
    ClientPortMessage(PortExit(_)) ->
      actor.continue(reset(State(..state, port: None)))
    CloseClient(reply) -> {
      close_port(state.port)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn reply_to(
  reply: Subject(Result(BitArray, Failure)),
) -> #(fn(BitArray) -> Nil, fn(Failure) -> Nil) {
  #(fn(frame) { process.send(reply, Ok(frame)) }, fn(failure) {
    process.send(reply, Error(failure))
  })
}

fn settle(
  state: State,
  outcome: Await,
  reply: #(fn(BitArray) -> Nil, fn(Failure) -> Nil),
) -> actor.Next(State, Message) {
  let #(answer, fail) = reply
  case outcome {
    Answered(frame, next, queued) -> {
      answer(frame)
      requeue(next, queued)
    }
    Failed(Cancelled, next, queued) -> {
      fail(Cancelled)
      requeue(next, queued)
    }
    Failed(failure, failed, queued) -> {
      close_port(failed.port)
      fail(failure)
      requeue(reset(State(..state, port: None)), queued)
    }
    CloseRequested(failure, _, queued) -> {
      close_port(state.port)
      fail(failure)
      reject_queued(queued)
      actor.stop()
    }
  }
}

fn requeue(state: State, queued: List(Message)) -> actor.Next(State, Message) {
  list.each(list.reverse(queued), fn(message) {
    process.send(state.subject, message)
  })
  actor.continue(state)
}

fn reject_queued(queued: List(Message)) -> Nil {
  list.each(queued, fn(message) {
    case message {
      OpenPort(_, reply) -> process.send(reply, Error(Nil))
      Request(reply: reply, ..) -> process.send(reply, Error(ClientClosed))
      Subscribe(reply: reply, ..) -> process.send(reply, Error(ClientClosed))
      NextNotification(reply: reply, ..) ->
        process.send(reply, Error(ClientClosed))
      CancelSubscription(_, reply) -> process.send(reply, Nil)
      CloseClient(reply) -> process.send(reply, Nil)
      CancelInFlight(_) | CallerDown | ClientPortMessage(_) -> Nil
    }
  })
}

// Decides whether a request is still worth writing when its turn comes.
// `Ok` carries the child and the caller to monitor.
fn admit(
  state: State,
  id: String,
  deadline: Int,
  reply: Subject(Result(BitArray, Failure)),
) -> Result(#(Pid, Pid), #(Failure, State)) {
  let caller = case process.subject_owner(reply) {
    Ok(caller) ->
      case process.is_alive(caller) {
        True -> Ok(caller)
        False -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
  case state.port, list.contains(state.abandoned, id), caller {
    None, _, _ -> Error(#(NotRunning, state))
    _, True, _ | _, _, Error(Nil) ->
      Error(#(
        CancelledUnsent,
        State(
          ..state,
          abandoned: list.filter(state.abandoned, fn(found) { found != id }),
        ),
      ))
    Some(port), False, Ok(caller) ->
      case monotonic_ms() >= deadline {
        True -> Error(#(TimedOutUnsent, state))
        False -> Ok(#(port, caller))
      }
  }
}

// Writes one admitted request and waits for its response while monitoring
// its caller.
fn exchange(
  state: State,
  port: Pid,
  caller: Pid,
  bytes: BitArray,
  id: String,
  deadline: Int,
  queued: List(Message),
) -> Await {
  send_command(port, bit_array.append(bytes, <<"\n">>))
  let monitor = process.monitor(caller)
  let outcome =
    await_response(state, deadline, id, queued, watching(state, monitor))
  process.demonitor_process(monitor)
  outcome
}

fn mailbox(state: State) -> process.Selector(Message) {
  process.new_selector() |> process.select(state.subject)
}

fn watching(
  state: State,
  monitor: process.Monitor,
) -> process.Selector(Message) {
  mailbox(state)
  |> process.select_specific_monitor(monitor, fn(_) { CallerDown })
}

fn abandon(state: State, id: String) -> State {
  case list.contains(state.abandoned, id) {
    True -> state
    False ->
      State(
        ..state,
        abandoned: list.take([id, ..state.abandoned], max_abandoned),
      )
  }
}

// Serves, in arrival order, the requests that queued up during a wait for a
// notification, then resumes that wait.
fn serve_queued(
  state: State,
  queued: List(Message),
  resume: fn(State, List(Message)) -> Await,
) -> Await {
  // `queued` is newest first; take the oldest request out of it.
  let #(earlier, from_request) =
    list.reverse(queued)
    |> list.split_while(fn(message) {
      case message {
        Request(..) -> False
        _ -> True
      }
    })
  case from_request {
    [Request(bytes, id, deadline, _, reply), ..later] ->
      serve(
        state,
        bytes,
        id,
        deadline,
        reply,
        list.reverse(list.append(earlier, later)),
        resume,
      )
    _ -> resume(state, queued)
  }
}

// Serves one request inside a wait for a notification. A failure that
// costs the child also ends the wait.
fn serve(
  state: State,
  bytes: BitArray,
  id: String,
  deadline: Int,
  reply: Subject(Result(BitArray, Failure)),
  queued: List(Message),
  resume: fn(State, List(Message)) -> Await,
) -> Await {
  case admit(state, id, deadline, reply) {
    Error(#(failure, state)) -> {
      process.send(reply, Error(failure))
      serve_queued(state, queued, resume)
    }
    Ok(#(port, caller)) ->
      case exchange(state, port, caller, bytes, id, deadline, queued) {
        Answered(frame, next, queued) -> {
          process.send(reply, Ok(frame))
          serve_queued(next, queued, resume)
        }
        Failed(Cancelled, next, queued) -> {
          process.send(reply, Error(Cancelled))
          serve_queued(next, queued, resume)
        }
        Failed(failure, ..) as failed -> {
          process.send(reply, Error(failure))
          failed
        }
        CloseRequested(failure, ..) as closing -> {
          process.send(reply, Error(failure))
          closing
        }
      }
  }
}

fn await_response(
  state: State,
  deadline: Int,
  id: String,
  queued: List(Message),
  selector: process.Selector(Message),
) -> Await {
  case state.frames {
    [frame, ..rest] ->
      case response_id(frame) {
        Error(detail) -> Failed(Malformed(detail), state, queued)
        Ok(Some(found)) if found == id ->
          Answered(frame, State(..state, frames: rest), queued)
        Ok(Some(found)) ->
          case list.contains(state.abandoned, found) {
            // The answer to a request its caller gave up on.
            True ->
              await_response(
                forget(State(..state, frames: rest), found),
                deadline,
                id,
                queued,
                selector,
              )
            False ->
              Failed(
                Malformed("the response id did not match the request"),
                state,
                queued,
              )
          }
        Ok(None) ->
          case enqueue_notification(State(..state, frames: rest), frame) {
            Error(detail) -> Failed(Malformed(detail), state, queued)
            Ok(next) -> await_response(next, deadline, id, queued, selector)
          }
      }
    [] ->
      receive(
        state,
        deadline,
        queued,
        fn(next, queued) {
          await_response(next, deadline, id, queued, selector)
        },
        Some(id),
        selector,
      )
  }
}

fn forget(state: State, id: String) -> State {
  State(
    ..state,
    abandoned: list.filter(state.abandoned, fn(found) { found != id }),
  )
}

fn is_abandoned_response(state: State, frame: BitArray) -> Bool {
  case response_id(frame) {
    Ok(Some(found)) -> list.contains(state.abandoned, found)
    _ -> False
  }
}

fn await_notification(
  state: State,
  deadline: Int,
  id: String,
  queued: List(Message),
  selector: process.Selector(Message),
) -> Await {
  case take_notification(state.notifications, id) {
    Ok(#(frame, rest)) ->
      Answered(frame, State(..state, notifications: rest), queued)
    Error(Nil) ->
      case state.frames {
        [frame, ..rest] ->
          case belongs_to(frame, id) {
            True -> Answered(frame, State(..state, frames: rest), queued)
            False ->
              case is_abandoned_response(state, frame) {
                True ->
                  await_notification(
                    State(..state, frames: rest),
                    deadline,
                    id,
                    queued,
                    selector,
                  )
                False ->
                  case
                    enqueue_notification(State(..state, frames: rest), frame)
                  {
                    Error(detail) -> Failed(Malformed(detail), state, queued)
                    Ok(next) ->
                      await_notification(next, deadline, id, queued, selector)
                  }
              }
          }
        [] ->
          receive(
            state,
            deadline,
            queued,
            fn(next, queued) {
              await_notification(next, deadline, id, queued, selector)
            },
            None,
            selector,
          )
      }
  }
}

// Waits for the next message while a request or stream waits. `in_flight`
// is the request awaiting its response, or `None` during a wait for a
// notification. Requests that arrive during a response wait are queued and
// replayed afterwards; a wait for a notification serves them at once.
fn receive(
  state: State,
  deadline: Int,
  queued: List(Message),
  continue: fn(State, List(Message)) -> Await,
  in_flight: Option(String),
  selector: process.Selector(Message),
) -> Await {
  let remaining = deadline - monotonic_ms()
  case remaining <= 0 {
    True -> Failed(TimedOut, state, queued)
    False ->
      case process.selector_receive(selector, remaining) {
        Error(Nil) -> Failed(TimedOut, state, queued)
        Ok(ClientPortMessage(PortData(chunk))) ->
          case collect(state, chunk) {
            Error(detail) -> Failed(Malformed(detail), state, queued)
            Ok(next) -> continue(next, queued)
          }
        Ok(ClientPortMessage(PortExit(_))) ->
          Failed(Exited, State(..state, port: None), queued)
        Ok(CloseClient(reply)) -> {
          process.send(reply, Nil)
          CloseRequested(ClientClosed, state, queued)
        }
        Ok(CancelInFlight(target)) ->
          case in_flight {
            Some(id) if id == target -> {
              case state.port {
                Some(port) -> send_command(port, cancellation_frame(id))
                None -> Nil
              }
              Failed(Cancelled, abandon(state, id), queued)
            }
            // A request that is still waiting, or was already answered.
            _ ->
              receive(
                abandon(state, target),
                deadline,
                queued,
                continue,
                in_flight,
                selector,
              )
          }
        Ok(CallerDown) ->
          case in_flight {
            Some(id) -> {
              case state.port {
                Some(port) -> send_command(port, cancellation_frame(id))
                None -> Nil
              }
              Failed(Cancelled, abandon(state, id), queued)
            }
            None -> Failed(TimedOut, state, queued)
          }
        Ok(Request(bytes, id, request_deadline, _, reply))
          if in_flight == None
        -> serve(state, bytes, id, request_deadline, reply, queued, continue)
        // A call that arrives while another is in flight waits in `queued`,
        // out of the mailbox the caller's check reads: bound it here.
        Ok(Request(max_pending: max_pending, reply: reply, ..) as request) ->
          case waiting_requests(queued) >= max_pending {
            True -> {
              process.send(reply, Error(Busy(max_pending)))
              receive(state, deadline, queued, continue, in_flight, selector)
            }
            False ->
              receive(
                state,
                deadline,
                [request, ..queued],
                continue,
                in_flight,
                selector,
              )
          }
        Ok(other) ->
          receive(
            state,
            deadline,
            [other, ..queued],
            continue,
            in_flight,
            selector,
          )
      }
  }
}

fn waiting_requests(queued: List(Message)) -> Int {
  list.count(queued, fn(message) {
    case message {
      Request(..) -> True
      _ -> False
    }
  })
}

fn collect(state: State, chunk: BitArray) -> Result(State, String) {
  let #(framer, results) = feed_framer(state.framer, chunk)
  use frames <- result.try(
    list.try_map(results, fn(found) {
      case found {
        Frame(frame) -> Ok(frame)
        FrameOversized(..) -> Error("a response frame exceeds the byte limit")
        InvalidTrailingBytes(_) ->
          Error("a response ended with unterminated data")
      }
    }),
  )
  let combined = list.append(state.frames, frames)
  case list.length(combined) > max_buffered_frames {
    True -> Error("the frame buffer exceeded its bound")
    False -> Ok(State(..state, framer: framer, frames: combined))
  }
}

fn enqueue_notification(
  state: State,
  frame: BitArray,
) -> Result(State, String) {
  case list.length(state.notifications) >= max_buffered_frames {
    True -> Error("the notification buffer exceeded its bound")
    False ->
      Ok(
        State(..state, notifications: list.append(state.notifications, [frame])),
      )
  }
}

fn take_notification(
  notifications: List(BitArray),
  id: String,
) -> Result(#(BitArray, List(BitArray)), Nil) {
  case list.split_while(notifications, fn(frame) { !belongs_to(frame, id) }) {
    #(_, []) -> Error(Nil)
    #(before, [found, ..after]) -> Ok(#(found, list.append(before, after)))
  }
}

fn reset(state: State) -> State {
  State(
    ..state,
    framer: new_framer(state.max_frame_bytes),
    frames: [],
    notifications: [],
    closed_subscriptions: [],
    abandoned: [],
  )
}

fn close_port(port: Option(Pid)) -> Nil {
  case port {
    Some(port) -> close_port_owner(port)
    None -> Nil
  }
}

fn cancellation_frame(id: String) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("notifications/cancelled")),
    #(
      "params",
      json.object([
        #("requestId", json.string(id)),
        #("reason", json.string("cancelled by the client")),
      ]),
    ),
  ])
  |> json.to_string
  |> bit_array.from_string
  |> bit_array.append(<<"\n">>)
}

fn parse(frame: BitArray) -> Result(Dynamic, String) {
  use text <- result.try(
    bit_array.to_string(frame) |> result.replace_error("a frame was not UTF-8"),
  )
  json.parse(text, decode.dynamic)
  |> result.replace_error("a frame was not valid JSON")
}

// `Some(id)` for a response, `None` for a notification.
fn response_id(frame: BitArray) -> Result(Option(String), String) {
  use value <- result.try(parse(frame))
  case decode.run(value, decode.at(["jsonrpc"], decode.string)) {
    Ok("2.0") ->
      case decode.run(value, decode.at(["id"], decode.dynamic)) {
        Ok(raw) ->
          case decode.run(raw, decode.string) {
            Ok(id) -> Ok(Some(id))
            Error(_) -> Error("a response id was not a string")
          }
        Error(_) ->
          case decode.run(value, decode.at(["method"], decode.string)) {
            Ok(_) -> Ok(None)
            Error(_) -> Error("the peer sent a frame without an id or method")
          }
      }
    _ -> Error("the peer sent malformed JSON-RPC")
  }
}

fn belongs_to(frame: BitArray, id: String) -> Bool {
  case parse(frame) {
    Error(_) -> False
    Ok(value) ->
      decode.run(
        value,
        decode.at(
          ["params", "_meta", "io.modelcontextprotocol/subscriptionId"],
          decode.string,
        ),
      )
      == Ok(id)
  }
}
