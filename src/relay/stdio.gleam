//// Serves an MCP server over standard input and output.
////
//// `serve(server, context)` reads newline-delimited JSON-RPC frames from
//// standard input until it closes and writes replies to standard output. It
//// blocks the calling process, which is usually `main`. `serve_with` takes a
//// `Config` for the runtime limits (`relay/runtime.config`). The stdio
//// transport enforces no authorization: run it only under a trusted parent
//// process. A client launches such a server with `relay/client.stdio`.
////
//// Start the VM with `-noinput` (for example `ERL_FLAGS=-noinput`). Without
//// it the VM's own terminal reader owns standard input, and `serve` returns
//// `StdinOwnedByVm` before reading anything.
////
//// Standard output carries only protocol frames. `serve` moves every logger
//// handler that writes to standard output to standard error, for the rest of
//// the VM's life, and makes standard error the group leader of the runtime
//// and its handlers, so their `io` output goes there too. Processes started
//// before `serve` keep their group leader and must not print to standard
//// output; neither may `erlang:display`, which writes to the descriptor
//// directly.
////
//// ```gleam
//// import relay/server
//// import relay/stdio
////
//// pub fn main() {
////   let assert Ok(Nil) = stdio.serve(server.new([]), Nil)
//// }
//// ```
////
//// `Config` is a record: change a field with
//// `stdio.Config(..stdio.config(), write_timeout: duration.seconds(10))`.
////
//// | Field | Default |
//// | --- | --- |
//// | `runtime`: frame, depth, handler limits | `relay/runtime.config()` |
//// | `write_timeout`: one write to standard output | 5 s, then `StdoutBroken` |
////
//// ## Output pressure
////
//// Responses are written one at a time. A parent that reads slowly holds
//// the write, and the write holds the runtime that produced the response.
//// A write that does not finish within the write timeout ends `serve` with
//// `StdoutBroken`; handlers still running are cancelled first. A request
//// that arrives while the runtime's exchange limit is reached is answered
//// with JSON-RPC error `-32000`.

import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import relay/internal/emit
import relay/internal/protocol/v2026_07_28 as v2026
import relay/internal/stdio_frames.{
  type Framer, type ReadOutcome, type Writer, Frame, FrameOversized,
  InvalidTrailingBytes,
}
import relay/reducer
import relay/runtime.{type Runtime}
import relay/server.{type Server}
import relay/telemetry

/// Stdio settings. Start from `config()` and update the fields you need.
pub type Config {
  Config(
    /// The runtime limits: frame size, nesting depth, handler timeout and
    /// the rest of `relay/runtime.Config`.
    runtime: runtime.Config,
    /// How long one write to standard output may take. A write that takes
    /// longer counts as broken output and `serve` stops with
    /// `StdoutBroken`. At least 1 ms.
    write_timeout: Duration,
  )
}

/// The default runtime limits and a 5 s write timeout.
pub fn config() -> Config {
  Config(runtime: runtime.config(), write_timeout: duration.seconds(5))
}

/// Why `serve` stopped with an error.
pub type StdioError {
  InvalidRuntimeConfig(field: runtime.ConfigField)
  /// The write timeout is shorter than 1 ms.
  InvalidWriteTimeout(timeout: Duration)
  /// The VM reads standard input itself because it was started without
  /// `-noinput`.
  StdinOwnedByVm
  /// Standard input could not be read.
  ReadFailed
  /// Standard output was closed, failed, or did not accept a reply within
  /// the write timeout.
  StdoutBroken
  StartupFailed
  /// Standard input ended in the middle of a frame.
  InvalidTrailingData(bytes: BitArray)
}

/// A one-line description of a stdio error.
pub fn describe_error(error: StdioError) -> String {
  case error {
    InvalidRuntimeConfig(_) -> "a stdio runtime setting is out of range"
    InvalidWriteTimeout(_) -> "the stdio write timeout must be at least 1 ms"
    StdinOwnedByVm ->
      "the VM reads standard input itself; start it with -noinput"
    ReadFailed -> "standard input could not be read"
    StdoutBroken -> "standard output failed while writing a reply"
    StartupFailed -> "the stdio server failed to start"
    InvalidTrailingData(_) -> "standard input ended in the middle of a frame"
  }
}

