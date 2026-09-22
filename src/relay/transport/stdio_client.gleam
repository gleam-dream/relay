import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode as dyn_decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import relay/transport/stdio.{
  type Framer, type FramerResult, Frame, FrameOversized, InvalidTrailingBytes,
  feed_framer, new_framer,
}

const max_buffered_frames = 256

/// Configuration for a local stdio client. The executable is launched directly
/// with `args`; it is never interpreted by a shell.
pub type Config {
  Config(
    executable: String,
    args: List(String),
    timeout_ms: Int,
    max_frame_bytes: Int,
  )
}

pub opaque type Client {
  Client(subject: Subject(ClientMessage))
}

type ClientMessage {
  OpenPort(String, List(String), Subject(Result(Pid, String)))
  Request(BitArray, String, Int, Subject(Result(BitArray, String)))
  Subscribe(BitArray, String, Int, Subject(Result(BitArray, String)))
  NextNotification(String, Int, Subject(Result(BitArray, String)))
  CancelSubscription(String, Subject(Nil))
  ClientPortMessage(PortMessage)
  CloseClient(Subject(Nil))
}

type PortMessage {
  PortData(BitArray)
  PortExit(Int)
}

type ClientState {
  ClientState(
    port_owner: Option(Pid),
    framer: Framer,
    frames: List(BitArray),
    notifications: List(BitArray),
    closed_subscriptions: List(String),
    subject: Subject(ClientMessage),
    max_frame_bytes: Int,
  )
}

type AwaitError {
  AwaitError(
    reason: String,
    state: ClientState,
    queued: List(ClientMessage),
    close_requested: Bool,
    preserve_state: Bool,
  )
}

type CloseResult {
  CloseAcknowledged
  CloseOwnerDown(process.Down)
}

@external(erlang, "relay_ffi", "start_stdio_client_port")
fn ffi_start_stdio_client_port(
  executable: String,
  args: List(String),
  subject: Subject(ClientMessage),
) -> Result(Pid, String)

@external(erlang, "relay_ffi", "send_stdio_client_command")
fn ffi_send_stdio_client_command(port_owner: Pid, bytes: BitArray) -> Nil

@external(erlang, "relay_ffi", "close_stdio_client_port")
fn ffi_close_stdio_client_port(port_owner: Pid) -> Nil

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn ffi_monotonic_time_ms() -> Int

/// Starts an owned local child process using an executable and argument list.
pub fn connect(config: Config) -> Result(Client, String) {
  case
    config.executable != ""
    && config.timeout_ms > 0
    && config.max_frame_bytes > 0
  {
    False -> Error("stdio client configuration is invalid")
    True ->
      case start_actor(config.max_frame_bytes) {
        Error(error) -> Error(string.inspect(error))
        Ok(client) -> {
          let Client(subject) = client
          case
            process.call(
              subject,
              waiting: config.timeout_ms,
              sending: fn(reply) {
                OpenPort(config.executable, config.args, reply)
              },
            )
          {
            Ok(_) -> Ok(client)
            Error(reason) -> {
              close(client)
              Error(reason)
            }
          }
        }
      }
  }
}

/// Writes one newline-delimited JSON-RPC frame and waits for one bounded reply.
pub fn request(
  client: Client,
  request: BitArray,
  expected_id: String,
  timeout_ms: Int,
  max_response_bytes: Int,
) -> Result(BitArray, String) {
  let Client(subject) = client
  process.call(subject, waiting: timeout_ms + 1000, sending: fn(reply) {
    Request(request, expected_id, timeout_ms, reply)
  })
  |> result_limit(max_response_bytes)
}

/// Opens a long-lived subscriptions/listen exchange and returns its
/// acknowledgement notification. The exchange remains owned by this client;
/// subsequent notifications can be read with `next_notification`.
pub fn subscribe(
  client: Client,
  request: BitArray,
  expected_id: String,
  timeout_ms: Int,
  max_response_bytes: Int,
) -> Result(BitArray, String) {
  let Client(subject) = client
  process.call(subject, waiting: timeout_ms + 1000, sending: fn(reply) {
    Subscribe(request, expected_id, timeout_ms, reply)
  })
  |> result_limit(max_response_bytes)
}

