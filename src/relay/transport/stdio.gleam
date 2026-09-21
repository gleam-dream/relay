import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import relay/runtime.{type Runtime, type RuntimeConfig}
import relay/server.{type Server}
import relay/telemetry

pub type StdioError {
  IoError(String)
  StdoutBroken(String)
  StartupFailed(String)
  OversizedFrame(size: Int, limit: Int)
  InvalidTrailingData(BitArray)
}

pub type ReadOutcome {
  ReadChunk(BitArray)
  ReadEof
  ReadFailed(String)
}

pub type FramerResult {
  Frame(BitArray)
  FrameOversized(size: Int, limit: Int)
  InvalidTrailingBytes(BitArray)
}

pub opaque type Framer {
  Framer(buffer: BitArray, max_frame_bytes: Int, dropping_oversized_tail: Bool)
}

/// Constructs a new framer with a maximum line byte limit.
pub fn new_framer(max_frame_bytes: Int) -> Framer {
  Framer(
    buffer: <<>>,
    max_frame_bytes: max_frame_bytes,
    dropping_oversized_tail: False,
  )
}

/// Feeds a chunk of bytes to the framer and extracts all complete newline-delimited frames.
pub fn feed_framer(
  framer: Framer,
  chunk: BitArray,
) -> #(Framer, List(FramerResult)) {
  let #(input, still_dropping) =
    discard_oversized_tail(framer.dropping_oversized_tail, chunk)
  case still_dropping {
    True -> #(
      Framer(
        buffer: <<>>,
        max_frame_bytes: framer.max_frame_bytes,
        dropping_oversized_tail: True,
      ),
      [],
    )
    False -> {
      let combined = bit_array.append(framer.buffer, input)
      let #(remaining, frames, dropping_tail) =
        extract_frames(combined, framer.max_frame_bytes, [])
      #(
        Framer(
          buffer: remaining,
          max_frame_bytes: framer.max_frame_bytes,
          dropping_oversized_tail: dropping_tail,
        ),
        frames,
      )
    }
  }
}

/// Finishes the framer at EOF, reporting any trailing bytes without newline.
pub fn finish_framer(framer: Framer) -> List(FramerResult) {
  case framer.dropping_oversized_tail {
    True -> []
    False ->
      case bit_array.byte_size(framer.buffer) {
        0 -> []
        _ -> [InvalidTrailingBytes(framer.buffer)]
      }
  }
}

fn extract_frames(
  bytes: BitArray,
  max_frame_bytes: Int,
  acc: List(FramerResult),
) -> #(BitArray, List(FramerResult), Bool) {
  case find_newline(bytes, 0) {
    None -> {
      let size = bit_array.byte_size(bytes)
      case size > max_frame_bytes {
        True -> #(
          <<>>,
          list.reverse([FrameOversized(size, max_frame_bytes), ..acc]),
          True,
        )
        False -> #(bytes, list.reverse(acc), False)
      }
    }
    Some(idx) -> {
      let assert Ok(line) = bit_array.slice(bytes, 0, idx)
      let total_len = bit_array.byte_size(bytes)
      let assert Ok(rest) = bit_array.slice(bytes, idx + 1, total_len - idx - 1)
      let clean_line = strip_trailing_cr(line)
      let size = bit_array.byte_size(clean_line)
      let res = case size > max_frame_bytes {
        True -> FrameOversized(size, max_frame_bytes)
        False -> Frame(clean_line)
      }
      extract_frames(rest, max_frame_bytes, [res, ..acc])
    }
  }
}

fn discard_oversized_tail(
  dropping: Bool,
  chunk: BitArray,
) -> #(BitArray, Bool) {
  case dropping {
    False -> #(chunk, False)
    True ->
      case find_newline(chunk, 0) {
        None -> #(<<>>, True)
        Some(idx) -> {
          let total_len = bit_array.byte_size(chunk)
          let assert Ok(rest) =
            bit_array.slice(chunk, idx + 1, total_len - idx - 1)
          #(rest, False)
        }
      }
  }
}