@external(erlang, "relay_ffi", "reserve_stdio")
fn reserve_stdio() -> Result(Nil, Nil)

@external(erlang, "relay_ffi", "read_stdin")
fn read_stdin() -> ReadOutcome

@external(erlang, "relay_ffi", "lead_output_to_stderr")
fn lead_output_to_stderr() -> Pid

@external(erlang, "relay_ffi", "restore_group_leader")
fn restore_group_leader(previous: Pid) -> Nil

@external(erlang, "relay_ffi", "write_stdout")
fn write_stdout(bytes: BitArray) -> Result(Nil, String)

/// Serves `server` with the default settings until standard input closes.
pub fn serve(
  server: Server(context),
  context: context,
) -> Result(Nil, StdioError) {
  serve_with(server, context, config())
}

/// Serves `server` with these settings until standard input closes.
pub fn serve_with(
  server: Server(context),
  context: context,
  config: Config,
) -> Result(Nil, StdioError) {
  let write_timeout_ms = duration.to_milliseconds(config.write_timeout)
  use _ <- result.try(case write_timeout_ms >= 1 {
    True -> Ok(Nil)
    False -> Error(InvalidWriteTimeout(config.write_timeout))
  })
  use runtime_config <- result.try(
    runtime.validate(config.runtime)
    |> result.map_error(fn(error) {
      case error {
        runtime.InvalidConfig(field) -> InvalidRuntimeConfig(field)
        runtime.ActorStartFailed(_) -> StartupFailed
      }
    }),
  )
  use _ <- result.try(reserve_stdio() |> result.replace_error(StdinOwnedByVm))
  let previous_leader = lead_output_to_stderr()
  let outcome =
    serve_reserved(server, context, runtime_config, write_timeout_ms)
  restore_group_leader(previous_leader)
  outcome
}

fn serve_reserved(
  server: Server(context),
  context: context,
  runtime_config: runtime.Config,
  write_timeout_ms: Int,
) -> Result(Nil, StdioError) {
  use writer <- result.try(
    stdio_frames.start_writer(write_stdout, write_timeout_ms)
    |> result.replace_error(StartupFailed),
  )
  let write_errors = process.new_subject()
  let sink = fn(output) {
    case output {
      runtime.OutputClose(_) -> Ok(Nil)
      runtime.OutputWrite(_, bytes) ->
        case stdio_frames.write_bytes(writer, bytes) {
          Ok(Nil) -> Ok(Nil)
          Error(_) -> {
            process.send(write_errors, StdoutBroken)
            Error(Nil)
          }
        }
    }
  }
  // One runtime per OS process: hold the server so calls copy no tool.
  case runtime.start_holding(server, runtime_config, sink) {
    Error(_) -> {
      stdio_frames.stop_writer(writer)
      Error(StartupFailed)
    }
    Ok(rt) -> {
      let framer =
        stdio_frames.new_framer(runtime.max_frame_bytes(runtime_config))
      let reader = start_reader()
      let outcome = read_loop(rt, context, reader, writer, framer, write_errors)
      process.kill(reader.0)
      runtime.close(rt)
      runtime.stop(rt)
      stdio_frames.stop_writer(writer)
      use _ <- result.try(outcome)
      case process.receive(write_errors, 0) {
        Ok(error) -> Error(error)
        Error(Nil) -> Ok(Nil)
      }
    }
  }
}

type Signal {
  Stdin(ReadOutcome)
  WriteFailed(StdioError)
  ReaderDown
}

// The reader owns the standard input port; the port closes when it exits.
fn start_reader() -> #(Pid, Subject(ReadOutcome)) {
  let subject = process.new_subject()
  let pid = process.spawn_unlinked(fn() { read_forever(subject) })
  #(pid, subject)
}