/// Waits for the next notification belonging to one subscription.
pub fn next_notification(
  client: Client,
  expected_id: String,
  timeout_ms: Int,
  max_response_bytes: Int,
) -> Result(BitArray, String) {
  let Client(subject) = client
  process.call(subject, waiting: timeout_ms + 1000, sending: fn(reply) {
    NextNotification(expected_id, timeout_ms, reply)
  })
  |> result_limit(max_response_bytes)
}

/// Cancels one long-lived subscription while keeping the child process alive.
pub fn cancel_subscription(client: Client, expected_id: String) -> Nil {
  let Client(subject) = client
  process.call(subject, waiting: 1000, sending: fn(reply) {
    CancelSubscription(expected_id, reply)
  })
}

/// Closes the child and terminates its owning process.
pub fn close(client: Client) -> Nil {
  let Client(subject) = client
  case process.subject_owner(subject) {
    Error(_) -> Nil
    Ok(owner) ->
      case process.is_alive(owner) {
        False -> Nil
        True -> {
          let reply = process.new_subject()
          let monitor = process.monitor(owner)
          process.send(subject, CloseClient(reply))
          let _ =
            process.new_selector()
            |> process.select_map(for: reply, mapping: fn(_) {
              CloseAcknowledged
            })
            |> process.select_specific_monitor(monitor, CloseOwnerDown)
            |> process.selector_receive(within: 1000)
          process.demonitor_process(monitor)
          Nil
        }
      }
  }
}

fn result_limit(
  result: Result(BitArray, String),
  max_response_bytes: Int,
) -> Result(BitArray, String) {
  case result {
    Error(reason) -> Error(reason)
    Ok(frame) ->
      case bit_array.byte_size(frame) > max_response_bytes {
        True -> Error("stdio client response exceeds its configured byte limit")
        False -> Ok(frame)
      }
  }
}

fn start_actor(max_frame_bytes: Int) -> Result(Client, actor.StartError) {
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      actor.initialised(ClientState(
        port_owner: None,
        framer: new_framer(max_frame_bytes),
        frames: [],
        notifications: [],
        closed_subscriptions: [],
        subject: subject,
        max_frame_bytes: max_frame_bytes,
      ))
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_client_message)
  case actor.start(builder) {
    Error(error) -> Error(error)
    Ok(started) -> Ok(Client(started.data))
  }
}