fn find_newline(bytes: BitArray, offset: Int) -> Option(Int) {
  case bytes {
    <<10, _:bytes>> -> Some(offset)
    <<_, rest:bytes>> -> find_newline(rest, offset + 1)
    _ -> None
  }
}

fn strip_trailing_cr(line: BitArray) -> BitArray {
  let len = bit_array.byte_size(line)
  case len > 0 {
    True -> {
      let last_idx = len - 1
      case bit_array.slice(line, last_idx, 1) {
        Ok(<<13>>) -> {
          let assert Ok(trimmed) = bit_array.slice(line, 0, last_idx)
          trimmed
        }
        _ -> line
      }
    }
    False -> line
  }
}

// Dedicated serialized writer actor

pub type WriterMessage {
  WriteBytes(bytes: BitArray, reply: Subject(Result(Nil, StdioError)))
  CloseWriter(reply: Subject(Nil))
}

pub opaque type Writer {
  Writer(subject: Subject(WriterMessage))
}

type StdinReader {
  StdinReader(pid: Pid, subject: Subject(ReadOutcome))
}

type StdioSignal {
  StdinSignal(ReadOutcome)
  WriterSignal(StdioError)
  StdinReaderDown(process.Down)
}

pub fn start_writer(
  sink: fn(BitArray) -> Result(Nil, StdioError),
) -> Result(Writer, actor.StartError) {
  let builder =
    actor.new(Nil)
    |> actor.on_message(fn(_state, msg) {
      case msg {
        WriteBytes(bytes, reply) -> {
          let res = sink(bytes)
          process.send(reply, res)
          actor.continue(Nil)
        }
        CloseWriter(reply) -> {
          process.send(reply, Nil)
          actor.stop()
        }
      }
    })

  case actor.start(builder) {
    Ok(started) -> Ok(Writer(started.data))
    Error(err) -> Error(err)
  }
}

pub fn write_bytes(writer: Writer, bytes: BitArray) -> Result(Nil, StdioError) {
  let Writer(subj) = writer
  process.call(subj, waiting: 5000, sending: fn(reply) {
    WriteBytes(bytes, reply)
  })
}

pub fn stop_writer(writer: Writer) -> Nil {
  let Writer(subj) = writer
  process.call(subj, waiting: 5000, sending: CloseWriter)
}

// Configuration for explicitly local unprotected stdio transport

pub type LocalUnprotectedStdioConfig {
  LocalUnprotectedStdioConfig(chunk_size: Int, runtime_config: RuntimeConfig)
}

pub fn default_stdio_config() -> LocalUnprotectedStdioConfig {
  LocalUnprotectedStdioConfig(
    chunk_size: 4096,
    runtime_config: runtime.default_config(),
  )
}

@external(erlang, "relay_ffi", "set_stdio_binary")
fn ffi_set_stdio_binary() -> Result(Nil, String)

@external(erlang, "relay_ffi", "close_stdin")
fn ffi_close_stdin() -> Nil

@external(erlang, "relay_ffi", "read_stdin")
fn ffi_read_stdin(chunk_size: Int) -> ReadOutcome

@external(erlang, "relay_ffi", "write_stdout")
fn ffi_write_stdout(bytes: BitArray) -> Result(Nil, String)

@external(erlang, "relay_ffi", "write_stderr")
fn ffi_write_stderr(bytes: BitArray) -> Result(Nil, String)

/// Writes diagnostic information to isolated standard error (never standard output).
pub fn log_stderr(message: String) -> Nil {
  let _ = ffi_write_stderr(bit_array.from_string(message <> "\n"))
  Nil
}

