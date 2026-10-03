//// Serves an MCP server over standard input and output.
////
//// `serve(server, context)` reads newline-delimited JSON-RPC frames from
//// standard input until it closes, writes replies to standard output, and
//// keeps standard output free of anything else. It blocks the calling
//// process, which is usually `main`. `serve_with` takes a `Config` for the
//// read chunk size and the runtime limits (`relay/runtime.config`). The
//// stdio transport enforces no authorization: run it only under a trusted
//// parent process. A client launches such a server with
//// `relay/client.stdio`.
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
//// | Setting | Default | Setter |
//// | --- | --- | --- |
//// | read chunk | 4 KiB | `with_chunk_size` |
//// | frame, depth, handler limits | `relay/runtime.config()` | `with_runtime` |

import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{None}
import gleam/result
import relay/internal/emit
import relay/internal/stdio_frames.{
  type Framer, type ReadOutcome, type Writer, Frame, FrameOversized,
  InvalidTrailingBytes,
}
import relay/reducer
import relay/runtime.{type Runtime}
import relay/server.{type Server}
import relay/telemetry

/// Stdio settings. Build with `config()` and the `with_*` setters.
pub opaque type Config {
  Config(chunk_size: Int, runtime: runtime.Config)
}

/// A 4 KiB read chunk and the default runtime limits.
pub fn config() -> Config {
  Config(chunk_size: 4096, runtime: runtime.config())
}

/// The largest chunk read from standard input at once.
pub fn with_chunk_size(config: Config, bytes: Int) -> Config {
  Config(..config, chunk_size: bytes)
}

/// The runtime limits: frame size, nesting depth, handler timeout and the
/// rest of `relay/runtime.Config`.
pub fn with_runtime(config: Config, runtime: runtime.Config) -> Config {
  Config(..config, runtime: runtime)
}

/// Why `serve` stopped with an error.
pub type StdioError {
  InvalidChunkSize(size: Int)
  InvalidRuntimeConfig(field: runtime.ConfigField)
  /// Standard input could not be switched to binary mode or read.
  ReadFailed
  /// Standard output was closed or failed while writing a reply.
  StdoutBroken
  StartupFailed
  /// Standard input ended in the middle of a frame.
  InvalidTrailingData(bytes: BitArray)
}

/// A one-line description of a stdio error.
pub fn describe_error(error: StdioError) -> String {
  case error {
    InvalidChunkSize(_) -> "the stdio read chunk size must be positive"
    InvalidRuntimeConfig(_) -> "a stdio runtime setting is out of range"
    ReadFailed -> "standard input could not be read"
    StdoutBroken -> "standard output failed while writing a reply"
    StartupFailed -> "the stdio server failed to start"
    InvalidTrailingData(_) -> "standard input ended in the middle of a frame"
  }
}

@external(erlang, "relay_ffi", "set_stdio_binary")
fn set_stdio_binary() -> Result(Nil, String)

@external(erlang, "relay_ffi", "close_stdin")
fn close_stdin() -> Nil

@external(erlang, "relay_ffi", "read_stdin")
fn read_stdin(chunk_size: Int) -> ReadOutcome

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
  use _ <- result.try(case config.chunk_size > 0 {
    True -> Ok(Nil)
    False -> Error(InvalidChunkSize(config.chunk_size))
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
  use _ <- result.try(set_stdio_binary() |> result.replace_error(ReadFailed))
  use writer <- result.try(case stdio_frames.start_writer(write_stdout) {
    Ok(writer) -> Ok(writer)
    Error(_) -> {
      close_stdin()
      Error(StartupFailed)
    }
  })
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
  case runtime.start(server, runtime_config, sink) {
    Error(_) -> {
      stdio_frames.stop_writer(writer)
      close_stdin()
      Error(StartupFailed)
    }
    Ok(rt) -> {
      let framer =
        stdio_frames.new_framer(runtime.max_frame_bytes(runtime_config))
      let reader = start_reader(config.chunk_size)
      let outcome = read_loop(rt, context, reader, writer, framer, write_errors)
      process.kill(reader.0)
      runtime.close(rt)
      runtime.stop(rt)
      stdio_frames.stop_writer(writer)
      close_stdin()
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

fn start_reader(chunk_size: Int) -> #(Pid, Subject(ReadOutcome)) {
  let subject = process.new_subject()
  let pid = process.spawn_unlinked(fn() { read_forever(subject, chunk_size) })
  #(pid, subject)
}

fn read_forever(subject: Subject(ReadOutcome), chunk_size: Int) -> Nil {
  let outcome = read_stdin(chunk_size)
  process.send(subject, outcome)
  case outcome {
    stdio_frames.ReadChunk(_) -> read_forever(subject, chunk_size)
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

const too_large = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Frame too large\"}}\n"

const too_deep = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"JSON nesting exceeds the configured depth\"}}\n"

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
            Error(_) -> Ok(Nil)
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
  stdio_frames.write_bytes(writer, bit_array.from_string(line))
  |> result.replace_error(StdoutBroken)
}