fn handle_client_message(
  state: ClientState,
  message: ClientMessage,
) -> actor.Next(ClientState, ClientMessage) {
  case message {
    OpenPort(executable, args, reply) ->
      case ffi_start_stdio_client_port(executable, args, state.subject) {
        Error(reason) -> {
          process.send(reply, Error(reason))
          actor.continue(state)
        }
        Ok(port_owner) -> {
          process.send(reply, Ok(port_owner))
          actor.continue(ClientState(..state, port_owner: Some(port_owner)))
        }
      }
    Request(bytes, expected_id, timeout_ms, reply) ->
      case state.port_owner {
        None -> {
          process.send(reply, Error("stdio client is closed"))
          actor.continue(state)
        }
        Some(port_owner) -> {
          ffi_send_stdio_client_command(
            port_owner,
            bit_array.append(bytes, bit_array.from_string("\n")),
          )
          let deadline = ffi_monotonic_time_ms() + timeout_ms
          case await_response(state, deadline, expected_id, []) {
            Error(AwaitError(reason, _failed_state, queued, close_requested, _)) -> {
              ffi_close_stdio_client_port(port_owner)
              process.send(reply, Error(reason))
              case close_requested {
                True -> {
                  reject_queued_calls(queued, reason)
                  actor.stop()
                }
                False -> {
                  list.each(list.reverse(queued), fn(next) {
                    process.send(state.subject, next)
                  })
                  actor.continue(
                    ClientState(
                      ..state,
                      port_owner: None,
                      framer: new_framer(state.max_frame_bytes),
                      frames: [],
                      notifications: [],
                    ),
                  )
                }
              }
            }
            Ok(#(frame, next_state, queued)) -> {
              process.send(reply, Ok(frame))
              list.each(list.reverse(queued), fn(next) {
                process.send(state.subject, next)
              })
              actor.continue(next_state)
            }
          }
        }
      }
    Subscribe(bytes, expected_id, timeout_ms, reply) ->
      case state.port_owner {
        None -> {
          process.send(reply, Error("stdio client is closed"))
          actor.continue(state)
        }
        Some(port_owner) -> {
          ffi_send_stdio_client_command(
            port_owner,
            bit_array.append(bytes, bit_array.from_string("\n")),
          )
          let deadline = ffi_monotonic_time_ms() + timeout_ms
          case await_notification(state, deadline, expected_id, [], False) {
            Error(AwaitError(reason, _failed_state, queued, close_requested, _)) -> {
              ffi_close_stdio_client_port(port_owner)
              process.send(reply, Error(reason))
              case close_requested {
                True -> {
                  reject_queued_calls(queued, reason)
                  actor.stop()
                }
                False -> {
                  list.each(list.reverse(queued), fn(next) {
                    process.send(state.subject, next)
                  })
                  actor.continue(
                    ClientState(
                      ..state,
                      port_owner: None,
                      framer: new_framer(state.max_frame_bytes),
                      frames: [],
                      notifications: [],
                    ),
                  )
                }
              }
            }
            Ok(#(frame, next_state, queued)) -> {
              process.send(reply, Ok(frame))
              list.each(list.reverse(queued), fn(next) {
                process.send(state.subject, next)
              })
              actor.continue(next_state)
            }
          }
        }
      }
    NextNotification(expected_id, timeout_ms, reply) -> {
      case list.contains(state.closed_subscriptions, expected_id) {
        True -> {
          process.send(reply, Error("stdio subscription is closed"))
          actor.continue(state)
        }
        False -> {
          let deadline = ffi_monotonic_time_ms() + timeout_ms
          case await_notification(state, deadline, expected_id, [], True) {
            Error(AwaitError(
              reason,
              failed_state,
              queued,
              close_requested,
              preserve_state,
            )) -> {
              process.send(reply, Error(reason))
              case close_requested {
                True -> {
                  reject_queued_calls(queued, reason)
                  actor.stop()
                }
                False -> {
                  case preserve_state {
                    True -> Nil
                    False -> close_port(failed_state.port_owner)
                  }
                  list.each(list.reverse(queued), fn(next) {
                    process.send(state.subject, next)
                  })
                  actor.continue(case preserve_state {
                    True -> failed_state
                    False -> reset_state(failed_state)
                  })
                }
              }
            }
            Ok(#(frame, next_state, queued)) -> {
              process.send(reply, Ok(frame))
              list.each(list.reverse(queued), fn(next) {
                process.send(state.subject, next)
              })
              actor.continue(next_state)
            }
          }
        }
      }
    }
    CancelSubscription(expected_id, reply) -> {
      case list.contains(state.closed_subscriptions, expected_id) {
        True -> {
          process.send(reply, Nil)
          actor.continue(state)
        }
        False -> {
          case state.port_owner {
            None -> Nil
            Some(port_owner) ->
              ffi_send_stdio_client_command(
                port_owner,
                cancellation_frame(expected_id),
              )
          }
          process.send(reply, Nil)
          actor.continue(
            ClientState(
              ..state,
              frames: discard_subscription_frames(state.frames, expected_id),
              notifications: discard_notifications(
                state.notifications,
                expected_id,
              ),
              closed_subscriptions: [expected_id, ..state.closed_subscriptions],
            ),
          )
        }
      }
    }
    ClientPortMessage(PortData(chunk)) ->
      case collect_frames(state.framer, chunk, state.max_frame_bytes) {
        Error(_) -> {
          case state.port_owner {
            Some(port_owner) -> ffi_close_stdio_client_port(port_owner)
            None -> Nil
          }
          actor.continue(
            ClientState(
              ..state,
              port_owner: None,
              framer: new_framer(state.max_frame_bytes),
              frames: [],
              notifications: [],
            ),
          )
        }
        Ok(#(framer, frames)) ->
          case append_frames(state, framer, frames) {
            Error(_) -> {
              close_port(state.port_owner)
              actor.continue(reset_state(state))
            }
            Ok(next_state) -> actor.continue(next_state)
          }
      }
    ClientPortMessage(PortExit(_status)) -> {
      close_port(state.port_owner)
      actor.continue(reset_state(state))
    }
    CloseClient(reply) -> {
      case state.port_owner {
        Some(port_owner) -> ffi_close_stdio_client_port(port_owner)
        None -> Nil
      }
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn await_response(
  state: ClientState,
  deadline: Int,
  expected_id: String,
  queued: List(ClientMessage),
) -> Result(#(BitArray, ClientState, List(ClientMessage)), AwaitError) {
  case state.frames {
    [frame, ..remaining] ->
      case is_matching_response(frame, expected_id) {
        Error(reason) -> Error(AwaitError(reason, state, queued, False, False))
        Ok(True) ->
          Ok(#(frame, ClientState(..state, frames: remaining), queued))
        Ok(False) ->
          case is_notification_frame(frame) {
            True ->
              case
                enqueue_notification(
                  ClientState(..state, frames: remaining),
                  frame,
                )
              {
                Error(reason) ->
                  Error(AwaitError(reason, state, queued, False, False))
                Ok(next_state) ->
                  await_response(next_state, deadline, expected_id, queued)
              }
            False ->
              await_response(
                ClientState(..state, frames: remaining),
                deadline,
                expected_id,
                queued,
              )
          }
      }
    [] -> {
      let remaining_ms = deadline - ffi_monotonic_time_ms()
      case remaining_ms <= 0 {
        True ->
          Error(AwaitError(
            "stdio response timed out",
            state,
            queued,
            False,
            False,
          ))
        False ->
          case process.receive(state.subject, remaining_ms) {
            Error(_) ->
              Error(AwaitError(
                "stdio response timed out",
                state,
                queued,
                False,
                False,
              ))
            Ok(ClientPortMessage(PortData(chunk))) ->
              case collect_frames(state.framer, chunk, state.max_frame_bytes) {
                Error(reason) ->
                  Error(AwaitError(reason, state, queued, False, False))
                Ok(#(framer, frames)) ->
                  case append_frames(state, framer, frames) {
                    Error(reason) ->
                      Error(AwaitError(reason, state, queued, False, False))
                    Ok(next_state) ->
                      await_response(next_state, deadline, expected_id, queued)
                  }
              }
            Ok(ClientPortMessage(PortExit(status))) ->
              Error(AwaitError(
                "stdio child exited with status " <> int.to_string(status),
                state,
                queued,
                False,
                False,
              ))
            Ok(CloseClient(reply)) -> {
              case state.port_owner {
                Some(port_owner) -> ffi_close_stdio_client_port(port_owner)
                None -> Nil
              }
              process.send(reply, Nil)
              Error(AwaitError(
                "stdio client closed",
                state,
                queued,
                True,
                False,
              ))
            }
            Ok(other) ->
              await_response(state, deadline, expected_id, [other, ..queued])
          }
      }
    }
  }
}

fn await_notification(
  state: ClientState,
  deadline: Int,
  expected_id: String,
  queued: List(ClientMessage),
  preserve_state: Bool,
) -> Result(#(BitArray, ClientState, List(ClientMessage)), AwaitError) {
  case take_notification(state.notifications, expected_id) {
    Ok(#(frame, remaining)) ->
      Ok(#(frame, ClientState(..state, notifications: remaining), queued))
    Error(Nil) -> {
      case state.frames {
        [frame, ..remaining] ->
          case notification_matches(frame, expected_id) {
            Error(reason) ->
              Error(AwaitError(reason, state, queued, False, False))
            Ok(True) ->
              Ok(#(frame, ClientState(..state, frames: remaining), queued))
            Ok(False) ->
              case
                enqueue_notification(
                  ClientState(..state, frames: remaining),
                  frame,
                )
              {
                Error(reason) ->
                  Error(AwaitError(
                    reason,
                    ClientState(..state, frames: remaining),
                    queued,
                    False,
                    False,
                  ))
                Ok(next_state) ->
                  await_notification(
                    next_state,
                    deadline,
                    expected_id,
                    queued,
                    preserve_state,
                  )
              }
          }
        [] -> {
          let remaining_ms = deadline - ffi_monotonic_time_ms()
          case remaining_ms <= 0 {
            True ->
              Error(AwaitError(
                "stdio notification timed out",
                state,
                queued,
                False,
                preserve_state,
              ))
            False ->
              case process.receive(state.subject, remaining_ms) {
                Error(_) ->
                  Error(AwaitError(
                    "stdio notification timed out",
                    state,
                    queued,
                    False,
                    preserve_state,
                  ))
                Ok(ClientPortMessage(PortData(chunk))) ->
                  case
                    collect_frames(state.framer, chunk, state.max_frame_bytes)
                  {
                    Error(reason) ->
                      Error(AwaitError(reason, state, queued, False, False))
                    Ok(#(framer, frames)) ->
                      case append_frames(state, framer, frames) {
                        Error(reason) ->
                          Error(AwaitError(reason, state, queued, False, False))
                        Ok(next_state) ->
                          await_notification(
                            next_state,
                            deadline,
                            expected_id,
                            queued,
                            preserve_state,
                          )
                      }
                  }
                Ok(ClientPortMessage(PortExit(status))) ->
                  Error(AwaitError(
                    "stdio child exited with status " <> int.to_string(status),
                    state,
                    queued,
                    False,
                    False,
                  ))
                Ok(CloseClient(reply)) -> {
                  case state.port_owner {
                    Some(port_owner) -> ffi_close_stdio_client_port(port_owner)
                    None -> Nil
                  }
                  process.send(reply, Nil)
                  Error(AwaitError(
                    "stdio client closed",
                    state,
                    queued,
                    True,
                    False,
                  ))
                }
                Ok(other) ->
                  await_notification(
                    state,
                    deadline,
                    expected_id,
                    [other, ..queued],
                    preserve_state,
                  )
              }
          }
        }
      }
    }
  }
}

fn take_notification(
  notifications: List(BitArray),
  expected_id: String,
) -> Result(#(BitArray, List(BitArray)), Nil) {
  case notifications {
    [] -> Error(Nil)
    [frame, ..rest] ->
      case notification_matches(frame, expected_id) {
        Ok(True) -> Ok(#(frame, rest))
        _ ->
          case take_notification(rest, expected_id) {
            Error(_) -> Error(Nil)
            Ok(#(found, remaining)) ->
              Ok(#(found, list.append([frame], remaining)))
          }
      }
  }
}

fn enqueue_notification(
  state: ClientState,
  frame: BitArray,
) -> Result(ClientState, String) {
  case list.length(state.notifications) >= max_buffered_frames {
    True -> Error("stdio notification buffer exceeded its configured bound")
    False ->
      Ok(
        ClientState(
          ..state,
          notifications: list.append(state.notifications, [frame]),
        ),
      )
  }
}

fn append_frames(
  state: ClientState,
  framer: Framer,
  frames: List(BitArray),
) -> Result(ClientState, String) {
  let combined = list.append(state.frames, frames)
  case list.length(combined) > max_buffered_frames {
    True -> Error("stdio frame buffer exceeded its configured bound")
    False -> Ok(ClientState(..state, framer: framer, frames: combined))
  }
}

fn reset_state(state: ClientState) -> ClientState {
  ClientState(
    ..state,
    port_owner: None,
    framer: new_framer(state.max_frame_bytes),
    frames: [],
    notifications: [],
    closed_subscriptions: [],
  )
}

fn close_port(port_owner: Option(Pid)) -> Nil {
  case port_owner {
    None -> Nil
    Some(owner) -> ffi_close_stdio_client_port(owner)
  }
}

fn cancellation_frame(expected_id: String) -> BitArray {
  let bytes =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("method", json.string("notifications/cancelled")),
      #(
        "params",
        json.object([
          #("requestId", json.string(expected_id)),
          #("reason", json.string("subscription closed")),
        ]),
      ),
    ])
    |> json.to_string
    |> bit_array.from_string
  bit_array.append(bytes, bit_array.from_string("\n"))
}

fn discard_notifications(
  notifications: List(BitArray),
  expected_id: String,
) -> List(BitArray) {
  list.filter(notifications, fn(frame) {
    case notification_matches(frame, expected_id) {
      Ok(True) -> False
      _ -> True
    }
  })
}

fn discard_subscription_frames(
  frames: List(BitArray),
  expected_id: String,
) -> List(BitArray) {
  list.filter(frames, fn(frame) {
    case notification_matches(frame, expected_id) {
      Ok(True) -> False
      _ -> True
    }
  })
}

fn reject_queued_calls(queued: List(ClientMessage), reason: String) -> Nil {
  list.each(queued, fn(message) {
    case message {
      OpenPort(_, _, reply) -> process.send(reply, Error(reason))
      Request(_, _, _, reply) -> process.send(reply, Error(reason))
      Subscribe(_, _, _, reply) -> process.send(reply, Error(reason))
      NextNotification(_, _, reply) -> process.send(reply, Error(reason))
      CancelSubscription(_, reply) -> process.send(reply, Nil)
      CloseClient(reply) -> process.send(reply, Nil)
      ClientPortMessage(_) -> Nil
    }
  })
}

fn is_notification_frame(frame: BitArray) -> Bool {
  case bit_array.to_string(frame) {
    Error(_) -> False
    Ok(raw) ->
      case json.parse(raw, dyn_decode.dynamic) {
        Error(_) -> False
        Ok(value) ->
          case
            dyn_decode.run(value, dyn_decode.at(["method"], dyn_decode.string))
          {
            Ok(_) -> True
            Error(_) -> False
          }
      }
  }
}

fn notification_matches(
  frame: BitArray,
  expected_id: String,
) -> Result(Bool, String) {
  case bit_array.to_string(frame) {
    Error(_) -> Error("stdio notification was not UTF-8")
    Ok(raw) ->
      case json.parse(raw, dyn_decode.dynamic) {
        Error(_) -> Error("stdio notification was not valid JSON")
        Ok(value) -> {
          let method =
            dyn_decode.run(value, dyn_decode.at(["method"], dyn_decode.string))
          case method {
            Error(_) -> Ok(False)
            Ok(_) ->
              case
                dyn_decode.run(
                  value,
                  dyn_decode.at(
                    [
                      "params",
                      "_meta",
                      "io.modelcontextprotocol/subscriptionId",
                    ],
                    dyn_decode.string,
                  ),
                )
              {
                Ok(actual) if actual == expected_id -> Ok(True)
                Ok(_) -> Ok(False)
                Error(_) -> Ok(False)
              }
          }
        }
      }
  }
}

fn is_matching_response(
  frame: BitArray,
  expected_id: String,
) -> Result(Bool, String) {
  case bit_array.to_string(frame) {
    Error(_) -> Error("stdio response was not UTF-8")
    Ok(raw) ->
      case json.parse(raw, dyn_decode.dynamic) {
        Error(_) -> Error("stdio response was not valid JSON")
        Ok(response) -> {
          let version =
            dyn_decode.run(
              response,
              dyn_decode.at(["jsonrpc"], dyn_decode.string),
            )
          case version {
            Error(_) -> Error("stdio peer sent malformed JSON-RPC")
            Ok("2.0") -> classify_frame_id(response, expected_id)
            Ok(_) -> Error("stdio peer used an unsupported JSON-RPC version")
          }
        }
      }
  }
}

fn classify_frame_id(
  response: Dynamic,
  expected_id: String,
) -> Result(Bool, String) {
  case dyn_decode.run(response, dyn_decode.at(["id"], dyn_decode.dynamic)) {
    Ok(raw_id) ->
      case dyn_decode.run(raw_id, dyn_decode.string) {
        Ok(actual_id) if actual_id == expected_id -> Ok(True)
        Ok(_) -> Error("stdio response ID did not match request")
        Error(_) -> Error("stdio response ID was not a string")
      }
    Error(_) ->
      case
        dyn_decode.run(response, dyn_decode.at(["method"], dyn_decode.string))
      {
        Ok(_) -> Ok(False)
        Error(_) -> Error("stdio peer sent a frame without a response ID")
      }
  }
}

fn collect_frames(
  framer: Framer,
  chunk: BitArray,
  limit: Int,
) -> Result(#(Framer, List(BitArray)), String) {
  let #(next_framer, results) = feed_framer(framer, chunk)
  case collect_frame_results(results, limit, []) {
    Error(reason) -> Error(reason)
    Ok(frames) -> Ok(#(next_framer, frames))
  }
}

fn collect_frame_results(
  results: List(FramerResult),
  limit: Int,
  frames: List(BitArray),
) -> Result(List(BitArray), String) {
  case results {
    [] -> Ok(list.reverse(frames))
    [Frame(frame), ..rest] ->
      collect_frame_results(rest, limit, [frame, ..frames])
    [FrameOversized(size, _), ..] ->
      Error(
        "stdio response frame exceeds the configured "
        <> int.to_string(limit)
        <> " byte limit ("
        <> int.to_string(size)
        <> " bytes)",
      )
    [InvalidTrailingBytes(_), ..] ->
      Error("stdio response ended with unterminated data")
  }
}
