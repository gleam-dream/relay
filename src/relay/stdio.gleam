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
//// | `max_unframed_bytes`: standard input read but not yet framed | 4 MiB, then `UnframedInputTooLarge` |
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
    /// How many bytes of standard input may wait unframed, read from the
    /// pipe but not yet framed and submitted. Input arrives as fast as the
    /// parent writes it, also while a slow write holds the server, so past
    /// this limit `serve` stops reading and returns `UnframedInputTooLarge`.
    /// At least the runtime's frame limit and 64 KiB, the size of one pipe
    /// read.
    max_unframed_bytes: Int,
  )
}

/// The default runtime limits, a 5 s write timeout, and 4 MiB of unframed
/// input, four times the default frame limit.
pub fn config() -> Config {
  Config(
    runtime: runtime.config(),
    write_timeout: duration.seconds(5),
    max_unframed_bytes: 4_194_304,
  )
}

/// Why `serve` stopped with an error.
pub type StdioError {
  InvalidRuntimeConfig(field: runtime.ConfigField)
  /// The write timeout is shorter than 1 ms.
  InvalidWriteTimeout(timeout: Duration)
  /// `max_unframed_bytes` is below the runtime's frame limit or 64 KiB.
  InvalidUnframedLimit(bytes: Int)
  /// More than `max_unframed_bytes` of standard input waited unframed.
  /// Serving stopped reading at once; the input after the limit is not
  /// read.
  UnframedInputTooLarge(limit: Int)
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
    InvalidUnframedLimit(_) ->
      "the unframed input limit must be at least the frame limit and 64 KiB"
    UnframedInputTooLarge(_) ->
      "standard input held more unframed bytes than the limit"
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
  use _ <- result.try(
    case
      config.max_unframed_bytes >= runtime.max_frame_bytes(runtime_config)
      && config.max_unframed_bytes >= min_unframed_bytes
    {
      True -> Ok(Nil)
      False -> Error(InvalidUnframedLimit(config.max_unframed_bytes))
    },
  )
  use _ <- result.try(reserve_stdio() |> result.replace_error(StdinOwnedByVm))
  let previous_leader = lead_output_to_stderr()
  let outcome =
    serve_reserved(
      server,
      context,
      runtime_config,
      write_timeout_ms,
      config.max_unframed_bytes,
    )
  restore_group_leader(previous_leader)
  outcome
}

// One read from a pipe returns at most this much.
const min_unframed_bytes = 65_536

fn serve_reserved(
  server: Server(context),
  context: context,
  runtime_config: runtime.Config,
  write_timeout_ms: Int,
  max_unframed_bytes: Int,
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
      let reader = start_reader(max_unframed_bytes)
      let outcome = read_loop(rt, context, reader, writer, framer, write_errors)
      process.kill(reader.pid)
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
  Stdin(Input)
  WriteFailed(StdioError)
  ReaderDown
}

// What the reader sends the serving process.
type Input {
  Read(ReadOutcome)
  /// More than the limit waited unframed; the reader has stopped.
  Overflowed(limit: Int)
}

type Reader {
  Reader(pid: Pid, input: Subject(Input), framed: Subject(Int))
}

// The reader owns the standard input port; the port closes when it exits.
// It counts the bytes it has sent and the serving process has not yet
// reported framed, and stops reading when they pass `limit`, so the input
// waiting in either mailbox stays bounded.
fn start_reader(limit: Int) -> Reader {
  let input = process.new_subject()
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let framed = process.new_subject()
      process.send(ready, framed)
      read_forever(input, framed, 0, limit)
    })
  let framed = process.receive_forever(ready)
  Reader(pid, input, framed)
}

fn read_forever(
  input: Subject(Input),
  framed: Subject(Int),
  unframed: Int,
  limit: Int,
) -> Nil {
  case read_stdin() {
    stdio_frames.ReadChunk(chunk) as outcome -> {
      let unframed =
        subtract_framed(framed, unframed) + bit_array.byte_size(chunk)
      case unframed > limit {
        True -> process.send(input, Overflowed(limit))
        False -> {
          process.send(input, Read(outcome))
          read_forever(input, framed, unframed, limit)
        }
      }
    }
    outcome -> process.send(input, Read(outcome))
  }
}

fn subtract_framed(framed: Subject(Int), unframed: Int) -> Int {
  case process.receive(framed, 0) {
    Ok(bytes) -> subtract_framed(framed, unframed - bytes)
    Error(Nil) -> unframed
  }
}

fn read_loop(
  rt: Runtime(context),
  context: context,
  reader: Reader,
  writer: Writer,
  framer: Framer,
  write_errors: Subject(StdioError),
) -> Result(Nil, StdioError) {
  let monitor = process.monitor(reader.pid)
  let selector =
    process.new_selector()
    |> process.select_map(reader.input, Stdin)
    |> process.select_map(write_errors, WriteFailed)
    |> process.select_specific_monitor(monitor, fn(_) { ReaderDown })
  loop(rt, context, reader, writer, framer, selector)
}

fn loop(
  rt: Runtime(context),
  context: context,
  reader: Reader,
  writer: Writer,
  framer: Framer,
  selector: process.Selector(Signal),
) -> Result(Nil, StdioError) {
  case process.selector_receive_forever(selector) {
    Stdin(Read(stdio_frames.ReadChunk(chunk))) -> {
      let #(framer, frames) = stdio_frames.feed_framer(framer, chunk)
      use _ <- result.try(submit(rt, context, writer, frames))
      process.send(reader.framed, bit_array.byte_size(chunk))
      loop(rt, context, reader, writer, framer, selector)
    }
    Stdin(Overflowed(limit)) -> Error(UnframedInputTooLarge(limit))
    Stdin(Read(stdio_frames.ReadEof)) ->
      case stdio_frames.finish_framer(framer) {
        [InvalidTrailingBytes(rest), ..] -> {
          emit.frame_rejected(0, telemetry.TrailingBytes, None)
          Error(InvalidTrailingData(rest))
        }
        _ -> Ok(Nil)
      }
    Stdin(Read(stdio_frames.ReadFailed(_))) -> Error(ReadFailed)
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