/// Runs a local unprotected stdio server over standard input/output.
pub fn run_local_unprotected_stdio_server(
  server: Server(context),
  config: LocalUnprotectedStdioConfig,
  context: context,
) -> Result(Nil, StdioError) {
  use _ <- result.try(case ffi_set_stdio_binary() {
    Ok(Nil) -> Ok(Nil)
    Error(err) -> Error(IoError(err))
  })

  use writer <- result.try(
    case
      start_writer(fn(bytes) {
        case ffi_write_stdout(bytes) {
          Ok(Nil) -> Ok(Nil)
          Error(err) -> Error(StdoutBroken(err))
        }
      })
    {
      Ok(w) -> Ok(w)
      Error(err) -> {
        ffi_close_stdin()
        Error(StartupFailed(string.inspect(err)))
      }
    },
  )

  let write_error_box = process.new_subject()
  let write_sink = fn(bytes) {
    case write_bytes(writer, bytes) {
      Ok(Nil) -> Nil
      Error(err) -> {
        process.send(write_error_box, err)
        Nil
      }
    }
  }

  use rt <- result.try(
    case runtime.start(server, config.runtime_config, write_sink) {
      Ok(r) -> Ok(r)
      Error(err) -> {
        stop_writer(writer)
        ffi_close_stdin()
        Error(StartupFailed(string.inspect(err)))
      }
    },
  )

  let framer = new_framer(config.runtime_config.max_frame_bytes)
  let reader = start_stdin_reader(config.chunk_size)

  let loop_res =
    select_stdio_loop(
      rt,
      context,
      reader,
      writer,
      framer,
      config.runtime_config.invocation_timeout_ms,
      write_error_box,
    )

  stop_stdin_reader(reader)
  runtime.close(rt)
  runtime.stop(rt, 1000)
  stop_writer(writer)
  ffi_close_stdin()

  case loop_res {
    Error(err) -> Error(err)
    Ok(Nil) ->
      case process.receive(write_error_box, 0) {
        Ok(err) -> Error(err)
        Error(Nil) -> Ok(Nil)
      }
  }
}

fn start_stdin_reader(chunk_size: Int) -> StdinReader {
  let subject = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() { read_stdin_forever(subject, chunk_size) })
  StdinReader(pid, subject)
}

fn read_stdin_forever(subject: Subject(ReadOutcome), chunk_size: Int) -> Nil {
  let outcome = ffi_read_stdin(chunk_size)
  process.send(subject, outcome)
  case outcome {
    ReadChunk(_) -> read_stdin_forever(subject, chunk_size)
    ReadEof | ReadFailed(_) -> Nil
  }
}

fn stop_stdin_reader(reader: StdinReader) -> Nil {
  let StdinReader(pid, _) = reader
  process.kill(pid)
}

fn select_stdio_loop(
  rt: Runtime(context),
  context: context,
  reader: StdinReader,
  writer: Writer,
  framer: Framer,
  timeout_ms: Int,
  writer_errors: Subject(StdioError),
) -> Result(Nil, StdioError) {
  let StdinReader(reader_pid, reader_subject) = reader
  let reader_monitor = process.monitor(reader_pid)
  let selector =
    process.new_selector()
    |> process.select_map(reader_subject, StdinSignal)
    |> process.select_map(writer_errors, WriterSignal)
    |> process.select_specific_monitor(reader_monitor, StdinReaderDown)
  select_stdio_events(
    rt,
    context,
    writer,
    framer,
    timeout_ms,
    writer_errors,
    selector,
  )
}

fn select_stdio_events(
  rt: Runtime(context),
  context: context,
  writer: Writer,
  framer: Framer,
  timeout_ms: Int,
  writer_errors: Subject(StdioError),
  selector: process.Selector(StdioSignal),
) -> Result(Nil, StdioError) {
  case process.selector_receive_forever(selector) {
    StdinSignal(ReadChunk(chunk)) -> {
      let #(next_framer, frames) = feed_framer(framer, chunk)
      use _ <- result.try(handle_extracted_frames(
        rt,
        context,
        writer,
        frames,
        timeout_ms,
      ))
      use _ <- result.try(check_writer_error(Some(writer_errors)))
      select_stdio_events(
        rt,
        context,
        writer,
        next_framer,
        timeout_ms,
        writer_errors,
        selector,
      )
    }
    StdinSignal(ReadEof) -> {
      use _ <- result.try(check_writer_error(Some(writer_errors)))
      case finish_framer(framer) {
        [] -> Ok(Nil)
        [InvalidTrailingBytes(rem)] -> {
          telemetry.emit_frame_rejected(
            0,
            "incomplete trailing bytes at EOF without newline",
          )
          Error(InvalidTrailingData(rem))
        }
        _ -> Ok(Nil)
      }
    }
    StdinSignal(ReadFailed(reason)) -> {
      use _ <- result.try(check_writer_error(Some(writer_errors)))
      Error(IoError(reason))
    }
    WriterSignal(err) -> Error(err)
    StdinReaderDown(_) -> Error(IoError("stdin reader exited unexpectedly"))
  }
}

