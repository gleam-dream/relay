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
    subject: Subject(ClientMessage),
    max_frame_bytes: Int,
  )
}

type AwaitError {
  AwaitError(String, List(ClientMessage), Bool)
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
            Error(AwaitError(reason, queued, close_requested)) -> {
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
                    ),
                  )
                }
              }
            }
            Ok(#(frame, next_state, queued)) -> {
              process.send(reply, Ok(frame))
              list.each(queued, fn(next) { process.send(state.subject, next) })
              actor.continue(next_state)
            }
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
            ),
          )
        }
        Ok(#(framer, frames)) ->
          actor.continue(ClientState(..state, framer: framer, frames: frames))
      }
    ClientPortMessage(PortExit(_status)) -> {
      case state.port_owner {
        Some(port_owner) -> ffi_close_stdio_client_port(port_owner)
        None -> Nil
      }
      actor.continue(ClientState(..state, port_owner: None, frames: []))
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
        Error(reason) -> Error(AwaitError(reason, queued, False))
        Ok(True) ->
          Ok(#(frame, ClientState(..state, frames: remaining), queued))
        Ok(False) ->
          await_response(
            ClientState(..state, frames: remaining),
            deadline,
            expected_id,
            queued,
          )
      }
    [] -> {
      let remaining_ms = deadline - ffi_monotonic_time_ms()
      case remaining_ms <= 0 {
        True -> Error(AwaitError("stdio response timed out", queued, False))
        False ->
          case process.receive(state.subject, remaining_ms) {
            Error(_) ->
              Error(AwaitError("stdio response timed out", queued, False))
            Ok(ClientPortMessage(PortData(chunk))) ->
              case collect_frames(state.framer, chunk, state.max_frame_bytes) {
                Error(reason) -> Error(AwaitError(reason, queued, False))
                Ok(#(framer, frames)) ->
                  await_response(
                    ClientState(..state, framer: framer, frames: frames),
                    deadline,
                    expected_id,
                    queued,
                  )
              }
            Ok(ClientPortMessage(PortExit(status))) ->
              Error(AwaitError(
                "stdio child exited with status " <> int.to_string(status),
                queued,
                False,
              ))
            Ok(CloseClient(reply)) -> {
              case state.port_owner {
                Some(port_owner) -> ffi_close_stdio_client_port(port_owner)
                None -> Nil
              }
              process.send(reply, Nil)
              Error(AwaitError("stdio client closed", queued, True))
            }
            Ok(other) ->
              await_response(state, deadline, expected_id, [other, ..queued])
          }
      }
    }
  }
}

fn reject_queued_calls(queued: List(ClientMessage), reason: String) -> Nil {
  list.each(queued, fn(message) {
    case message {
      OpenPort(_, _, reply) -> process.send(reply, Error(reason))
      Request(_, _, _, reply) -> process.send(reply, Error(reason))
      CloseClient(reply) -> process.send(reply, Nil)
      ClientPortMessage(_) -> Nil
    }
  })
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