fn read_forever(subject: Subject(ReadOutcome)) -> Nil {
  let outcome = read_stdin()
  process.send(subject, outcome)
  case outcome {
    stdio_frames.ReadChunk(_) -> read_forever(subject)
    stdio_frames.ReadEof | stdio_frames.ReadFailed(_) -> Nil
  }
}

fn read_loop(
  rt: Runtime(context),
  context: context,
  reader: #(Pid, Subject(ReadOutcome)),
  writer: Writer,
  framer: Framer,
  write_errors: Subject(StdioError),
) -> Result(Nil, StdioError) {
  let monitor = process.monitor(reader.0)
  let selector =
    process.new_selector()
    |> process.select_map(reader.1, Stdin)
    |> process.select_map(write_errors, WriteFailed)
    |> process.select_specific_monitor(monitor, fn(_) { ReaderDown })
  loop(rt, context, writer, framer, selector)
}

fn loop(
  rt: Runtime(context),
  context: context,
  writer: Writer,
  framer: Framer,
  selector: process.Selector(Signal),
) -> Result(Nil, StdioError) {
  case process.selector_receive_forever(selector) {
    Stdin(stdio_frames.ReadChunk(chunk)) -> {
      let #(framer, frames) = stdio_frames.feed_framer(framer, chunk)
      use _ <- result.try(submit(rt, context, writer, frames))
      loop(rt, context, writer, framer, selector)
    }
    Stdin(stdio_frames.ReadEof) ->
      case stdio_frames.finish_framer(framer) {
        [InvalidTrailingBytes(rest), ..] -> {
          emit.frame_rejected(0, telemetry.TrailingBytes, None)
          Error(InvalidTrailingData(rest))
        }
        _ -> Ok(Nil)
      }
    Stdin(stdio_frames.ReadFailed(_)) -> Error(ReadFailed)
    WriteFailed(error) -> Error(error)
    ReaderDown -> Error(ReadFailed)
  }
}

const too_large =
  "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Frame too large\"}}\n"

const too_deep =
  "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"JSON nesting exceeds the configured depth\"}}\n"

fn submit(
  rt: Runtime(context),
  context: context,
  writer: Writer,
  frames: List(stdio_frames.FramerResult),
) -> Result(Nil, StdioError) {
  case frames {
    [] -> Ok(Nil)
    [frame, ..rest] -> {
      let written = case frame {
        Frame(bytes) ->
          case
            runtime.send_frame(
              rt,
              reducer.new_exchange_id(),
              context,
              bytes,
              None,
            )
          {
            Ok(Nil) -> Ok(Nil)
            Error(runtime.FrameTooLarge(..)) -> write(writer, too_large)
            Error(runtime.FrameTooDeep(..)) -> write(writer, too_deep)
            // The request is refused, not dropped: its caller gets an
            // answer instead of waiting for its own timeout.
            Error(runtime.TooManyLiveExchanges(..)) ->
              refuse(writer, bytes, "Too many requests in progress")
            Error(runtime.RuntimeStopped) ->
              refuse(writer, bytes, "The server is stopping")
          }
        FrameOversized(..) -> {
          emit.frame_rejected(0, telemetry.FrameTooLarge, None)
          write(writer, too_large)
        }
        InvalidTrailingBytes(_) -> Ok(Nil)
      }
      use _ <- result.try(written)
      submit(rt, context, writer, rest)
    }
  }
}

fn write(writer: Writer, line: String) -> Result(Nil, StdioError) {
  write_frame(writer, bit_array.from_string(line))
}

fn write_frame(writer: Writer, bytes: BitArray) -> Result(Nil, StdioError) {
  stdio_frames.write_bytes(writer, bytes)
  |> result.replace_error(StdoutBroken)
}

// Answers a request the runtime did not admit. A notification gets nothing.
fn refuse(
  writer: Writer,
  frame: BitArray,
  message: String,
) -> Result(Nil, StdioError) {
  case v2026.encode_refusal(frame, message) {
    Some(response) -> write_frame(writer, response)
    None -> Ok(Nil)
  }
}