/// Generic stream read loop for testing and real stdio transport.
pub fn stream_read_loop(
  rt: Runtime(context),
  context: context,
  reader: fn() -> ReadOutcome,
  writer: Writer,
  framer: Framer,
  timeout_ms: Int,
) -> Result(Nil, StdioError) {
  stream_read_loop_inner(rt, context, reader, writer, framer, timeout_ms, None)
}

fn stream_read_loop_inner(
  rt: Runtime(context),
  context: context,
  reader: fn() -> ReadOutcome,
  writer: Writer,
  framer: Framer,
  timeout_ms: Int,
  write_error_box: Option(Subject(StdioError)),
) -> Result(Nil, StdioError) {
  case reader() {
    ReadChunk(chunk) -> {
      let #(next_framer, frames) = feed_framer(framer, chunk)
      use _ <- result.try(handle_extracted_frames(
        rt,
        context,
        writer,
        frames,
        timeout_ms,
      ))
      use _ <- result.try(check_writer_error(write_error_box))
      stream_read_loop_inner(
        rt,
        context,
        reader,
        writer,
        next_framer,
        timeout_ms,
        write_error_box,
      )
    }
    ReadEof -> {
      let trailing = finish_framer(framer)
      case trailing {
        [] -> check_writer_error(write_error_box)
        [InvalidTrailingBytes(rem)] -> {
          telemetry.emit_frame_rejected(
            0,
            "incomplete trailing bytes at EOF without newline",
          )
          Error(InvalidTrailingData(rem))
        }
        _ -> Ok(Nil)
      }
    }
    ReadFailed(err) -> {
      use _ <- result.try(check_writer_error(write_error_box))
      Error(IoError(err))
    }
  }
}

fn check_writer_error(
  write_error_box: Option(Subject(StdioError)),
) -> Result(Nil, StdioError) {
  case write_error_box {
    None -> Ok(Nil)
    Some(box) ->
      case process.receive(box, 0) {
        Ok(err) -> Error(err)
        Error(Nil) -> Ok(Nil)
      }
  }
}

fn handle_extracted_frames(
  rt: Runtime(context),
  context: context,
  writer: Writer,
  frames: List(FramerResult),
  timeout_ms: Int,
) -> Result(Nil, StdioError) {
  case frames {
    [] -> Ok(Nil)
    [fr, ..rest] -> {
      use _ <- result.try(case fr {
        Frame(bytes) -> {
          let ex = server.fresh_exchange()
          case runtime.send_frame(rt, ex, context, bytes, timeout_ms) {
            Ok(Nil) -> Ok(Nil)
            Error(runtime.FrameTooLarge(_size, _limit)) -> {
              write_bytes(
                writer,
                bit_array.from_string(
                  "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Frame too large\"}}\n",
                ),
              )
            }
            Error(_) -> Ok(Nil)
          }
        }
        FrameOversized(_size, _limit) -> {
          telemetry.emit_frame_rejected(0, "oversized frame")
          write_bytes(
            writer,
            bit_array.from_string(
              "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Frame too large\"}}\n",
            ),
          )
        }
        InvalidTrailingBytes(_) -> Ok(Nil)
      })
      handle_extracted_frames(rt, context, writer, rest, timeout_ms)
    }
  }
}
