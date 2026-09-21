import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import relay/runtime.{type Runtime, type RuntimeConfig}
import relay/server.{type Server}
import relay/telemetry

pub type StdioError {
  IoError(String)
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
  Framer(buffer: BitArray, max_frame_bytes: Int)
}

/// Constructs a new framer with a maximum line byte limit.
pub fn new_framer(max_frame_bytes: Int) -> Framer {
  Framer(buffer: <<>>, max_frame_bytes: max_frame_bytes)
}

/// Feeds a chunk of bytes to the framer and extracts all complete newline-delimited frames.
pub fn feed_framer(
  framer: Framer,
  chunk: BitArray,
) -> #(Framer, List(FramerResult)) {
  let combined = bit_array.append(framer.buffer, chunk)
  let #(remaining, frames) =
    extract_frames(combined, framer.max_frame_bytes, [])
  #(Framer(buffer: remaining, max_frame_bytes: framer.max_frame_bytes), frames)
}

/// Finishes the framer at EOF, reporting any trailing bytes without newline.
pub fn finish_framer(framer: Framer) -> List(FramerResult) {
  case bit_array.byte_size(framer.buffer) {
    0 -> []
    _ -> [InvalidTrailingBytes(framer.buffer)]
  }
}

fn extract_frames(
  bytes: BitArray,
  max_frame_bytes: Int,
  acc: List(FramerResult),
) -> #(BitArray, List(FramerResult)) {
  case find_newline(bytes, 0) {
    None -> {
      let size = bit_array.byte_size(bytes)
      case size > max_frame_bytes {
        True -> #(
          <<>>,
          list.reverse([FrameOversized(size, max_frame_bytes), ..acc]),
        )
        False -> #(bytes, list.reverse(acc))
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
fn ffi_set_stdio_binary() -> Nil

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
  ffi_set_stdio_binary()

  let assert Ok(writer) =
    start_writer(fn(bytes) {
      case ffi_write_stdout(bytes) {
        Ok(Nil) -> Ok(Nil)
        Error(err) -> Error(IoError(err))
      }
    })

  let write_sink = fn(bytes) {
    let _ = write_bytes(writer, bytes)
    Nil
  }

  let assert Ok(rt) = runtime.start(server, config.runtime_config, write_sink)

  let framer = new_framer(config.runtime_config.max_frame_bytes)

  let loop_res =
    stream_read_loop(
      rt,
      context,
      fn() { ffi_read_stdin(config.chunk_size) },
      writer,
      framer,
      config.runtime_config.invocation_timeout_ms,
    )

  runtime.close(rt)
  runtime.stop(rt, 1000)
  stop_writer(writer)

  loop_res
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
  case reader() {
    ReadChunk(chunk) -> {
      let #(next_framer, frames) = feed_framer(framer, chunk)
      handle_extracted_frames(rt, context, writer, frames, timeout_ms)
      stream_read_loop(rt, context, reader, writer, next_framer, timeout_ms)
    }
    ReadEof -> {
      let trailing = finish_framer(framer)
      case trailing {
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
    ReadFailed(err) -> Error(IoError(err))
  }
}

fn handle_extracted_frames(
  rt: Runtime(context),
  context: context,
  writer: Writer,
  frames: List(FramerResult),
  timeout_ms: Int,
) -> Nil {
  list.each(frames, fn(fr) {
    case fr {
      Frame(bytes) -> {
        let ex = server.fresh_exchange()
        case runtime.send_frame(rt, ex, context, bytes, timeout_ms) {
          Ok(Nil) -> Nil
          Error(runtime.FrameTooLarge(_size, _limit)) -> {
            let _ =
              write_bytes(
                writer,
                bit_array.from_string(
                  "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Frame too large\"}}\n",
                ),
              )
            Nil
          }
          Error(_) -> Nil
        }
      }
      FrameOversized(_size, _limit) -> {
        telemetry.emit_frame_rejected(0, "oversized frame")
        let _ =
          write_bytes(
            writer,
            bit_array.from_string(
              "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Frame too large\"}}\n",
            ),
          )
        Nil
      }
      InvalidTrailingBytes(_) -> Nil
    }
  })
}
